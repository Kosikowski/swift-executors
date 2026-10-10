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
    // Not necessarily image 0: libraries inserted at launch, such as the
    // Thread Sanitizer runtime, come before the main executable.
    let images = (0 ..< _dyld_image_count()).lazy.compactMap { _dyld_get_image_header($0) }
    guard let header = images.first(where: { $0.pointee.filetype == UInt32(MH_EXECUTE) }),
          header.pointee.magic == MH_MAGIC_64
    else {
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

/// Waits up to `timeout` for `condition` to hold and reports whether it did.
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// The process's physical memory footprint in bytes, as Activity Monitor
/// reports it.
func physicalFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { info in
        info.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS, "task_info failed: \(result)")
    return Int(info.phys_footprint)
}

/// Counts events from callbacks on any thread.
final class Counter: Sendable {
    private let count = Atomic(0)

    var value: Int {
        count.load(ordering: .relaxed)
    }

    func increment() {
        count.wrappingAdd(1, ordering: .relaxed)
    }
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
