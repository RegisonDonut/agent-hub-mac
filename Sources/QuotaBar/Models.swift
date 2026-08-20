import Foundation

struct QuotaWindow: Codable, Equatable, Sendable {
    let usedPercent: Double
    let resetsAt: Date?
    let windowName: String

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

enum CodingProvider: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case codex

    var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    var companyName: String { self == .claudeCode ? "Anthropic" : "OpenAI" }
}

enum SubscriptionWarning: Int, Comparable, Sendable {
    case none = 0
    case soon = 1
    case urgent = 2

    static func < (lhs: SubscriptionWarning, rhs: SubscriptionWarning) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct AccountIdentity: Equatable, Sendable {
    let email: String
    let planName: String?
    let subscriptionExpiresAt: Date?

    init(email: String, planName: String?, subscriptionExpiresAt: Date? = nil) {
        self.email = email
        self.planName = planName
        self.subscriptionExpiresAt = subscriptionExpiresAt
    }
}

struct AccountRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let provider: CodingProvider
    var email: String
    var planName: String?
    var subscriptionExpiresAt: Date?
    var quotas: [QuotaWindow]
    var lastRefreshedAt: Date
    var isCurrent: Bool

    init(
        provider: CodingProvider,
        email: String,
        planName: String? = nil,
        subscriptionExpiresAt: Date? = nil,
        quotas: [QuotaWindow] = [],
        lastRefreshedAt: Date = Date(),
        isCurrent: Bool = true
    ) {
        self.id = Self.makeID(provider: provider, email: email)
        self.provider = provider
        self.email = email
        self.planName = planName
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.quotas = quotas
        self.lastRefreshedAt = lastRefreshedAt
        self.isCurrent = isCurrent
    }

    static func makeID(provider: CodingProvider, email: String) -> String {
        "\(provider.rawValue):\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func subscriptionDaysRemaining(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let subscriptionExpiresAt else { return nil }
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: subscriptionExpiresAt)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    func hasPassedQuotaReset(now: Date = Date()) -> Bool {
        quotas.contains { reset in
            guard let date = reset.resetsAt else { return false }
            return date <= now
        }
    }

    func subscriptionWarning(now: Date = Date()) -> SubscriptionWarning {
        guard let days = subscriptionDaysRemaining(now: now) else { return .none }
        if days <= 3 { return .urgent }
        if days <= 7 { return .soon }
        return .none
    }
}

struct QuotaSnapshot: Equatable, Sendable {
    var codexWeekly: QuotaWindow?
    var claudeSession: QuotaWindow?
    var claudeWeekly: QuotaWindow?
    var refreshedAt: Date?
    var codexError: String?
    var claudeError: String?

    static let empty = QuotaSnapshot()

    var claudeSessionForDisplay: QuotaWindow? {
        guard let session = claudeSession else { return nil }
        guard let weekly = claudeWeekly, weekly.remainingPercent <= 0 else { return session }
        return QuotaWindow(usedPercent: 100, resetsAt: weekly.resetsAt, windowName: session.windowName)
    }
}

enum QuotaError: LocalizedError {
    case executableMissing(String)
    case processFailed(String)
    case malformedResponse(String)
    case notLoggedIn(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let name): return "未找到 \(name)"
        case .processFailed(let message): return message
        case .malformedResponse(let source): return "无法解析 \(source) 的额度数据"
        case .notLoggedIn(let source): return "\(source) 尚未登录"
        case .network(let message): return message
        }
    }
}
