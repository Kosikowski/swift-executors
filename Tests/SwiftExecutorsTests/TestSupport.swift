//
//  TestSupport.swift
//  SwiftExecutorsTests
//
//  Created by Mateusz Kosikowski on 09/10/2026.
//
import Dispatch
import Foundation
import MachO
import Synchronization

/// Whether this process's main executable was linked against the macOS 15 /
/// iOS 18 SDK or later.
///
/// The Swift runtime checks this before it lets `assumeIsolated` consult a
/// custom executor. For an older host it uses a legacy check, which - depending
/// on the toolchain that compiled the call - can trap even on the executor's
/// own thread. swiftly's `swiftpm-testing-helper` is linked against SDK 14.
let hostLinkedAgainstModernSDK: Bool = {
    guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else {
        return true
    }
    var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0 ..< header.pointee.ncmds {
        let load = command.load(as: load_command.self)
        if load.cmd == UInt32(LC_BUILD_VERSION) {
            let build = command.load(as: build_version_command.self)
            let sdkMajor = build.sdk >> 16 // Encoded as xxxx.yy.zz
            switch Int32(build.platform) {
            case PLATFORM_MACOS:
                return sdkMajor >= 15
            case PLATFORM_IOS, PLATFORM_IOSSIMULATOR, PLATFORM_MACCATALYST, PLATFORM_TVOS, PLATFORM_TVOSSIMULATOR:
                return sdkMajor >= 18
            default:
                return true
            }
        }
        command = command.advanced(by: Int(load.cmdsize))
    }
    // No LC_BUILD_VERSION: linked by a toolchain that predates it.
    return false
}()

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
