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

    // TODO: add more unit tests
}
