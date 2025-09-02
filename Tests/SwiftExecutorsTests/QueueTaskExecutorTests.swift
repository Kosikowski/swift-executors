//
//  QueueTaskExecutorTests.swift
//  SwiftExecutorsTests
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import SwiftExecutors
import XCTest

final class QueueTaskExecutorTests: XCTestCase {
    var executor: QueueTaskExecutor!

    override func setUp() {
        super.setUp()
        executor = QueueTaskExecutor(label: "TestExecutor")
    }

    override func tearDown() {
        executor = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testDefaultInitialization() {
        XCTAssertNotNil(executor, "Executor should be initialized")
    }

    func testCustomLabelInitialization() {
        let customExecutor = QueueTaskExecutor(label: "CustomLabel")
        XCTAssertNotNil(customExecutor, "Executor with custom label should be initialized")
    }

    func testCustomMaxConcurrentInitialization() {
        let customExecutor = QueueTaskExecutor(
            label: "CustomMaxConcurrent",
            maxConcurrent: 2
        )
        XCTAssertNotNil(customExecutor, "Executor with custom maxConcurrent should be initialized")
    }

    func testCustomQoSInitialization() {
        let customExecutor = QueueTaskExecutor(
            label: "CustomQoS",
            qos: .userInitiated
        )
        XCTAssertNotNil(customExecutor, "Executor with custom QoS should be initialized")
    }

    func testFullCustomInitialization() {
        let customExecutor = QueueTaskExecutor(
            label: "FullCustom",
            maxConcurrent: 5,
            qos: .background
        )
        XCTAssertNotNil(customExecutor, "Executor with all custom parameters should be initialized")
    }

    // MARK: - Task Execution Tests

    func testBasicTaskExecution() async {
        let expectation = XCTestExpectation(description: "Task should execute")

        await withTaskExecutorPreference(executor) {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testMultipleTaskExecution() async {
        let expectation = XCTestExpectation(description: "All tasks should execute")
        expectation.expectedFulfillmentCount = 3

        await withTaskExecutorPreference(executor) {
            expectation.fulfill()
        }

        await withTaskExecutorPreference(executor) {
            expectation.fulfill()
        }

        await withTaskExecutorPreference(executor) {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testTaskExecutionWithReturnValue() async {
        let result = await withTaskExecutorPreference(executor) {
            "Test Result"
        }

        XCTAssertEqual(result, "Test Result", "Task should return expected value")
    }

    func testTaskExecutionWithThrowingFunction() async throws {
        let result = try await withTaskExecutorPreference(executor) {
            // Simulate a throwing operation
            if false {
                throw TestError.testError
            }
            return "Success"
        }

        XCTAssertEqual(result, "Success", "Throwing task should return expected value")
    }

    func testTaskExecutionWithError() async {
        do {
            _ = try await withTaskExecutorPreference(executor) {
                throw TestError.testError
            }
            XCTFail("Task should throw an error")
        } catch {
            XCTAssertEqual(error as? TestError, TestError.testError, "Task should throw expected error")
        }
    }

    // MARK: - Concurrency Control Tests

    func testMaxConcurrentLimitation() async {
        let limitedExecutor = QueueTaskExecutor(
            label: "LimitedExecutor",
            maxConcurrent: 2
        )

        let expectation = XCTestExpectation(description: "All tasks should execute with concurrency limit")
        expectation.expectedFulfillmentCount = 4

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    await withTaskExecutorPreference(limitedExecutor) {
                        // Simulate some work
                        try? await Task.sleep(nanoseconds: 100_000) // 0.1ms
                        expectation.fulfill()
                    }
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 3.0)

        // This test verifies that all tasks complete on the limited executor
        // The actual concurrency limitation is tested at the NSOperationQueue level
    }

    // MARK: - QoS Tests

    func testDifferentQoSLevels() async {
        let qosLevels: [QualityOfService] = [.userInteractive, .userInitiated, .default, .utility, .background]

        for qos in qosLevels {
            let qosExecutor = QueueTaskExecutor(label: "QOSTest", qos: qos)
            let expectation = XCTestExpectation(description: "Task with QoS \(qos) should execute")

            await withTaskExecutorPreference(qosExecutor) {
                expectation.fulfill()
            }

            await fulfillment(of: [expectation], timeout: 1.0)
        }
    }

    // MARK: - Task Group Integration Tests

    func testTaskGroupWithExecutor() async throws {
        let expectation = XCTestExpectation(description: "All tasks in group should execute")
        expectation.expectedFulfillmentCount = 3

        let results = try await withTaskExecutorPreference(executor) {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for i in 1 ... 3 {
                    group.addTask {
                        expectation.fulfill()
                        return i
                    }
                }

                var results: [Int] = []
                for try await result in group {
                    results.append(result)
                }
                return results.sorted()
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(results, [1, 2, 3], "Task group should return expected results")
    }

    // MARK: - Error Handling Tests

    func testTaskGroupWithThrowingTasks() async {
        let expectation = XCTestExpectation(description: "Error should be thrown from task group")

        do {
            _ = try await withTaskExecutorPreference(executor) {
                try await withThrowingTaskGroup(of: Int.self) { group in
                    group.addTask {
                        throw TestError.testError
                    }

                    for try await _ in group {
                        // This should not execute due to error
                    }
                    return []
                }
            }
            XCTFail("Task group should throw an error")
        } catch {
            XCTAssertEqual(error as? TestError, TestError.testError, "Task group should throw expected error")
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // MARK: - Performance Tests

    func testExecutorPerformance() async {
        let performanceExecutor = QueueTaskExecutor(label: "PerformanceTest")

        measure {
            let expectation = XCTestExpectation(description: "Performance test")
            expectation.expectedFulfillmentCount = 100

            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0 ..< 100 {
                        group.addTask {
                            await withTaskExecutorPreference(performanceExecutor) {
                                expectation.fulfill()
                            }
                        }
                    }
                }
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    // MARK: - Stress Tests

    func testStressTestWithManyTasks() async {
        let stressExecutor = QueueTaskExecutor(
            label: "StressTest",
            maxConcurrent: 4
        )

        let expectation = XCTestExpectation(description: "All stress test tasks should execute")
        expectation.expectedFulfillmentCount = 50

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 50 {
                group.addTask {
                    await withTaskExecutorPreference(stressExecutor) {
                        // Simulate varying work loads
                        let sleepTime = UInt64.random(in: 10000 ... 100_000) // 0.01-0.1ms
                        try? await Task.sleep(nanoseconds: sleepTime)
                        expectation.fulfill()
                    }
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 10.0)
    }
}

// MARK: - Test Error

private enum TestError: Error, Equatable {
    case testError
}
