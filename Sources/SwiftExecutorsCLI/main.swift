//
//  main.swift
//  SwiftExecutors
//
//  Created by Mateusz Kosikowski on 19/06/2025.
//

import Foundation
import SwiftExecutors

let ioPool = QueueTaskExecutor(label: "File-IO",
                               maxConcurrent: 10, // read 4 files at once
                               qos: .utility)

/// A helper that spins up 100 reads but **never**  >4 simultaneously
func loadFiles(urls: [URL]) async throws -> [Data] {
    try await withTaskExecutorPreference(ioPool) {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in urls {
                group.addTask {
                    let a = Int.random(in: 0 ... 1000)
                    // runs on our OperationQueue
                    print("downloading \(a)")
                    var i = 0
                    for _ in 1 ... 3_000_000 {
                        i = i + 1
                    }
                    print("downloaded \(a)")
                    // let data = try Data(contentsOf: url)
                    let data = Data(capacity: a)
                    print(a, data)
                    return data
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
}

Task.detached { // detached so it survives caller's cancellation
    await withTaskExecutorPreference(
        QueueTaskExecutor(label: "Thumbnails", maxConcurrent: 2, qos: .background)
    ) {
        print("generating")
        var i = 0
        for _ in 1 ... 3_000_000 {
            i = i + 1
        }
        print("generated")
    }
}

var urls: [URL] = []
for _ in 0 ..< 100 {
    urls.append(URL(string: "https://google.com/")!)
}

print("Start")
let result = try await loadFiles(urls: urls)
print(result)
