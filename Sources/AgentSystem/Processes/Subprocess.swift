import Foundation

enum Subprocess {
    struct Output {
        var status: Int32
        var data: Data
    }

    static func run(_ path: String, _ arguments: [String], directory: String? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        // Drained on another thread: a child that fills the pipe would otherwise never exit.
        let collected = Collected()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected.set(output.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard drained.wait(timeout: .now() + timeout) == .success else { return nil }
        return Output(status: process.terminationStatus, data: collected.value)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func set(_ new: Data) { lock.withLock { data = new } }
        var value: Data { lock.withLock { data } }
    }
}
