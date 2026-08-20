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

        _ = try? await ProcessRunner.run(
            executable: claude,
            arguments: ["auth", "logout"],
            timeout: 20
        )
        try Task.checkCancellation()

        let result = try await ProcessRunner.run(
            executable: claude,
            arguments: ["auth", "login", "--claudeai", "--email", email],
            timeout: 3 * 60
        )
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw AccountLoginError.failed("Claude Code 登录未完成")
        }

        let status = try await ProcessRunner.run(
            executable: claude,
            arguments: ["auth", "status", "--json"],
            timeout: 20
        )
        try Task.checkCancellation()
        guard status.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
              let actualEmail = json["email"] as? String,
              !actualEmail.isEmpty else {
            throw AccountLoginError.failed("Claude Code 已授权，但无法确认登录账号")
        }
        guard actualEmail.caseInsensitiveCompare(email) == .orderedSame else {
            throw AccountLoginError.accountMismatch(expected: email, actual: actualEmail)
        }
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
    case accountMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .accountMismatch(let expected, let actual):
            return "实际登录的是 \(actual)，不是 \(expected)。请退出网页中的当前 Claude 账号后重试。"
        }
    }
}
