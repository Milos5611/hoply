import AgentKit
import Darwin
import Foundation

public struct ProcessScanner: Sendable {
    public static let defaultLsofPath = "/usr/sbin/lsof"

    public var lsofPath: String
    public var lsofTimeout: TimeInterval

    public init(lsofPath: String = ProcessScanner.defaultLsofPath, lsofTimeout: TimeInterval = 3) {
        self.lsofPath = lsofPath
        self.lsofTimeout = lsofTimeout
    }

    public func scan() -> ProcessSnapshot {
        libprocScan() ?? lsofScan() ?? ProcessSnapshot(source: .unavailable, processes: [])
    }

    public func libprocScan() -> ProcessSnapshot? {
        let now = Date()
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }

        let uid = getuid()
        var reader = ArgumentReader()
        var processes: [ScannedProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let info = Self.bsdInfo(pid), info.pbi_uid == uid else { continue }
            processes.append(Self.process(pid, info: info, listeners: Self.listeners(of: pid), reader: &reader))
        }
        // Our own process is always readable; without it the process list can't be trusted.
        guard processes.contains(where: { $0.pid == getpid() }) else { return nil }
        return ProcessSnapshot(takenAt: now, source: .libproc, processes: processes)
    }

    public func lsofScan() -> ProcessSnapshot? {
        let now = Date()
        let arguments = ["-w", "-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-a", "-u", String(getuid()), "-F", "pcnPtRguT"]
        guard FileManager.default.isExecutableFile(atPath: lsofPath),
              let output = Subprocess.run(lsofPath, arguments, timeout: lsofTimeout) else { return nil }
        // lsof exits 1 when nothing matches, with empty output.
        guard output.status == 0 || output.data.isEmpty else { return nil }
        var reader = ArgumentReader()
        var processes: [ScannedProcess] = []
        var seen: Set<pid_t> = []
        func add(_ pid: pid_t, entry: LsofParser.Entry?) {
            guard pid > 1, seen.insert(pid).inserted else { return }
            if let info = Self.bsdInfo(pid) {
                guard info.pbi_uid == getuid() else { return }
                processes.append(Self.process(pid, info: info, listeners: entry?.listeners ?? [], reader: &reader))
            } else if let entry, let started = ProcessDirectory.startTime(of: pid) {
                processes.append(ScannedProcess(
                    identity: ProcessIdentity(pid: pid, startedAt: started), parentPID: entry.parentPID ?? 0,
                    groupID: entry.groupID ?? 0, uid: entry.uid ?? getuid(), name: entry.command,
                    cwd: ProcessDirectory.cwd(of: pid), listeners: entry.listeners))
            }
        }
        for entry in LsofParser.parse(String(decoding: output.data, as: UTF8.self)) {
            add(entry.pid, entry: entry)
            var parent = Self.bsdInfo(entry.pid).map { pid_t($0.pbi_ppid) } ?? entry.parentPID ?? 0
            while parent > 1, !seen.contains(parent) {
                add(parent, entry: nil)
                parent = Self.bsdInfo(parent).map { pid_t($0.pbi_ppid) } ?? 0
            }
        }
        return ProcessSnapshot(takenAt: now, source: .lsof, processes: processes)
    }

    public static func identity(of pid: Int32) -> ProcessIdentity? {
        guard let info = bsdInfo(pid), info.pbi_status != UInt32(SZOMB) else { return nil }
        return ProcessIdentity(pid: pid, startedAt: startTime(info))
    }

    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        self.identity(of: identity.pid) == identity
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    // Must stay the same arithmetic as `ProcessDirectory.startTime`: identities are compared for equality.
    private static func startTime(_ info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    private static func process(_ pid: pid_t, info: proc_bsdinfo, listeners: [ListeningSocket],
                                reader: inout ArgumentReader) -> ScannedProcess {
        var info = info
        let longName = withUnsafeBytes(of: &info.pbi_name) { string($0) }
        let shortName = withUnsafeBytes(of: &info.pbi_comm) { string($0) }
        let command = reader.read(pid)
        return ScannedProcess(
            identity: ProcessIdentity(pid: pid, startedAt: startTime(info)), parentPID: Int32(info.pbi_ppid),
            groupID: Int32(info.pbi_pgid), uid: info.pbi_uid, name: longName.isEmpty ? shortName : longName,
            executable: executablePath(pid) ?? command?.executable, arguments: command?.arguments ?? [],
            cwd: ProcessDirectory.cwd(of: pid), memoryBytes: footprint(pid), listeners: listeners)
    }

    private static func string(_ raw: UnsafeRawBufferPointer) -> String {
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    private static func footprint(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    static func listeners(of pid: pid_t) -> [ListeningSocket] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 8)
        let used = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }

        var result: [ListeningSocket] = []
        for descriptor in descriptors.prefix(Int(used) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP),
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let endpoint = socket.psi.soi_proto.pri_tcp.tcpsi_ini
            // `insi_lport` is an int that holds the 16-bit port in network byte order.
            let port = Int(UInt16(truncatingIfNeeded: endpoint.insi_lport).bigEndian)
            let isIPv6 = Int32(endpoint.insi_vflag) & INI_IPV6 != 0
            guard port > 0, let address = address(endpoint, ipv6: isIPv6) else { continue }
            let listener = ListeningSocket(port: port, family: isIPv6 ? .ipv6 : .ipv4, address: address)
            if !result.contains(listener) { result.append(listener) }
        }
        return result
    }

    private static func address(_ endpoint: in_sockinfo, ipv6: Bool) -> String? {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ipv6 {
            var address = endpoint.insi_laddr.ina_6
            guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return nil }
        } else {
            var address = endpoint.insi_laddr.ina_46.i46a_addr4
            guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return nil }
        }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private struct ArgumentReader {
        private var buffer: [UInt8]

        init() {
            var limit: Int32 = 0
            var size = MemoryLayout<Int32>.size
            var name = [CTL_KERN, KERN_ARGMAX]
            let found = sysctl(&name, 2, &limit, &size, nil, 0) == 0 && limit > 0
            buffer = [UInt8](repeating: 0, count: found ? Int(limit) : 1_048_576)
        }

        mutating func read(_ pid: pid_t) -> (executable: String, arguments: [String])? {
            var name = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = buffer.count
            let status = buffer.withUnsafeMutableBytes { sysctl(&name, 3, $0.baseAddress, &size, nil, 0) }
            guard status == 0, size > 0, size <= buffer.count else { return nil }
            return ProcessArguments.parse(procargs2: buffer[..<size])
        }
    }
}
