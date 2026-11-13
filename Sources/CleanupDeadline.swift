import Foundation

enum CleanupDeadline {
    /// Unlike a task-group race, this returns on time even if inference ignores
    /// cancellation. A late result cannot resume the caller twice or paste text.
    static func run<Value: Sendable>(seconds: Double,
                                     operation: @escaping @Sendable () async throws -> Value) async -> Value? {
        let race = Race<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard race.start(continuation) else { return }
                race.add(Task.detached {
                    do { try Task.checkCancellation(); race.finish(try await operation()) }
                    catch { race.finish(nil) }
                })
                race.add(Task.detached {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    race.finish(nil)
                })
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Value?, Never>?
        private var tasks: [Task<Void, Never>] = []

        func start(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
            let cancelled = lock.withLock {
                if finished { return true }
                self.continuation = continuation
                return false
            }
            if cancelled { continuation.resume(returning: nil) }
            return !cancelled
        }

        func add(_ task: Task<Void, Never>) {
            let cancel = lock.withLock {
                if finished { return true }
                tasks.append(task)
                return false
            }
            if cancel { task.cancel() }
        }

        func finish(_ value: Value?) {
            let pending: (CheckedContinuation<Value?, Never>?, [Task<Void, Never>])? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                let pending = (continuation, tasks)
                continuation = nil
                tasks = []
                return pending
            }
            guard let pending else { return }
            pending.1.forEach { $0.cancel() }
            pending.0?.resume(returning: value)
        }
    }
}
