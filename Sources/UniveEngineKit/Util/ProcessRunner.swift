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
        // One serial queue for the readers and the final drain, so no line lands after the result is returned.
        let serial = DispatchQueue(label: "univeengine.process-output")
        let streams: [(Pipe, LineSplitter, @Sendable (String) -> Line)] = [
            (out, LineSplitter(), { .stdout($0) }), (err, LineSplitter(), { .stderr($0) }),
        ]
        for (pipe, splitter, wrap) in streams {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                serial.sync {
                    for line in splitter.feed(data) { collector.append(line); onLine?(wrap(line)) }
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { p in
                    for (pipe, _, _) in streams { pipe.fileHandleForReading.readabilityHandler = nil }
                    serial.sync {
                        // Read what's left without waiting for end-of-file: Wine hands its stderr to wineserver and
                        // its system processes, which keep the pipe open long after this command has exited.
                        for (pipe, splitter, wrap) in streams {
                            let rest = Self.drainWithoutBlocking(pipe.fileHandleForReading)
                            for line in splitter.feed(rest) + splitter.flush() { collector.append(line); onLine?(wrap(line)) }
                        }
                    }
                    cont.resume(returning: ProcessResult(status: p.terminationStatus, output: collector.text))
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
    /// Everything readable right now, then stops at "would block" instead of waiting for end-of-file.
    static func drainWithoutBlocking(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
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
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
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
