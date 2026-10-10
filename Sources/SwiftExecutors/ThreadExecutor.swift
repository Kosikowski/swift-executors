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
/// Jobs run in batches, one batch per pass of the thread's run loop, so the
/// run loop's timers, ports and other sources keep firing however busy the
/// executor is.
///
/// Jobs never run inside one another. If a job spins the thread's run loop,
/// as some legacy APIs do while they wait for a callback, run-loop sources and
/// callbacks still fire, but other jobs wait until that job returns. So a job
/// that spins while it waits for another job on this executor, such as a
/// `Task` that calls an actor backed by it, waits until it gives up. Have the
/// callback reach the actor with `assumeIsolated`, `await` the result rather
/// than spin, or let jobs run inside the spin with `allowingNestedJobs(_:)`.
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

    /// Exposes the number of jobs waiting for the thread, for testing purposes only.
    @_spi(ThreadExecutorTesting)
    public var testQueuedJobCount: Int {
        worker.queuedJobCount
    }

    /// Spins up the thread & run-loop pair exactly once.
    ///
    /// - Parameters:
    ///   - name: Shows up in Instruments and thread lists, handy for
    ///     debugging.
    ///   - qualityOfService: The thread's quality of service. `nil`, the
    ///     default, inherits the creating thread's. Real-time work such as
    ///     audio should ask for `.userInteractive` rather than run at the
    ///     priority of whatever happened to create the executor.
    ///
    public init(name: String = "ThreadExecutor", qualityOfService: QualityOfService? = nil) {
        // Step 1: The worker must not reference `self`: the executor's
        //         lifetime is driven by its owners, not by its own thread.
        let worker = Worker()
        let thread = Thread { worker.run() }

        // Step 2: Human-readable thread label for debuggers & Instruments.
        thread.name = name
        thread.qualityOfService = qualityOfService ?? Thread.currentQoS

        // Step 3: Start the thread and block until its run loop is ready.
        thread.start()
        worker.waitUntilReady()

        self.thread = thread
        self.worker = worker
    }

    /// Called by the Swift runtime every time a job arrives, whether it is
    /// isolated to an actor backed by this executor or is a task that prefers
    /// this executor.
    /// Must be **non-blocking** - schedule, then *return immediately*.
    ///
    public func enqueue(_ job: consuming ExecutorJob) {
        // A noncopyable `ExecutorJob` cannot be stored in the queue, so carry
        // it as an `UnownedJob`; the runtime keeps the job alive until it has
        // run. While jobs are queued or running the queue also holds `self`,
        // so the executor outlives every job queued on it.
        worker.submit(UnownedJob(job), on: self)
    }

    /// Runs `body`, letting other jobs on this executor run whenever `body`
    /// spins the thread's run loop in the default mode.
    ///
    /// Jobs normally never run inside one another, so a job that spins the
    /// run loop until another job on this executor has run waits forever:
    /// for example, a call to a legacy API that runs the run loop until its
    /// reply arrives, when the reply reaches it through a `Task` or an actor
    /// backed by this executor. Wrap such a call in this method to let the
    /// waiting jobs run inside it.
    ///
    /// Use it only where the calling job's state is consistent: as at an
    /// `await`, any code isolated to this executor - the calling actor's own
    /// methods included - may run before `body` returns. Jobs that run inside
    /// `body` do not let further jobs run inside themselves unless they call
    /// this method too.
    ///
    /// Any code on the executor's thread may call this method, a run-loop
    /// callback included. A callback that fires while a job spins the run
    /// loop and calls it lets the waiting jobs run inside that job, whether
    /// or not the job called it itself.
    ///
    /// Must be called on the executor's thread.
    public func allowingNestedJobs<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
        precondition(isCurrentThread, "allowingNestedJobs must be called on the '\(thread.name ?? "ThreadExecutor")' thread")
        return try worker.allowingNestedJobs(body)
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
        worker.isCurrentThread
    }

    deinit {
        // Mark the thread as cancelled so well-behaved APIs can bail out.
        thread.cancel()

        // The queue holds the executor while it has jobs, so none are queued
        // or running by now. This may run on the worker thread itself, when
        // the queue let go of the last reference.
        worker.requestStop()
    }
}

/// Runs jobs on the worker thread, one batch per pass of its run loop.
///
/// `queue` and `stopRequested` are shared between threads. `isDraining`,
/// `unstarted`, `allowsNestedJobs`, `depth`, `hasStoppedNestedRun` and
/// `isStopped` are touched only on the worker thread. `runLoop`, `threadID`
/// and `source` are written once on the worker thread before `ready` is
/// signalled, and read elsewhere only after `waitUntilReady()`.
private final class Worker: @unchecked Sendable {
    /// Jobs waiting for the thread, and the executor they run on.
    struct Queue {
        var jobs: [UnownedJob] = []

        /// Set while jobs are queued or running, so that none of them runs
        /// against a freed executor.
        var owner: ThreadExecutor?
    }

    private(set) var runLoop: CFRunLoop!
    private(set) var threadID: pthread_t!

    /// Signalled while jobs are waiting; its callout runs them. Being a
    /// source, it also keeps the run loop from finishing while it is idle.
    private var source: CFRunLoopSource!

    private let ready = DispatchSemaphore(value: 0)
    private let queue = Mutex(Queue())
    private let stopRequested = Atomic(false)
    private var isDraining = false

    /// The jobs of the running batch that have not started yet.
    private var unstarted: ArraySlice<UnownedJob> = []

    /// Whether the job running now lets other jobs run inside it.
    private var allowsNestedJobs = false

    private var isStopped = false

    /// Whether a stop request has already stopped a nested run once.
    private var hasStoppedNestedRun = false

    /// How many default-mode runs of the run loop are in progress. 1 means
    /// only the thread's own run; more means code on the thread is running
    /// the run loop again from inside it.
    private var depth = 0

    var isCurrentThread: Bool {
        pthread_equal(pthread_self(), threadID) != 0
    }

    var queuedJobCount: Int {
        queue.withLock { $0.jobs.count }
    }

    /// The worker thread's body.
    func run() {
        runLoop = CFRunLoopGetCurrent()
        threadID = pthread_self()

        // The source refers to the worker without retaining it. It cannot
        // call back once the worker is gone: it is invalidated before
        // `run()` returns.
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        context.perform = { info in
            Unmanaged<Worker>.fromOpaque(info!).takeUnretainedValue().drain()
        }
        source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        CFRunLoopAddSource(runLoop, source, .defaultMode)

        let activities: CFRunLoopActivity = [.entry, .beforeSources, .beforeWaiting, .exit]
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, 0) { _, activity in
            self.observe(activity)
        }
        CFRunLoopAddObserver(runLoop, observer, .defaultMode)

        ready.signal()

        // CFRunLoopRun() also returns when code on this thread calls
        // CFRunLoopStop(); only stopIfRequested() may end the thread.
        while !isStopped {
            CFRunLoopRun()
        }

        // Nothing calls into the worker once these are gone, and nothing
        // left on the run loop refers to it.
        CFRunLoopObserverInvalidate(observer)
        CFRunLoopSourceInvalidate(source)
    }

    func waitUntilReady() {
        ready.wait()
    }

    /// Queues `job` to run on `executor` and makes sure a drain is due.
    /// Callable from any thread.
    func submit(_ job: UnownedJob, on executor: ThreadExecutor) {
        let wasIdle = queue.withLock { queue in
            queue.jobs.append(job)
            if queue.owner == nil {
                queue.owner = executor
            }
            return queue.jobs.count == 1
        }
        // While jobs are waiting a drain is already due: the source is
        // signalled, or a drain is running and checks the queue once its
        // batch is done. A job queued from inside that drain is left to
        // that check too, unless the running job lets jobs in before then.
        guard wasIdle, !(isCurrentThread && isDraining && !allowsNestedJobs) else { return }

        CFRunLoopSourceSignal(source)
        // In case the run-loop is napping, prod it so it wakes up soon.
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `body`, letting other jobs run inside the current job whenever
    /// `body` spins the run loop. Callable only on the worker thread.
    func allowingNestedJobs<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
        let allowed = allowsNestedJobs
        allowsNestedJobs = true
        defer { allowsNestedJobs = allowed }
        if isDraining {
            // The jobs behind this one in its batch go back to the front of
            // the queue, and with those queued since, may now run inside it.
            let behind = unstarted
            unstarted = []
            let hasWaiting = queue.withLock { queue in
                queue.jobs.insert(contentsOf: behind, at: 0)
                return !queue.jobs.isEmpty
            }
            if hasWaiting {
                CFRunLoopSourceSignal(source)
            }
        }
        return try body()
    }

    /// Asks the thread to finish. Callable from any thread, this one included.
    func requestStop() {
        stopRequested.store(true, ordering: .releasing)
        // Guarantees the run loop another pass, in which stopIfRequested() runs.
        CFRunLoopSourceSignal(source)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs the jobs queued so far. Jobs queued meanwhile run in the next
    /// pass of the run loop, after it has serviced its timers and ports.
    ///
    /// Never nests unless the running job allows it: if a job spins the run
    /// loop, the drains that fire inside that spin return at once, and the
    /// jobs wait until that job returns.
    private func drain() {
        guard !isDraining || allowsNestedJobs else { return }
        let isNested = isDraining

        // Unowned references only: the owner keeps the executor alive until
        // the batch has run.
        let (batch, executors) = queue.withLock { queue in
            var batch: [UnownedJob] = []
            swap(&batch, &queue.jobs)
            return (batch, queue.owner.map { ($0.asUnownedSerialExecutor(), $0.asUnownedTaskExecutor()) })
        }
        // Every queued job sets the owner, so no owner means no jobs: the
        // signal came from a stop request, or its jobs ran in an earlier pass.
        guard let (serialExecutor, taskExecutor) = executors else { return }

        // A drain inside a job runs only once that job has put the rest of
        // its batch back in the queue.
        assert(unstarted.isEmpty, "A drain started with jobs of another batch left")
        let allowedNestedJobs = allowsNestedJobs
        unstarted = batch[...]
        isDraining = true
        // Each job decides for itself whether jobs may run inside it.
        allowsNestedJobs = false
        // Running with both roles makes each job isolated to the serial
        // executor *and* keeps the task's executor preference pointed at
        // this thread. `runSynchronously` runs & *removes* the job exactly
        // once.
        while let job = unstarted.popFirst() {
            job.runSynchronously(isolatedTo: serialExecutor, taskExecutor: taskExecutor)
        }
        isDraining = isNested
        allowsNestedJobs = allowedNestedJobs

        let (hasMore, released) = queue.withLock { queue -> (Bool, ThreadExecutor?) in
            if !queue.jobs.isEmpty {
                return (true, nil)
            }
            // A nested drain leaves the owner to the drain around it, whose
            // batch is still running.
            return (false, isNested ? nil : queue.owner.take())
        }
        if hasMore {
            // This callout is still running, so the run loop polls rather
            // than sleeps before its next pass: no need to wake it up.
            CFRunLoopSourceSignal(source)
        }
        // Dropping the last reference to the executor runs its deinit here,
        // on the worker thread.
        withExtendedLifetime(released) {}
    }

    /// Tracks how deeply the run loop is nested, and stops it when asked.
    private func observe(_ activity: CFRunLoopActivity) {
        switch activity {
        case .entry:
            depth += 1
        case .exit:
            depth -= 1
            // Back in the thread's own run, which may go to sleep without
            // another pass if this nested run was started from an observer.
            if depth == 1, stopRequested.load(ordering: .acquiring) {
                CFRunLoopWakeUp(runLoop)
            }
        default:
            stopIfRequested()
        }
    }

    /// Ends the thread's own run for good once a stop has been requested.
    ///
    /// If a callback on this thread is running the run loop in the default
    /// mode at that moment, its run is stopped once, the way `CFRunLoopStop()`
    /// asks whoever runs the run loop to return, so a callback that runs it
    /// until stopped returns too. Later runs are left alone: stopping each of
    /// them would keep a callback that polls the run loop from ever sleeping.
    /// The thread's own run stops in its first pass after the callback returns.
    private func stopIfRequested() {
        guard !isStopped, stopRequested.load(ordering: .acquiring) else { return }
        if depth == 1 {
            isStopped = true
            CFRunLoopStop(runLoop)
        } else if !hasStoppedNestedRun {
            hasStoppedNestedRun = true
            CFRunLoopStop(runLoop)
        }
    }
}

extension Thread {
    /// The quality of service of the calling thread.
    static var currentQoS: QualityOfService {
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE: .userInteractive
        case QOS_CLASS_USER_INITIATED: .userInitiated
        case QOS_CLASS_DEFAULT: .default
        case QOS_CLASS_UTILITY: .utility
        case QOS_CLASS_BACKGROUND: .background
        default: .default
        }
    }
}
