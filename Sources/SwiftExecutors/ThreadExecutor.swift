//
//  ThreadExecutor.swift
//  SwiftExecutors
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import Foundation
import Synchronization

/// An executor that runs every job on one dedicated `Thread`.
///
/// When to use it:
///   • Legacy C / C++ / Objective-C libraries that rely on thread-local storage
///   • Frameworks that demand a single-thread affinity (Core MIDI, Core Audio)
///   • Real-time loops that must never hop between cores (jank = audio glitches)
///
/// It is both a `SerialExecutor` and a `TaskExecutor`:
///   • as a `SerialExecutor` it can back an actor through `unownedExecutor`,
///     pinning all of that actor's code to the thread;
///   • as a `TaskExecutor` it can be passed to `withTaskExecutorPreference(_:)`,
///     `Task(executorPreference:)` or `group.addTask(executorPreference:)`,
///     so nonisolated async code runs on the thread too.
///
/// Jobs never run inside one another. If a job spins the thread's run loop,
/// as some legacy APIs do while they wait for a callback, run-loop sources and
/// callbacks still fire, but other jobs wait until that job returns.
///
/// Every job runs isolated to this executor, so a call from it to a
/// `@concurrent` function goes back through the run loop instead of
/// continuing inline.
///
/// You *would not* use this for high-throughput background work - that's what a
/// `QueueTaskExecutor` or `DispatchQueueTaskExecutor` is for.
///
public final class ThreadExecutor: SerialExecutor, TaskExecutor, @unchecked Sendable {
    /// The long-lived worker thread. Lives for the lifetime of the executor.
    private let thread: Thread

    /// Owns the thread's run loop and the jobs waiting for it.
    private let worker: Worker

    /// The worker thread's POSIX identity, used for cheap isolation checks.
    private let threadID: pthread_t

    /// Exposes the thread for testing purposes only.
    @_spi(ThreadExecutorTesting)
    public var testThread: Thread {
        thread
    }

    /// Exposes the run loop for testing purposes only.
    @_spi(ThreadExecutorTesting)
    public var testRunLoop: CFRunLoop {
        worker.runLoop
    }

    /// Spins up the thread & run-loop pair exactly once.
    ///
    /// - Parameter name: Shows up in Instruments and thread lists, handy
    ///   for debugging.
    ///
    public init(name: String = "ThreadExecutor") {
        // Step 1: The worker must not reference `self`: the executor's
        //         lifetime is driven by its owners, not by its own thread.
        let worker = Worker()
        let thread = Thread { worker.run() }

        // Step 2: Human-readable thread label for debuggers & Instruments.
        thread.name = name
        thread.qualityOfService = Thread.currentQos // Inherit caller's QoS
        // To prevent priority inversion set to .userInteractive

        // Step 3: Start the thread and block until its run loop is ready.
        thread.start()
        worker.waitUntilReady()

        self.thread = thread
        self.worker = worker
        threadID = worker.threadID
    }

    /// Called by the Swift runtime every time a job arrives, whether it is
    /// isolated to an actor backed by this executor or is a task that prefers
    /// this executor.
    /// Must be **non-blocking** - schedule, then *return immediately*.
    ///
    public func enqueue(_ job: consuming ExecutorJob) {
        // A noncopyable `ExecutorJob` cannot be stored in the queue, so carry
        // it as an `UnownedJob`; the runtime keeps the job alive until it has
        // run. The queue also holds `self`, so the executor outlives every
        // job queued on it.
        worker.submit(.job(UnownedJob(job), self))
    }

    /// Reports whether the caller is running on this executor's thread.
    ///
    /// The runtime asks this when it cannot prove isolation from its own
    /// bookkeeping - for example, `assumeIsolated` called from a C callback
    /// that the thread-affine library delivers on this thread.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    public func isIsolatingCurrentContext() -> Bool? {
        isCurrentThread
    }

    /// Crashes unless the caller is running on this executor's thread.
    ///
    /// Used by the runtime on OS versions that predate
    /// `isIsolatingCurrentContext()`.
    public func checkIsolated() {
        // Not `precondition`: the runtime relies on this trapping even in
        // -Ounchecked builds.
        if !isCurrentThread {
            fatalError("Expected to be running on the '\(thread.name ?? "ThreadExecutor")' thread")
        }
    }

    private var isCurrentThread: Bool {
        pthread_equal(pthread_self(), threadID) != 0
    }

    deinit {
        // Queued jobs hold the executor, so none are left by now. The stop
        // goes through the same queue as jobs, so it never lands inside one.
        worker.submit(.stop)

        // Mark the thread as cancelled so well-behaved APIs can bail out.
        thread.cancel()
    }
}

/// Runs queued work on the worker thread, one item at a time.
///
/// `pending` is shared between threads behind a mutex. `isDraining`,
/// `isStopped` and `keepAlive` are touched only on the worker thread.
/// `runLoop` and `threadID` are written once on the worker thread before
/// `ready` is signalled, and read elsewhere only after `waitUntilReady()`.
private final class Worker: @unchecked Sendable {
    enum Work: Sendable {
        /// A job and the executor it runs on, kept alive until the job has run.
        case job(UnownedJob, ThreadExecutor)
        case stop
    }

    private(set) var runLoop: CFRunLoop!
    private(set) var threadID: pthread_t!

    private let ready = DispatchSemaphore(value: 0)
    private let pending = Mutex<[Work]>([])
    private var keepAlive: CFRunLoopSource!
    private var isDraining = false
    private var isStopped = false

    /// The worker thread's body.
    func run() {
        runLoop = CFRunLoopGetCurrent()
        threadID = pthread_self()

        // A run loop with no sources returns from CFRunLoopRun() at once,
        // which would let the thread exit before any job arrives. This
        // never-signalled source keeps it parked until stop().
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        CFRunLoopAddSource(runLoop, keepAlive, .defaultMode)

        ready.signal()

        // CFRunLoopRun() also returns when code on this thread calls
        // CFRunLoopStop(); only stop() may end the thread.
        while !isStopped {
            CFRunLoopRun()
        }
    }

    func waitUntilReady() {
        ready.wait()
    }

    /// Queues `work` and makes sure a drain is scheduled. Callable from any thread.
    func submit(_ work: Work) {
        let wasEmpty = pending.withLock { queue in
            queue.append(work)
            return queue.count == 1
        }
        // While the queue is non-empty a drain is already scheduled or running.
        guard wasEmpty else { return }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            self.drain()
        }
        // In case the run-loop is napping, prod it so it wakes up soon.
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs queued work in order.
    ///
    /// Never nests: if a job spins the run loop, the drain blocks that fire
    /// inside that spin return at once, and this loop picks up their work
    /// when the job returns.
    private func drain() {
        guard !isDraining, !isStopped else { return }
        isDraining = true
        defer { isDraining = false }

        while true {
            let batch = pending.withLock { queue in
                var batch: [Work] = []
                swap(&batch, &queue)
                return batch
            }
            if batch.isEmpty {
                return
            }
            for work in batch {
                switch work {
                case let .job(job, executor):
                    // Running with both roles makes the job isolated to the
                    // serial executor *and* keeps the task's executor
                    // preference pointed at this thread. `runSynchronously`
                    // runs & *removes* the job exactly once.
                    job.runSynchronously(
                        isolatedTo: executor.asUnownedSerialExecutor(),
                        taskExecutor: executor.asUnownedTaskExecutor()
                    )
                case .stop:
                    stop()
                    return
                }
            }
        }
    }

    /// Makes the outer `CFRunLoopRun()` return for good, ending the thread.
    private func stop() {
        isStopped = true
        // Without the keep-alive source the run loop also finishes on its own
        // if this stop lands in a nested run started outside any job.
        CFRunLoopRemoveSource(runLoop, keepAlive, .defaultMode)
        CFRunLoopStop(runLoop)
    }
}

extension Thread {
    static var currentQos: QualityOfService {
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE: return .userInteractive
        case QOS_CLASS_USER_INITIATED: return .userInitiated
        case QOS_CLASS_DEFAULT: return .default
        case QOS_CLASS_UTILITY: return .utility
        case QOS_CLASS_BACKGROUND: return .background
        default: return .default
        }
    }
}
