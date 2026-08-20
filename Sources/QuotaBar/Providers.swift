import Foundation

struct CodexQuotaProvider {
    func fetch() async throws -> CodexQuotaResult {
        guard let codex = ExecutableLocator.find("codex") else {
            throw QuotaError.executableMissing("Codex CLI")
        }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-hub","title":"AgentHub","version":"1.2.0"},"capabilities":{}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#,
            #"{"id":3,"method":"account/rateLimits/read","params":{}}"#
        ].joined(separator: "\n") + "\n"

        let result = try await ProcessRunner.run(
            executable: codex,
            arguments: ["app-server", "--stdio"],
            stdin: Data(requests.utf8),
            stdinCloseDelay: 5,
            timeout: 20
        )
        guard result.exitCode == 0 else {
            let detail = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw QuotaError.processFailed(detail?.isEmpty == false ? detail! : "Codex app-server 执行失败")
        }
        if ProcessInfo.processInfo.environment["AGENTHUB_DEBUG"] == "1" {
            print(String(data: result.stdout, encoding: .utf8) ?? "<non-UTF8 Codex output>")
        }

        var identity: AccountIdentity?
        var quota: QuotaWindow?
        var quotaError: String?
        var accountIsSignedOut = false
        for line in result.stdout.split(separator: 0x0A) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let id = object["id"] as? Int
            else { continue }

            if id == 3, let error = object["error"] as? [String: Any] {
                quotaError = (error["message"] as? String) ?? "Codex 额度读取失败"
                continue
            }
            guard let response = object["result"] as? [String: Any] else { continue }

            if id == 2 {
                if let account = response["account"] as? [String: Any],
                   let email = account["email"] as? String,
                   !email.isEmpty {
                    identity = AccountIdentity(
                        email: email,
                        planName: account["planType"] as? String
                    )
                } else if response["account"] is NSNull {
                    accountIsSignedOut = true
                }
                continue
            }

            guard id == 3, let rateLimits = response["rateLimits"] as? [String: Any] else { continue }

            let windows = [rateLimits["primary"], rateLimits["secondary"]]
                .compactMap { $0 as? [String: Any] }
            guard let weekly = windows.first(where: { numeric($0["windowDurationMins"]) ?? 0 >= 7 * 24 * 60 }) ?? windows.first else {
                continue
            }
            guard let used = numeric(weekly["usedPercent"]) else { continue }
            let reset = numeric(weekly["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
            quota = QuotaWindow(usedPercent: used, resetsAt: reset, windowName: "周额度")
        }
        if accountIsSignedOut && identity == nil { throw QuotaError.notLoggedIn("Codex") }
        if quota != nil || identity != nil {
            return CodexQuotaResult(weekly: quota, identity: identity, quotaError: quota == nil ? (quotaError ?? "Codex 额度暂时不可用") : nil)
        }
        throw QuotaError.malformedResponse("Codex")
    }

    private func numeric(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

}

struct CodexQuotaResult: Sendable {
    let weekly: QuotaWindow?
    let identity: AccountIdentity?
    let quotaError: String?
}

struct ClaudeQuotaResult: Sendable {
    let session: QuotaWindow
    let weekly: QuotaWindow
    let identity: AccountIdentity?
}

struct ClaudeQuotaProvider {
    func fetch() async throws -> ClaudeQuotaResult {
        let credential = try await readCredential()
        let identity = try? await readIdentity()
        guard let oauth = credential["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw QuotaError.notLoggedIn("Claude Code")
        }

        do {
            return try await requestUsage(token: token, identity: identity)
        } catch ClaudeHTTPError.unauthorized {
            // Claude Code refreshes its own OAuth token safely; never rewrite Keychain credentials here.
            try? await refreshCredentialThroughCLI()
            let refreshed = try await readCredential()
            guard let oauth = refreshed["claudeAiOauth"] as? [String: Any],
                  let newToken = oauth["accessToken"] as? String else {
                throw QuotaError.notLoggedIn("Claude Code")
            }
            return try await requestUsage(token: newToken, identity: try? await readIdentity())
        }
    }

    private func readIdentity() async throws -> AccountIdentity {
        guard let claude = ExecutableLocator.find("claude") else {
            throw QuotaError.executableMissing("Claude Code CLI")
        }
        let result = try await ProcessRunner.run(
            executable: claude,
            arguments: ["auth", "status", "--json"],
            timeout: 12
        )
        guard result.exitCode == 0,
              let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              (object["loggedIn"] as? Bool) == true,
              let email = object["email"] as? String,
              !email.isEmpty else {
            throw QuotaError.notLoggedIn("Claude Code")
        }
        return AccountIdentity(
            email: email,
            planName: object["subscriptionType"] as? String
        )
    }

    private func readCredential() async throws -> [String: Any] {
        let user = NSUserName()
        let security = URL(fileURLWithPath: "/usr/bin/security")
        let result = try await ProcessRunner.run(
            executable: security,
            arguments: ["find-generic-password", "-a", user, "-s", "Claude Code-credentials", "-w"],
            timeout: 8
        )
        guard result.exitCode == 0 else { throw QuotaError.notLoggedIn("Claude Code") }
        guard let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw QuotaError.malformedResponse("Claude Code 凭据")
        }
        return object
    }

    private func refreshCredentialThroughCLI() async throws {
        guard let claude = ExecutableLocator.find("claude") else { return }
        _ = try await ProcessRunner.run(
            executable: claude,
            arguments: ["auth", "status", "--json"],
            timeout: 12
        )
    }

    private func requestUsage(token: String, identity: AccountIdentity?) async throws -> ClaudeQuotaResult {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw QuotaError.network("Claude Code usage URL 无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Claude Code 网络响应无效")
        }
        if http.statusCode == 401 { throw ClaudeHTTPError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.network("Claude Code usage 请求失败（HTTP \(http.statusCode)）")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.malformedResponse("Claude Code")
        }

        let sessionObject = (json["five_hour"] as? [String: Any]) ?? activeLimit(in: json, group: "session")
        let weeklyObject = (json["seven_day"] as? [String: Any]) ?? activeLimit(in: json, group: "weekly")
        guard let sessionObject, let weeklyObject,
              let sessionUsed = percent(in: sessionObject),
              let weeklyUsed = percent(in: weeklyObject) else {
            throw QuotaError.malformedResponse("Claude Code")
        }

        return ClaudeQuotaResult(
            session: QuotaWindow(usedPercent: sessionUsed, resetsAt: resetDate(in: sessionObject), windowName: "日/会话额度（5 小时）"),
            weekly: QuotaWindow(usedPercent: weeklyUsed, resetsAt: resetDate(in: weeklyObject), windowName: "周额度（7 天）"),
            identity: identity
        )
    }

    private func activeLimit(in json: [String: Any], group: String) -> [String: Any]? {
        guard let limits = json["limits"] as? [[String: Any]] else { return nil }
        return limits.first { ($0["group"] as? String) == group && ($0["is_active"] as? Bool) == true }
            ?? limits.first { ($0["group"] as? String) == group }
    }

    private func percent(in object: [String: Any]) -> Double? {
        (object["utilization"] as? NSNumber)?.doubleValue
            ?? (object["percent"] as? NSNumber)?.doubleValue
    }

    private func resetDate(in object: [String: Any]) -> Date? {
        guard let string = object["resets_at"] as? String else { return nil }
        return ISO8601DateFormatter.withFractionalSeconds.date(from: string)
            ?? ISO8601DateFormatter().date(from: string)
    }
}

private enum ClaudeHTTPError: Error {
    case unauthorized
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
