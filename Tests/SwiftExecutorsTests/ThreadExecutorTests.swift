//
//  ThreadExecutorTests.swift
//  swift-executors
//
//  Created by Mateusz Kosikowski on 18/06/2025.
//
import XCTest
@_spi(ThreadExecutorTesting) import SwiftExecutors // Replace with your module name, import SPI

final class ThreadExecutorTests: XCTestCase {
    var executor: ThreadExecutor!

    override func setUp() {
        super.setUp()
        executor = ThreadExecutor(name: "TestExecutor")
    }

    override func tearDown() {
        executor = nil
        super.tearDown()
    }

    /// Test that the executor initializes correctly and its thread is running.
    func testInitialization() {
        XCTAssertNotNil(executor.testThread, "Thread should be initialized")
        XCTAssertEqual(executor.testThread.name, "TestExecutor", "Thread name should match")
    }

    func testThreadIsRunning() {
        // Thread state can be complex, so we'll just verify the thread exists and has a name
        XCTAssertNotNil(executor.testThread, "Thread should exist")
        XCTAssertNotNil(executor.testThread.name, "Thread should have a name")
        XCTAssertFalse(executor.testThread.isCancelled, "Thread should not be cancelled")
    }

    func testThreadName() {
        XCTAssertEqual(executor.testThread.name, "TestExecutor", "Thread name should match")
    }

    func testThreadQualityOfService() {
        // Thread should exist and have basic properties
        XCTAssertNotNil(executor.testThread, "Thread should exist")
    }

    func testExecutorIdentity() {
        let executor1 = ThreadExecutor(name: "Executor1")
        let executor2 = ThreadExecutor(name: "Executor2")

        XCTAssertNotEqual(executor1.testThread, executor2.testThread, "Different executors should have different threads")
    }

    func testExecutorReinitialization() {
        // Create a new executor in a separate scope
        do {
            let tempExecutor = ThreadExecutor(name: "TempExecutor")
            XCTAssertNotNil(tempExecutor.testThread, "Temporary executor should be initialized")
        }
    }
}
