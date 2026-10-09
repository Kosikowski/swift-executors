//
//  QueueTaskExecutorTests.swift
//  SwiftExecutorsTests
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import Foundation
import SwiftExecutors
import Testing

@Suite("QueueTaskExecutor")
struct QueueTaskExecutorTests {
    // MARK: - Where work runs

    @Test("Work under the executor preference runs on its operation queue")
    func runsOnOperationQueue() async {
        let executor = QueueTaskExecutor(label: "test.operation.preference")

        let name = await withTaskExecutorPreference(executor) {
            await onPreferredExecutor { currentOperationQueueName() }
        }

        #expect(name == "test.operation.preference")
    }

    @Test("Child tasks that prefer the executor run on its operation queue")
    func childTasksRunOnOperationQueue() async {
        let executor = QueueTaskExecutor(label: "test.operation.children")

        let names = await withTaskGroup(of: String?.self) { group in
            for _ in 0 ..< 5 {
                group.addTask(executorPreference: executor) { currentOperationQueueName() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(names == Array(repeating: "test.operation.children", count: 5))
    }

    // MARK: - Concurrency limit

    @Test("Never runs more jobs at once than maxConcurrent", arguments: [1, 3])
    func respectsMaxConcurrent(limit: Int) async {
        let executor = QueueTaskExecutor(label: "test.operation.limited", maxConcurrent: limit)
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 12 {
                group.addTask(executorPreference: executor) { tracker.occupy() }
            }
        }

        #expect(tracker.peak <= limit)
        #expect(tracker.peak == limit || limit == 1)
    }

    @Test("Runs many short tasks to completion")
    func stress() async {
        let executor = QueueTaskExecutor(label: "test.operation.stress", maxConcurrent: 4)

        let completed = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 50 {
                group.addTask(executorPreference: executor) {
                    try? await Task.sleep(for: .microseconds(Int.random(in: 10 ... 100)))
                    return 1
                }
            }
            return await group.reduce(0, +)
        }

        #expect(completed == 50)
    }

    @Test("Each quality of service runs work", arguments: [
        QualityOfService.userInteractive, .userInitiated, .default, .utility, .background,
    ])
    func runsAtEveryQoS(qos: QualityOfService) async {
        let executor = QueueTaskExecutor(label: "test.operation.qos", qos: qos)

        let name = await withTaskExecutorPreference(executor) {
            await onPreferredExecutor { currentOperationQueueName() }
        }

        #expect(name == "test.operation.qos")
    }

    // MARK: - Results and errors

    @Test("Returns the operation's value")
    func returnsValue() async {
        let executor = QueueTaskExecutor()

        let result = await withTaskExecutorPreference(executor) { "Test Result" }

        #expect(result == "Test Result")
    }

    @Test("Propagates a typed error from the operation")
    func propagatesTypedError() async {
        let executor = QueueTaskExecutor()

        await #expect(throws: TestError.boom) {
            try await withTaskExecutorPreference(executor) { () throws(TestError) in
                throw .boom
            }
        }
    }

    @Test("Propagates an error from a child task")
    func propagatesChildTaskError() async {
        let executor = QueueTaskExecutor(label: "test.operation.throwing")

        await #expect(throws: TestError.boom) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask(executorPreference: executor) { throw TestError.boom }
                try await group.waitForAll()
            }
        }
    }
}
