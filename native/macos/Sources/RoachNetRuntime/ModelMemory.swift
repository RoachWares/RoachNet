#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import RoachInference

/// The machine's memory as model loading sees it.
enum SystemMemory {
    /// The machine's memory, or on Linux the cgroup's limit when it is
    /// lower (a container, a systemd slice with MemoryMax).
    static var total: Int {
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        #if canImport(Darwin)
        return physical
        #else
        guard let limit = cgroupMemory()?.limit else { return physical }
        return min(physical, limit)
        #endif
    }

    /// What the system could hand out now without paging. On macOS: free,
    /// inactive, purgeable and speculative pages (Activity Monitor's
    /// "available"). On Linux: the kernel's own estimate, `MemAvailable`, or
    /// less when a cgroup limit leaves less headroom than that.
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
        let host = meminfo.flatMap(memAvailable(meminfo:)) ?? total / 2
        guard let cgroup = cgroupMemory() else { return host }
        return min(host, cgroup.available)
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

    /// The most a newly loaded model may take now, or nil when only the budget decides.
    ///
    /// On Linux it is `available()`. Going past a cgroup's limit, or past what a
    /// machine with little swap has free, ends with the OOM killer stopping the
    /// runtime, not with a slower machine. On macOS the system compresses and
    /// swaps memory, and its available figure leaves out what it could compress,
    /// so the budget alone decides there, as before.
    static func loadHeadroom() -> Int? {
        #if canImport(Darwin)
        return nil
        #else
        return available()
        #endif
    }

    /// How refusals name the machine.
    static var thisMachine: String {
        #if canImport(Darwin)
        return "this Mac"
        #else
        return "this computer"
        #endif
    }

    static func gigabytes(_ bytes: Int) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

    /// The memory pressure level: 1 normal, 2 warning, 4 critical; 0 when it
    /// can't be read. macOS reports its own. On Linux it comes from pressure
    /// stall information, the cgroup's own (cgroup v2) before the whole
    /// machine's, or from the available share where neither is there.
    static func pressureLevel() -> Int {
        #if canImport(Darwin)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        return Int(level)
        #else
        let psi = cgroupPressure() ?? (try? String(contentsOfFile: "/proc/pressure/memory", encoding: .utf8))
        if let psi, let level = pressureLevel(psi: psi) { return level }
        let total = total
        guard total > 0 else { return 0 }
        return pressureLevel(available: available(), total: total)
        #endif
    }

    #if !canImport(Darwin)
    /// The memory limit and headroom from the cgroups this process is in,
    /// walking up to the root: the lowest limit, and the least headroom under
    /// any of them. nil when no cgroup sets a limit.
    static func cgroupMemory() -> (limit: Int, available: Int)? {
        guard let membership = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8) else { return nil }
        let (version, directories) = cgroupDirectories(procSelfCgroup: membership)
        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        let levels: [CgroupLevel] = directories.compactMap { directory in
            let limitFile = version == 2 ? "memory.max" : "memory.limit_in_bytes"
            let usageFile = version == 2 ? "memory.current" : "memory.usage_in_bytes"
            guard let limitText = read(directory + "/" + limitFile), let usageText = read(directory + "/" + usageFile),
                  let usage = Int(usageText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            let inactive = read(directory + "/memory.stat").map { inactiveFile(memoryStat: $0, version: version) } ?? 0
            return CgroupLevel(limit: cgroupLimitValue(limitText, version: version), usage: usage, inactiveFile: inactive)
        }
        return cgroupLimit(levels)
    }

    /// The process's own cgroup v2 pressure stall information, when there is one.
    static func cgroupPressure() -> String? {
        guard let membership = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8) else { return nil }
        let (version, directories) = cgroupDirectories(procSelfCgroup: membership)
        guard version == 2, let own = directories.first else { return nil }
        return try? String(contentsOfFile: own + "/memory.pressure", encoding: .utf8)
    }
    #endif

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

    /// One cgroup on the way from this process to the root.
    struct CgroupLevel: Equatable {
        /// nil when this cgroup sets no limit.
        let limit: Int?
        let usage: Int
        /// Page cache the kernel can drop before it would hit the limit.
        let inactiveFile: Int
    }

    /// The cgroup folders that bound this process, its own first and the root
    /// last, from the text of /proc/self/cgroup. A cgroup v1 memory controller
    /// is used where there is one (hybrid setups); otherwise the v2 tree.
    static func cgroupDirectories(procSelfCgroup: String, root: String = "/sys/fs/cgroup") -> (version: Int, directories: [String]) {
        var unified: String?
        var legacy: String?
        for line in procSelfCgroup.split(separator: "\n") {
            let fields = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let controllers = fields[1].split(separator: ",")
            if fields[0] == "0", fields[1].isEmpty {
                unified = String(fields[2])
            } else if controllers.contains("memory") {
                legacy = String(fields[2])
            }
        }
        func walk(_ base: String, _ path: String) -> [String] {
            var parts = path.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
            var directories: [String] = []
            while true {
                directories.append(parts.isEmpty ? base : base + "/" + parts.joined(separator: "/"))
                if parts.isEmpty { break }
                parts.removeLast()
            }
            return directories
        }
        if let legacy { return (1, walk(root + "/memory", legacy)) }
        if let unified { return (2, walk(root, unified)) }
        return (2, [])
    }

    /// A cgroup memory limit in bytes, or nil for none: "max" in cgroup v2, a
    /// value near Int64.max in cgroup v1.
    static func cgroupLimitValue(_ text: String, version: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "max", let value = Int(trimmed), value > 0 else { return nil }
        if version == 1, value >= 1 << 62 { return nil }
        return value
    }

    /// Reclaimable page cache from a cgroup's memory.stat: `inactive_file` in
    /// cgroup v2, `total_inactive_file` (the whole subtree) in cgroup v1.
    static func inactiveFile(memoryStat: String, version: Int) -> Int {
        var found: [String: Int] = [:]
        for line in memoryStat.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2, let value = Int(fields[1]), value >= 0 else { continue }
            found[String(fields[0])] = value
        }
        return (version == 1 ? found["total_inactive_file"] : nil) ?? found["inactive_file"] ?? 0
    }

    /// The lowest limit among `levels`, and the least headroom under any of
    /// them; nil when none sets a limit.
    static func cgroupLimit(_ levels: [CgroupLevel]) -> (limit: Int, available: Int)? {
        var result: (limit: Int, available: Int)?
        for level in levels {
            guard let limit = level.limit else { continue }
            let used = max(0, level.usage - level.inactiveFile)
            let headroom = max(0, limit - used)
            result = (min(result?.limit ?? limit, limit), min(result?.available ?? headroom, headroom))
        }
        return result
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
    /// the numbers, instead of the Mac swapping itself to a halt or, on Linux,
    /// the OOM killer stopping the runtime. `headroom` caps the room by the
    /// memory free now (see `SystemMemory.loadHeadroom()`).
    /// Called with `lock` held.
    func makeRoom(for name: String, footprint wanted: ModelFootprint, budget: Int,
                  headroom: () -> Int? = SystemMemory.loadHeadroom) throws -> ModelFootprint {
        var footprint = wanted
        let floor = min(2_048, wanted.context)
        // An idle copy of this same model (another context length) is replaced by
        // this load, so it doesn't count against the room; a busy one stays until
        // its requests finish, so it does.
        func resident() -> Int { loaded.values.filter { $0.name != name || $0.isBusy }.reduce(0) { $0 + $1.resident } }
        // Memory free now, counting that idle copy's as free too.
        func free() -> Int? {
            guard let measured = headroom() else { return nil }
            return measured + loaded.values.filter { $0.name == name && !$0.isBusy }.reduce(0) { $0 + $1.resident }
        }
        func fits(_ size: Int) -> Bool { resident() + size <= budget && (free().map { size <= $0 } ?? true) }
        // Idle extra request slots go first; they only hold caches.
        if !fits(footprint.total) {
            var trimmed = false
            for item in loaded.values where item.trimSlots(idleSince: .distantFuture) { trimmed = true }
            if trimmed { refreshResident() }
        }
        // Unload idle models, oldest first, until this one fits beside the rest.
        while !fits(footprint.total) {
            let oldestFirst = loaded.values.filter { $0.name != name }.sorted { $0.lastUsed < $1.lastUsed }
            guard let idle = oldestFirst.first(where: { !$0.isBusy }) else { break }
            loaded[idle.name] = nil
            RuntimeLog.write("native engine unloaded \(idle.name) to make room for \(name)")
        }
        let besideLoaded = budget - resident()
        let freeNow = free()
        let room = min(besideLoaded, freeNow ?? Int.max)
        if footprint.total > room {
            var context = footprint.context
            while context > floor, footprint.with(context: context).total > room { context = max(floor, context / 2) }
            footprint = footprint.with(context: context)
            if footprint.context < wanted.context {
                RuntimeLog.write("native engine: \(name) gets a \(footprint.context)-token context (asked \(wanted.context)) to fit in memory")
            }
        }
        if footprint.total > budget {
            throw requestError("\(name) needs about \(SystemMemory.gigabytes(footprint.total)) of memory; models can use \(SystemMemory.gigabytes(budget)) on \(SystemMemory.thisMachine). "
                               + "Pick a smaller model or quantization, or set ROACHNET_MODEL_MEMORY_GB.", 507)
        }
        // It fits the budget but not beside the models that are busy right now
        // (they can't be unloaded mid-request). Loading anyway would push the
        // total past the budget and the Mac into swap.
        if footprint.total > room {
            // Less is free on the machine than the budget leaves: other programs,
            // or a container's limit, hold the rest.
            if let freeNow, freeNow < besideLoaded {
                throw requestError("\(name) needs about \(SystemMemory.gigabytes(footprint.total)) of memory, and \(SystemMemory.gigabytes(max(0, freeNow))) is free on "
                                   + "\(SystemMemory.thisMachine) right now. Close other programs, or pick a smaller model or quantization.", 503)
            }
            throw requestError("\(name) needs about \(SystemMemory.gigabytes(footprint.total)) of memory, and \(SystemMemory.gigabytes(max(0, room))) is free beside "
                               + "the models answering requests right now. Try again when they finish.", 503)
        }
        return footprint
    }
}
