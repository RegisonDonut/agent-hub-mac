import Foundation

struct QuotaUsageSample: Codable, Equatable, Identifiable, Sendable {
    let accountID: Int
    let email: String
    let usedPercent: Double
    let resetAt: Date?
    let recordedAt: Date

    var id: String { "\(accountID)-\(recordedAt.timeIntervalSince1970)" }
}

struct QuotaUsageAccount: Equatable, Identifiable, Sendable {
    let id: Int
    let email: String
}

struct QuotaUsageBucket: Equatable, Identifiable, Sendable {
    let start: Date
    let usedPercent: Double

    var id: Date { start }
}

struct QuotaUsageSummary: Equatable, Sendable {
    let usedPercent: Double?
    let coveredDuration: TimeInterval
    let requestedDuration: TimeInterval

    var hasFullCoverage: Bool { coveredDuration >= requestedDuration * 0.98 }
}

struct AggregateQuotaUsageSummary: Equatable, Sendable {
    let usedPercent: Double?
    let coveredDuration: TimeInterval
    let requestedDuration: TimeInterval
    let coveredAccounts: Int
    let totalAccounts: Int

    var hasFullCoverage: Bool {
        coveredAccounts == totalAccounts && totalAccounts > 0 && coveredDuration >= requestedDuration * 0.98
    }
}

enum QuotaUsageGranularity: String, CaseIterable, Identifiable {
    case hourly = "1 小时"
    case fourHourly = "4 小时"
    case daily = "1 天"
    case weekly = "1 周"

    var id: Self { self }

    var component: Calendar.Component {
        switch self {
        case .hourly, .fourHourly: return .hour
        case .daily: return .day
        case .weekly: return .weekOfYear
        }
    }

    var step: Int {
        switch self {
        case .hourly, .daily, .weekly: return 1
        case .fourHourly: return 4
        }
    }

    var visibleDuration: TimeInterval {
        switch self {
        case .hourly: return 24 * 3_600
        case .fourHourly: return 7 * 24 * 3_600
        case .daily: return 30 * 24 * 3_600
        case .weekly: return 8 * 7 * 24 * 3_600
        }
    }

    var rangeLabel: String {
        switch self {
        case .hourly: return "最近 24 小时"
        case .fourHourly: return "最近 7 天"
        case .daily: return "最近 30 天"
        case .weekly: return "最近 8 周"
        }
    }
}

struct QuotaUsageHistoryRepository: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base.appendingPathComponent("AgentHub", isDirectory: true)
                .appendingPathComponent("quota-usage-history.json")
        }
    }

    func load() -> [QuotaUsageSample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([QuotaUsageSample].self, from: data)) ?? []
    }

    func save(_ samples: [QuotaUsageSample]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(samples)
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

@MainActor
final class QuotaUsageStore: ObservableObject {
    @Published private(set) var samples: [QuotaUsageSample]

    private let repository: QuotaUsageHistoryRepository
    private let calendar: Calendar
    private let retentionDuration: TimeInterval = 60 * 24 * 3_600

    init(
        repository: QuotaUsageHistoryRepository = QuotaUsageHistoryRepository(),
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.repository = repository
        self.calendar = calendar
        self.samples = repository.load().sorted { $0.recordedAt < $1.recordedAt }
    }

    var accounts: [QuotaUsageAccount] {
        let latest = samples.reduce(into: [Int: QuotaUsageSample]()) { result, sample in
            if result[sample.accountID]?.recordedAt ?? .distantPast < sample.recordedAt {
                result[sample.accountID] = sample
            }
        }
        return latest.values
            .map { QuotaUsageAccount(id: $0.accountID, email: $0.email) }
            .sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
    }

    func record(_ accounts: [ManagedCodexAccount], now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retentionDuration)
        var changed = false
        samples.removeAll {
            let expired = $0.recordedAt < cutoff
            changed = changed || expired
            return expired
        }

        for account in accounts {
            guard let used = account.weeklyUsedPercent,
                  let recordedAt = account.usageUpdatedAt else { continue }
            let clamped = min(100, max(0, used))
            if let existingIndex = samples.firstIndex(where: {
                $0.accountID == account.id && $0.recordedAt == recordedAt
            }) {
                let replacement = QuotaUsageSample(
                    accountID: account.id,
                    email: account.email,
                    usedPercent: clamped,
                    resetAt: account.weeklyResetAt,
                    recordedAt: recordedAt
                )
                if samples[existingIndex] != replacement {
                    samples[existingIndex] = replacement
                    changed = true
                }
                continue
            }
            samples.append(QuotaUsageSample(
                accountID: account.id,
                email: account.email,
                usedPercent: clamped,
                resetAt: account.weeklyResetAt,
                recordedAt: recordedAt
            ))
            changed = true
        }

        guard changed else { return }
        samples.sort { $0.recordedAt < $1.recordedAt }
        try? repository.save(samples)
    }

    func summary(accountID: Int, duration: TimeInterval, now: Date = Date()) -> QuotaUsageSummary {
        QuotaUsageCalculator.summary(
            samples: samples.filter { $0.accountID == accountID },
            duration: duration,
            now: now
        )
    }

    func aggregateSummary(duration: TimeInterval, now: Date = Date()) -> AggregateQuotaUsageSummary {
        let accountIDs = accounts.map(\.id)
        let summaries = accountIDs.map { summary(accountID: $0, duration: duration, now: now) }
        let covered = summaries.filter { $0.usedPercent != nil }
        return AggregateQuotaUsageSummary(
            usedPercent: covered.isEmpty ? nil : covered.compactMap(\.usedPercent).reduce(0, +),
            coveredDuration: covered.map(\.coveredDuration).min() ?? 0,
            requestedDuration: duration,
            coveredAccounts: covered.count,
            totalAccounts: accountIDs.count
        )
    }

    func buckets(
        accountID: Int,
        granularity: QuotaUsageGranularity,
        now: Date = Date()
    ) -> [QuotaUsageBucket] {
        QuotaUsageCalculator.buckets(
            samples: samples.filter { $0.accountID == accountID },
            granularity: granularity,
            now: now,
            calendar: calendar
        )
    }

    func aggregateBuckets(
        granularity: QuotaUsageGranularity,
        now: Date = Date()
    ) -> [QuotaUsageBucket] {
        var totals: [Date: Double] = [:]
        for account in accounts {
            for bucket in buckets(accountID: account.id, granularity: granularity, now: now) {
                totals[bucket.start, default: 0] += bucket.usedPercent
            }
        }
        return totals.keys.sorted().map {
            QuotaUsageBucket(start: $0, usedPercent: totals[$0, default: 0])
        }
    }
}

enum QuotaUsageCalculator {
    static func summary(
        samples: [QuotaUsageSample],
        duration: TimeInterval,
        now: Date
    ) -> QuotaUsageSummary {
        let ordered = samples.sorted { $0.recordedAt < $1.recordedAt }
        let cutoff = now.addingTimeInterval(-duration)
        let relevant = ordered.filter { $0.recordedAt >= cutoff && $0.recordedAt <= now }
        guard let firstAvailable = relevant.first else {
            return QuotaUsageSummary(usedPercent: nil, coveredDuration: 0, requestedDuration: duration)
        }
        let baseline = ordered.last { $0.recordedAt < cutoff }
        let calculationSamples = (baseline.map { [$0] } ?? []) + relevant
        guard calculationSamples.count >= 2 else {
            return QuotaUsageSummary(
                usedPercent: nil,
                coveredDuration: max(0, now.timeIntervalSince(firstAvailable.recordedAt)),
                requestedDuration: duration
            )
        }
        let firstDate = baseline == nil ? firstAvailable.recordedAt : cutoff
        return QuotaUsageSummary(
            usedPercent: increments(calculationSamples).reduce(0) { $0 + $1.usedPercent },
            coveredDuration: min(duration, max(0, now.timeIntervalSince(firstDate))),
            requestedDuration: duration
        )
    }

    static func buckets(
        samples: [QuotaUsageSample],
        granularity: QuotaUsageGranularity,
        now: Date,
        calendar: Calendar
    ) -> [QuotaUsageBucket] {
        let rangeStart = now.addingTimeInterval(-granularity.visibleDuration)
        let ordered = samples.sorted { $0.recordedAt < $1.recordedAt }
        let baseline = ordered.last { $0.recordedAt < rangeStart }
        let relevant = ordered.filter { $0.recordedAt >= rangeStart && $0.recordedAt <= now }
        let values = increments((baseline.map { [$0] } ?? []) + relevant)

        var totals: [Date: Double] = [:]
        for value in values where value.date >= rangeStart {
            let bucket = bucketStart(for: value.date, granularity: granularity, calendar: calendar)
            totals[bucket, default: 0] += value.usedPercent
        }

        let firstBucket = bucketStart(for: rangeStart, granularity: granularity, calendar: calendar)
        let lastBucket = bucketStart(for: now, granularity: granularity, calendar: calendar)
        var result: [QuotaUsageBucket] = []
        var date = firstBucket
        while date <= lastBucket {
            result.append(QuotaUsageBucket(start: date, usedPercent: totals[date, default: 0]))
            guard let next = calendar.date(
                byAdding: granularity.component,
                value: granularity.step,
                to: date
            ) else { break }
            date = next
        }
        return result
    }

    private struct Increment {
        let date: Date
        let usedPercent: Double
    }

    private static func increments(_ samples: [QuotaUsageSample]) -> [Increment] {
        guard samples.count >= 2 else { return [] }
        return zip(samples, samples.dropFirst()).map { previous, current in
            let delta = current.usedPercent >= previous.usedPercent
                ? current.usedPercent - previous.usedPercent
                : current.usedPercent
            return Increment(date: current.recordedAt, usedPercent: max(0, delta))
        }
    }

    private static func bucketStart(
        for date: Date,
        granularity: QuotaUsageGranularity,
        calendar: Calendar
    ) -> Date {
        if granularity == .daily { return calendar.startOfDay(for: date) }
        if granularity == .weekly {
            let startOfDay = calendar.startOfDay(for: date)
            let weekday = calendar.component(.weekday, from: startOfDay)
            let daysSinceMonday = (weekday + 5) % 7
            return calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay)
                ?? startOfDay
        }
        let startOfDay = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        return calendar.date(byAdding: .hour, value: (hour / granularity.step) * granularity.step, to: startOfDay)
            ?? date
    }
}
