import Foundation
import os

/// What a finished tool left: exit status and both outputs.
struct ProcessOutcome: Sendable {
    let status: Int32
    let output: Data
    let errors: Data

    /// After the tool exits, how long its pipes may stay open: a daemon started by a shell profile inherits them
    /// and never closes them.
    static let drainGrace: TimeInterval = 2

    /// `run` on a GCD thread: it blocks for up to `timeout`, and a few hung tools on the cooperative pool would
    /// stall every other task in the process. `make` builds the process on that thread, as `Process` is not Sendable.
    static func runDetached(
        tool: String,
        timeout: TimeInterval,
        _ make: @escaping @Sendable () -> Process
    ) async throws -> ProcessOutcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try run(make(), tool: tool, timeout: timeout) })
            }
        }
    }

    /// Blocking: reads both pipes while the tool runs, so a large output cannot fill a pipe and stall it.
    /// Past `timeout` the tool is terminated, killed if it ignores that, and the call throws `LiveError.timedOut`.
    static func run(_ process: Process, tool: String, timeout: TimeInterval) throws -> ProcessOutcome {
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let output = PipeReader(out.fileHandleForReading)
        let errors = PipeReader(err.fileHandleForReading)
        defer {
            output.stop()
            errors.stop()
        }
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            throw LiveError.timedOut(tool: tool, seconds: timeout)
        }
        let grace = min(deadline, .now() + drainGrace)
        output.wait(until: grace)
        errors.wait(until: grace)
        return ProcessOutcome(status: process.terminationStatus, output: output.data, errors: errors.data)
    }
}

/// Collects a pipe through a readability handler: no thread waits on it, so stopping it leaves nothing blocked.
private final class PipeReader: Sendable {
    private let handle: FileHandle
    private let buffer = OSAllocatedUnfairLock(initialState: Data())
    private let finished = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [buffer, finished] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finished.signal()
            } else {
                buffer.withLock { $0.append(chunk) }
            }
        }
    }

    var data: Data {
        buffer.withLock { $0 }
    }

    func wait(until deadline: DispatchTime) {
        if finished.wait(timeout: deadline) == .success {
            // Lets a later wait return at once too.
            finished.signal()
        }
    }

    func stop() {
        handle.readabilityHandler = nil
    }
}
