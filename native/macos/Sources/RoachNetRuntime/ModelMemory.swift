import Darwin
import Foundation
import RoachInference

/// The Mac's memory as model loading sees it.
enum SystemMemory {
    static var total: Int { Int(ProcessInfo.processInfo.physicalMemory) }

    /// What the system could hand out now without paging: free, inactive,
    /// purgeable and speculative pages (Activity Monitor's "available").
    static func available() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return total / 2 }
        let pages = Int(stats.free_count) + Int(stats.inactive_count) + Int(stats.purgeable_count) + Int(stats.speculative_count)
        return pages * Int(getpagesize())
    }

    /// How much loaded models may use together: `ROACHNET_MODEL_MEMORY_GB`,
    /// or 80% of the Mac's memory so macOS and the apps around it keep theirs.
    static var modelBudget: Int {
        if let text = ProcessInfo.processInfo.environment["ROACHNET_MODEL_MEMORY_GB"], let gigabytes = Double(text), gigabytes > 0 {
            return Int(gigabytes * 1_073_741_824)
        }
        return total / 10 * 8
    }

    static func gigabytes(_ bytes: Int) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

    /// The kernel's memory pressure level: 1 normal, 2 warning, 4 critical; 0 when it can't be read.
    static func pressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        return Int(level)
    }

    /// macOS is short of memory (warning or worse): idle request slots hand their caches back sooner.
    static var underPressure: Bool { pressureLevel() >= 2 }
}

extension NativeModelServer {
    /// Fits a model into memory before loading it, the way a careful person
    /// would: idle models are unloaded first, then the context is shortened
    /// (never below 2,048 tokens), and only then is the load refused, with
    /// the numbers, instead of the Mac swapping itself to a halt.
    /// Called with `lock` held.
    func makeRoom(for name: String, footprint wanted: ModelFootprint, budget: Int) throws -> ModelFootprint {
        var footprint = wanted
        let floor = min(2_048, wanted.context)
        func resident() -> Int { loaded.values.reduce(0) { $0 + $1.resident } }
        // Idle extra request slots go first; they only hold caches.
        if resident() + footprint.total > budget {
            var trimmed = false
            for item in loaded.values where item.trimSlots(idleSince: .distantFuture) { trimmed = true }
            if trimmed { refreshResident() }
        }
        // Unload idle models, oldest first, until this one fits beside the rest.
        while resident() + footprint.total > budget {
            let oldestFirst = loaded.values.filter { $0.name != name }.sorted { $0.lastUsed < $1.lastUsed }
            guard let idle = oldestFirst.first(where: { !$0.isBusy }) else { break }
            loaded[idle.name] = nil
            RuntimeLog.write("native engine unloaded \(idle.name) to make room for \(name)")
        }
        let room = budget - resident()
        if footprint.total > room {
            var context = footprint.context
            while context > floor, footprint.with(context: context).total > room { context = max(floor, context / 2) }
            footprint = footprint.with(context: context)
            if footprint.context < wanted.context {
                RuntimeLog.write("native engine: \(name) gets a \(footprint.context)-token context (asked \(wanted.context)) to fit in memory")
            }
        }
        if footprint.total > budget {
            throw requestError("\(name) needs about \(SystemMemory.gigabytes(footprint.total)) of memory; models can use \(SystemMemory.gigabytes(budget)) on this Mac. "
                               + "Pick a smaller model or quantization, or set ROACHNET_MODEL_MEMORY_GB.", 507)
        }
        return footprint
    }
}
