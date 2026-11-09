import CoreServices
import Foundation

public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private let paths: [String]
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "hoply.fsevents")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let box: Box

    private final class Box: Sendable {
        let handler: Handler
        init(handler: @escaping Handler) { self.handler = handler }
    }

    public init(paths: [String], latency: TimeInterval = 0.5, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.box = Box(handler: handler)
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        lock.withLock { stream != nil }
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: DirectoryWatcher.retainBox, release: DirectoryWatcher.releaseBox,
                                           copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, DirectoryWatcher.callback, &context,
                                                paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    private static let retainBox: CFAllocatorRetainCallBack = { info in
        guard let info else { return nil }
        _ = Unmanaged<Box>.fromOpaque(info).retain()
        return info
    }

    private static let releaseBox: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<Box>.fromOpaque(info).release()
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
        let changed = (0..<min(count, array.count)).compactMap { array[$0] as? String }
        if !changed.isEmpty { box.handler(changed) }
    }
}
