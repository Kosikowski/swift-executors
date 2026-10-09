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
              onStart: @Sendable () -> Void = {},
              until done: @Sendable () -> Bool = { false }) -> Bool
    {
        isSpinning = true
        log.append("spin-start")
        onStart()
        let deadline = ContinuousClock.now + timeout
        while !done(), ContinuousClock.now < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        isSpinning = false
        log.append("spin-end")
        return done()
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
    let deadline = ContinuousClock.now + .seconds(2)
    while !thread.isFinished, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return thread.isFinished
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

    // MARK: - Jobs that run the run loop themselves

    @Test("No job runs inside a job that spins the run loop")
    func jobsDoNotNestInsideASpin() async {
        let spinner = RunLoopSpinner(executor: executor)
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)

        let spin = Task { await spinner.spin(onStart: { startedContinuation.yield() }) }
        for await _ in started {
            break
        }
        let anyRanInsideSpin = await withTaskGroup(of: Bool.self) { group in
            for i in 0 ..< 5 {
                group.addTask { await spinner.record("probe-\(i)") }
            }
            return await group.contains(true)
        }
        _ = await spin.value

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

        @Test("assumeIsolated traps off the thread")
        func assumeIsolatedTrapsOffThread() async {
            await #expect(processExitsWith: .failure) {
                let counter = PinnedCounter(executor: ThreadExecutor(name: "test.thread.trap"))
                _ = valueAssumingIsolation(of: counter)
            }
        }
    #endif
}
