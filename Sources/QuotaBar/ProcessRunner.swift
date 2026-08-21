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
        environment: [String: String] = [:],
        inputController: ProcessInputController? = nil
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
            environment: environment,
            inputController: inputController
        )
    }

    static func run(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        stdinCloseDelay: TimeInterval = 0,
        timeout: TimeInterval = 15,
        environment: [String: String] = [:],
        inputController: ProcessInputController? = nil
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
                if stdin != nil || inputController != nil { process.standardInput = inputPipe }

                let completion = LockedProcessCompletion(continuation)
                guard cancellation.register(process: process, completion: completion) else { return }

                process.terminationHandler = { process in
                    inputController?.finish()
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
                    if inputController != nil {
                        inputController?.attach(inputPipe.fileHandleForWriting)
                    }
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

/// A short-lived input channel for an interactive child process. It never
/// persists input and is invalidated as soon as the process exits.
final class ProcessInputController: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var pending: [Data] = []
    private var finished = false

    func sendLine(_ value: String) throws {
        let data = Data((value + "\n").utf8)
        lock.lock()
        guard !finished else {
            lock.unlock()
            throw QuotaError.processFailed("登录任务已经结束，请重新点击账号")
        }
        if let handle {
            lock.unlock()
            try handle.write(contentsOf: data)
        } else {
            pending.append(data)
            lock.unlock()
        }
    }

    fileprivate func attach(_ handle: FileHandle) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            try? handle.close()
            return
        }
        self.handle = handle
        let queued = pending
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        for data in queued { try? handle.write(contentsOf: data) }
    }

    fileprivate func finish() {
        lock.lock()
        finished = true
        let handle = handle
        self.handle = nil
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        try? handle?.close()
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
