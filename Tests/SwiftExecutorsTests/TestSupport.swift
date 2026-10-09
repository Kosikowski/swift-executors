//
//  TestSupport.swift
//  SwiftExecutorsTests
//
//  Created by Mateusz Kosikowski on 09/10/2026.
//
import Dispatch
import Foundation
import Synchronization

/// Label of the dispatch queue running the caller.
func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

/// Name of the operation queue running the caller, if any.
func currentOperationQueueName() -> String? {
    OperationQueue.current?.name
}

/// Name of the thread running the caller.
func currentThreadName() -> String? {
    Thread.current.name
}

/// Runs `body` on the task's preferred executor.
///
/// `@concurrent` forces the hop: under `NonisolatedNonsendingByDefault` a plain
/// nonisolated async function would stay on its caller's executor instead.
@concurrent
func onPreferredExecutor<T: Sendable>(_ body: @Sendable () -> T) async -> T {
    body()
}

/// Records the peak number of callers inside `occupy(for:)` at once.
final class OverlapTracker: Sendable {
    private let state = Mutex((active: 0, peak: 0))

    var peak: Int {
        state.withLock { $0.peak }
    }

    /// Blocks the calling thread for `interval` while counted as active,
    /// so overlapping jobs on the executor under test become visible.
    func occupy(for interval: TimeInterval = 0.02) {
        state.withLock {
            $0.active += 1
            $0.peak = max($0.peak, $0.active)
        }
        Thread.sleep(forTimeInterval: interval)
        state.withLock { $0.active -= 1 }
    }
}

enum TestError: Error, Equatable {
    case boom
}
