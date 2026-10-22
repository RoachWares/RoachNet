import Darwin
import Foundation
import RoachInference

enum SystemMemory {
    static var total: Int { Int(ProcessInfo.processInfo.physicalMemory) }

    static func available() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return total / 2 }
        let pages =
            Int(stats.free_count) + Int(stats.inactive_count) + Int(stats.purgeable_count)
            + Int(stats.speculative_count)
        return pages * Int(getpagesize())
    }

    static var modelBudget: Int {
        if let text = ProcessInfo.processInfo.environment["ROACHNET_MODEL_MEMORY_GB"], let gigabytes = Double(text),
            gigabytes > 0, gigabytes < 1_000_000
        {
            return Int(gigabytes * 1_073_741_824)
        }
        return total / 10 * 8
    }

    static func gigabytes(_ bytes: Int) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
}

extension NativeModelServer {
    func makeRoom(for name: String, footprint wanted: ModelFootprint, budget: Int) throws -> ModelFootprint {
        var footprint = wanted
        let floor = min(2_048, wanted.context)
        func resident() -> Int { loaded.values.filter { $0.name != name || $0.isBusy }.reduce(0) { $0 + $1.resident } }
        if resident() + footprint.total > budget {
            var trimmed = false
            for item in loaded.values where item.trimSlots(idleSince: .distantFuture) { trimmed = true }
            if trimmed { refreshResident() }
        }
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
                RuntimeLog.write(
                    "native engine: \(name) gets a \(footprint.context)-token context (asked \(wanted.context)) to fit in memory"
                )
            }
        }
        if footprint.total > budget {
            throw requestError(
                "\(name) needs about \(SystemMemory.gigabytes(footprint.total)) of memory; models can use \(SystemMemory.gigabytes(budget)) on this Mac. "
                    + "Pick a smaller model or quantization, or set ROACHNET_MODEL_MEMORY_GB.", 507)
        }
        if footprint.total > room {
            throw requestError(
                "\(name) needs about \(SystemMemory.gigabytes(footprint.total)) of memory, and \(SystemMemory.gigabytes(max(0, room))) is free beside "
                    + "the models answering requests right now. Try again when they finish.", 503)
        }
        return footprint
    }
}
