import Foundation

/// Runs blocking work on a thread of its own, so that it never holds one of the few threads of
/// Swift's cooperative pool: checking a bundle's seal, reading a Keychain that can prompt.
func runOnDedicatedThread<Result: Sendable>(
    _ work: @escaping @Sendable () throws -> Result
) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(with: Swift.Result { try work() })
        }
    }
}
