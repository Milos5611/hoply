import AgentKit
import Foundation

public struct IngestUpdate: Sendable, Equatable {
    public var progress: IngestProgress
    /// Sessions whose ledger rows or metadata changed since the previous update.
    public var changedSessions: Set<SessionKey>
}

/// Owns ledger ingestion. Claude transcripts: backfill (newest files first), FSEvents tailing, a periodic
/// stat-only rescan, and immediate tails requested by hooks; files are processed one at a time, so a file's
/// cursor and turn count are never updated by two readers at once. Copilot CLI's session store: polled, and
/// read only when the database or its WAL changed. Telemetry usage (Copilot IDE, Qwen Code): recorded as it
/// arrives. All three report through `updates`.
public actor IngestCoordinator {
    /// Single consumer. Progress during backfill is throttled to about four updates a second.
    public nonisolated let updates: AsyncStream<IngestUpdate>
    public private(set) var progress = IngestProgress()

    private let continuation: AsyncStream<IngestUpdate>.Continuation
    private let store: Store
    private let claude: ClaudeTranscriptIngester
    private let copilot: CopilotStoreIngester?
    private let watch: Bool
    private let rescanInterval: Duration
    private let copilotPollInterval: Duration
    private let copilotBatchSize: Int
    private let chunkBytes: Int
    private var cursors: [String: FileCursor] = [:]
    private var pending: [String] = []
    private var backfillRemaining: Set<String> = []
    private var pendingChanges: Set<SessionKey> = []
    private var draining = false
    private var cursorResets = 0
    private var started = false
    private var stopped = false
    private var runGeneration = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var watcher: DirectoryWatcher?
    private var rescanTask: Task<Void, Never>?
    private var lastEmit: ContinuousClock.Instant?
    private var copilotCursor: FileCursor?
    private var copilotSignature: CopilotStoreIngester.Signature?
    /// The session rows last written, so a poll only rewrites sessions whose metadata moved.
    private var copilotSessions: [String: CopilotSession] = [:]
    private var copilotPolling = false
    private var copilotTask: Task<Void, Never>?
    private var recording = 0
    private var telemetryCwds: [SessionKey: String] = [:]

    public init(store: Store, claude: ClaudeTranscriptIngester = ClaudeTranscriptIngester(),
                copilot: CopilotStoreIngester? = nil, watch: Bool = true, rescanInterval: Duration = .seconds(60),
                copilotPollInterval: Duration = .seconds(10), copilotBatchSize: Int = 500, chunkBytes: Int = 4 << 20) {
        self.store = store
        self.claude = claude
        self.copilot = copilot
        self.watch = watch
        self.rescanInterval = rescanInterval
        self.copilotPollInterval = copilotPollInterval
        self.copilotBatchSize = max(copilotBatchSize, 1)
        self.chunkBytes = chunkBytes
        (updates, continuation) = AsyncStream.makeStream(of: IngestUpdate.self)
    }

    deinit {
        watcher?.stop()
        rescanTask?.cancel()
        copilotTask?.cancel()
        continuation.finish()
    }

    /// Loads cursors, starts watching and polling, reads Copilot's store once, then backfills transcripts.
    /// Returns when the backfill queue is empty.
    public func start() async {
        guard !started else { return }
        started = true
        stopped = false
        let generation = runGeneration
        do {
            cursors = try await store.cursors(source: .claudeCode)
            if let copilot { copilotCursor = try await store.cursors(source: .copilotCLI)[copilot.databasePath] }
        } catch {
            progress.lastError = "Could not read ingest cursors: \(error)"
        }
        guard generation == runGeneration else { return }
        if watch {
            startWatcher()
            let interval = rescanInterval
            rescanTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    await self.rescan()
                }
            }
            if copilot != nil {
                let interval = copilotPollInterval
                copilotTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: interval)
                        guard !Task.isCancelled, let self else { return }
                        await self.pollCopilot()
                    }
                }
            }
        }
        // Runs at the backfill's first suspension, so its progress update still comes first.
        let initialPoll = Task { await self.pollCopilot() }
        await backfill()
        await initialPoll.value
    }

    /// Stops watching and rescanning, drops queued files and ends in-flight reads after their current batch,
    /// so a half-read file keeps the cursor of its last committed batch. Returns once nothing is writing; later
    /// calls are ignored until the next `start()`.
    public func stop() async {
        stopped = true
        started = false
        runGeneration += 1
        watcher?.stop()
        watcher = nil
        rescanTask?.cancel()
        rescanTask = nil
        copilotTask?.cancel()
        copilotTask = nil
        pending.removeAll()
        if isBusy {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        backfillRemaining.removeAll()
        if progress.isBackfilling {
            progress.isBackfilling = false
            emit(force: true)
        }
    }

    /// A hook reported this transcript (`transcript_path`): read its new lines ahead of everything else.
    /// Paths outside the configured Claude directory are ignored, since backfill and rescans never see them.
    public func tailTranscript(atPath path: String) async {
        let canonical = ClaudeTranscriptIngester.canonical(path)
        guard !stopped, claude.isTranscript(canonical) else { return }
        pending.removeAll { $0 == canonical }
        pending.insert(canonical, at: 0)
        await drain()
    }

    /// Stat-only pass over all transcripts; anything whose size or inode moved is read.
    public func rescan() async {
        guard !stopped else { return }
        if watch, watcher?.isRunning != true { startWatcher() }
        for file in claude.discover() where needsWork(file) { enqueue(file.path) }
        await drain()
    }

    /// Re-reads every transcript and Copilot's whole store. Only cursors are reset; ledger rows are never deleted.
    public func reindex() async {
        guard !stopped else { return }
        cursorResets += 1
        // New polls wait for the reset; one already running must not save its cursor or signature after it.
        while copilotPolling { try? await Task.sleep(for: .milliseconds(10)) }
        var reset = false
        do {
            try await store.resetCursors(source: .claudeCode)
            cursors = try await store.cursors(source: .claudeCode)
            if let copilot {
                try await store.resetCursors(source: .copilotCLI)
                copilotCursor = try await store.cursors(source: .copilotCLI)[copilot.databasePath]
                copilotSignature = nil
                copilotSessions = [:]
            }
            reset = true
        } catch {
            progress.lastError = "Reindex failed: \(error)"
            emit(force: true)
        }
        cursorResets -= 1
        resumeIdleWaiters()
        if reset {
            await pollCopilot()
            await backfill()
        }
    }

    /// For tests and shutdown: waits until queued files, a Copilot poll and telemetry writes are done.
    public func waitUntilIdle() async {
        while isBusy || !pending.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Copilot CLI

    /// Reads new rows from Copilot CLI's session store, if its database or WAL changed since the last read.
    /// Runs every 10 s while started; call it when a Copilot CLI hook arrives to pick up a turn sooner.
    public func pollCopilot() async {
        guard let copilot, started, !stopped, !copilotPolling, cursorResets == 0 else { return }
        let signature = copilot.signature()
        guard signature != copilotSignature else { return }
        copilotPolling = true
        let generation = runGeneration
        let previous = progress.copilot
        var status: CopilotStoreStatus
        do {
            let schemaVersion = try await readCopilot(copilot, signature: signature, generation: generation)
            status = .ready(schemaVersion: schemaVersion)
            if generation == runGeneration { copilotSignature = signature }
        } catch let error as CopilotStoreError {
            switch error {
            case .notFound:
                status = .notFound
                copilotSignature = signature
            case .unsupported(let detail):
                status = .unsupported(detail)
                copilotSignature = signature
            case .changedWhileReading:
                status = progress.copilot
            }
        } catch {
            status = .failed("\(error)")
        }
        copilotPolling = false
        resumeIdleWaiters()
        progress.copilot = status
        if previous != status || !pendingChanges.isEmpty { emit(force: true) }
    }

    /// Returns the store's schema version. Each batch is written with its cursor (the last event id) in one
    /// transaction. A lower maximum id than the cursor, or a new inode, means the database was recreated, so
    /// reading restarts at 0; the upserts make that safe.
    private func readCopilot(_ copilot: CopilotStoreIngester, signature: CopilotStoreIngester.Signature,
                             generation: Int) async throws -> Int? {
        let connection = try copilot.open()
        let database = signature.database ?? FileStat(inode: 0, size: 0, modified: .distantPast)
        var after = copilotCursor?.offset ?? 0
        if let cursor = copilotCursor, cursor.inode != database.inode { after = 0 }
        if try connection.maxEventID() < after { after = 0 }
        while !stopped, generation == runGeneration {
            let events = try connection.events(after: after, limit: copilotBatchSize)
            guard let last = events.last else { break }
            let sessions = try connection.sessions(ids: Array(Set(events.map(\.sessionID))))
            let file = FileCursor(inode: database.inode, size: database.size, offset: last.id, headHash: 0)
            let changed = try await store.apply(CopilotUsageMapper.batch(events: events, sessions: sessions),
                                                cursor: IngestCursor(source: .copilotCLI, path: copilot.databasePath,
                                                                     file: file))
            after = last.id
            copilotCursor = file
            pendingChanges.formUnion(changed)
            copilotSessions.merge(sessions) { _, new in new }
            if events.count < copilotBatchSize { break }
        }
        guard !stopped, generation == runGeneration else { return connection.schemaVersion }
        let moved = try connection.sessions().values.filter { copilotSessions[$0.id] != $0 }.sorted { $0.id < $1.id }
        if !moved.isEmpty {
            pendingChanges.formUnion(try await store.apply(LedgerBatch(sessions: moved.map {
                CopilotUsageMapper.sessionUpdate($0)
            })))
            for session in moved { copilotSessions[session.id] = session }
        }
        return connection.schemaVersion
    }

    // MARK: - Telemetry

    /// Persists telemetry usage for sources whose ledger is their OTel (others are dropped). A record without
    /// a cwd gets its session's known cwd, else its process's (`process.pid`), else stays "Unassigned".
    public func record(_ usage: [UsageRecord]) async {
        var records = usage.filter { UsageAuthority.persistsTelemetry(from: $0.source) }
        guard !records.isEmpty, !stopped else { return }
        recording += 1
        for record in records {
            if let cwd = record.cwd { telemetryCwds[SessionKey(source: record.source, id: record.sessionID)] = cwd }
        }
        for index in records.indices where records[index].cwd == nil {
            let key = SessionKey(source: records[index].source, id: records[index].sessionID)
            if let known = telemetryCwds[key] {
                records[index].cwd = known
            } else if let pid = records[index].processID,
                      let cwd = ProcessDirectory.cwd(of: pid, notStartedAfter: records[index].timestamp) {
                records[index].cwd = cwd
                telemetryCwds[key] = cwd
            }
        }
        do {
            pendingChanges.formUnion(try await store.apply(TelemetryUsage.ledgerBatch(records)))
        } catch {
            progress.lastError = "Telemetry usage: \(error)"
        }
        recording -= 1
        resumeIdleWaiters()
        emit(force: true)
    }

    // MARK: - Work queue

    private func backfill() async {
        guard !stopped else { return }
        let work = claude.discover().filter(needsWork)
        backfillRemaining = Set(work.map(\.path))
        progress = IngestProgress(filesDone: 0, filesTotal: work.count, bytesDone: 0,
                                  bytesTotal: work.reduce(0) { $0 + unreadBytes($1) }, isBackfilling: !work.isEmpty,
                                  lastError: progress.lastError, copilot: progress.copilot)
        emit(force: true)
        for file in work { enqueue(file.path) }
        await drain()
    }

    private func enqueue(_ path: String) {
        if !stopped, !pending.contains(path) { pending.append(path) }
    }

    private func drain() async {
        guard !draining, !stopped else { return }
        draining = true
        while !pending.isEmpty, !stopped {
            await process(pending.removeFirst())
        }
        draining = false
        resumeIdleWaiters()
        if progress.isBackfilling, backfillRemaining.isEmpty { progress.isBackfilling = false }
        emit(force: true)
    }

    private var isBusy: Bool { draining || cursorResets > 0 || copilotPolling || recording > 0 }

    private func resumeIdleWaiters() {
        guard !isBusy else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func process(_ path: String) async {
        let inBackfill = backfillRemaining.contains(path)
        var cursor = cursors[path]
        do {
            while true {
                guard let chunk = try FileTailer.read(path: path, from: cursor, maxBytes: chunkBytes) else { break }
                if chunk.lines.isEmpty, chunk.cursor == cursor { break }
                let batch = ClaudeTranscriptIngester.batch(lines: chunk.lines, path: path, startOffset: chunk.startOffset)
                // If work stops before the end, `needsWork` must still see the rest of the file as unread.
                var committed = chunk.cursor
                if !chunk.atEnd { committed.size = committed.offset }
                let changed = try await store.apply(batch, cursor: IngestCursor(source: .claudeCode, path: path,
                                                                                file: committed))
                cursor = committed
                cursors[path] = committed
                pendingChanges.formUnion(changed)
                if inBackfill {
                    progress.bytesDone += chunk.bytesConsumed
                    emit()
                }
                if stopped { return }
                if chunk.atEnd || chunk.bytesConsumed == 0 { break }
            }
        } catch {
            progress.lastError = "\(URL(fileURLWithPath: path).lastPathComponent): \(error)"
        }
        if inBackfill {
            backfillRemaining.remove(path)
            progress.filesDone += 1
            emit()
        }
    }

    private func needsWork(_ file: ClaudeTranscriptIngester.TranscriptFile) -> Bool {
        guard let cursor = cursors[file.path] else { return true }
        return cursor.inode != file.stat.inode || cursor.size != file.stat.size
    }

    private func unreadBytes(_ file: ClaudeTranscriptIngester.TranscriptFile) -> Int64 {
        guard let cursor = cursors[file.path], cursor.inode == file.stat.inode, file.stat.size >= cursor.offset else {
            return file.stat.size
        }
        return file.stat.size - cursor.offset
    }

    private func filesChanged(_ paths: [String]) async {
        for path in paths where claude.isTranscript(path) { enqueue(path) }
        await drain()
    }

    private func startWatcher() {
        guard FileManager.default.fileExists(atPath: claude.projectsDirectory) else { return }
        let watcher = DirectoryWatcher(paths: [claude.projectsDirectory], latency: 0.5) { [weak self] paths in
            Task { await self?.filesChanged(paths) }
        }
        if watcher.start() { self.watcher = watcher }
    }

    private func emit(force: Bool = false) {
        let now = ContinuousClock.now
        if !force, let lastEmit, now - lastEmit < .milliseconds(250) { return }
        lastEmit = now
        continuation.yield(IngestUpdate(progress: progress, changedSessions: pendingChanges))
        pendingChanges = []
    }
}
