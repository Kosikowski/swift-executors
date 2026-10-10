//
//  ThreadExecutorTests.swift
//  SwiftExecutorsTests
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import CoreFoundation
import Foundation
@_spi(ThreadExecutorTesting) import SwiftExecutors
import Synchronization
import Testing

/// An actor whose code always runs on the thread of `executor`.
actor PinnedCounter {
    let executor: ThreadExecutor
    private(set) var value = 0

    init(executor: ThreadExecutor) {
        self.executor = executor
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func increment() -> Int {
        value += 1
        return value
    }

    func isOnExecutorThread() -> Bool {
        Thread.current == executor.testThread
    }
}

/// An actor that spins its thread's run loop the way legacy APIs do while
/// they wait for a callback.
actor RunLoopSpinner {
    let executor: ThreadExecutor
    private var isSpinning = false
    private(set) var log: [String] = []

    init(executor: ThreadExecutor) {
        self.executor = executor
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Runs the run loop in the default mode until `done()` or `timeout`,
    /// and reports whether `done()` was reached.
    func spin(timeout: Duration = .milliseconds(200),
              allowingNestedJobs: Bool = false,
              onStart: @Sendable () -> Void = {},
              until done: @Sendable () -> Bool = { false }) -> Bool
    {
        isSpinning = true
        log.append("spin-start")
        onStart()
        let deadline = ContinuousClock.now + timeout
        func runUntilDone() {
            while !done(), ContinuousClock.now < deadline {
                _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            }
        }
        if allowingNestedJobs {
            executor.allowingNestedJobs(runUntilDone)
        } else {
            runUntilDone()
        }
        isSpinning = false
        log.append("spin-end")
        return done()
    }

    /// Throws out of `allowingNestedJobs`, logs the error, then spins the run
    /// loop without it, as `spin(timeout:allowingNestedJobs:onStart:until:)`
    /// does.
    func spinAfterThrowingOutOfNestedJobs(timeout: Duration = .milliseconds(200),
                                          onStart: @Sendable () -> Void = {},
                                          until done: @Sendable () -> Bool = { false }) -> Bool
    {
        do {
            try executor.allowingNestedJobs { () throws(TestError) in throw .boom }
        } catch {
            log.append("threw \(error)")
        }
        return spin(timeout: timeout, onStart: onStart, until: done)
    }

    /// Asks `counter` to count up through a new task, and spins the run loop
    /// until it has, the way a legacy API waits for its reply.
    func spinUntilCounted(by counter: PinnedCounter,
                          timeout: Duration,
                          allowingNestedJobs: Bool,
                          askingInsideTheSpin: Bool = false) -> Bool
    {
        let counted = Flag()
        let deadline = ContinuousClock.now + timeout
        func ask() {
            // Isolated to this actor, so its first job is queued on the
            // executor from inside this one.
            Task {
                _ = await counter.increment()
                log.append("counted")
                counted.raise()
            }
        }
        func waitForReply() {
            if askingInsideTheSpin {
                ask()
            }
            while !counted.isRaised, ContinuousClock.now < deadline {
                _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            }
        }

        log.append("spin-start")
        if !askingInsideTheSpin {
            ask()
        }
        if allowingNestedJobs {
            executor.allowingNestedJobs(waitForReply)
        } else {
            waitForReply()
        }
        log.append("spin-end")
        return counted.isRaised
    }

    /// Logs `entry` and reports whether a spin was in progress.
    func record(_ entry: String) -> Bool {
        log.append(entry)
        return isSpinning
    }

    /// Stops the current run of the thread's run loop, as a legacy library might.
    func stopRunLoop() {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

/// A flag that callbacks on any thread can raise.
final class Flag: Sendable {
    private let raised = Atomic(false)

    var isRaised: Bool {
        raised.load(ordering: .acquiring)
    }

    func raise() {
        raised.store(true, ordering: .releasing)
    }
}

/// Raises a flag when it is freed.
final class Sentinel: Sendable {
    private let freed: Flag

    init(raisingWhenFreed freed: Flag) {
        self.freed = freed
    }

    deinit {
        freed.raise()
    }
}

/// Leaves `sentinel` with the current thread's run loop, in a block queued
/// for a mode that never runs. The run loop lets go of it only when the run
/// loop itself is freed.
func holdUntilRunLoopIsFreed(_ sentinel: Sentinel) {
    CFRunLoopPerformBlock(CFRunLoopGetCurrent(), "test.never" as CFString) {
        _ = sentinel
    }
}

/// Collects values from jobs running on any thread.
final class Recorder: Sendable {
    private let entries = Mutex<[Int]>([])

    var values: [Int] {
        entries.withLock { $0 }
    }

    func append(_ value: Int) {
        entries.withLock { $0.append(value) }
    }
}

/// Runs `body` on the executor's thread as a plain run-loop block, outside
/// any Swift job - the way a thread-affine C library delivers its callbacks.
func runOnThread<T: Sendable>(of executor: ThreadExecutor, _ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let runLoop = executor.testRunLoop
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            continuation.resume(returning: body())
        }
        CFRunLoopWakeUp(runLoop)
    }
}

/// Reads the counter through `assumeIsolated` from whatever thread calls it.
func valueAssumingIsolation(of counter: PinnedCounter) -> Int {
    counter.assumeIsolated { $0.value }
}

/// Waits up to two seconds for `thread` to exit and reports whether it did.
func waitUntilFinished(_ thread: Thread) async -> Bool {
    await waitUntil { thread.isFinished }
}

/// Adds a repeating timer to `runLoop`, as a legacy library might leave one
/// on its thread, and returns it so the caller can invalidate it.
func addTimer(to runLoop: CFRunLoop, every interval: TimeInterval, _ fired: @escaping @Sendable () -> Void) -> CFRunLoopTimer {
    let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0) { _ in
        fired()
    }!
    CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    return timer
}

@Suite("ThreadExecutor")
struct ThreadExecutorTests {
    let executor = ThreadExecutor(name: "test.thread")

    // MARK: - Thread lifecycle

    @Test("The thread is running once init returns")
    func threadIsRunning() {
        #expect(executor.testThread.isExecuting)
        #expect(!executor.testThread.isFinished)
        #expect(!executor.testThread.isCancelled)
    }

    @Test("The thread carries the given name")
    func threadName() {
        #expect(executor.testThread.name == "test.thread")
    }

    @Test("The thread runs at the requested quality of service")
    func threadQualityOfService() {
        let executor = ThreadExecutor(name: "test.thread.qos", qualityOfService: .userInteractive)

        #expect(executor.testThread.qualityOfService == .userInteractive)
    }

    @Test("The thread inherits its creator's quality of service by default")
    func threadInheritsQualityOfService() async {
        let executor = await withCheckedContinuation { (created: CheckedContinuation<ThreadExecutor, Never>) in
            let creator = Thread {
                created.resume(returning: ThreadExecutor(name: "test.thread.inherited-qos"))
            }
            creator.qualityOfService = .utility
            creator.start()
        }

        #expect(executor.testThread.qualityOfService == .utility)
    }

    @Test("Each executor owns a different thread")
    func distinctThreads() {
        let other = ThreadExecutor(name: "test.thread.other")

        #expect(executor.testThread != other.testThread)
    }

    @Test("Releasing the executor stops its thread")
    func deinitStopsThread() async throws {
        var executor: ThreadExecutor? = ThreadExecutor(name: "test.thread.deinit")
        let thread = try #require(executor?.testThread)
        executor = nil

        #expect(await waitUntilFinished(thread))
        #expect(thread.isCancelled)
    }

    @Test("Releasing the executor stops its thread even during a nested run")
    func deinitStopsThreadDuringNestedRun() async throws {
        var executor: ThreadExecutor? = ThreadExecutor(name: "test.thread.nested-deinit")
        let thread = try #require(executor?.testThread)
        let runLoop = try #require(executor?.testRunLoop)

        // A plain callback that runs the loop again, like a legacy API
        // waiting for a reply. The executor is released while it runs.
        await withCheckedContinuation { (spinning: CheckedContinuation<Void, Never>) in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                spinning.resume()
                _ = CFRunLoopRunInMode(.defaultMode, 1, false)
            }
            CFRunLoopWakeUp(runLoop)
        }
        executor = nil

        #expect(await waitUntilFinished(thread))
    }

    @Test("Releasing the executor ends a callback that runs the run loop until stopped, and then the thread")
    func deinitEndsCallbackRunningUntilStopped() async throws {
        var executor: ThreadExecutor? = ThreadExecutor(name: "test.thread.run-until-stopped")
        let thread = try #require(executor?.testThread)
        let runLoop = try #require(executor?.testRunLoop)
        let callbackReturned = Flag()

        // A timer keeps the run loop from ever running out of sources, so
        // the callback's CFRunLoopRun() returns only when stopped.
        let timer = addTimer(to: runLoop, every: 3600) {}
        defer { CFRunLoopTimerInvalidate(timer) }
        await withCheckedContinuation { (running: CheckedContinuation<Void, Never>) in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                running.resume()
                CFRunLoopRun()
                callbackReturned.raise()
            }
            CFRunLoopWakeUp(runLoop)
        }
        executor = nil

        #expect(await waitUntilFinished(thread))
        #expect(callbackReturned.isRaised)
    }

    @Test("A callback still running the run loop when the executor is released keeps waiting normally")
    func callbackWaitingInRunLoopOutlivesRelease() async throws {
        var executor: ThreadExecutor? = ThreadExecutor(name: "test.thread.waiting-callback")
        let thread = try #require(executor?.testThread)
        let runLoop = try #require(executor?.testRunLoop)
        let passes = Counter()
        let replied = Flag()

        // A legacy API that polls the run loop until its reply arrives.
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                waiting.resume()
                while !replied.isRaised {
                    passes.increment()
                    _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
                }
            }
            CFRunLoopWakeUp(runLoop)
        }
        executor = nil
        try await Task.sleep(for: .milliseconds(300))

        // Apart from the one pass the release stops early, each pass sleeps
        // its full 50 ms: the run loop neither keeps stopping under the
        // callback nor spins without sleeping.
        #expect(!thread.isFinished)
        #expect(passes.value < 50)

        replied.raise()
        #expect(await waitUntilFinished(thread))
    }

    @Test("Releasing the executor from its own thread frees its run loop")
    func releaseOnOwnThreadFreesRunLoop() async {
        let freed = Flag()

        // Only the task and the job queue hold the executor, so it is
        // normally released on its own thread as the task finishes there.
        // `releaseDuringJobFreesRunLoop` forces that on Swift 6.3 and later.
        await Task(executorPreference: ThreadExecutor(name: "test.thread.self-release")) {
            holdUntilRunLoopIsFreed(Sentinel(raisingWhenFreed: freed))
        }.value

        #expect(await waitUntil { freed.isRaised })
    }

    @Test("Releasing the executor from another thread frees its run loop")
    func releaseFromAnotherThreadFreesRunLoop() async throws {
        let freed = Flag()
        var executor: ThreadExecutor? = ThreadExecutor(name: "test.thread.release")

        try await runOnThread(of: #require(executor)) {
            holdUntilRunLoopIsFreed(Sentinel(raisingWhenFreed: freed))
        }
        executor = nil

        #expect(await waitUntil { freed.isRaised })
    }

    // `_swift_createJobForTestingOnly` first shipped with Swift 6.3.
    #if compiler(>=6.3)
        @Test("Queued jobs keep the executor alive until they have run")
        @available(macOS 26.4, iOS 26.4, tvOS 26.4, watchOS 26.4, visionOS 26.4, *)
        func queuedJobsKeepExecutorAlive() async throws {
            let recorder = Recorder()
            let gate = DispatchSemaphore(value: 0)
            var executor: ThreadExecutor? = ThreadExecutor(name: "test.thread.drain")
            let thread = try #require(executor?.testThread)

            // The first job holds the thread until `gate` opens, so the rest wait in the queue.
            executor?.enqueue(_swift_createJobForTestingOnly {
                gate.wait()
                recorder.append(0)
            })
            for i in 1 ..< 10 {
                executor?.enqueue(_swift_createJobForTestingOnly { recorder.append(i) })
            }
            executor = nil

            // deinit cancels the thread, so this shows the executor is still alive.
            #expect(!thread.isCancelled)
            gate.signal()

            #expect(await waitUntilFinished(thread))
            #expect(thread.isCancelled)
            #expect(recorder.values == Array(0 ..< 10))
        }

        @Test("Releasing the executor while one of its jobs runs frees its run loop")
        @available(macOS 26.4, iOS 26.4, tvOS 26.4, watchOS 26.4, visionOS 26.4, *)
        func releaseDuringJobFreesRunLoop() async {
            let freed = Flag()
            let gate = DispatchSemaphore(value: 0)
            var executor: ThreadExecutor? = ThreadExecutor(name: "test.thread.release-in-job")

            // The job holds the thread until `gate` opens, so the job queue
            // drops the last reference, on the executor's thread.
            executor?.enqueue(_swift_createJobForTestingOnly {
                holdUntilRunLoopIsFreed(Sentinel(raisingWhenFreed: freed))
                gate.wait()
            })
            executor = nil
            gate.signal()

            #expect(await waitUntil { freed.isRaised })
        }

        @Test("Jobs that run inside another job keep the executor alive for it")
        @available(macOS 26.4, iOS 26.4, tvOS 26.4, watchOS 26.4, visionOS 26.4, *)
        func nestedJobsKeepExecutorAlive() async throws {
            let gate = DispatchSemaphore(value: 0)
            let nestedRan = Flag()
            let outerFinished = Flag()
            var executor: ThreadExecutor? = ThreadExecutor(name: "test.thread.nested-alive")
            let thread = try #require(executor?.testThread)
            unowned let unownedExecutor = try #require(executor)

            // The job queue holds the only reference. The nested job empties
            // the queue while the outer job still runs.
            executor?.enqueue(_swift_createJobForTestingOnly {
                gate.wait()
                unownedExecutor.allowingNestedJobs {
                    while !nestedRan.isRaised {
                        _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
                    }
                }
                // Traps if the executor was freed under the outer job.
                _ = unownedExecutor.testThread
                outerFinished.raise()
            })
            executor?.enqueue(_swift_createJobForTestingOnly { nestedRan.raise() })
            executor = nil
            gate.signal()

            #expect(await waitUntilFinished(thread))
            #expect(outerFinished.isRaised)
        }
    #endif

    // MARK: - As a SerialExecutor

    @Test("An actor backed by the executor runs on its thread")
    func actorRunsOnThread() async {
        let counter = PinnedCounter(executor: executor)

        #expect(await counter.isOnExecutorThread())
        #expect(await counter.increment() == 1)
    }

    @Test("Concurrent calls into the actor are serialised")
    func actorCallsAreSerialised() async {
        let counter = PinnedCounter(executor: executor)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 100 {
                group.addTask { _ = await counter.increment() }
            }
        }

        #expect(await counter.value == 100)
    }

    // `_swift_createJobForTestingOnly` first shipped with Swift 6.3.
    #if compiler(>=6.3)
        @Test("Jobs run in the order they were enqueued")
        @available(macOS 26.4, iOS 26.4, tvOS 26.4, watchOS 26.4, visionOS 26.4, *)
        func jobsRunInOrder() async {
            let recorder = Recorder()

            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                for i in 0 ..< 100 {
                    executor.enqueue(_swift_createJobForTestingOnly {
                        recorder.append(i)
                        if i == 99 {
                            done.resume()
                        }
                    })
                }
            }

            #expect(recorder.values == Array(0 ..< 100))
        }
    #endif

    // MARK: - Run-loop sources while the executor is busy

    @Test("Run-loop timers keep firing while jobs keep arriving")
    func timersFireWhileJobsKeepArriving() async {
        let fires = Counter()
        let timer = addTimer(to: executor.testRunLoop, every: 0.005) { fires.increment() }
        defer { CFRunLoopTimerInvalidate(timer) }

        // Each yield queues the task's next job while the current one runs.
        let (yields, firesDuringYields) = await Task(executorPreference: executor) {
            let firesBefore = fires.value
            let deadline = ContinuousClock.now + .milliseconds(200)
            var yields = 0
            while ContinuousClock.now < deadline {
                await Task.yield()
                yields += 1
            }
            return (yields, fires.value - firesBefore)
        }.value

        #expect(yields > 100)
        // About 40 when nothing holds the timer back.
        #expect(firesDuringYields >= 5)
    }

    @Test("Jobs that keep arriving do not build up memory")
    func jobsThatKeepArrivingDoNotBuildUpMemory() async {
        let growth = await Task(executorPreference: executor) {
            let footprintBefore = physicalFootprint()
            for _ in 0 ..< 100_000 {
                await Task.yield()
            }
            return physicalFootprint() - footprintBefore
        }.value

        #expect(growth < 8 << 20)
    }

    // MARK: - Jobs that run the run loop themselves

    @Test("No job runs inside a job that spins the run loop")
    func jobsDoNotNestInsideASpin() async {
        let executor = executor
        let spinner = RunLoopSpinner(executor: executor)
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)

        // The spin lasts until all the probes are queued, so they certainly
        // arrive while it runs.
        let spin = Task {
            await spinner.spin(
                timeout: .seconds(5),
                onStart: { startedContinuation.yield() },
                until: { executor.testQueuedJobCount >= 5 }
            )
        }
        for await _ in started {
            break
        }
        let anyRanInsideSpin = await withTaskGroup(of: Bool.self) { group in
            for i in 0 ..< 5 {
                group.addTask { await spinner.record("probe-\(i)") }
            }
            return await group.contains(true)
        }
        let probesArrivedDuringSpin = await spin.value

        #expect(probesArrivedDuringSpin)
        #expect(!anyRanInsideSpin)
        let log = await spinner.log
        #expect(log.prefix(2) == ["spin-start", "spin-end"])
        #expect(log.count == 7)
    }

    @Test("Run-loop callbacks still fire while a job spins")
    func callbacksFireDuringSpin() async {
        let spinner = RunLoopSpinner(executor: executor)
        let delivered = Flag()

        let completed = await spinner.spin(
            timeout: .seconds(5),
            onStart: {
                // A legacy library schedules its reply on the current run loop.
                CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) {
                    delivered.raise()
                }
            },
            until: { delivered.isRaised }
        )

        #expect(completed)
    }

    @Test("A callback during a spin reaches another actor on the executor through assumeIsolated")
    func callbackDuringSpinReachesActorThroughAssumeIsolated() async {
        let spinner = RunLoopSpinner(executor: executor)
        let counter = PinnedCounter(executor: executor)
        let delivered = Flag()

        let completed = await spinner.spin(
            timeout: .seconds(5),
            onStart: {
                // A reply delivered as a run-loop callback reaches the actor
                // while the spinning job waits. `Task { await counter.increment() }`
                // would only run after the spin.
                CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) {
                    _ = counter.assumeIsolated { $0.increment() }
                    delivered.raise()
                }
            },
            until: { delivered.isRaised }
        )

        #expect(completed)
        #expect(await counter.value == 1)
    }

    @Test("A spin that allows nested jobs lets another job on the executor send its reply",
          arguments: [false, true])
    func spinAllowingNestedJobsGetsItsReply(askingInsideTheSpin: Bool) async {
        let spinner = RunLoopSpinner(executor: executor)
        let counter = PinnedCounter(executor: executor)

        let completed = await spinner.spinUntilCounted(
            by: counter,
            timeout: .seconds(5),
            allowingNestedJobs: true,
            askingInsideTheSpin: askingInsideTheSpin
        )

        #expect(completed)
        #expect(await counter.value == 1)
        #expect(await spinner.log == ["spin-start", "counted", "spin-end"])
    }

    @Test("A spin that does not allow nested jobs gets its reply only after giving up")
    func spinWithoutNestedJobsGivesUpFirst() async {
        let spinner = RunLoopSpinner(executor: executor)
        let counter = PinnedCounter(executor: executor)

        let completed = await spinner.spinUntilCounted(by: counter, timeout: .milliseconds(200), allowingNestedJobs: false)

        // The reply still arrives, once the spinning job has returned.
        var log = await spinner.log
        let deadline = ContinuousClock.now + .seconds(2)
        while !log.contains("counted"), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            log = await spinner.log
        }

        #expect(!completed)
        #expect(log == ["spin-start", "spin-end", "counted"])
        #expect(await counter.value == 1)
    }

    @Test("Jobs that run inside a spin allowing nested jobs do not let jobs into themselves")
    func nestedJobsDoNotInheritTheAllowance() async {
        let executor = executor
        let outer = RunLoopSpinner(executor: executor)
        let inner = RunLoopSpinner(executor: executor)
        let innerDone = Flag()
        let (outerStarted, outerStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (innerStarted, innerStartedContinuation) = AsyncStream.makeStream(of: Void.self)

        let outerSpin = Task {
            await outer.spin(
                timeout: .seconds(5),
                allowingNestedJobs: true,
                onStart: { outerStartedContinuation.yield() },
                until: { innerDone.isRaised }
            )
        }
        for await _ in outerStarted {
            break
        }
        // Runs inside the outer spin, and spins itself until the probe is
        // queued, so the probe certainly arrives while it spins.
        let innerSpin = Task {
            let probeArrived = await inner.spin(
                timeout: .seconds(5),
                onStart: { innerStartedContinuation.yield() },
                until: { executor.testQueuedJobCount >= 1 }
            )
            innerDone.raise()
            return probeArrived
        }
        for await _ in innerStarted {
            break
        }
        let probeRanInsideInnerSpin = await inner.record("probe")

        #expect(await innerSpin.value)
        #expect(!probeRanInsideInnerSpin)
        #expect(await outerSpin.value)
        #expect(await inner.log == ["spin-start", "spin-end", "probe"])
    }

    // `_swift_createJobForTestingOnly` first shipped with Swift 6.3.
    #if compiler(>=6.3)
        @Test("Jobs behind a job that lets jobs in run inside it first, ahead of jobs queued later")
        @available(macOS 26.4, iOS 26.4, tvOS 26.4, watchOS 26.4, visionOS 26.4, *)
        func jobsBehindRunInsideAheadOfLaterOnes() async {
            let executor = executor
            let recorder = Recorder()
            let blockerStarted = Flag()
            let release = DispatchSemaphore(value: 0)
            let laterJobQueued = DispatchSemaphore(value: 0)
            let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)

            // The blocker holds the thread while jobs 1 to 3 queue up, so
            // they run as one batch, with 2 and 3 behind 1.
            executor.enqueue(_swift_createJobForTestingOnly {
                blockerStarted.raise()
                release.wait()
            })
            #expect(await waitUntil { blockerStarted.isRaised })
            executor.enqueue(_swift_createJobForTestingOnly {
                recorder.append(1)
                startedContinuation.yield()
                laterJobQueued.wait()
                executor.allowingNestedJobs {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while recorder.values.count < 4, ContinuousClock.now < deadline {
                        _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
                    }
                }
                recorder.append(5)
            })
            for i in 2 ... 3 {
                executor.enqueue(_swift_createJobForTestingOnly { recorder.append(i) })
            }
            release.signal()
            for await _ in started {
                break
            }
            // Reaches the queue while 2 and 3 are still in job 1's batch, yet
            // runs after them: they go back to the front of the queue.
            executor.enqueue(_swift_createJobForTestingOnly { recorder.append(4) })
            laterJobQueued.signal()

            #expect(await waitUntil { recorder.values.count == 5 })
            #expect(recorder.values == [1, 2, 3, 4, 5])
        }
    #endif

    @Test("allowingNestedJobs rethrows the body's error, and jobs no longer run inside the job afterwards")
    func allowingNestedJobsRethrowsAndClosesTheGate() async {
        let executor = executor
        let spinner = RunLoopSpinner(executor: executor)
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)

        let spin = Task {
            await spinner.spinAfterThrowingOutOfNestedJobs(
                timeout: .seconds(5),
                onStart: { startedContinuation.yield() },
                until: { executor.testQueuedJobCount >= 1 }
            )
        }
        for await _ in started {
            break
        }
        let probeRanInsideSpin = await spinner.record("probe")

        #expect(await spin.value)
        #expect(!probeRanInsideSpin)
        #expect(await spinner.log == ["threw boom", "spin-start", "spin-end", "probe"])
    }

    @Test("allowingNestedJobs works from a plain callback, and jobs still do not nest afterwards")
    func allowingNestedJobsFromCallback() async {
        let executor = executor
        let counter = PinnedCounter(executor: executor)
        let replied = Flag()

        let repliedInsideCallback = await runOnThread(of: executor) {
            executor.allowingNestedJobs {
                // The reply comes back through a job, which may run inside
                // this callback. No job is running, so nothing is nested.
                Task {
                    _ = await counter.increment()
                    replied.raise()
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while !replied.isRaised, ContinuousClock.now < deadline {
                    _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
                }
                return replied.isRaised
            }
        }

        // The allowance did not leak into the jobs that follow.
        let spinner = RunLoopSpinner(executor: executor)
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let spin = Task {
            await spinner.spin(
                timeout: .seconds(5),
                onStart: { startedContinuation.yield() },
                until: { executor.testQueuedJobCount >= 1 }
            )
        }
        for await _ in started {
            break
        }
        let probeRanInsideSpin = await spinner.record("probe")

        #expect(repliedInsideCallback)
        #expect(await counter.value == 1)
        #expect(await spin.value)
        #expect(!probeRanInsideSpin)
    }

    @Test("A job that stops the run loop does not stop the executor")
    func stoppingTheRunLoopKeepsTheExecutor() async {
        let spinner = RunLoopSpinner(executor: executor)

        await spinner.stopRunLoop()
        await Task.yield()

        #expect(await spinner.record("after-stop") == false)
        #expect(executor.testThread.isExecuting)
    }

    // MARK: - As a TaskExecutor

    @Test("Work under the executor preference runs on its thread")
    func taskPreferenceRunsOnThread() async {
        let name = await withTaskExecutorPreference(executor) {
            await onPreferredExecutor { currentThreadName() }
        }

        #expect(name == "test.thread")
    }

    @Test("A task created with the executor preference runs on its thread")
    func unstructuredTaskRunsOnThread() async {
        let name = await Task(executorPreference: executor) {
            currentThreadName()
        }.value

        #expect(name == "test.thread")
    }

    // MARK: - Isolation checking

    @Test(
        "assumeIsolated works from a plain callback on the thread",
        .enabled(
            if: hostLinkedAgainstModernSDK,
            "The test host predates the macOS 15 / iOS 18 SDK, so the runtime may not ask the executor"
        )
    )
    func assumeIsolatedFromCallback() async {
        let counter = PinnedCounter(executor: executor)
        _ = await counter.increment()

        let value = await runOnThread(of: executor) {
            valueAssumingIsolation(of: counter)
        }

        #expect(value == 1)
    }

    @Test("checkIsolated passes on the thread")
    func checkIsolatedOnThread() async {
        let executor = executor
        let passed = await runOnThread(of: executor) {
            executor.checkIsolated()
            return true
        }

        #expect(passed)
    }

    @Test("isIsolatingCurrentContext reports whether the caller is on the thread")
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    func isIsolatingCurrentContext() async {
        let executor = executor
        let onThread = await runOnThread(of: executor) {
            executor.isIsolatingCurrentContext()
        }

        #expect(onThread == true)
        #expect(executor.isIsolatingCurrentContext() == false)
    }

    #if os(macOS)
        @Test("checkIsolated traps off the thread")
        func checkIsolatedTrapsOffThread() async {
            await #expect(processExitsWith: .failure) {
                ThreadExecutor(name: "test.thread.trap").checkIsolated()
            }
        }

        @Test("allowingNestedJobs traps off the thread")
        func allowingNestedJobsTrapsOffThread() async {
            await #expect(processExitsWith: .failure) {
                ThreadExecutor(name: "test.thread.trap").allowingNestedJobs {}
            }
        }

        @Test("assumeIsolated traps off the thread")
        func assumeIsolatedTrapsOffThread() async {
            await #expect(processExitsWith: .failure) {
                let counter = PinnedCounter(executor: ThreadExecutor(name: "test.thread.trap"))
                _ = valueAssumingIsolation(of: counter)
            }
        }
    #endif
}
