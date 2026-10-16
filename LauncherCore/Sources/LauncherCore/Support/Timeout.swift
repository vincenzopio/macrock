/// Runs an operation, cancelling it and throwing `TimeoutError` if it has not finished in time.
/// The operation must stop when cancelled.
func withTimeout<Result: Sendable>(
    _ timeout: Duration, operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

public struct TimeoutError: Error, Equatable {}
