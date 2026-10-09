//
//  ThreadExecutor.swift
//  SwiftExecutors
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import Foundation

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
/// You *would not* use this for high-throughput background work - that's what a
/// `QueueTaskExecutor` or `DispatchQueueTaskExecutor` is for.
///
public final class ThreadExecutor: SerialExecutor, TaskExecutor, @unchecked Sendable {
    /// The long-lived worker thread. Lives for the lifetime of the executor.
    private let thread: Thread

    /// The worker thread's run loop, used to schedule jobs onto it.
    private let runLoop: CFRunLoop

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
        runLoop
    }

    /// Spins up the thread & run-loop pair exactly once.
    ///
    /// - Parameter name: Shows up in Instruments and thread lists, handy
    ///   for debugging.
    ///
    public init(name: String = "ThreadExecutor") {
        // Step 1: Values the worker thread hands back once its run loop exists.
        //         The semaphore orders the writes before the reads below.
        let handoff = ThreadHandoff()

        // Step 2: Define the thread body - this runs *on the new thread*.
        //         It must not capture `self`: the executor's lifetime is
        //         driven by its owners, not by its own thread.
        let thread = Thread {
            let runLoop = CFRunLoopGetCurrent()!

            // A run loop with no sources returns from CFRunLoopRun() at once,
            // which would let the thread exit before any job arrives. This
            // never-signalled source keeps it parked until deinit stops it.
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            CFRunLoopAddSource(runLoop, keepAlive, .defaultMode)

            handoff.runLoop = runLoop
            handoff.threadID = pthread_self()

            // Tell the creating thread the run-loop is ready to accept work.
            handoff.ready.signal()

            // From here on the thread parks inside the CFRunLoop event pump
            // until deinit stops it.
            CFRunLoopRun()
        }

        // Step 3: Human-readable thread label for debuggers & Instruments.
        thread.name = name
        thread.qualityOfService = Thread.currentQos // Inherit caller's QoS
        // To prevent priority inversion set to .userInteractive

        // Step 4: Start the thread and block until it reports its run loop.
        thread.start()
        handoff.ready.wait()

        self.thread = thread
        runLoop = handoff.runLoop!
        threadID = handoff.threadID!
    }

    /// Called by the Swift runtime every time a job arrives, whether it is
    /// isolated to an actor backed by this executor or is a task that prefers
    /// this executor.
    /// Must be **non-blocking** - schedule, then *return immediately*.
    ///
    public func enqueue(_ job: consuming ExecutorJob) {
        // 1. A noncopyable `ExecutorJob` cannot be captured by an escaping
        //    closure, so carry it across as an `UnownedJob`. The runtime keeps
        //    the job alive until it has run.
        let unownedJob = UnownedJob(job)

        // 2. Unowned references to `self` in both roles. Running with both
        //    makes the job isolated to this serial executor *and* keeps the
        //    task's executor preference pointed at this thread.
        let serialExecutor = asUnownedSerialExecutor()
        let taskExecutor = asUnownedTaskExecutor()

        // 3. Ask the run-loop to perform the block on its own thread.
        //    `defaultMode` is fine; if you need a custom mode, pass it here.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            // `runSynchronously` runs & *removes* the job exactly once.
            unownedJob.runSynchronously(isolatedTo: serialExecutor, taskExecutor: taskExecutor)
        }

        // 4. In case the run-loop is napping, prod it so it wakes up soon.
        CFRunLoopWakeUp(runLoop)
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
        precondition(isCurrentThread, "Expected to be running on the '\(thread.name ?? "ThreadExecutor")' thread")
    }

    private var isCurrentThread: Bool {
        pthread_equal(pthread_self(), threadID) != 0
    }

    deinit {
        // Stop the run-loop after the jobs already queued on it have run.
        // Capture the run loop, not `self`: the block outlives this deinit.
        let runLoop = runLoop
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)

        // Mark the thread as cancelled so well-behaved APIs can bail out.
        thread.cancel()
    }
}

/// Carries the worker thread's run loop and identity back to `init`.
///
/// Written once on the worker thread before `ready` is signalled, and read
/// only after `ready.wait()` returns, so the semaphore provides the ordering.
private final class ThreadHandoff: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    var runLoop: CFRunLoop?
    var threadID: pthread_t?
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
