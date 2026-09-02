import Foundation

struct ObservedTask: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var lastActiveAt: Date?
    var totalQuotaPercent: Double
    var totalWorkDuration: TimeInterval
    var sessionCount: Int
    var daily: [TaskDailySummary]

    var isActive: Bool {
        guard let lastActiveAt else { return false }
        return lastActiveAt >= Date().addingTimeInterval(-30 * 60)
    }
}

struct TaskDailySummary: Identifiable, Equatable, Sendable {
    let date: Date
    var quotaPercent: Double
    var workDuration: TimeInterval
    var sessionCount: Int
    var triggerCount: Int

    var id: Date { date }
}

struct TaskObservationEvent: Decodable, Sendable {
    let type: String
    let taskID: String
    let taskName: String?
    let sessionID: String?
    let timestamp: Date
    let quotaPercent: Double?
    let workSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case type
        case taskID = "task_id"
        case taskName = "task_name"
        case sessionID = "session_id"
        case timestamp
        case quotaPercent = "quota_percent"
        case workSeconds = "work_seconds"
    }
}

@MainActor
final class TaskObservationStore: ObservableObject {
    static let refreshInterval: TimeInterval = 60

    @Published private(set) var tasks: [ObservedTask] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let fileManager: FileManager
    private let eventsURL: URL?
    private var lifecycleTask: Task<Void, Never>?

    init(fileManager: FileManager = .default, eventsURL: URL? = nil) {
        self.fileManager = fileManager
        self.eventsURL = eventsURL
    }

    deinit { lifecycleTask?.cancel() }

    func start() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await refresh()
            }
            lifecycleTask = nil
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            tasks = try await loadTasks()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadTasks() async throws -> [ObservedTask] {
        let url = eventsURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentHub/task-observations/tasks.jsonl")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [TaskObservationEvent] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let event = try? decoder.decode(TaskObservationEvent.self, from: Data(line)),
               !event.taskID.isEmpty {
                events.append(event)
            }
        }
        return Self.summarize(events: events, now: Date())
    }

    nonisolated static func summarize(events: [TaskObservationEvent], now: Date) -> [ObservedTask] {
        var grouped: [String: [TaskObservationEvent]] = [:]
        for event in events { grouped[event.taskID, default: []].append(event) }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -13, to: today) ?? today

        return grouped.compactMap { id, taskEvents in
            guard let latest = taskEvents.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            let name = taskEvents.reversed().compactMap(\.taskName).first ?? id
            var daily: [Date: TaskDailySummary] = [:]
            var sessionIDs = Set<String>()
            var quota = 0.0
            var work = 0.0
            var triggers = 0
            for event in taskEvents where event.timestamp >= earliest {
                let date = calendar.startOfDay(for: event.timestamp)
                var summary = daily[date] ?? TaskDailySummary(date: date, quotaPercent: 0, workDuration: 0, sessionCount: 0, triggerCount: 0)
                summary.quotaPercent += max(0, event.quotaPercent ?? 0)
                summary.workDuration += max(0, event.workSeconds ?? 0)
                if event.type == "session_start" || event.type == "register" { triggers += 1; summary.triggerCount += 1 }
                if let sessionID = event.sessionID, !sessionIDs.contains(sessionID), event.type == "session_start" {
                    sessionIDs.insert(sessionID)
                    summary.sessionCount += 1
                }
                daily[date] = summary
                quota += max(0, event.quotaPercent ?? 0)
                work += max(0, event.workSeconds ?? 0)
            }
            let sortedDaily = (0..<14).compactMap { offset -> TaskDailySummary? in
                guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
                return daily[date] ?? TaskDailySummary(date: date, quotaPercent: 0, workDuration: 0, sessionCount: 0, triggerCount: 0)
            }
            return ObservedTask(id: id, name: name, lastActiveAt: latest.timestamp, totalQuotaPercent: quota, totalWorkDuration: work, sessionCount: sessionIDs.count, daily: sortedDaily)
        }
        .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }
}
