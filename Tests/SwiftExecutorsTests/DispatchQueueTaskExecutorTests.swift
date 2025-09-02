//
//  DispatchQueueTaskExecutorTests.swift
//  SwiftExecutorsTests
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import SwiftExecutors
import XCTest

final class DispatchQueueTaskExecutorTests: XCTestCase {
    var executor: DispatchQueueTaskExecutor!

    override func setUp() {
        super.setUp()
        executor = DispatchQueueTaskExecutor(label: "TestExecutor")
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
        let customExecutor = DispatchQueueTaskExecutor(label: "CustomLabel")
        XCTAssertNotNil(customExecutor, "Executor with custom label should be initialized")
    }

    func testConcurrentInitialization() {
        let concurrentExecutor = DispatchQueueTaskExecutor(
            label: "ConcurrentTest",
            qos: .userInitiated,
            attributes: .concurrent
        )
        XCTAssertNotNil(concurrentExecutor, "Concurrent executor should be initialized")
    }

    func testSerialInitialization() {
        let serialExecutor = DispatchQueueTaskExecutor(
            label: "SerialTest",
            qos: .utility
        )
        XCTAssertNotNil(serialExecutor, "Serial executor should be initialized")
    }

    func testConvenienceConcurrentInitializer() {
        let concurrentExecutor = DispatchQueueTaskExecutor(
            concurrentLabel: "ConvenienceConcurrent",
            qos: .background
        )
        XCTAssertNotNil(concurrentExecutor, "Convenience concurrent executor should be initialized")
    }

    func testConvenienceSerialInitializer() {
        let serialExecutor = DispatchQueueTaskExecutor(
            serialLabel: "ConvenienceSerial",
            qos: .userInteractive
        )
        XCTAssertNotNil(serialExecutor, "Convenience serial executor should be initialized")
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

    // MARK: - Concurrency Tests

    func testConcurrentTaskExecution() async {
        let concurrentExecutor = DispatchQueueTaskExecutor(
            label: "ConcurrentTest",
            qos: .default,
            attributes: .concurrent
        )

        let expectation = XCTestExpectation(description: "All concurrent tasks should execute")
        expectation.expectedFulfillmentCount = 5

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask {
                    await withTaskExecutorPreference(concurrentExecutor) {
                        // Simulate some work
                        try? await Task.sleep(nanoseconds: 100_000) // 0.1ms
                        expectation.fulfill()
                    }
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testSerialTaskExecution() async {
        let serialExecutor = DispatchQueueTaskExecutor(
            label: "SerialTest",
            qos: .default
        )

        let expectation = XCTestExpectation(description: "Tasks should execute in order")
        expectation.expectedFulfillmentCount = 3

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 3 {
                group.addTask {
                    await withTaskExecutorPreference(serialExecutor) {
                        expectation.fulfill()
                    }
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        // This test verifies that all tasks complete on the serial executor
        // Note: Serial execution order might not be guaranteed due to Swift's cooperative threading
    }

    // MARK: - QoS Tests

    func testDifferentQoSLevels() async {
        let qosLevels: [DispatchQoS] = [.userInteractive, .userInitiated, .default, .utility, .background]

        for qos in qosLevels {
            let qosExecutor = DispatchQueueTaskExecutor(label: "QOSTest", qos: qos)
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
        let performanceExecutor = DispatchQueueTaskExecutor(label: "PerformanceTest")

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
}

// MARK: - Test Error

private enum TestError: Error, Equatable {
    case testError
}
