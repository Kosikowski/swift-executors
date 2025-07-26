# Swift Executors

A Swift library providing custom task executors for fine-grained control over concurrency and thread management in Swift applications.

## Overview

Swift Executors provides two main executor types that allow you to control how Swift tasks are executed:

- **QueueTaskExecutor**: A task executor backed by `NSOperationQueue` for controlling concurrency and prioritizing work
- **ThreadExecutor**: A serial executor that pins every actor job to a dedicated thread for thread-affinity requirements

## Features

- **Concurrency Control**: Limit the number of concurrent operations with `QueueTaskExecutor`
- **Thread Affinity**: Pin tasks to specific threads with `ThreadExecutor` for frameworks requiring thread-local storage
- **Quality of Service**: Configure QoS levels for priority handling
- **Swift Concurrency Integration**: Seamlessly works with Swift's async/await and structured concurrency
- **Cross-Platform**: Supports iOS 17+ and macOS 15+

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

### ThreadExecutor

Use `ThreadExecutor` when you need thread affinity for:
- Legacy C/C++/Objective-C libraries that rely on thread-local storage
- Frameworks that demand single-thread affinity (Core MIDI, Core Audio)
- Real-time loops that must never hop between cores

```swift
import SwiftExecutors

// Create a dedicated thread executor
let audioExecutor = ThreadExecutor(name: "AudioThread")

// Use it for audio processing
func processAudio() async {
    await withTaskExecutorPreference(audioExecutor) {
        // This code runs on a dedicated thread
        // Perfect for audio processing that requires thread affinity
        await processAudioBuffer()
    }
}
```

## API Reference

### QueueTaskExecutor

```swift
public final class QueueTaskExecutor: TaskExecutor, @unchecked Sendable {
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

### ThreadExecutor

```swift
public final class ThreadExecutor: SerialExecutor, @unchecked Sendable {
    public init(name: String = "ThreadExecutor")
}
```

**Parameters:**
- `name`: Human-readable thread name for debugging

## Examples

### Background Image Processing

```swift
let imageProcessor = QueueTaskExecutor(
    label: "ImageProcessing",
    maxConcurrent: 2,
    qos: .background
)

func processImages(_ images: [UIImage]) async -> [UIImage] {
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

### Audio Processing with Thread Affinity

```swift
let audioThread = ThreadExecutor(name: "AudioProcessor")

func startAudioProcessing() async {
    await withTaskExecutorPreference(audioThread) {
        // All audio processing happens on the same thread
        // This prevents audio glitches from thread hopping
        while isProcessing {
            await processAudioFrame()
            await sleep(1.0 / sampleRate)
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
