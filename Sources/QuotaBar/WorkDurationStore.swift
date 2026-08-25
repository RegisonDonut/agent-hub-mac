import Foundation

struct WorkInterval: Equatable, Sendable {
    let threadID: String
    let start: Date
    let end: Date
}

struct WorkDay: Identifiable, Equatable, Sendable {
    let date: Date
    let duration: TimeInterval
    let isFuture: Bool

    var id: Date { date }
}

struct WorkDashboardSnapshot: Equatable, Sendable {
    var last24Hours: TimeInterval = 0
    var last7Days: TimeInterval = 0
    var calendarDays: [WorkDay] = []
    var updatedAt: Date?
}

enum WorkDurationCalculator {
    static func makeSnapshot(
        intervals: [WorkInterval],
        now: Date = Date(),
        calendar sourceCalendar: Calendar = .autoupdatingCurrent
    ) -> WorkDashboardSnapshot {
        var calendar = sourceCalendar
        calendar.timeZone = sourceCalendar.timeZone
        let merged = mergeWithinThreads(intervals)
        let last24Start = now.addingTimeInterval(-24 * 60 * 60)
        let last7DaysStart = now.addingTimeInterval(-7 * 24 * 60 * 60)

        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let currentWeekStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: today) ?? today
        let calendarStart = calendar.date(byAdding: .weekOfYear, value: -52, to: currentWeekStart) ?? currentWeekStart
        let calendarEnd = calendar.date(byAdding: .day, value: 371, to: calendarStart) ?? now

        var dailyDurations: [Date: TimeInterval] = [:]
        for interval in merged {
            guard interval.end > interval.start else { continue }
            var day = calendar.startOfDay(for: max(interval.start, calendarStart))
            while day < interval.end, day < calendarEnd {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                let seconds = overlap(interval, from: day, to: nextDay)
                if seconds > 0 { dailyDurations[day, default: 0] += seconds }
                day = nextDay
            }
        }

        var days: [WorkDay] = []
        var day = calendarStart
        while day < calendarEnd {
            days.append(WorkDay(
                date: day,
                duration: dailyDurations[day, default: 0],
                isFuture: day > today
            ))
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }

        return WorkDashboardSnapshot(
            last24Hours: merged.reduce(0) { $0 + overlap($1, from: last24Start, to: now) },
            last7Days: merged.reduce(0) { $0 + overlap($1, from: last7DaysStart, to: now) },
            calendarDays: days,
            updatedAt: now
        )
    }

    static func mergeWithinThreads(_ intervals: [WorkInterval]) -> [WorkInterval] {
        let grouped = Dictionary(grouping: intervals, by: \.threadID)
        var merged: [WorkInterval] = []
        for threadIntervals in grouped.values {
            let sorted = threadIntervals
                .filter { $0.end > $0.start }
                .sorted { $0.start < $1.start }
            guard var current = sorted.first else { continue }
            for interval in sorted.dropFirst() {
                if interval.start <= current.end {
                    current = WorkInterval(
                        threadID: current.threadID,
                        start: current.start,
                        end: max(current.end, interval.end)
                    )
                } else {
                    merged.append(current)
                    current = interval
                }
            }
            merged.append(current)
        }
        return merged.sorted { $0.start < $1.start }
    }

    private static func overlap(_ interval: WorkInterval, from start: Date, to end: Date) -> TimeInterval {
        max(0, min(interval.end, end).timeIntervalSince(max(interval.start, start)))
    }
}

@MainActor
final class WorkDurationStore: ObservableObject {
    static let refreshInterval: TimeInterval = 60 * 60

    @Published private(set) var snapshot = WorkDashboardSnapshot()
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let fileManager: FileManager
    private var lifecycleTask: Task<Void, Never>?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func start() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                await refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let intervals = try await loadIntervals()
            snapshot = WorkDurationCalculator.makeSnapshot(intervals: intervals)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadIntervals() async throws -> [WorkInterval] {
        let codexDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let stateDatabase = codexDirectory.appendingPathComponent("state_5.sqlite")
        let historyDatabase = codexDirectory.appendingPathComponent("thread_history_1.sqlite")
        guard fileManager.fileExists(atPath: stateDatabase.path),
              fileManager.fileExists(atPath: historyDatabase.path) else {
            throw QuotaError.processFailed("尚未找到 Codex 本地会话记录")
        }

        let historyURI = "file:\(historyDatabase.path)?mode=ro".replacingOccurrences(of: "'", with: "''")
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("agenthub-work-history-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: outputURL) }
        let query = """
        ATTACH DATABASE '\(historyURI)' AS history;
        SELECT
            tt.thread_id,
            tt.turn_id,
            tt.started_at * 1000 AS started_at_ms,
            CASE
                WHEN tt.completed_at IS NOT NULL THEN
                    COALESCE(tt.started_at * 1000 + tt.duration_ms, tt.completed_at * 1000)
                WHEN t.updated_at_ms >= (unixepoch('now', '-2 minutes') * 1000) THEN
                    unixepoch('now') * 1000
                ELSE MAX(tt.started_at * 1000, t.updated_at_ms)
            END AS ended_at_ms
        FROM history.thread_turns AS tt
        JOIN threads AS t ON t.id = tt.thread_id
        WHERE tt.started_at IS NOT NULL
          AND CASE
                WHEN tt.completed_at IS NOT NULL THEN
                    COALESCE(tt.started_at * 1000 + tt.duration_ms, tt.completed_at * 1000)
                WHEN t.updated_at_ms >= (unixepoch('now', '-2 minutes') * 1000) THEN
                    unixepoch('now') * 1000
                ELSE MAX(tt.started_at * 1000, t.updated_at_ms)
              END >= (unixepoch('now', '-370 days') * 1000)
        ORDER BY tt.thread_id, tt.started_at;
        """
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [
                "-readonly",
                "-json",
                "-cmd", ".timeout 3000",
                "-cmd", ".once \(outputURL.path)",
                stateDatabase.path,
                query
            ],
            timeout: 30
        )
        guard result.exitCode == 0 else {
            let message = String(data: result.stderr, encoding: .utf8) ?? "读取会话记录失败"
            throw QuotaError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let data = try Data(contentsOf: outputURL)
        let rows = try JSONDecoder().decode([WorkIntervalRow].self, from: data)
        return rows.compactMap { row in
            let start = Date(timeIntervalSince1970: Double(row.startedAtMilliseconds) / 1000)
            let end = Date(timeIntervalSince1970: Double(row.endedAtMilliseconds) / 1000)
            guard end > start else { return nil }
            return WorkInterval(threadID: row.threadID, start: start, end: end)
        }
    }
}

private struct WorkIntervalRow: Decodable {
    let threadID: String
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case startedAtMilliseconds = "started_at_ms"
        case endedAtMilliseconds = "ended_at_ms"
    }
}
