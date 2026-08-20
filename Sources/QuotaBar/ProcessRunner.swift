import Foundation

struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        stdinCloseDelay: TimeInterval = 0,
        timeout: TimeInterval = 15,
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
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

            process.terminationHandler = { process in
                let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
                completion.resume(.success(ProcessResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)))
            }

            do {
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
