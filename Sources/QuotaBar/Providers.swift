import Foundation

struct CodexQuotaProvider {
    func fetch() async throws -> CodexQuotaResult {
        var lastPartial: CodexQuotaResult?
        var lastError: Error?

        for attempt in 0..<3 {
            do {
                let result = try await fetchOnce()
                if result.weekly != nil {
                    return CodexQuotaResult(
                        weekly: result.weekly,
                        identity: result.identity ?? lastPartial?.identity,
                        quotaError: nil
                    )
                }
                lastPartial = CodexQuotaResult(
                    weekly: nil,
                    identity: result.identity ?? lastPartial?.identity,
                    quotaError: result.quotaError
                )
            } catch let error as QuotaError {
                if case .notLoggedIn = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }

            if attempt < 2 {
                let delay: UInt64 = attempt == 0 ? 600_000_000 : 1_500_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        if let partial = lastPartial {
            return CodexQuotaResult(
                weekly: nil,
                identity: partial.identity,
                quotaError: "已重试 3 次：\(partial.quotaError ?? "Codex 额度暂时不可用")"
            )
        }
        throw lastError ?? QuotaError.malformedResponse("Codex")
    }

    private func fetchOnce() async throws -> CodexQuotaResult {
        guard let codex = ExecutableLocator.find("codex") else {
            throw QuotaError.executableMissing("Codex CLI")
        }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-hub","title":"AgentHub","version":"1.3.3"},"capabilities":{}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#,
            #"{"id":3,"method":"account/rateLimits/read","params":{}}"#
        ].joined(separator: "\n") + "\n"

        let result = try await ProcessRunner.run(
            executable: codex,
            // Always inspect the preserved first-party login, even while the user's
            // interactive Codex sessions are routed through the local account pool.
            arguments: ["-c", "model_provider=\"openai\"", "app-server", "--stdio"],
            stdin: Data(requests.utf8),
            stdinCloseDelay: 5,
            timeout: 20,
            environment: SystemProxyEnvironment.current()
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
