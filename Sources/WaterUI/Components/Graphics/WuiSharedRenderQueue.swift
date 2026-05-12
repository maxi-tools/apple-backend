import Foundation

/// Shared render queue for Apple backend GPU components.
///
/// Keeping a single worker queue avoids per-component dispatch thread growth
/// when pages contain many GPU-backed views/filters.
enum WuiSharedRenderQueue {
    private static let queueKey = DispatchSpecificKey<Void>()

    static let queue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "waterui.shared-render-queue",
            qos: .userInteractive,
            attributes: [.concurrent],
            autoreleaseFrequency: .workItem
        )
        queue.setSpecific(key: queueKey, value: ())
        return queue
    }()

    static func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    static func sync<T>(_ work: () -> T) -> T {
        if isCurrent {
            return work()
        }
        return queue.sync(execute: work)
    }

    static func barrier<T>(_ work: () -> T) -> T {
        if isCurrent {
            return work()
        }
        return queue.sync(flags: .barrier, execute: work)
    }

    static func barrierAsync(_ work: @escaping @Sendable () -> Void) {
        queue.async(flags: .barrier, execute: work)
    }

    static func drain() {
        if isCurrent {
            return
        }
        queue.sync(flags: .barrier) {}
    }

    static var isCurrent: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }
}
