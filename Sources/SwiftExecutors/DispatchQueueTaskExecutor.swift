//
//  DispatchQueueTaskExecutor.swift
//  SwiftExecutors
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import Foundation

/// A TaskExecutor backed by Grand Central Dispatch (GCD).
///
/// This executor allows you to offload free-standing tasks to a GCD-based
/// thread pool. It's useful when you want to leverage GCD's efficient
/// thread management, work with existing GCD-based code, or need the
/// performance characteristics of dispatch queues.
public final class DispatchQueueTaskExecutor: TaskExecutor, @unchecked Sendable {
    /// Private dispatch queue used as the underlying thread pool.
    private let queue: DispatchQueue

    /// Creates a new task executor backed by a GCD dispatch queue.
    ///
    /// - Parameters:
    ///   - label: Human-readable name for debugging (Instruments/Xcode).
    ///   - qos: Quality of service for priority handling.
    ///   - attributes: Queue attributes (e.g., `.concurrent`, `.initiallyInactive`).
    ///   - target: Target queue for execution (nil for default).
    public init(label: String = "DispatchTaskExec",
                qos: DispatchQoS = .default,
                attributes: DispatchQueue.Attributes = [],
                target: DispatchQueue? = nil)
    {
        queue = DispatchQueue(
            label: label,
            qos: qos,
            attributes: attributes,
            target: target
        )
    }

    /// Convenience initializer for creating a concurrent queue with specific QoS.
    ///
    /// - Parameters:
    ///   - label: Human-readable name for debugging.
    ///   - qos: Quality of service for priority handling.
    ///   - target: Target queue for execution (nil for default).
    public convenience init(concurrentLabel: String = "ConcurrentDispatchExec",
                            qos: DispatchQoS = .default,
                            target: DispatchQueue? = nil)
    {
        self.init(label: concurrentLabel, qos: qos, attributes: .concurrent, target: target)
    }

    /// Convenience initializer for creating a serial queue with specific QoS.
    ///
    /// - Parameters:
    ///   - label: Human-readable name for debugging.
    ///   - qos: Quality of service for priority handling.
    ///   - target: Target queue for execution (nil for default).
    public convenience init(serialLabel: String = "SerialDispatchExec",
                            qos: DispatchQoS = .default,
                            target: DispatchQueue? = nil)
    {
        self.init(label: serialLabel, qos: qos, attributes: [], target: target)
    }

    /// Required protocol method — invoked by Swift runtime when a task is enqueued.
    ///
    /// This method must be fast and non-blocking. We wrap the job in an `UnownedJob`,
    /// and submit it asynchronously to the dispatch queue. Swift's runtime retains the
    /// executor via the `UnownedTaskExecutor` so it can safely call into it.
    public func enqueue(_ job: consuming ExecutorJob) {
        let exec = asUnownedTaskExecutor() // Stable, reusable reference to this executor
        let unowned = UnownedJob(job) // Wrap the consuming job for lifecycle safety

        queue.async {
            // This block executes off the main thread.
            // Since this is not actor-isolated, we pass nil for `isolatedTo`.
            unowned.runSynchronously(on: exec)
        }
    }

    /// Return a stable, identity-preserving executor reference.
    ///
    /// Swift requires this to keep long-term references to the executor
    /// for equality checks and lifetime management.
    public func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
