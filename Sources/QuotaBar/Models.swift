import Foundation

struct QuotaWindow: Equatable, Sendable {
    let usedPercent: Double
    let resetsAt: Date?
    let windowName: String

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
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
