import Foundation
import Darwin

public struct CPUTicks {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32
}

/// Wrappers around Mach host calls: per-core tick counts and process count.
public enum MachHostBridge {
    /// Bounded so a malformed response can't be misread as an enormous core count.
    private static let maxCores = 1024

    public static func readPerCoreTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        ) == KERN_SUCCESS, let info else { return [] }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        let count = min(Int(cpuCount), maxCores)
        // The kernel's tick counters are unsigned 32-bit, but the Mach API
        // hands them back through `integer_t` (Int32) — past 2^31 ticks
        // (~248 days of accumulation per state at 100Hz) the raw value goes
        // negative, and a plain `UInt32(_:)` init would trap. Reinterpret
        // the bit pattern instead; the wrapping delta math downstream is
        // already modulo-2^32 correct.
        return (0..<count).map { i in
            let o = i * Int(CPU_STATE_MAX)
            return CPUTicks(
                user: UInt32(bitPattern: info[o + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[o + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[o + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[o + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// Number of running processes, via proc_listpids.
    public static func processCount() -> Int? {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return nil }
        return Int(bufferSize) / MemoryLayout<pid_t>.size
    }

    /// 1-minute load average.
    public static func loadAverage1m() -> Double? {
        var loadavg = [Double](repeating: 0, count: 3)
        guard getloadavg(&loadavg, 3) == 3 else { return nil }
        return loadavg[0]
    }
}
