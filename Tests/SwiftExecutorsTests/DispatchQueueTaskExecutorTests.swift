//
//  DispatchQueueTaskExecutorTests.swift
//  SwiftExecutorsTests
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import Dispatch
import Foundation
import SwiftExecutors
import Testing

@Suite("DispatchQueueTaskExecutor")
struct DispatchQueueTaskExecutorTests {
    // MARK: - Where work runs

    @Test("Work under the executor preference runs on its queue")
    func runsOnQueue() async {
        let executor = DispatchQueueTaskExecutor(label: "test.dispatch.preference")

        let label = await withTaskExecutorPreference(executor) {
            await onPreferredExecutor { currentQueueLabel() }
        }

        #expect(label == "test.dispatch.preference")
    }

    @Test("Child tasks that prefer the executor run on its queue")
    func childTasksRunOnQueue() async {
        let executor = DispatchQueueTaskExecutor(concurrentLabel: "test.dispatch.children")

        let labels = await withTaskGroup(of: String.self) { group in
            for _ in 0 ..< 5 {
                group.addTask(executorPreference: executor) { currentQueueLabel() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(labels == Array(repeating: "test.dispatch.children", count: 5))
    }

    @Test("A task created with the executor preference runs on its queue")
    func unstructuredTaskRunsOnQueue() async {
        let executor = DispatchQueueTaskExecutor(label: "test.dispatch.task")

        let label = await Task(name: "probe", executorPreference: executor) {
            currentQueueLabel()
        }.value

        #expect(label == "test.dispatch.task")
    }

    @Test("Jobs run on the target queue when one is given")
    func usesTargetQueue() async {
        let key = DispatchSpecificKey<String>()
        let target = DispatchQueue(label: "test.dispatch.target")
        target.setSpecific(key: key, value: "target")
        let executor = DispatchQueueTaskExecutor(label: "test.dispatch.targeted", target: target)

        let value = await withTaskExecutorPreference(executor) {
            await onPreferredExecutor { DispatchQueue.getSpecific(key: key) }
        }

        #expect(value == "target")
    }

    @Test("An initially inactive queue still runs jobs")
    func initiallyInactiveQueueRuns() async {
        let executor = DispatchQueueTaskExecutor(label: "test.dispatch.inactive", attributes: .initiallyInactive)

        let label = await withTaskExecutorPreference(executor) {
            await onPreferredExecutor { currentQueueLabel() }
        }

        #expect(label == "test.dispatch.inactive")
    }

    // MARK: - Serial vs concurrent

    @Test("The serial initializer never overlaps jobs")
    func serialQueueDoesNotOverlap() async {
        let executor = DispatchQueueTaskExecutor(serialLabel: "test.dispatch.serial")
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask(executorPreference: executor) { tracker.occupy() }
            }
        }

        #expect(tracker.peak == 1)
    }

    @Test("The concurrent initializer overlaps jobs")
    func concurrentQueueOverlaps() async {
        let executor = DispatchQueueTaskExecutor(concurrentLabel: "test.dispatch.concurrent")
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask(executorPreference: executor) { tracker.occupy() }
            }
        }

        #expect(tracker.peak > 1)
    }

    @Test("Each quality of service runs work", arguments: [
        DispatchQoS.userInteractive, .userInitiated, .default, .utility, .background,
    ])
    func runsAtEveryQoS(qos: DispatchQoS) async {
        let executor = DispatchQueueTaskExecutor(label: "test.dispatch.qos", qos: qos)

        let label = await withTaskExecutorPreference(executor) {
            await onPreferredExecutor { currentQueueLabel() }
        }

        #expect(label == "test.dispatch.qos")
    }

    // MARK: - Results and errors

    @Test("Returns the operation's value")
    func returnsValue() async {
        let executor = DispatchQueueTaskExecutor()

        let result = await withTaskExecutorPreference(executor) { "Test Result" }

        #expect(result == "Test Result")
    }

    @Test("Propagates a typed error from the operation")
    func propagatesTypedError() async {
        let executor = DispatchQueueTaskExecutor()

        await #expect(throws: TestError.boom) {
            try await withTaskExecutorPreference(executor) { () throws(TestError) in
                throw .boom
            }
        }
    }

    @Test("Propagates an error from a child task")
    func propagatesChildTaskError() async {
        let executor = DispatchQueueTaskExecutor(concurrentLabel: "test.dispatch.throwing")

        await #expect(throws: TestError.boom) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask(executorPreference: executor) { throw TestError.boom }
                try await group.waitForAll()
            }
        }
    }
}
