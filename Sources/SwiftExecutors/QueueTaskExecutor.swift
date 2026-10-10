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
public final class QueueTaskExecutor: TaskExecutor {
    /// Private operation queue used as the underlying thread pool.
    private let queue: OperationQueue

    /// Creates a new task executor backed by an NSOperationQueue.
    ///
    /// - Parameters:
    ///   - label: Human-readable name for debugging (Instruments/Xcode).
    ///   - maxConcurrent: Max simultaneous tasks (throttles throughput). Must be
    ///     positive, or `OperationQueue.defaultMaxConcurrentOperationCount`: a
    ///     queue with a limit of 0 would never run a job.
    ///   - qos: Quality of service for priority handling (e.g. `.userInitiated`, `.background`).
    public init(label: String = "TaskExec",
                maxConcurrent: Int = OperationQueue.defaultMaxConcurrentOperationCount,
                qos: QualityOfService = .default)
    {
        precondition(
            maxConcurrent > 0 || maxConcurrent == OperationQueue.defaultMaxConcurrentOperationCount,
            "maxConcurrent must be positive or OperationQueue.defaultMaxConcurrentOperationCount, not \(maxConcurrent): no job would ever run"
        )
        queue = OperationQueue()
        queue.name = label
        queue.maxConcurrentOperationCount = maxConcurrent // Throttle concurrency at the queue level
        queue.qualityOfService = qos // Influence thread priority and scheduling
    }

    /// Required protocol method — invoked by Swift runtime when a task is enqueued.
    ///
    /// This method must be fast and non-blocking. A noncopyable `ExecutorJob`
    /// cannot be captured by an escaping closure, so we carry it across as an
    /// `UnownedJob`; the runtime keeps the job alive until it has run.
    public func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedTaskExecutor()

        queue.addOperation {
            // Not actor-isolated: the job runs with only this task executor.
            unownedJob.runSynchronously(on: executor)
        }
    }
}
