#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import RoachInference

/// The machine's memory as model loading sees it.
enum SystemMemory {
    static var total: Int { Int(ProcessInfo.processInfo.physicalMemory) }

    /// What the system could hand out now without paging. On macOS: free,
    /// inactive, purgeable and speculative pages (Activity Monitor's
    /// "available"). On Linux: the kernel's own estimate, `MemAvailable`.
    static func available() -> Int {
        #if canImport(Darwin)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return total / 2 }
        let pages = Int(stats.free_count) + Int(stats.inactive_count) + Int(stats.purgeable_count) + Int(stats.speculative_count)
        return pages * Int(getpagesize())
        #else
        let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8)
        return meminfo.flatMap(memAvailable(meminfo:)) ?? total / 2
        #endif
    }

    /// How much loaded models may use together: `ROACHNET_MODEL_MEMORY_GB`,
    /// or 80% of the machine's memory so the system and the apps around it keep theirs.
    static var modelBudget: Int {
        // `Double("inf")` parses, and `Int(.infinity)` traps; past a petabyte isn't a budget anyway.
        if let text = ProcessInfo.processInfo.environment["ROACHNET_MODEL_MEMORY_GB"], let gigabytes = Double(text),
           gigabytes > 0, gigabytes < 1_000_000 {
            return Int(gigabytes * 1_073_741_824)
        }
        return total / 10 * 8
    }

    static func gigabytes(_ bytes: Int) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

    /// The memory pressure level: 1 normal, 2 warning, 4 critical; 0 when it
    /// can't be read. macOS reports its own; on Linux it comes from the
    /// kernel's pressure stall information, or from `MemAvailable` where that
    /// isn't there (older kernels, some containers).
    static func pressureLevel() -> Int {
        #if canImport(Darwin)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        return Int(level)
        #else
        if let psi = try? String(contentsOfFile: "/proc/pressure/memory", encoding: .utf8), let level = pressureLevel(psi: psi) {
            return level
        }
        let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8)
        guard let available = meminfo.flatMap(memAvailable(meminfo:)), total > 0 else { return 0 }
        return pressureLevel(available: available, total: total)
        #endif
    }

    /// The system is short of memory (warning or worse): idle request slots hand their caches back sooner.
    static var underPressure: Bool { pressureLevel() >= 2 }

    // MARK: Linux sources, parsed here so every platform tests them

    /// `MemAvailable` from the text of /proc/meminfo, in bytes.
    static func memAvailable(meminfo: String) -> Int? {
        for line in meminfo.split(separator: "\n") where line.hasPrefix("MemAvailable:") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let kibibytes = Int(fields[1]), kibibytes >= 0, kibibytes < Int.max / 1024 else { return nil }
            return kibibytes * 1024
        }
        return nil
    }

    /// A level from /proc/pressure/memory: the share of the last ten seconds
    /// in which tasks stalled waiting for memory. Any stall at all ("some") of
    /// 10% or more is a warning; every task stalled ("full") 10% of the time,
    /// or "some" at 40%, is critical.
    static func pressureLevel(psi: String) -> Int? {
        func avg10(_ kind: String) -> Double? {
            guard let line = psi.split(separator: "\n").first(where: { $0.hasPrefix(kind + " ") }) else { return nil }
            guard let field = line.split(separator: " ").first(where: { $0.hasPrefix("avg10=") }) else { return nil }
            guard let value = Double(field.dropFirst("avg10=".count)), value.isFinite, value >= 0 else { return nil }
            return value
        }
        guard let some = avg10("some") else { return nil }
        let full = avg10("full") ?? 0
        if full >= 10 || some >= 40 { return 4 }
        if some >= 10 { return 2 }
        return 1
    }

    /// A level from how much memory is still available: under 5% critical,
    /// under 15% a warning.
    static func pressureLevel(available: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let share = Double(max(0, available)) / Double(total)
        if share < 0.05 { return 4 }
        if share < 0.15 { return 2 }
        return 1
    }
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
        // An idle copy of this same model (another context length) is replaced by
        // this load, so it doesn't count against the room; a busy one stays until
        // its requests finish, so it does.
        func resident() -> Int { loaded.values.filter { $0.name != name || $0.isBusy }.reduce(0) { $0 + $1.resident } }
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
        // It fits the budget but not beside the models that are busy right now
        // (they can't be unloaded mid-request). Loading anyway would push the
        // total past the budget and the Mac into swap.
        if footprint.total > room {
            throw requestError("\(name) needs about \(SystemMemory.gigabytes(footprint.total)) of memory, and \(SystemMemory.gigabytes(max(0, room))) is free beside "
                               + "the models answering requests right now. Try again when they finish.", 503)
        }
        return footprint
    }
}
