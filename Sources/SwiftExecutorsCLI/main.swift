//
//  main.swift
//  SwiftExecutors
//
//  Created by Mateusz Kosikowski on 19/06/2025.
//

import Foundation
import SwiftExecutors

/// Runs at most 4 jobs at once, however many tasks prefer it.
let ioPool = QueueTaskExecutor(label: "File-IO",
                               maxConcurrent: 4,
                               qos: .utility)

/// Simulates CPU-bound work.
///
/// `@concurrent` makes it leave the caller's actor and run on the task's
/// preferred executor. Without it, under `NonisolatedNonsendingByDefault`,
/// it would run on whatever executor called it.
@concurrent
func busyWork() async -> Int {
    var total = 0
    for i in 1 ... 3_000_000 {
        total &+= i
    }
    return total
}

/// Spins up one child task per URL, each running on `ioPool`.
func loadFiles(urls: [URL]) async throws -> [Data] {
    try await withThrowingTaskGroup(of: Data.self) { group in
        for url in urls {
            group.addTask(name: url.lastPathComponent, executorPreference: ioPool) {
                _ = await busyWork()
                // Stand-in for `try Data(contentsOf: url)`.
                return Data(url.absoluteString.utf8)
            }
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
}

/// An actor whose code always runs on one dedicated thread.
actor AudioEngine {
    private let executor = ThreadExecutor(name: "Audio")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private var framesRendered = 0

    func render(frames: Int) -> String {
        framesRendered += frames
        return "rendered \(framesRendered) frames on thread '\(Thread.current.name ?? "?")'"
    }
}

print("Start")

let urls = (0 ..< 100).map { URL(string: "https://example.com/file-\($0)")! }
let files = try await loadFiles(urls: urls)
print("Loaded \(files.count) files")

let thumbnails = DispatchQueueTaskExecutor(concurrentLabel: "Thumbnails", qos: .background)
let thumbnailTask = Task(name: "Thumbnails", executorPreference: thumbnails) {
    await busyWork()
}
let checksum = await thumbnailTask.value
print("Generated thumbnails, checksum \(checksum)")

let engine = AudioEngine()
for _ in 0 ..< 3 {
    let status = await engine.render(frames: 512)
    print(status)
}
