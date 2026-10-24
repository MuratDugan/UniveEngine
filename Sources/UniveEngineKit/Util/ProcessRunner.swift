import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
    public var succeeded: Bool { status == 0 }
}

public enum ProcessRunnerError: Error {
    case launchFailed(String)
}

/// Async wrapper around `Process`: streams output lines, supports cancellation.
public enum ProcessRunner {
    public enum Line: Sendable {
        case stdout(String)
        case stderr(String)
    }

    /// Runs to completion and returns combined output. Cancelling the task terminates the process.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        onLine: (@Sendable (Line) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = Collector()
        // Both pipes are read without blocking, on one serial queue, by the readability handlers and by the final
        // drain at exit. A handler that runs after the drain finds the run closed and reads nothing, so no output is
        // lost or added after the result is returned, and reading an emptied pipe never throws.
        let serial = DispatchQueue(label: "univeengine.process-output")
        let streams: [(Pipe, LineSplitter, @Sendable (String) -> Line)] = [
            (out, LineSplitter(), { .stdout($0) }), (err, LineSplitter(), { .stderr($0) }),
        ]
        for (pipe, splitter, wrap) in streams {
            let fd = pipe.fileHandleForReading.fileDescriptor
            Self.makeNonBlocking(fd)
            pipe.fileHandleForReading.readabilityHandler = { _ in
                serial.sync {
                    guard !collector.isClosed else { return }
                    for line in splitter.feed(Self.readAvailable(fd)) { collector.append(line); onLine?(wrap(line)) }
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { p in
                    for (pipe, _, _) in streams { pipe.fileHandleForReading.readabilityHandler = nil }
                    let output: String = serial.sync {
                        // Read what's left without waiting for end-of-file: Wine hands its stderr to wineserver and
                        // its system processes, which keep the pipe open long after this command has exited.
                        for (pipe, splitter, wrap) in streams {
                            let rest = Self.readAvailable(pipe.fileHandleForReading.fileDescriptor)
                            for line in splitter.feed(rest) + splitter.flush() { collector.append(line); onLine?(wrap(line)) }
                        }
                        collector.close()
                        return collector.text
                    }
                    cont.resume(returning: ProcessResult(status: p.terminationStatus, output: output))
                }
                do { try process.run() }
                catch { cont.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription)) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

extension ProcessRunner {
    static func makeNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Everything readable right now from a non-blocking descriptor; stops at "would block" or end-of-file.
    static func readAvailable(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { data.append(buffer, count: n) } else if n < 0 && errno == EINTR { continue } else { break }
        }
        return data
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var closed = false
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    /// The result has been taken: later reads are dropped.
    func close() { lock.lock(); closed = true; lock.unlock() }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

/// Splits a byte stream into lines, keeping partial trailing data between reads.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }

    /// The last line when the output didn't end with a newline.
    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        return [String(decoding: buffer, as: UTF8.self)]
    }
}
