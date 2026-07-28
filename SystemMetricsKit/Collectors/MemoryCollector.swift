import Foundation
import MacStatKit

public final class MemoryCollector: Collector {
    public init() {}

    public func collect() -> MemoryStats? {
        guard let stats = Self.readVMStatistics() else { return nil }
        guard let totalBytes: UInt64 = Self.sysctlValue(name: "hw.memsize") else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)

        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let externalPages = UInt64(stats.external_page_count)
        let wirePages = UInt64(stats.wire_count)
        let compressorPages = UInt64(stats.compressor_page_count)

        let appMemoryPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let appMemoryBytes = appMemoryPages * pageSize
        let wiredBytes = wirePages * pageSize
        let compressedBytes = compressorPages * pageSize
        let cachedBytes = (externalPages + purgeablePages) * pageSize
        let usedBytes = appMemoryBytes + wiredBytes + compressedBytes

        let swap: xsw_usage? = Self.sysctlValue(name: "vm.swapusage")
        let pressureRaw: Int32? = Self.sysctlValue(name: "kern.memorystatus_vm_pressure_level")

        return MemoryStats(
            usedBytes: usedBytes,
            appMemoryBytes: appMemoryBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedBytes: cachedBytes,
            totalBytes: totalBytes,
            swapUsedBytes: swap?.xsu_used,
            swapTotalBytes: swap?.xsu_total,
            pressureLevel: pressureRaw.flatMap { MemoryPressureLevel(rawValue: Int($0)) }
        )
    }

    private static func readVMStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return stats
    }

    private static func sysctlValue<T>(name: String) -> T? {
        var size = MemoryLayout<T>.size
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }

        guard sysctlbyname(name, buffer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else {
            return nil
        }
        return buffer.load(as: T.self)
    }
}
