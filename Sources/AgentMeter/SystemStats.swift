import Darwin
import Foundation

struct CPUTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// System-wide memory, using the same definitions as Activity Monitor.
struct MemoryInfo {
    var total: UInt64
    /// App memory: anonymous pages minus purgeable pages
    var app: UInt64
    var wired: UInt64
    /// Physical memory occupied by the compressor
    var compressed: UInt64
    var swapTotal: UInt64
    var swapUsed: UInt64
    /// 1 = normal, 2 = warning, 4 = critical
    var pressureLevel: Int32

    var used: UInt64 { app + wired + compressed }

    static let empty = MemoryInfo(total: 0, app: 0, wired: 0, compressed: 0, swapTotal: 0, swapUsed: 0, pressureLevel: 0)
}

enum SystemStats {
    static let host = mach_host_self()
    static let pageSize = UInt64(getpagesize())
    static let physicalMemory = ProcessInfo.processInfo.physicalMemory

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: t.0, system: t.1, idle: t.2, nice: t.3)
    }

    static func memory() -> MemoryInfo? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        let anonymous = UInt64(vm.internal_page_count)
        let purgeable = UInt64(vm.purgeable_count)
        return MemoryInfo(
            total: physicalMemory,
            app: (anonymous > purgeable ? anonymous - purgeable : 0) * pageSize,
            wired: UInt64(vm.wire_count) * pageSize,
            compressed: UInt64(vm.compressor_page_count) * pageSize,
            swapTotal: swap.xsu_total,
            swapUsed: swap.xsu_used,
            pressureLevel: level
        )
    }
}
