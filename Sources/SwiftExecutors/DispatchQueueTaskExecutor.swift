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
public final class DispatchQueueTaskExecutor: TaskExecutor {
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
    public convenience init(concurrentLabel: String,
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
    public convenience init(serialLabel: String,
                            qos: DispatchQoS = .default,
                            target: DispatchQueue? = nil)
    {
        self.init(label: serialLabel, qos: qos, attributes: [], target: target)
    }

    /// Required protocol method — invoked by Swift runtime when a task is enqueued.
    ///
    /// This method must be fast and non-blocking. A noncopyable `ExecutorJob`
    /// cannot be captured by an escaping closure, so we carry it across as an
    /// `UnownedJob`; the runtime keeps the job alive until it has run.
    public func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedTaskExecutor()

        queue.async {
            // Not actor-isolated: the job runs with only this task executor.
            unownedJob.runSynchronously(on: executor)
        }
    }
}
