//
//  QueueTaskExecutor.swift
//  SwiftExecutors
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import Foundation

/// A TaskExecutor backed by NSOperationQueue.
///
/// This executor allows you to offload free-standing tasks to an
/// NSOperationQueue-based thread pool. It’s useful when you want to
/// control concurrency, prioritise work, or isolate blocking/CPU-heavy
/// operations away from Swift’s cooperative thread pool.
public final class QueueTaskExecutor: TaskExecutor, @unchecked Sendable {
    /// Private operation queue used as the underlying thread pool.
    private let queue: OperationQueue

    /// Creates a new task executor backed by an NSOperationQueue.
    ///
    /// - Parameters:
    ///   - label: Human-readable name for debugging (Instruments/Xcode).
    ///   - maxConcurrent: Max simultaneous tasks (throttles throughput).
    ///   - qos: Quality of service for priority handling (e.g. `.userInitiated`, `.background`).
    public init(label: String = "TaskExec",
                maxConcurrent: Int = OperationQueue.defaultMaxConcurrentOperationCount,
                qos: QualityOfService = .default)
    {
        queue = OperationQueue()
        queue.name = label
        queue.maxConcurrentOperationCount = maxConcurrent // Throttle concurrency at the queue level
        queue.qualityOfService = qos // Influence thread priority and scheduling
    }

    /// Required protocol method — invoked by Swift runtime when a task is enqueued.
    ///
    /// This method must be fast and non-blocking. We wrap the job in an `UnownedJob`,
    /// and submit it asynchronously to the OperationQueue. Swift’s runtime retains the
    /// executor via the `UnownedTaskExecutor` so it can safely call into it.
    public func enqueue(_ job: consuming ExecutorJob) {
        let exec = asUnownedTaskExecutor() // Stable, reusable reference to this executor
        let unowned = UnownedJob(job) // Wrap the consuming job for lifecycle safety

        queue.addOperation {
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
