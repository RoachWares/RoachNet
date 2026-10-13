import Foundation

/// Runs work that blocks on threads of its own, not on dispatch's workers.
///
/// On Linux, libdispatch has no kernel workqueue behind it. A global queue has
/// about one worker per CPU, and only a slow monitor adds more when they block.
/// URLSession callbacks and Process termination handlers run on those same
/// workers. So work that waits on a socket, a child process or another
/// thread's result can hold up the very completion it is waiting for. Before
/// this, eight concurrent status reads took seconds on two CPUs (ROA-90).
///
/// A thread of its own costs macOS nothing either, so every platform uses it.
public enum BlockingWork {
    /// Starts `work` on a new thread named `name`.
    public static func start(_ name: String, qos: QualityOfService = .default, _ work: @escaping () -> Void) {
        let thread = Thread {
            #if canImport(Darwin)
            autoreleasepool { work() }
            #else
            work()
            #endif
        }
        thread.name = name
        thread.qualityOfService = qos
        thread.start()
    }

    /// Runs every closure at once and returns when all of them have finished.
    /// The last one runs on the calling thread; each of the others gets its own.
    public static func all(_ name: String, _ works: [() -> Void]) {
        guard let last = works.last else { return }
        let group = DispatchGroup()
        for work in works.dropLast() {
            group.enter()
            start(name) {
                work()
                group.leave()
            }
        }
        last()
        group.wait()
    }
}
