import Foundation
import Testing

/// Runs the tests of a suite on threads of their own instead of the threads of the task pool.
///
/// A test that asks SourceKit waits on its thread for the answer. SourceKit works for the answer on a thread that
/// the dispatch library gives to its global queue. The task pool has one thread per core. On macOS the kernel
/// counts a thread of the pool that waits as running, and it gives the global queue no thread while as many
/// threads run as the machine has cores. So when every thread of the pool waits for SourceKit, no answer comes.
/// A suite with this trait holds none of the pool's threads.
public struct OwnThreads: TestScoping, SuiteTrait, TestTrait {
    /// The name of each thread that runs a part of a test.
    public static let threadName = "SwiftLint test"

    public func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        guard #available(macOS 15.0, *) else {
            try await function()
            return
        }
        try await withTaskExecutorPreference(ThreadPerJob()) {
            try await function()
        }
    }
}

public extension Trait where Self == OwnThreads {
    static var ownThreads: Self { Self() }
}

@available(macOS 15.0, *)
private final class ThreadPerJob: TaskExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        Thread {
            // On Linux, a thread gets a name only from itself.
            Thread.current.name = OwnThreads.threadName
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }.start()
    }
}
