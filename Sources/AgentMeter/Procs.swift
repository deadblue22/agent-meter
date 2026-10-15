import Darwin
import Foundation

/// A reading of one process at one moment. Only processes owned by the current user can be read.
struct RawProcess {
    let pid: Int32
    let ppid: Int32
    let name: String
    /// Start time in seconds; used to detect PID reuse between samples
    let startTime: UInt64
    /// Accumulated CPU time (user + system), in nanoseconds
    let cpuNanos: UInt64
    /// Physical footprint (the same figure as Activity Monitor's "Memory" column)
    let memory: UInt64
    /// Exited and waiting to be reaped by its parent
    let isZombie: Bool
}

enum Procs {
    /// proc_pid_rusage reports CPU time in Mach absolute time units
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(got, 0))).filter { $0 > 0 }
    }

    static func read(_ pid: Int32) -> RawProcess? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        let longName = cString(bsd.pbi_name)
        return RawProcess(
            pid: pid,
            ppid: Int32(bsd.pbi_ppid),
            name: longName.isEmpty ? cString(bsd.pbi_comm) : longName,
            startTime: bsd.pbi_start_tvsec,
            cpuNanos: (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom,
            memory: usage.ri_phys_footprint,
            isZombie: bsd.pbi_status == 5  // SZOMB
        )
    }

    /// Current working directory of a process
    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Command-line arguments, plus only the environment variables named in `keys` (all others are dropped).
    static func arguments(_ pid: Int32, environmentKeys keys: Set<String>) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }

        // Layout: argc, exec path, NUL padding, argv[0..argc), environment, terminated by an empty string
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }

        func nextString() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            let value = String(decoding: buffer[start..<i], as: UTF8.self)
            i += 1
            return value
        }

        var arguments: [String] = []
        while arguments.count < argc, let value = nextString() { arguments.append(value) }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            if keys.contains(key) { environment[key] = String(entry[entry.index(after: eq)...]) }
        }
        return (arguments, environment)
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}
