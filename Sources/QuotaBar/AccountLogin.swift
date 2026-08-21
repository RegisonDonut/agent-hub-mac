import Foundation

struct AccountLoginLauncher: Sendable {
    func login(to account: AccountRecord, inputController: ProcessInputController? = nil) async throws {
        guard account.provider == .codex else {
            throw AccountLoginError.failed("AgentHub 目前仅支持 Codex")
        }
        try await loginCodex()
    }

    private func loginCodex() async throws {
        guard let codex = ExecutableLocator.find("codex") else {
            throw QuotaError.executableMissing("Codex CLI")
        }

        _ = try? await ProcessRunner.run(
            executable: codex,
            arguments: ["logout"],
            timeout: 20,
            environment: SystemProxyEnvironment.current()
        )
        let result = try await ProcessRunner.run(
            executable: codex,
            arguments: ["login"],
            timeout: 3 * 60,
            environment: SystemProxyEnvironment.current()
        )
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw AccountLoginError.failed("Codex 登录未完成")
        }
    }
}

enum AccountLoginError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}
