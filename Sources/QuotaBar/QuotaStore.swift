import Foundation

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot = QuotaSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var accounts: [AccountRecord]
    @Published private(set) var loggingInAccountID: String?
    @Published private(set) var loginStatusMessage: String?

    private var refreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private let codex = CodexQuotaProvider()
    private let claude = ClaudeQuotaProvider()
    private let accountRepository: AccountHistoryRepository
    private let loginLauncher = AccountLoginLauncher()

    init(accountRepository: AccountHistoryRepository = AccountHistoryRepository()) {
        self.accountRepository = accountRepository
        self.accounts = accountRepository.load()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let codexResult: Result<CodexQuotaResult, Error> = capture { try await self.codex.fetch() }
        async let claudeResult: Result<ClaudeQuotaResult, Error> = capture { try await self.claude.fetch() }
        let (newCodex, newClaude) = await (codexResult, claudeResult)

        var next = snapshot
        switch newCodex {
        case .success(let result):
            if let weekly = result.weekly { next.codexWeekly = weekly }
            next.codexError = result.quotaError
            recordCurrentAccount(provider: .codex, identity: result.identity, quotas: result.weekly.map { [$0] })
        case .failure(let error):
            next.codexError = error.localizedDescription
            markSignedOutIfNeeded(provider: .codex, error: error)
        }
        switch newClaude {
        case .success(let result):
            next.claudeSession = result.session
            next.claudeWeekly = result.weekly
            next.claudeError = nil
            recordCurrentAccount(provider: .claudeCode, identity: result.identity, quotas: [result.session, result.weekly])
        case .failure(let error):
            next.claudeError = error.localizedDescription
            markSignedOutIfNeeded(provider: .claudeCode, error: error)
        }
        next.refreshedAt = Date()
        snapshot = next
        try? accountRepository.save(accounts)
    }

    func removeAccount(accountID: String) {
        accounts.removeAll { $0.id == accountID }
        try? accountRepository.save(accounts)
    }

    func login(to account: AccountRecord) {
        guard !account.isCurrent, loggingInAccountID == nil else { return }
        loggingInAccountID = account.id
        loginStatusMessage = "正在打开 \(account.provider.displayName) 官方登录页，请确认账号 \(account.email)…"

        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await loginLauncher.login(to: account)
                loginStatusMessage = "登录完成，正在刷新账号状态…"
                await refresh()
                loginStatusMessage = nil
            } catch is CancellationError {
                loginStatusMessage = "已取消登录授权"
                loggingInAccountID = nil
                loginTask = nil
                Task { await self.refresh() }
                return
            } catch {
                loginStatusMessage = error.localizedDescription
                await refresh()
            }
            loggingInAccountID = nil
            loginTask = nil
        }
    }

    func cancelLogin() {
        guard loginTask != nil else { return }
        loginStatusMessage = "正在取消登录授权…"
        loginTask?.cancel()
    }

    private func recordCurrentAccount(provider: CodingProvider, identity: AccountIdentity?, quotas: [QuotaWindow]?) {
        let now = Date()
        if let identity {
            let id = AccountRecord.makeID(provider: provider, email: identity.email)
            for index in accounts.indices where accounts[index].provider == provider {
                accounts[index].isCurrent = accounts[index].id == id
            }
            if let index = accounts.firstIndex(where: { $0.id == id }) {
                accounts[index].email = identity.email
                accounts[index].planName = identity.planName ?? accounts[index].planName
                if let quotas { accounts[index].quotas = quotas }
                accounts[index].lastRefreshedAt = now
                accounts[index].isCurrent = true
            } else {
                accounts.append(AccountRecord(
                    provider: provider,
                    email: identity.email,
                    planName: identity.planName,
                    quotas: quotas ?? [],
                    lastRefreshedAt: now
                ))
            }
        } else if let quotas, let index = accounts.firstIndex(where: { $0.provider == provider && $0.isCurrent }) {
            accounts[index].quotas = quotas
            accounts[index].lastRefreshedAt = now
        }
        sortAccounts()
    }

    private func markSignedOutIfNeeded(provider: CodingProvider, error: Error) {
        guard let quotaError = error as? QuotaError, case .notLoggedIn = quotaError else { return }
        for index in accounts.indices where accounts[index].provider == provider {
            accounts[index].isCurrent = false
        }
        sortAccounts()
    }

    private func sortAccounts() {
        accounts.sort {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.lastRefreshedAt > $1.lastRefreshedAt
        }
    }

    private func capture<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
