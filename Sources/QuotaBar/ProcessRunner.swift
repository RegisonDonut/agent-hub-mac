import Foundation

struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

enum ProcessRunner {
    static func runInPseudoTerminal(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
        let wrapper = #"""
        parent_pid=$PPID
        /usr/bin/script -q /dev/null "$@" &
        child_pid=$!
        cleanup() {
          kill -TERM "$child_pid" 2>/dev/null || true
          wait "$child_pid" 2>/dev/null || true
        }
        trap 'cleanup; trap - EXIT; exit 143' TERM INT HUP
        trap cleanup EXIT
        while kill -0 "$child_pid" 2>/dev/null; do
          if ! kill -0 "$parent_pid" 2>/dev/null; then exit 143; fi
          sleep 0.25
        done
        wait "$child_pid"
        child_exit_code=$?
        trap - TERM INT HUP EXIT
        exit "$child_exit_code"
        """#
        return try await run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", wrapper, "agenthub-pty", executable.path] + arguments,
            timeout: timeout,
            environment: environment
        )
    }

    static func run(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        stdinCloseDelay: TimeInterval = 0,
        timeout: TimeInterval = 15,
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
        let cancellation = ProcessCancellationController()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
                }

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                let inputPipe = Pipe()
                if stdin != nil { process.standardInput = inputPipe }

                let completion = LockedProcessCompletion(continuation)
                guard cancellation.register(process: process, completion: completion) else { return }

                process.terminationHandler = { process in
                    let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if cancellation.isCancelled {
                        completion.resume(.failure(CancellationError()))
                    } else {
                        completion.resume(.success(ProcessResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)))
                    }
                }

                do {
                    try Task.checkCancellation()
                    try process.run()
                    if let stdin {
                        inputPipe.fileHandleForWriting.write(stdin)
                        if stdinCloseDelay > 0 {
                            DispatchQueue.global().asyncAfter(deadline: .now() + stdinCloseDelay) {
                                try? inputPipe.fileHandleForWriting.close()
                            }
                        } else {
                            try? inputPipe.fileHandleForWriting.close()
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning {
                            process.terminate()
                            completion.resume(.failure(QuotaError.processFailed("命令执行超时")))
                        }
                    }
                } catch {
                    completion.resume(.failure(error))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class ProcessCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var completion: LockedProcessCompletion?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(process: Process, completion: LockedProcessCompletion) -> Bool {
        lock.lock()
        self.process = process
        self.completion = completion
        let shouldRun = !cancelled
        lock.unlock()
        if !shouldRun { completion.resume(.failure(CancellationError())) }
        return shouldRun
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        let completion = completion
        lock.unlock()
        completion?.resume(.failure(CancellationError()))
        if process?.isRunning == true { process?.terminate() }
    }
}

private final class LockedProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<ProcessResult, Error>

    init(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

enum ExecutableLocator {
    static func find(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}
