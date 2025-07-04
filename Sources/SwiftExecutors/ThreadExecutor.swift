//
//  job.swift
//  swift-executors
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import Foundation

/// A custom executor that pins every actor job to one dedicated Thread.
///
/// When to use it:
///   • Legacy C / C++ / Objective-C libraries that rely on thread-local storage
///   • Frameworks that demand a single-thread affinity (Core MIDI, Core Audio)
///   • Real-time loops that must never hop between cores (jank = audio glitches)
///
/// You *would not* use this for high-throughput background work-that's what a
/// TaskExecutor + NSOperationQueue or Dispatch queue is for.
///
public final class ThreadExecutor: SerialExecutor, @unchecked Sendable {
    /// The long-lived worker thread. Lives for the lifetime of the executor.
    private var thread: Thread!

    /// Exposes the thread for testing purposes only.
    @_spi(ThreadExecutorTesting)
    public var testThread: Thread {
        thread
    }

    /// We capture the Thread's CFRunLoop so we can schedule blocks onto it.
    /// NOTE: It's `!` on purpose – the run-loop is set *inside* the thread body
    /// and is guaranteed to exist before `init` returns.
    private var runLoop: CFRunLoop!

    // ... rest of the class remains unchanged ...

    /// Spins up the thread & run-loop pair exactly once.
    ///
    /// - Parameter name: Shows up in Instruments and thread lists, handy
    ///   for debugging.
    ///
    public init(name: String = "ThreadExecutor") {
        // Step 1: A semaphore so the main thread can wait until the worker
        //         thread has captured its run-loop.
        let ready = DispatchSemaphore(value: 0)

        // Step 2: Define the thread body - this runs *on the new thread*.
        let thread = Thread { [weak self] in
            // Save the run-loop so enqueue(_:) can get to it later.
            self?.runLoop = CFRunLoopGetCurrent()

            // Tell the main thread the run-loop is ready to accept work.
            ready.signal()

            // Start the run-loop.  From here on the thread parks inside
            //     the CFRunLoop event pump until we stop it in deinit.
            CFRunLoopRun()
        }

        // Step 3: Human-readable thread label for debuggers & Instruments.
        thread.name = name
        thread.qualityOfService = Thread.currentQos // Inherit caller's QoS
        // To prevent priority inversion set to .userInteractive

        self.thread = thread

        // Step 4: Kick the tires - the thread begins executing the closure
        //         defined above.
        thread.start()

        // Step 5: Block *this* thread (the caller) until the worker says
        //         "run-loop ready."  Guarantees enqueue(_:) won't crash.
        ready.wait()
    }

    /// Called by the Swift runtime every time an *actor job* arrives.
    /// Must be **non-blocking** - schedule, then *return immediately*.
    ///
    public func enqueue(_ job: consuming ExecutorJob) {
        // 1. Convert the `consuming` job into an UnownedJob wrapper so the
        //    runtime can safely hold onto it until the callback fires.
        let unowned = UnownedJob(job)

        // 2. Grab a *stable* reference to `self` as an unowned executor.
        //    ︙  IMPORTANT: You MUST cache & reuse this for equality checks.
        let exec = asUnownedSerialExecutor()

        // 3. Ask the run-loop to perform the block on its own thread.
        //    `defaultMode` is fine; if you need a custom mode, pass it here.
        CFRunLoopPerformBlock(runLoop,
                              CFRunLoopMode.defaultMode.rawValue)
        {
            // 3a. Finally run the job on the target thread.
            //     `runSynchronously` runs & *removes* the job exactly once.
            unowned.runSynchronously(on: exec)
        }

        // 4. In case the run-loop is napping, prod it so it wakes up soon.
        CFRunLoopWakeUp(runLoop)
    }

    /// Return a canonical, identity-stable wrapper that the runtime can keep
    /// forever.  Re-creating wrappers on each call breaks equality tests.
    ///
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    deinit {
        // Gracefully stop the run-loop *on its own thread*.
        // We can't call CFRunLoopStop() from a different thread.
        CFRunLoopPerformBlock(runLoop,
                              CFRunLoopMode.defaultMode.rawValue)
        {
            CFRunLoopStop(self.runLoop)
        }
        CFRunLoopWakeUp(runLoop)

        // Mark the thread as cancelled so well-behaved APIs can bail out.
        thread.cancel()
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
