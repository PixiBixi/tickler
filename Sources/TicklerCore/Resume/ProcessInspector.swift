import Darwin
import Foundation

public protocol ProcessInspecting: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    /// `/dev/ttysNNN` of the process' controlling terminal.
    func ttyPath(of pid: Int32) -> String?
    /// A `claude --resume <id>` process, if one runs.
    func pid(runningResumeOf sessionId: String) -> Int32?
}

/// Reads the process table through libproc and sysctl, no `ps` subprocess.
public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public func ttyPath(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let device = dev_t(bitPattern: info.e_tdev)
        guard device != dev_t(bitPattern: UInt32.max), let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    public func pid(runningResumeOf sessionId: String) -> Int32? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            if let args = arguments(of: pid), Self.isResume(of: sessionId, arguments: args) {
                return pid
            }
        }
        return nil
    }

    func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Self.arguments(fromProcArgs: Data(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated argv strings, then env.
    static func arguments(fromProcArgs data: Data) -> [String]? {
        guard data.count > 4 else { return nil }
        let argc = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = data.startIndex + 4
        while index < data.endIndex, data[index] != 0 {
            index += 1
        }
        while index < data.endIndex, data[index] == 0 {
            index += 1
        }
        var args: [String] = []
        while args.count < argc, index < data.endIndex {
            let end = data[index...].firstIndex(of: 0) ?? data.endIndex
            args.append(String(decoding: data[index ..< end], as: UTF8.self))
            index = end + 1
        }
        return args
    }

    static func isResume(of sessionId: String, arguments args: [String]) -> Bool {
        guard let first = args.first, (first as NSString).lastPathComponent == "claude",
              let flag = args.firstIndex(of: "--resume"), flag + 1 < args.count else { return false }
        return args[flag + 1] == sessionId
    }
}
