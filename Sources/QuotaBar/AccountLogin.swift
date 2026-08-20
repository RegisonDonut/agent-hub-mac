import Foundation

struct AccountLoginLauncher: Sendable {
    func login(to account: AccountRecord) async throws {
        switch account.provider {
        case .claudeCode:
            try await loginClaude(email: account.email)
        case .codex:
            try await loginCodex()
        }
    }

    private func loginClaude(email: String) async throws {
        guard let claude = ExecutableLocator.find("claude") else {
            throw QuotaError.executableMissing("Claude Code CLI")
        }
        let result = try await ProcessRunner.run(
            executable: claude,
            arguments: ["auth", "login", "--claudeai", "--email", email],
            timeout: 10 * 60
        )
        guard result.exitCode == 0 else {
            throw AccountLoginError.failed("Claude Code 登录未完成")
        }
    }

    private func loginCodex() async throws {
        guard let codex = ExecutableLocator.find("codex") else {
            throw QuotaError.executableMissing("Codex CLI")
        }

        _ = try? await ProcessRunner.run(
            executable: codex,
            arguments: ["logout"],
            timeout: 20
        )
        let result = try await ProcessRunner.run(
            executable: codex,
            arguments: ["login"],
            timeout: 10 * 60
        )
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
