import AppKit
import Foundation
import Security

struct ManagedCodexAccount: Identifiable, Equatable {
    let id: Int
    let name: String
    let email: String
    let planType: String?
    let status: String
    let schedulable: Bool
    let fiveHourUsedPercent: Double?
    let weeklyUsedPercent: Double?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let usageUpdatedAt: Date?

    var isEnabled: Bool { status == "active" }
    var hasVerifiedQuota: Bool { weeklyUsedPercent != nil && usageUpdatedAt != nil }
    var isQuotaExhausted: Bool { weeklyUsedPercent.map { $0 >= 100 } ?? false }
    var weeklyRemainingPercent: Double? {
        weeklyUsedPercent.map { min(100, max(0, 100 - $0)) }
    }
    var isAvailable: Bool {
        isEnabled && schedulable && hasVerifiedQuota && !isQuotaExhausted
    }

    static func displayOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let leftRank = lhs.sortRank
        let rightRank = rhs.sortRank
        if leftRank != rightRank { return leftRank < rightRank }

        switch leftRank {
        case 0:
            let leftRemaining = lhs.weeklyRemainingPercent ?? 0
            let rightRemaining = rhs.weeklyRemainingPercent ?? 0
            if leftRemaining != rightRemaining { return leftRemaining > rightRemaining }
        case 1:
            let leftReset = lhs.weeklyResetAt ?? .distantFuture
            let rightReset = rhs.weeklyResetAt ?? .distantFuture
            if leftReset != rightReset { return leftReset < rightReset }
        default:
            break
        }
        return lhs.id > rhs.id
    }

    private var sortRank: Int {
        guard isEnabled else { return 3 }
        guard hasVerifiedQuota else { return 2 }
        return (weeklyRemainingPercent ?? 0) > 0 ? 0 : 1
    }
}

struct CodexOAuthLoginFlow: Codable, Equatable {
    let authorizationURL: URL
    let sessionID: String
    let state: String
    let createdAt: Date

    var isExpired: Bool { Date().timeIntervalSince(createdAt) >= 30 * 60 }
}

struct Sub2APIAdminSession {
    let accessToken: String
}

enum Sub2APIServiceState: Equatable {
    case stopped
    case starting(String)
    case running
    case failed(String)
    case dockerUnavailable(String)

    var title: String {
        switch self {
        case .stopped: return "已停止"
        case .starting(let message): return message
        case .running: return "运行中"
        case .failed: return "启动失败"
        case .dockerUnavailable: return "Docker 不可用"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var detail: String? {
        switch self {
        case .failed(let message), .dockerUnavailable(let message): return message
        default: return nil
        }
    }
}

@MainActor
final class Sub2APIServiceManager: ObservableObject {
    static let pinnedVersion = "0.1.179"
    static let hostPort = 18_080
    static let codexProviderID = "agenthub_multiaccount"

    @Published private(set) var state: Sub2APIServiceState = .stopped
    @Published private(set) var adminEmail = "admin@agenthub.local"
    @Published private(set) var adminPassword = ""
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var codexRoutingEnabled = false
    @Published private(set) var isUpdatingCodexRouting = false
    @Published private(set) var codexRoutingMessage: String?
    @Published private(set) var managedCodexAccounts: [ManagedCodexAccount] = []
    @Published private(set) var isRefreshingManagedAccounts = false
    @Published private(set) var managedAccountsMessage: String?
    @Published private(set) var refreshingQuotaAccountIDs: Set<Int> = []
    @Published private(set) var quotaRefreshErrors: [Int: String] = [:]
    @Published private(set) var oauthLoginFlow: CodexOAuthLoginFlow?
    @Published var oauthCallbackInput = ""
    @Published private(set) var isStartingOAuthLogin = false
    @Published private(set) var isCompletingOAuthLogin = false
    @Published private(set) var oauthLoginMessage: String?

    let baseURL = URL(string: "http://127.0.0.1:\(hostPort)")!

    private var lifecycleTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private let fileManager = FileManager.default

    private var supportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentHub/Sub2API", isDirectory: true)
    }

    private var composeURL: URL { supportDirectory.appendingPathComponent("docker-compose.yml") }
    private var environmentURL: URL { supportDirectory.appendingPathComponent(".env") }
    private var codexConfigURL: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }
    private var codexCredentialHelperURL: URL {
        supportDirectory.appendingPathComponent("codex-api-key")
    }
    private var codexAPIKeyURL: URL {
        supportDirectory.appendingPathComponent("codex-api-key.secret")
    }
    private var oauthFlowURL: URL {
        supportDirectory.appendingPathComponent("codex-oauth-flow.json")
    }

    init() {
        let currentProvider = Self.currentModelProvider(in: codexConfigURL)
        codexRoutingEnabled = currentProvider == Self.codexProviderID || currentProvider == "agenthub_sub2api"
        if currentProvider == "agenthub_sub2api" {
            try? updateCodexProvider(Self.codexProviderID)
        }
        restoreOAuthLoginFlow()
    }

    func start() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await startService()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await refreshState()
            }
        }
    }

    func startService() async {
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            await self?.performStart()
        }
        await operationTask?.value
        operationTask = nil
    }

    func restartService() async {
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            state = .starting("正在重启多账号服务…")
            do {
                try ensureConfiguration()
                _ = try await runDocker(composeArguments(["up", "-d", "--remove-orphans", "--force-recreate"]), timeout: 600)
                try await enforceLoopbackBinding()
                try await waitUntilHealthy(timeout: 180)
                state = .running
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        await operationTask?.value
        operationTask = nil
    }

    func stopService() async {
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            state = .starting("正在停止多账号服务…")
            do {
                try ensureConfiguration()
                _ = try await runDocker(composeArguments(["stop"]), timeout: 90)
                state = .stopped
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        await operationTask?.value
        operationTask = nil
    }

    func refreshState() async {
        if await isHealthy() {
            state = .running
        } else if state.isRunning {
            state = .stopped
        }
        lastCheckedAt = Date()
    }

    func refreshManagedCodexAccounts(forceQuotaRefresh: Bool = false) async {
        guard state.isRunning, !isRefreshingManagedAccounts else { return }
        isRefreshingManagedAccounts = true
        defer { isRefreshingManagedAccounts = false }

        do {
            let accounts = try await loadManagedCodexAccounts()
            managedCodexAccounts = accounts

            // `schedulable` only means that Sub2API has administratively enabled the
            // account. It is not evidence that the upstream subscription has quota.
            // Probe every new account before AgentHub ever labels it as available.
            let accountsToProbe = accounts.filter {
                $0.isEnabled && (forceQuotaRefresh || !$0.hasVerifiedQuota)
            }
            for account in accountsToProbe {
                refreshingQuotaAccountIDs.insert(account.id)
                quotaRefreshErrors[account.id] = nil
                do {
                    _ = try await adminAPI(
                        path: "/api/v1/admin/openai/accounts/\(account.id)/quota/refresh",
                        method: "POST",
                        body: [:]
                    )
                } catch {
                    quotaRefreshErrors[account.id] = error.localizedDescription
                }
                refreshingQuotaAccountIDs.remove(account.id)
            }

            if !accountsToProbe.isEmpty {
                managedCodexAccounts = try await loadManagedCodexAccounts()
            }
            let failedCount = accountsToProbe.filter { quotaRefreshErrors[$0.id] != nil }.count
            managedAccountsMessage = failedCount == 0
                ? nil
                : "有 \(failedCount) 个账号的额度验证失败；失败账号不会参与可用状态判断"
        } catch {
            managedAccountsMessage = error.localizedDescription
        }
    }

    func isRefreshingQuota(for accountID: Int) -> Bool {
        refreshingQuotaAccountIDs.contains(accountID)
    }

    private func loadManagedCodexAccounts() async throws -> [ManagedCodexAccount] {
        let payload = try await adminAPI(
            path: "/api/v1/admin/accounts",
            queryItems: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "page_size", value: "200"),
                URLQueryItem(name: "platform", value: "openai"),
                URLQueryItem(name: "sort_by", value: "created_at"),
                URLQueryItem(name: "sort_order", value: "desc")
            ]
        )
        guard let page = payload as? [String: Any],
              let items = page["items"] as? [[String: Any]] else {
            throw QuotaError.processFailed("无法读取 Codex 账号列表")
        }
        return items.compactMap(Self.parseManagedCodexAccount).sorted(by: ManagedCodexAccount.displayOrder)
    }

    func beginCodexAccountLogin() async {
        guard !isStartingOAuthLogin else { return }
        isStartingOAuthLogin = true
        oauthLoginMessage = "正在生成官方登录链接…"
        defer { isStartingOAuthLogin = false }

        do {
            guard state.isRunning else {
                throw QuotaError.processFailed("本地多账号服务尚未运行")
            }
            guard let result = try await adminAPI(
                path: "/api/v1/admin/openai/generate-auth-url",
                method: "POST",
                body: [:]
            ) as? [String: Any],
                  let rawURL = result["auth_url"] as? String,
                  let authorizationURL = URL(string: rawURL),
                  let sessionID = result["session_id"] as? String,
                  let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "state" })?.value,
                  !state.isEmpty else {
                throw QuotaError.processFailed("无法生成 Codex 登录链接")
            }

            let flow = CodexOAuthLoginFlow(
                authorizationURL: authorizationURL,
                sessionID: sessionID,
                state: state,
                createdAt: Date()
            )
            oauthLoginFlow = flow
            oauthCallbackInput = ""
            oauthLoginMessage = "请在浏览器完成登录，再粘贴最终回调链接"
            try persistOAuthLoginFlow(flow)
        } catch {
            oauthLoginMessage = error.localizedDescription
        }
    }

    func copyCodexAuthorizationURL() {
        guard let url = oauthLoginFlow?.authorizationURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        oauthLoginMessage = "登录链接已复制"
    }

    func openCodexAuthorizationURL() {
        guard let url = oauthLoginFlow?.authorizationURL else { return }
        NSWorkspace.shared.open(url)
    }

    func cancelCodexAccountLogin() {
        oauthLoginFlow = nil
        oauthCallbackInput = ""
        oauthLoginMessage = nil
        try? fileManager.removeItem(at: oauthFlowURL)
    }

    func completeCodexAccountLogin() async {
        guard !isCompletingOAuthLogin else { return }
        isCompletingOAuthLogin = true
        oauthLoginMessage = "正在验证并添加账号…"
        defer { isCompletingOAuthLogin = false }

        do {
            guard let flow = oauthLoginFlow, !flow.isExpired else {
                cancelCodexAccountLogin()
                throw QuotaError.processFailed("登录链接已超过 30 分钟，请重新生成")
            }
            let callback = try Self.parseOAuthCallback(oauthCallbackInput, expectedState: flow.state)
            guard let tokenInfo = try await adminAPI(
                path: "/api/v1/admin/openai/exchange-code",
                method: "POST",
                body: [
                    "session_id": flow.sessionID,
                    "code": callback.code,
                    "state": callback.state
                ]
            ) as? [String: Any] else {
                throw QuotaError.processFailed("Codex 授权结果无效")
            }

            let groupID = try await defaultOpenAIGroupID()
            let credentials = Self.openAICredentials(from: tokenInfo)
            let extra = Self.openAIExtra(from: tokenInfo)
            let email = (tokenInfo["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountName = (email?.isEmpty == false ? email! : nil) ?? "Codex 账号"
            _ = try await adminAPI(
                path: "/api/v1/admin/accounts",
                method: "POST",
                body: [
                    "name": accountName,
                    "platform": "openai",
                    "type": "oauth",
                    "credentials": credentials,
                    "extra": extra,
                    "group_ids": [groupID]
                ]
            )

            cancelCodexAccountLogin()
            await refreshManagedCodexAccounts()
            try await prepareCodexRoutingKey()
            await setCodexRoutingEnabled(true)
            managedAccountsMessage = "账号已添加，多账号模式已启用；新启动的 Codex 将自动使用账号池"
        } catch {
            oauthLoginMessage = error.localizedDescription
        }
    }

    func setManagedCodexAccountEnabled(_ account: ManagedCodexAccount, enabled: Bool) async {
        do {
            _ = try await adminAPI(
                path: "/api/v1/admin/accounts/\(account.id)",
                method: "PUT",
                body: ["status": enabled ? "active" : "inactive"]
            )
            await refreshManagedCodexAccounts()
        } catch {
            managedAccountsMessage = error.localizedDescription
        }
    }

    private func adminAPI(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> Any {
        let session = try await createAdminSession()
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(
            url: baseURL.appendingPathComponent(normalizedPath),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty { components.queryItems = queryItems }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.processFailed("本地多账号服务响应无效")
        }
        let code = (envelope["code"] as? NSNumber)?.intValue ?? -1
        guard (200..<300).contains(http.statusCode), code == 0 else {
            let details = (envelope["detail"] as? String)
                ?? (envelope["message"] as? String)
                ?? "请求失败（HTTP \(http.statusCode)）"
            throw QuotaError.processFailed(details)
        }
        return envelope["data"] ?? NSNull()
    }

    private func defaultOpenAIGroupID() async throws -> Int {
        guard let groups = try await adminAPI(
            path: "/api/v1/admin/groups/all",
            queryItems: [
                URLQueryItem(name: "platform", value: "openai"),
                URLQueryItem(name: "status", value: "active")
            ]
        ) as? [[String: Any]],
              let group = groups.first(where: { ($0["name"] as? String) == "openai-default" })
                ?? groups.first,
              let id = (group["id"] as? NSNumber)?.intValue else {
            throw QuotaError.processFailed("未找到可用的 Codex 账号组")
        }
        return id
    }

    private func prepareCodexRoutingKey() async throws {
        if let existing = try await activeCodexAPIKey() {
            try saveCodexAPIKey(existing)
            try writeCodexCredentialHelper()
            return
        }

        let groupID = try await defaultOpenAIGroupID()
        guard let created = try await adminAPI(
            path: "/api/v1/keys",
            method: "POST",
            body: [
                "name": "AgentHub Codex local",
                "group_id": groupID,
                "ip_whitelist": ["127.0.0.1", "::1"],
                "quota": 0,
                "rate_limit_5h": 0,
                "rate_limit_1d": 0,
                "rate_limit_7d": 0
            ]
        ) as? [String: Any],
              let key = created["key"] as? String,
              !key.isEmpty else {
            throw QuotaError.processFailed("无法创建本机 Codex 连接凭据")
        }
        try saveCodexAPIKey(key)
        try writeCodexCredentialHelper()
    }

    private func activeCodexAPIKey() async throws -> String? {
        guard let payload = try await adminAPI(
            path: "/api/v1/keys",
            queryItems: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "page_size", value: "100"),
                URLQueryItem(name: "sort_by", value: "created_at"),
                URLQueryItem(name: "sort_order", value: "desc")
            ]
        ) as? [String: Any],
              let items = payload["items"] as? [[String: Any]] else {
            throw QuotaError.processFailed("无法读取本机 Codex 连接凭据")
        }
        let activeItems = items.filter { ($0["status"] as? String) == "active" }
        let preferred = activeItems.first { ($0["name"] as? String) == "AgentHub Codex local" }
            ?? activeItems.first
        return preferred?["key"] as? String
    }

    static func parseOAuthCallback(
        _ rawValue: String,
        expectedState: String
    ) throws -> (code: String, state: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QuotaError.processFailed("请粘贴浏览器地址栏中的完整回调链接")
        }

        let candidate = trimmed.contains("://") ? trimmed : "http://localhost/?\(trimmed)"
        let components = URLComponents(string: candidate)
        let code = components?.queryItems?.first(where: { $0.name == "code" })?.value
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value
            ?? expectedState
        guard let code, !code.isEmpty else {
            throw QuotaError.processFailed("回调链接中没有找到授权码")
        }
        guard state == expectedState else {
            throw QuotaError.processFailed("回调链接与当前登录会话不匹配，请重新登录")
        }
        return (code, state)
    }

    private static func openAICredentials(from tokenInfo: [String: Any]) -> [String: Any] {
        let keys = [
            "access_token", "refresh_token", "id_token", "expires_at", "email",
            "chatgpt_account_id", "chatgpt_user_id", "organization_id", "plan_type",
            "subscription_expires_at", "client_id"
        ]
        var credentials: [String: Any] = [:]
        for key in keys where tokenInfo[key] != nil && !(tokenInfo[key] is NSNull) {
            credentials[key] = tokenInfo[key]
        }
        return credentials
    }

    private static func openAIExtra(from tokenInfo: [String: Any]) -> [String: Any] {
        let keys = ["email", "name", "privacy_mode"]
        var extra: [String: Any] = [
            "openai_long_context_billing_enabled": false,
            "openai_oauth_responses_websockets_v2_enabled": false,
            "openai_oauth_responses_websockets_v2_mode": "off"
        ]
        for key in keys where tokenInfo[key] != nil && !(tokenInfo[key] is NSNull) {
            extra[key] = tokenInfo[key]
        }
        return extra
    }

    private static func parseManagedCodexAccount(_ item: [String: Any]) -> ManagedCodexAccount? {
        guard let id = (item["id"] as? NSNumber)?.intValue else { return nil }
        let extra = item["extra"] as? [String: Any] ?? [:]
        let name = item["name"] as? String ?? "Codex 账号"
        let email = (extra["email"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        return ManagedCodexAccount(
            id: id,
            name: name,
            email: email,
            planType: (extra["plan_type"] as? String) ?? (item["plan_type"] as? String),
            status: item["status"] as? String ?? "unknown",
            schedulable: item["schedulable"] as? Bool ?? false,
            fiveHourUsedPercent: (extra["codex_5h_used_percent"] as? NSNumber)?.doubleValue,
            weeklyUsedPercent: (extra["codex_7d_used_percent"] as? NSNumber)?.doubleValue,
            fiveHourResetAt: parseISODate(extra["codex_5h_reset_at"] as? String),
            weeklyResetAt: parseISODate(extra["codex_7d_reset_at"] as? String),
            usageUpdatedAt: parseISODate(extra["codex_usage_updated_at"] as? String)
        )
    }

    private static func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private func persistOAuthLoginFlow(_ flow: CodexOAuthLoginFlow) throws {
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(flow)
        try data.write(to: oauthFlowURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oauthFlowURL.path)
    }

    private func restoreOAuthLoginFlow() {
        guard let data = try? Data(contentsOf: oauthFlowURL),
              let flow = try? JSONDecoder().decode(CodexOAuthLoginFlow.self, from: data),
              !flow.isExpired else {
            try? fileManager.removeItem(at: oauthFlowURL)
            return
        }
        oauthLoginFlow = flow
        oauthLoginMessage = "登录尚未完成，请粘贴浏览器中的回调链接"
    }

    func createAdminSession() async throws -> Sub2APIAdminSession {
        guard !adminEmail.isEmpty, !adminPassword.isEmpty else {
            throw QuotaError.processFailed("本地管理员凭据尚未准备完成")
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": adminEmail,
            "password": adminPassword
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["code"] as? Int) == 0,
              let payload = envelope["data"] as? [String: Any],
              let accessToken = payload["access_token"] as? String else {
            throw QuotaError.processFailed("无法建立本地多账号管理会话")
        }
        return Sub2APIAdminSession(accessToken: accessToken)
    }

    func revealDataDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([supportDirectory])
    }

    func setCodexRoutingEnabled(_ enabled: Bool) async {
        guard !isUpdatingCodexRouting else { return }
        isUpdatingCodexRouting = true
        codexRoutingMessage = enabled ? "正在启用 Codex 多账号模式…" : "正在切回官方 Codex…"
        defer { isUpdatingCodexRouting = false }

        do {
            try ensureConfiguration()
            if enabled {
                guard state.isRunning else {
                    throw QuotaError.processFailed("本地多账号服务尚未运行")
                }
                try await prepareCodexRoutingKey()
            }
            try updateCodexProvider(enabled ? Self.codexProviderID : "openai")
            codexRoutingEnabled = enabled
            codexRoutingMessage = enabled
                ? "新启动的 Codex 将使用本地多账号池"
                : "新启动的 Codex 将使用官方授权"
        } catch {
            codexRoutingMessage = error.localizedDescription
            let provider = Self.currentModelProvider(in: codexConfigURL)
            codexRoutingEnabled = provider == Self.codexProviderID || provider == "agenthub_sub2api"
        }
    }

    private func saveCodexAPIKey(_ key: String) throws {
        try key.write(to: codexAPIKeyURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codexAPIKeyURL.path)
    }

    private func writeCodexCredentialHelper() throws {
        let helper = """
        #!/bin/zsh
        exec /bin/cat "\(codexAPIKeyURL.path)"
        """
        try helper.write(to: codexCredentialHelperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexCredentialHelperURL.path)
    }

    private func updateCodexProvider(_ provider: String) throws {
        try fileManager.createDirectory(
            at: codexConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var contents = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
        let backupURL = codexConfigURL.appendingPathExtension("agenthub-backup")
        if fileManager.fileExists(atPath: codexConfigURL.path),
           !fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.copyItem(at: codexConfigURL, to: backupURL)
        }

        contents = Self.settingTopLevelValue("model_provider", to: provider, in: contents)
        if !contents.contains("[model_providers.\(Self.codexProviderID)]") {
            if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
            contents += """

            [model_providers.\(Self.codexProviderID)]
            name = "AgentHub Codex Multi-Account"
            base_url = "http://127.0.0.1:\(Self.hostPort)/v1"
            wire_api = "responses"

            [model_providers.\(Self.codexProviderID).auth]
            command = "\(codexCredentialHelperURL.path)"
            timeout_ms = 3000
            refresh_interval_ms = 0
            """
        }
        try contents.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    }

    static func currentModelProvider(in configURL: URL) -> String? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        let topLevel = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        for line in topLevel {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "model_provider" {
                return parts[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    static func settingTopLevelValue(_ key: String, to value: String, in contents: String) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            ?? lines.endIndex
        if let index = lines[..<firstTable].firstIndex(where: {
            $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key
        }) {
            lines[index] = "\(key) = \"\(value)\""
        } else {
            lines.insert("\(key) = \"\(value)\"", at: firstTable)
        }
        return lines.joined(separator: "\n")
    }

    private func performStart() async {
        state = .starting("正在准备本地服务…")
        do {
            try ensureConfiguration()
            if await isHealthy() {
                try await enforceLoopbackBinding()
                state = .running
                return
            }

            guard let docker = ExecutableLocator.find("docker") else {
                state = .dockerUnavailable("未找到 Docker。请先安装并启动 Docker Desktop。")
                return
            }
            guard await ensureDockerReady(docker) else {
                state = .dockerUnavailable("Docker Desktop 无法启动，请打开 Docker Desktop 后重试。")
                return
            }

            state = .starting("首次运行可能需要下载本地服务镜像…")
            _ = try await runDocker(composeArguments(["up", "-d", "--remove-orphans"]), timeout: 900)
            try await enforceLoopbackBinding()
            state = .starting("正在等待数据库迁移和服务就绪…")
            try await waitUntilHealthy(timeout: 180)
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func ensureConfiguration() throws {
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if !fileManager.fileExists(atPath: environmentURL.path) {
            let password = try secureRandomString(byteCount: 24)
            let postgresPassword = try secureRandomString(byteCount: 32)
            let redisPassword = try secureRandomString(byteCount: 32)
            let jwtSecret = try secureRandomHex(byteCount: 32)
            let totpKey = try secureRandomHex(byteCount: 32)
            let contents = """
            SUB2API_VERSION=\(Self.pinnedVersion)
            SERVER_PORT=\(Self.hostPort)
            RUN_MODE=simple
            SIMPLE_MODE_CONFIRM=true
            POSTGRES_USER=sub2api
            POSTGRES_PASSWORD=\(postgresPassword)
            POSTGRES_DB=sub2api
            REDIS_PASSWORD=\(redisPassword)
            ADMIN_EMAIL=\(adminEmail)
            ADMIN_PASSWORD=\(password)
            JWT_SECRET=\(jwtSecret)
            TOTP_ENCRYPTION_KEY=\(totpKey)
            TZ=Asia/Shanghai
            """
            try contents.write(to: environmentURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environmentURL.path)
        } else {
            try updateEnvironmentValue("SUB2API_VERSION", value: Self.pinnedVersion)
        }

        if !fileManager.fileExists(atPath: composeURL.path) ||
            (try? String(contentsOf: composeURL)).map({ $0 != Self.composeFile }) == true {
            try Self.composeFile.write(to: composeURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: composeURL.path)
        }
        loadCredentials()
    }

    private func updateEnvironmentValue(_ key: String, value: String) throws {
        var contents = try String(contentsOf: environmentURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = lines.firstIndex(where: { $0.hasPrefix("\(key)=") }) {
            lines[index] = "\(key)=\(value)"
        } else {
            lines.append("\(key)=\(value)")
        }
        contents = lines.joined(separator: "\n")
        try contents.write(to: environmentURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environmentURL.path)
    }

    private func loadCredentials() {
        guard let contents = try? String(contentsOf: environmentURL, encoding: .utf8) else { return }
        var values: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        adminEmail = values["ADMIN_EMAIL"] ?? adminEmail
        adminPassword = values["ADMIN_PASSWORD"] ?? ""
    }

    private func composeArguments(_ arguments: [String]) -> [String] {
        [
            "compose", "--project-name", "agenthub-sub2api",
            "--env-file", environmentURL.path,
            "--file", composeURL.path
        ] + arguments
    }

    private func runDocker(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        guard let docker = ExecutableLocator.find("docker") else {
            throw QuotaError.processFailed("未找到 Docker")
        }
        let result = try await ProcessRunner.run(executable: docker, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let message = [stderr, stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Docker 命令失败"
            throw QuotaError.processFailed(String(message.suffix(1_200)))
        }
        return result
    }

    private func ensureDockerReady(_ docker: URL) async -> Bool {
        if await dockerIsReady(docker) { return true }

        let dockerApplications = [
            URL(fileURLWithPath: "/Applications/Docker.app"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Docker.app")
        ]
        guard let dockerApp = dockerApplications.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return false
        }

        state = .starting("正在启动 Docker Desktop…")
        _ = try? await NSWorkspace.shared.openApplication(at: dockerApp, configuration: .init())
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await dockerIsReady(docker) { return true }
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
        }
        return false
    }

    private func dockerIsReady(_ docker: URL) async -> Bool {
        guard let result = try? await ProcessRunner.run(
            executable: docker,
            arguments: ["info", "--format", "{{.ServerVersion}}"],
            timeout: 15
        ) else { return false }
        return result.exitCode == 0
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func waitUntilHealthy(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if await isHealthy() { return }
            try await Task.sleep(nanoseconds: 2 * 1_000_000_000)
        }
        throw QuotaError.processFailed("本地多账号服务在 \(Int(timeout)) 秒内未能启动，请查看服务日志")
    }

    private func enforceLoopbackBinding() async throws {
        let result = try await runDocker([
            "inspect", "--format", "{{json .HostConfig.PortBindings}}", "agenthub-sub2api"
        ], timeout: 15)
        guard Self.portBindingsAreLoopbackOnly(result.stdout) else {
            _ = try? await runDocker(["stop", "agenthub-sub2api"], timeout: 30)
            throw QuotaError.processFailed("安全拦截：检测到多账号服务端口并非仅绑定本机，服务已自动停止")
        }
    }

    static func portBindingsAreLoopbackOnly(_ data: Data) -> Bool {
        struct Binding: Decodable {
            let hostIP: String
            let hostPort: String

            enum CodingKeys: String, CodingKey {
                case hostIP = "HostIp"
                case hostPort = "HostPort"
            }
        }

        guard let bindings = try? JSONDecoder().decode([String: [Binding]].self, from: data),
              bindings.count == 1,
              let httpBindings = bindings["8080/tcp"],
              httpBindings.count == 1,
              let binding = httpBindings.first else {
            return false
        }
        return (binding.hostIP == "127.0.0.1" || binding.hostIP == "::1") &&
            binding.hostPort == String(hostPort)
    }

    private func secureRandomHex(byteCount: Int) throws -> String {
        try secureRandomData(byteCount: byteCount).map { String(format: "%02x", $0) }.joined()
    }

    private func secureRandomString(byteCount: Int) throws -> String {
        try secureRandomData(byteCount: byteCount)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func secureRandomData(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw QuotaError.processFailed("无法生成本地服务密钥")
        }
        return Data(bytes)
    }

    static let composeFile = """
    services:
      sub2api:
        image: weishaw/sub2api:${SUB2API_VERSION}
        container_name: agenthub-sub2api
        restart: unless-stopped
        security_opt:
          - no-new-privileges:true
        ports:
          - "127.0.0.1:${SERVER_PORT}:8080"
        volumes:
          - sub2api_data:/app/data
        environment:
          AUTO_SETUP: "true"
          SERVER_HOST: "0.0.0.0"
          SERVER_PORT: "8080"
          SERVER_MODE: "release"
          RUN_MODE: "${RUN_MODE}"
          SIMPLE_MODE_CONFIRM: "${SIMPLE_MODE_CONFIRM}"
          DATABASE_HOST: "postgres"
          DATABASE_PORT: "5432"
          DATABASE_USER: "${POSTGRES_USER}"
          DATABASE_PASSWORD: "${POSTGRES_PASSWORD}"
          DATABASE_DBNAME: "${POSTGRES_DB}"
          DATABASE_SSLMODE: "disable"
          REDIS_HOST: "redis"
          REDIS_PORT: "6379"
          REDIS_PASSWORD: "${REDIS_PASSWORD}"
          REDIS_DB: "0"
          ADMIN_EMAIL: "${ADMIN_EMAIL}"
          ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
          JWT_SECRET: "${JWT_SECRET}"
          JWT_EXPIRE_HOUR: "24"
          TOTP_ENCRYPTION_KEY: "${TOTP_ENCRYPTION_KEY}"
          TZ: "${TZ}"
        depends_on:
          postgres:
            condition: service_healthy
          redis:
            condition: service_healthy
        networks:
          - internal
        healthcheck:
          test: ["CMD", "wget", "-q", "-T", "5", "-O", "/dev/null", "http://localhost:8080/health"]
          interval: 10s
          timeout: 5s
          retries: 12
          start_period: 30s

      postgres:
        image: postgres:18-alpine
        container_name: agenthub-sub2api-postgres
        restart: unless-stopped
        environment:
          PGDATA: "/var/lib/postgresql/data"
          POSTGRES_USER: "${POSTGRES_USER}"
          POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
          POSTGRES_DB: "${POSTGRES_DB}"
          TZ: "${TZ}"
        volumes:
          - postgres_data:/var/lib/postgresql/data
        networks:
          - internal
        healthcheck:
          test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
          interval: 5s
          timeout: 5s
          retries: 12

      redis:
        image: redis:8-alpine
        container_name: agenthub-sub2api-redis
        restart: unless-stopped
        command: ["redis-server", "--save", "60", "1", "--appendonly", "yes", "--appendfsync", "everysec", "--requirepass", "${REDIS_PASSWORD}"]
        environment:
          REDISCLI_AUTH: "${REDIS_PASSWORD}"
          TZ: "${TZ}"
        volumes:
          - redis_data:/data
        networks:
          - internal
        healthcheck:
          test: ["CMD", "redis-cli", "ping"]
          interval: 5s
          timeout: 5s
          retries: 12

    volumes:
      sub2api_data:
      postgres_data:
      redis_data:

    networks:
      internal:
        driver: bridge
    """
}
