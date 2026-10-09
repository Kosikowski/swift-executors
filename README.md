[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKosikowski%2Fswift-executors%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Kosikowski/swift-executors)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKosikowski%2Fswift-executors%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Kosikowski/swift-executors)

# Swift Executors

A Swift library providing custom task executors for fine-grained control over concurrency and thread management in Swift applications.

## Overview

Swift Executors provides three main executor types that allow you to control how Swift tasks are executed:

- **QueueTaskExecutor**: A task executor backed by `NSOperationQueue` for controlling concurrency and prioritizing work
- **DispatchQueueTaskExecutor**: A task executor backed by Grand Central Dispatch (GCD) for efficient thread management and performance
- **ThreadExecutor**: A serial executor and task executor that runs every job on one dedicated thread, for thread-affinity requirements

## Features

- **Concurrency Control**: Limit the number of concurrent operations with `QueueTaskExecutor`
- **GCD Integration**: Leverage Grand Central Dispatch with `DispatchQueueTaskExecutor` for efficient thread management
- **Thread Affinity**: Pin an actor, or a task, to one thread with `ThreadExecutor` for frameworks requiring thread-local storage
- **Isolation Checking**: `ThreadExecutor` implements `checkIsolated()` and `isIsolatingCurrentContext()`, so `assumeIsolated` works from callbacks on its thread (see [ThreadExecutor](#threadexecutor) for the one exception)
- **Quality of Service**: Configure QoS levels for priority handling
- **Swift Concurrency Integration**: Seamlessly works with Swift's async/await and structured concurrency
- **Cross-Platform**: Supports iOS 18+ and macOS 15+

## Requirements

- Swift 6.2+ (Xcode 26+)
- iOS 18+ / macOS 15+ (task executors need the Swift runtime that ships with these releases)

## Installation

### Swift Package Manager

Add the following dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Kosikowski/swift-executors.git", from: "1.0.0")
]
```

Or add it to your Xcode project:
1. File → Add Package Dependencies
2. Enter the repository URL
3. Select the version you want to use

## Usage

### QueueTaskExecutor

Use `QueueTaskExecutor` when you need to control concurrency, prioritize work, or isolate blocking operations from Swift's cooperative thread pool.

```swift
import SwiftExecutors

// Create an executor for file I/O operations
let ioExecutor = QueueTaskExecutor(
    label: "File-IO",
    maxConcurrent: 4,  // Limit to 4 concurrent operations
    qos: .utility
)

// Use the executor for file operations
func loadFiles(urls: [URL]) async throws -> [Data] {
    try await withTaskExecutorPreference(ioExecutor) {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for url in urls {
                group.addTask {
                    // This runs on the custom executor
                    return try Data(contentsOf: url)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
}
```

### DispatchQueueTaskExecutor

Use `DispatchQueueTaskExecutor` when you want to leverage GCD's efficient thread management, work with existing GCD-based code, or need the performance characteristics of dispatch queues.

```swift
import SwiftExecutors

// Create a concurrent executor for network operations
let networkExecutor = DispatchQueueTaskExecutor(
    label: "Network",
    qos: .userInitiated,
    attributes: .concurrent
)

// Use it for network requests
func fetchData(urls: [URL]) async throws -> [Data] {
    try await withTaskExecutorPreference(networkExecutor) {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for url in urls {
                group.addTask {
                    // This runs on the GCD queue
                    return try Data(contentsOf: url)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
}

// Create a serial executor: one job at a time, in submission order
let serialExecutor = DispatchQueueTaskExecutor(
    serialLabel: "SerialProcessor",
    qos: .utility
)

// Use it for work that must run one item at a time
func processSequentially(_ items: [String]) async -> [String] {
    await withTaskExecutorPreference(serialExecutor) {
        var results: [String] = []
        for item in items {
            // One item at a time, in order, on the serial queue. GCD may use
            // a different thread for each job, so don't rely on thread identity.
            let processed = await processItem(item)
            results.append(processed)
        }
        return results
    }
}
```

### ThreadExecutor

Use `ThreadExecutor` when you need thread affinity for:
- Legacy C/C++/Objective-C libraries that rely on thread-local storage
- Frameworks that demand single-thread affinity (Core MIDI, Core Audio)
- Real-time loops that must never hop between cores

Back an actor with it to pin all of that actor's code to one thread:

```swift
import SwiftExecutors

actor AudioEngine {
    private let executor = ThreadExecutor(name: "AudioThread")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func render() {
        // Always runs on the "AudioThread" thread
    }
}
```

It is also a `TaskExecutor`, so nonisolated async code can prefer it:

```swift
let audioExecutor = ThreadExecutor(name: "AudioThread")

func processAudio() async {
    await withTaskExecutorPreference(audioExecutor) {
        // Written outside any actor, so this closure - and the nonisolated
        // async functions it calls - runs on the dedicated thread
        await processAudioBuffer()
    }
}
```

Write such closures outside actor-isolated code; see
[`nonisolated(nonsending)` and `@concurrent`](#swift-62-nonisolatednonsending-and-concurrent).

When a thread-affine library delivers a callback on that thread, outside any Swift task,
`assumeIsolated` lets you touch the actor's state synchronously. `ThreadExecutor` confirms
the caller is on its thread, and traps if it is not.

The runtime only asks the executor when the process's main executable was linked against
the macOS 15 / iOS 18 SDK or later, which every app built with Xcode 26 is. In a plugin
loaded by an older host app, `assumeIsolated` from a callback can trap even on the right
thread.

```swift
extension AudioEngine {
    /// Called by the audio library on "AudioThread".
    nonisolated func handleCallback() {
        assumeIsolated { engine in
            engine.render()
        }
    }
}
```

### Swift 6.2: `nonisolated(nonsending)` and `@concurrent`

This package enables the `NonisolatedNonsendingByDefault` upcoming feature (SE-0461).
With it, a `nonisolated async` function runs on its **caller's** executor.

That decides where the closure you pass to `withTaskExecutorPreference` runs:

- **Written in nonisolated code** (a free function, a `nonisolated` method), the closure
  runs on the preferred executor, and so do the nonisolated async functions it calls.
- **Written in actor-isolated code** (for example a `@MainActor` method), the closure stays
  on that actor, and so do the nonisolated async functions it calls. Only `@concurrent`
  functions move to the preferred executor.

Mark work that should always move to the preferred executor `@concurrent`:

```swift
@concurrent
func resize(_ image: CGImage) async -> CGImage {
    // Runs on the task's preferred executor, or the global pool if none is set
}

await withTaskExecutorPreference(imageProcessor) {
    let thumbnail = await resize(image)
}
```

Child tasks (`group.addTask`) and `Task(executorPreference:)` closures that are not
isolated to an actor always run on the preferred executor.

## API Reference

### QueueTaskExecutor

```swift
public final class QueueTaskExecutor: TaskExecutor {
    public init(
        label: String = "TaskExec",
        maxConcurrent: Int = OperationQueue.defaultMaxConcurrentOperationCount,
        qos: QualityOfService = .default
    )
}
```

**Parameters:**
- `label`: Human-readable name for debugging (shows up in Instruments/Xcode)
- `maxConcurrent`: Maximum number of simultaneous tasks (throttles throughput)
- `qos`: Quality of service for priority handling

### DispatchQueueTaskExecutor

```swift
public final class DispatchQueueTaskExecutor: TaskExecutor {
    public init(
        label: String = "DispatchTaskExec",
        qos: DispatchQoS = .default,
        attributes: DispatchQueue.Attributes = [],
        target: DispatchQueue? = nil
    )
    
    // Convenience initializers
    public convenience init(concurrentLabel: String,
                            qos: DispatchQoS = .default,
                            target: DispatchQueue? = nil)
    
    public convenience init(serialLabel: String,
                            qos: DispatchQoS = .default,
                            target: DispatchQueue? = nil)
}
```

**Parameters:**
- `label`: Human-readable name for debugging (shows up in Instruments/Xcode)
- `qos`: Quality of service for priority handling
- `attributes`: Queue attributes, e.g. `.concurrent`. The queue starts active even if `.initiallyInactive` is passed
- `target`: Target queue for execution (nil for default)

### ThreadExecutor

```swift
public final class ThreadExecutor: SerialExecutor, TaskExecutor, @unchecked Sendable {
    public init(name: String = "ThreadExecutor")

    // Isolation checks used by assumeIsolated / preconditionIsolated
    public func checkIsolated()
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    public func isIsolatingCurrentContext() -> Bool?
}
```

**Parameters:**
- `name`: Human-readable thread name for debugging

The thread starts in `init` and stops once the executor is released, after the jobs
already queued on it have run.

Jobs never run inside one another. If a job spins the thread's run loop, as some legacy
APIs do while they wait for a callback, run-loop sources and callbacks still fire, but
other jobs wait until that job returns. Code on the thread that calls `CFRunLoopStop`
does not stop the executor.

Every job runs isolated to the executor, so a call from it to a `@concurrent` function
goes back through the run loop instead of continuing inline.

## Examples

### Background Image Processing

```swift
let imageProcessor = QueueTaskExecutor(
    label: "ImageProcessing",
    maxConcurrent: 2,
    qos: .background
)

func processImages(_ images: [UIImage]) async throws -> [UIImage] {
    try await withTaskExecutorPreference(imageProcessor) {
        try await withThrowingTaskGroup(of: UIImage.self) { group in
            for image in images {
                group.addTask {
                    // Heavy image processing on background thread
                    return await applyFilters(to: image)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
}
```

### Network Operations with GCD

```swift
let networkExecutor = DispatchQueueTaskExecutor(
    label: "NetworkOperations",
    qos: .userInitiated,
    attributes: .concurrent
)

func downloadMultipleFiles(_ urls: [URL]) async throws -> [Data] {
    try await withTaskExecutorPreference(networkExecutor) {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for url in urls {
                group.addTask {
                    // Concurrent downloads using GCD's efficient thread pool
                    return try await downloadFile(from: url)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
}
```

### Audio Processing with Thread Affinity

```swift
let audioThread = ThreadExecutor(name: "AudioProcessor")

func startAudioProcessing() async throws {
    try await withTaskExecutorPreference(audioThread) {
        // Written outside any actor, so all audio processing happens on
        // the same thread. This prevents audio glitches from thread hopping
        while isProcessing {
            await processAudioFrame()
            try await Task.sleep(for: .seconds(1.0 / sampleRate))
        }
    }
}
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

## License

This project is licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.

## Author

Created by Mateusz Kosikowski.

## Acknowledgments

This project demonstrates advanced Swift concurrency patterns and provides practical solutions for real-world threading requirements in Swift applications. 
