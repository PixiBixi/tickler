import Foundation
import os

/// What a background run left: exit status and both outputs. `status` is -1 when the process never started.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
    public let cancelled: Bool
}

/// Runs one argv in a folder with a deadline, and can be stopped from another thread.
public final class ClaudeRunProcess: Sendable {
    private struct State {
        var process: Process?
        var cancelled = false
        var finished = false
    }

    /// After SIGTERM, how long the process may take to exit before SIGKILL.
    static let killGrace: TimeInterval = 5
    /// After a stop, how long the pipes may stay open: a child of the process can hold them.
    private static let stopDrainGrace: TimeInterval = 0.3

    private let command: [String]
    private let cwd: String
    private let timeout: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(command: [String], cwd: String, timeout: TimeInterval = 1800) {
        self.command = command
        self.cwd = cwd
        self.timeout = timeout
    }

    /// Runs on a GCD thread, so a 30 minute wait never holds a cooperative pool thread.
    public func run() async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.runBlocking())
            }
        }
    }

    /// Stops the run and its children (SIGTERM, then SIGKILL). Before `run()` it prevents the launch; after exit it does nothing.
    public func cancel() {
        let process: Process? = state.withLock { state in
            guard !state.finished else { return nil }
            state.cancelled = true
            return state.process
        }
        guard let process else { return }
        Self.stop(process)
    }

    /// `Process` starts the child as leader of its own group: signalling the group also stops what the login shell launched.
    private static func stop(_ process: Process) {
        let group = -process.processIdentifier
        kill(group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            if kill(group, 0) == 0 {
                kill(group, SIGKILL)
            }
        }
    }

    private func failure(_ message: String, cancelled: Bool = false) -> ProcessResult {
        ProcessResult(status: -1, stdout: Data(), stderr: Data(message.utf8), timedOut: false, cancelled: cancelled)
    }

    private enum Launch {
        case launched, cancelled
        case failed(String)
    }

    /// Under the lock, so a cancel() either lands before the launch (nothing starts) or sees the process.
    private func launch(_ process: Process) -> Launch {
        state.withLock { state in
            if state.cancelled {
                state.finished = true
                return .cancelled
            }
            do {
                try process.run()
                state.process = process
                return .launched
            } catch {
                state.finished = true
                return .failed(error.localizedDescription)
            }
        }
    }

    private func runBlocking() -> ProcessResult {
        guard !command.isEmpty else { return failure("empty command") }
        let process = Process()
        if command[0].hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
        }
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        switch launch(process) {
        case .launched: break
        case .cancelled: return failure("cancelled before start", cancelled: true)
        case let .failed(message): return failure(message)
        }

        let output = PipeReader(out.fileHandleForReading)
        let errors = PipeReader(err.fileHandleForReading)
        defer {
            output.stop()
            errors.stop()
        }
        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            Self.stop(process)
            exited.wait()
        }
        let cancelled = state.withLock { state in
            state.finished = true
            return state.cancelled
        }
        let stopped = timedOut || cancelled
        let grace = DispatchTime.now() + (stopped ? Self.stopDrainGrace : ProcessOutcome.drainGrace)
        output.wait(until: grace)
        errors.wait(until: grace)
        return ProcessResult(
            status: process.terminationStatus,
            stdout: output.data,
            stderr: errors.data,
            timedOut: timedOut,
            cancelled: cancelled && !timedOut
        )
    }
}
