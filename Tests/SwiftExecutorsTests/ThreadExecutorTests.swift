//
//  ThreadExecutorTests.swift
//  SwiftExecutorsTests
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import CoreFoundation
import Foundation
@_spi(ThreadExecutorTesting) import SwiftExecutors
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

        let deadline = ContinuousClock.now + .seconds(2)
        while !thread.isFinished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(thread.isFinished)
        #expect(thread.isCancelled)
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

    @Test("assumeIsolated works from a plain callback on the thread")
    func assumeIsolatedFromCallback() async {
        let counter = PinnedCounter(executor: executor)
        _ = await counter.increment()

        let value = await runOnThread(of: executor) {
            counter.assumeIsolated { $0.value }
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
    #endif
}
