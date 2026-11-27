import Foundation

/// Runs CPU-heavy synchronous work on a GCD thread. On the cooperative pool it delays every other test,
/// and the timing tests (`ProcessOutcomeTests`) fail on a small CI runner. Record expectations on the returned value.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}
