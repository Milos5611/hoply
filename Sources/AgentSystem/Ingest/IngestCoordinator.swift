import AgentKit
import Foundation

public struct IngestUpdate: Sendable, Equatable {
    public var progress: IngestProgress
    /// Sessions whose ledger rows or metadata changed since the previous update.
    public var changedSessions: Set<SessionKey>
}

/// Owns transcript ingestion: backfill (newest files first), FSEvents tailing, a periodic stat-only rescan,
/// and immediate tails requested by hooks. Files are processed one at a time, so a file's cursor and turn
/// count are never updated by two readers at once.
public actor IngestCoordinator {
    /// Single consumer. Progress during backfill is throttled to about four updates a second.
    public nonisolated let updates: AsyncStream<IngestUpdate>
    public private(set) var progress = IngestProgress()

    private let continuation: AsyncStream<IngestUpdate>.Continuation
    private let store: Store
    private let claude: ClaudeTranscriptIngester
    private let watch: Bool
    private let rescanInterval: Duration
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

    public init(store: Store, claude: ClaudeTranscriptIngester = ClaudeTranscriptIngester(), watch: Bool = true,
                rescanInterval: Duration = .seconds(60), chunkBytes: Int = 4 << 20) {
        self.store = store
        self.claude = claude
        self.watch = watch
        self.rescanInterval = rescanInterval
        self.chunkBytes = chunkBytes
        (updates, continuation) = AsyncStream.makeStream(of: IngestUpdate.self)
    }

    deinit {
        watcher?.stop()
        rescanTask?.cancel()
        continuation.finish()
    }

    /// Loads cursors, starts watching, then backfills. Returns when the backfill queue is empty.
    public func start() async {
        guard !started else { return }
        started = true
        stopped = false
        let generation = runGeneration
        do {
            cursors = try await store.cursors(source: .claudeCode)
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
        }
        await backfill()
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
        pending.removeAll()
        if draining || cursorResets > 0 {
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

    /// Re-reads every transcript from the start. Only cursors are reset; ledger rows are never deleted.
    public func reindex() async {
        guard !stopped else { return }
        cursorResets += 1
        var reset = false
        do {
            try await store.resetCursors(source: .claudeCode)
            cursors = try await store.cursors(source: .claudeCode)
            reset = true
        } catch {
            progress.lastError = "Reindex failed: \(error)"
            emit(force: true)
        }
        cursorResets -= 1
        resumeIdleWaiters()
        if reset { await backfill() }
    }

    /// For tests and shutdown: waits until queued files are processed.
    public func waitUntilIdle() async {
        while draining || !pending.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Work queue

    private func backfill() async {
        guard !stopped else { return }
        let work = claude.discover().filter(needsWork)
        backfillRemaining = Set(work.map(\.path))
        progress = IngestProgress(filesDone: 0, filesTotal: work.count, bytesDone: 0,
                                  bytesTotal: work.reduce(0) { $0 + unreadBytes($1) }, isBackfilling: !work.isEmpty,
                                  lastError: progress.lastError)
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

    private func resumeIdleWaiters() {
        guard !draining, cursorResets == 0 else { return }
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
