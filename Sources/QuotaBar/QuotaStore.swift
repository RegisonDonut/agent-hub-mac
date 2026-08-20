import Foundation

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot = QuotaSnapshot.empty
    @Published private(set) var isRefreshing = false

    private var refreshTask: Task<Void, Never>?
    private let codex = CodexQuotaProvider()
    private let claude = ClaudeQuotaProvider()

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

        async let codexResult: Result<QuotaWindow, Error> = capture { try await self.codex.fetch() }
        async let claudeResult: Result<ClaudeQuotaResult, Error> = capture { try await self.claude.fetch() }
        let (newCodex, newClaude) = await (codexResult, claudeResult)

        var next = snapshot
        switch newCodex {
        case .success(let quota):
            next.codexWeekly = quota
            next.codexError = nil
        case .failure(let error):
            next.codexError = error.localizedDescription
        }
        switch newClaude {
        case .success(let quota):
            next.claudeSession = quota.session
            next.claudeWeekly = quota.weekly
            next.claudeError = nil
        case .failure(let error):
            next.claudeError = error.localizedDescription
        }
        next.refreshedAt = Date()
        snapshot = next
    }

    private func capture<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
