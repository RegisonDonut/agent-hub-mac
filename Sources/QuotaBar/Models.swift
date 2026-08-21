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
    // Kept only so older accounts.json files remain decodable during migration.
    case legacyUnsupported = "claudeCode"
    case codex

    var displayName: String { self == .codex ? "Codex" : "不再支持的旧账号" }
    var companyName: String { self == .codex ? "OpenAI" : "" }
}

enum AccountAvailability: Equatable, Sendable {
    case liveAvailable
    case liveExhausted
    case lastKnownAvailable
    case estimatedRefreshed
    case waitingForReset(Date)
    case unknown

    var isAvailable: Bool {
        switch self {
        case .liveAvailable, .lastKnownAvailable, .estimatedRefreshed: return true
        default: return false
        }
    }

    var isUnavailable: Bool {
        switch self {
        case .liveExhausted, .waitingForReset: return true
        default: return false
        }
    }

    var sortPriority: Int {
        switch self {
        case .liveAvailable, .liveExhausted: return 0
        case .estimatedRefreshed: return 1
        case .lastKnownAvailable: return 2
        case .waitingForReset: return 3
        case .unknown: return 4
        }
    }
}

struct AccountIdentity: Equatable, Sendable {
    let email: String
    let planName: String?
}

struct AccountRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let provider: CodingProvider
    var email: String
    var planName: String?
    var quotas: [QuotaWindow]
    var lastRefreshedAt: Date
    var isCurrent: Bool

    init(
        provider: CodingProvider,
        email: String,
        planName: String? = nil,
        quotas: [QuotaWindow] = [],
        lastRefreshedAt: Date = Date(),
        isCurrent: Bool = true
    ) {
        self.id = Self.makeID(provider: provider, email: email)
        self.provider = provider
        self.email = email
        self.planName = planName
        self.quotas = quotas
        self.lastRefreshedAt = lastRefreshedAt
        self.isCurrent = isCurrent
    }

    static func makeID(provider: CodingProvider, email: String) -> String {
        "\(provider.rawValue):\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func hasPassedQuotaReset(now: Date = Date()) -> Bool {
        quotas.contains { reset in
            guard let date = reset.resetsAt else { return false }
            return date <= now
        }
    }

    func availability(now: Date = Date()) -> AccountAvailability {
        guard !quotas.isEmpty else { return .unknown }
        let exhausted = quotas.filter { $0.remainingPercent <= 0 }

        if isCurrent {
            return exhausted.isEmpty ? .liveAvailable : .liveExhausted
        }
        if exhausted.isEmpty { return .lastKnownAvailable }

        let resetDates = exhausted.compactMap(\.resetsAt)
        guard resetDates.count == exhausted.count, let readyAt = resetDates.max() else { return .unknown }
        return readyAt <= now ? .estimatedRefreshed : .waitingForReset(readyAt)
    }

}

struct QuotaSnapshot: Equatable, Sendable {
    var codexWeekly: QuotaWindow?
    var refreshedAt: Date?
    var codexError: String?

    static let empty = QuotaSnapshot()
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
