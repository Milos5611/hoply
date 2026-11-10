import AgentKit
import AgentSystem
import Foundation
import XCTest

final class ListeningTestSocket {
    let descriptor: Int32
    let port: Int

    init(ipv6: Bool = false, port requested: Int = 0) throws {
        let descriptor = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        self.descriptor = descriptor
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var bound = false
        var assigned: in_port_t = 0
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            address.sin6_port = in_port_t(requested).bigEndian
            bound = withUnsafeMutableBytes(of: &address) { Self.bind(descriptor, $0) }
            assigned = address.sin6_port
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            address.sin_port = in_port_t(requested).bigEndian
            bound = withUnsafeMutableBytes(of: &address) { Self.bind(descriptor, $0) }
            assigned = address.sin_port
        }
        guard bound, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        port = Int(in_port_t(bigEndian: assigned))
    }

    private static func bind(_ descriptor: Int32, _ raw: UnsafeMutableRawBufferPointer) -> Bool {
        guard let address = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return false }
        var length = socklen_t(raw.count)
        return Darwin.bind(descriptor, address, length) == 0 && getsockname(descriptor, address, &length) == 0
    }

    func close() { Darwin.close(descriptor) }

    static func freePort(in range: Range<Int> = 20_000..<40_000) throws -> Int {
        for _ in 0..<50 {
            let candidate = Int.random(in: range)
            if let socket = try? ListeningTestSocket(port: candidate) {
                socket.close()
                return candidate
            }
        }
        throw POSIXError(.EADDRINUSE)
    }
}

final class ProcessScannerTests: XCTestCase {
    func testReportsAListeningSocketOpenedInThisProcess() throws {
        let socket = try ListeningTestSocket()
        defer { socket.close() }
        let v6 = try ListeningTestSocket(ipv6: true)
        defer { v6.close() }

        let snapshot = ProcessScanner().scan()
        XCTAssertEqual(snapshot.source, .libproc)
        let own = try XCTUnwrap(snapshot.process(getpid()))
        XCTAssertTrue(own.listeners.contains(ListeningSocket(port: socket.port, family: .ipv4, address: "127.0.0.1")))
        XCTAssertTrue(own.listeners.contains(ListeningSocket(port: v6.port, family: .ipv6, address: "::1")))
        XCTAssertEqual(own.listeners.first { $0.port == socket.port }?.reach, .loopback)
        XCTAssertEqual(own.cwd, URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        XCTAssertEqual(own.parentPID, getppid())
        XCTAssertEqual(own.groupID, getpgrp())
        XCTAssertEqual(own.uid, getuid())
        XCTAssertEqual(own.identity.startedAt, ProcessDirectory.startTime(of: getpid()))
        XCTAssertEqual(ProcessScanner.identity(of: getpid()), own.identity)
        XCTAssertFalse(own.arguments.isEmpty)
        XCTAssertNotNil(own.executable)
        XCTAssertGreaterThan(own.memoryBytes ?? 0, 1_000_000)
        XCTAssertNotNil(snapshot.process(getppid()))
        XCTAssertTrue(snapshot.processes.allSatisfy { $0.uid == getuid() })
        XCTAssertTrue(snapshot.listening.contains { $0.pid == getpid() })
    }

    func testAClosedSocketIsNoLongerReported() throws {
        let socket = try ListeningTestSocket()
        let port = socket.port
        socket.close()
        let own = try XCTUnwrap(ProcessScanner().scan().process(getpid()))
        XCTAssertFalse(own.listeners.contains { $0.port == port })
    }

    func testTheLsofFallbackReportsTheSameListener() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: ProcessScanner.defaultLsofPath), "No lsof")
        let socket = try ListeningTestSocket()
        defer { socket.close() }
        let fallback = try XCTUnwrap(ProcessScanner().lsofScan())
        XCTAssertEqual(fallback.source, .lsof)
        let own = try XCTUnwrap(fallback.process(getpid()))
        XCTAssertEqual(own.listeners.filter { $0.port == socket.port },
                       [ListeningSocket(port: socket.port, family: .ipv4, address: "127.0.0.1")])
        let direct = try XCTUnwrap(ProcessScanner().scan().process(getpid()))
        XCTAssertEqual(own.identity, direct.identity)
        XCTAssertEqual(own.cwd, direct.cwd)
        XCTAssertEqual(own.groupID, direct.groupID)
        XCTAssertNotNil(fallback.process(getppid()))
    }

    func testAMissingLsofYieldsNoFallback() {
        XCTAssertNil(ProcessScanner(lsofPath: "/nonexistent/lsof").lsofScan())
    }

    func testMonitorFindsAndStopsAChildServer() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/nc"), "No nc")
        let directory = try TempDirectory()
        let cwd = try XCTUnwrap(realpath(directory.url.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let port = try ListeningTestSocket.freePort()
        let child = try SpawnedProcess("/usr/bin/nc", ["-l", "127.0.0.1", String(port)], directory: cwd)
        defer { child.cleanUp() }

        let monitor = DevServerMonitor(terminator: ProcessTerminator(grace: 2))
        var found: DevServer?
        for _ in 0..<50 where found == nil {
            found = await monitor.refresh(hubPort: 4318).servers.first { $0.port == port }
            if found == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let server = try XCTUnwrap(found)
        XCTAssertEqual(server.process.pid, child.pid)
        XCTAssertEqual(server.cwd, cwd)
        XCTAssertEqual(server.groupKey, cwd)
        XCTAssertEqual(server.frameworkName, "nc")
        XCTAssertNil(server.stopRefusal)
        XCTAssertNil(server.session)
        let latest = await monitor.latest
        XCTAssertEqual(latest?.servers.first { $0.port == port }, server)

        let project = ProjectRef(id: 3, root: cwd, name: "scratch-app", kind: .folder)
        let sessions = [DevServerClassifier.Session(key: SessionKey(source: .claudeCode, id: "s"), cwd: cwd)]
        let named = await monitor.refresh(hubPort: 4318, sessions: sessions) { cwds in
            XCTAssertTrue(cwds.contains(cwd))
            return [cwd: project]
        }
        let resolved = try XCTUnwrap(named.servers.first { $0.port == port })
        XCTAssertEqual(resolved.groupKey, "project:3")
        XCTAssertTrue(resolved.displayName.hasPrefix("scratch-app · nc :\(port)"))
        XCTAssertEqual(resolved.session, sessions[0].key)
        XCTAssertEqual(named.servers(for: sessions[0].key).map(\.id), [resolved.id])
        let hidden = await monitor.refresh(hubPort: port)
        XCTAssertFalse(hidden.servers.contains { $0.port == port })

        var stale = server
        stale.process.startedAt = stale.process.startedAt.addingTimeInterval(-60)
        let refused = await monitor.stop(stale)
        XCTAssertEqual(refused, .refused(.identityChanged))
        XCTAssertTrue(child.isRunning)

        let outcome = await monitor.stop(server)
        XCTAssertEqual(outcome, .terminated)
        XCTAssertNotNil(child.waitForExit())
        let after = await monitor.refresh(hubPort: 4318)
        XCTAssertFalse(after.servers.contains { $0.port == port })
        let again = await monitor.stop(server)
        XCTAssertEqual(again, .refused(.processGone))
    }

    func testRealProcesses() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOPLY_REAL_PROCESSES"] == "1",
                          "Set HOPLY_REAL_PROCESSES=1 to time a scan of this Mac's processes")
        let scanner = ProcessScanner()
        var times: [TimeInterval] = []
        var snapshot = scanner.scan()
        for _ in 0..<20 {
            let start = Date()
            snapshot = scanner.scan()
            times.append(Date().timeIntervalSince(start))
        }
        let lsofStart = Date()
        let lsof = scanner.lsofScan()
        let lsofTime = Date().timeIntervalSince(lsofStart)
        let classifier = DevServerClassifier(hubPort: 4318, ownPID: getpid(), uid: getuid(), homeDirectory: NSHomeDirectory())
        let sessions = [DevServerClassifier.Session(key: SessionKey(source: .claudeCode, id: "probe"),
                                                    cwd: FileManager.default.currentDirectoryPath)]
        let servers = classifier.servers(in: snapshot, sessions: sessions)
        let ports = Set(snapshot.listening.flatMap { $0.listeners.map(\.port) })
        let lsofPorts = Set((lsof?.listening ?? []).flatMap { $0.listeners.map(\.port) })
        print(String(format: "processes %d, listening %d (%d ports), lsof listening %d (%d ports, same set: %@)",
                     snapshot.processes.count, snapshot.listening.count, ports.count, lsof?.listening.count ?? -1,
                     lsofPorts.count, String(ports == lsofPorts)))
        print(String(format: "scan median %.1f ms, max %.1f ms; lsof %.0f ms", times.sorted()[10] * 1000,
                     (times.max() ?? 0) * 1000, lsofTime * 1000))
        print("dev servers \(servers.count): " + servers.map { "\($0.frameworkName) \($0.portLabel) stop=\($0.stopRefusal.map { "\($0)" } ?? "allowed") session=\($0.sessionMatch?.rawValue ?? "none")" }
            .joined(separator: ", "))
        print("listening without a cwd \(snapshot.listening.filter { $0.cwd == nil }.count), candidates \(classifier.candidateDirectories(in: snapshot).count)")
        print("with cwd \(snapshot.processes.filter { $0.cwd != nil }.count), with argv \(snapshot.processes.filter { !$0.arguments.isEmpty }.count), with memory \(snapshot.processes.filter { $0.memoryBytes != nil }.count)")
    }
}
