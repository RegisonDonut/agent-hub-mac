import SwiftUI

struct WorkDashboardView: View {
    @ObservedObject var store: WorkDurationStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    metrics
                    workloadCalendar

                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }

                    Text("工作时长按 Codex 每轮任务的开始与结束时间计算；同一会话内的重叠区间只计一次，并发会话分别累加。跨日任务按本机时区拆分到对应日期。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .task { store.start() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("数据看板")
                    .font(.headline)
                Text("本机 Codex 会话 · 每小时自动更新")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let updatedAt = store.snapshot.updatedAt {
                Text("更新于 \(updatedAt, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metricCard(
                title: "最近 24 小时",
                duration: store.snapshot.last24Hours,
                systemImage: "clock"
            )
            metricCard(
                title: "最近 7 天",
                duration: store.snapshot.last7Days,
                systemImage: "calendar.badge.clock"
            )
        }
    }

    private func metricCard(title: String, duration: TimeInterval, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 38, height: 38)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(WorkDurationFormat.compact(duration))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var workloadCalendar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.isRefreshing && store.snapshot.calendarDays.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在读取会话记录…")
                        .controlSize(.small)
                    Spacer()
                }
                .frame(height: 130)
            } else {
                WorkCalendarView(days: store.snapshot.calendarDays)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WorkCalendarView: View {
    let days: [WorkDay]
    @State private var visibleMonth: Date

    private let calendar = Calendar.autoupdatingCurrent
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 7)

    init(days: [WorkDay]) {
        self.days = days
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? calendar.startOfDay(for: now)
        _visibleMonth = State(initialValue: currentMonth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("工作量日历")
                        .font(.title3.bold())
                    Text("最近一个月 · 悬停日期查看当天有效工作时长")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { moveMonth(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveToPreviousMonth)

                Text(visibleMonth.formatted(.dateTime.year().month(.wide)))
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 100)

                Button { moveMonth(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveToNextMonth)
            }

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(Array(calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthCells) { cell in
                    dayCell(cell)
                }
            }
        }
    }

    private var monthCells: [MonthWorkCell] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let gridStart = calendar.date(byAdding: .day, value: -(firstWeekday - 1), to: monthInterval.start)
            ?? monthInterval.start
        let finalDay = calendar.date(byAdding: .day, value: -1, to: monthInterval.end) ?? monthInterval.end
        let finalWeekday = calendar.component(.weekday, from: finalDay)
        let trailingDays = 7 - finalWeekday
        let gridEnd = calendar.date(byAdding: .day, value: trailingDays + 1, to: finalDay) ?? monthInterval.end
        let durations = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0.duration) })
        let today = calendar.startOfDay(for: Date())

        var cells: [MonthWorkCell] = []
        var date = gridStart
        while date < gridEnd {
            cells.append(MonthWorkCell(
                date: date,
                duration: durations[calendar.startOfDay(for: date), default: 0],
                isInVisibleMonth: calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month),
                isToday: calendar.isDate(date, inSameDayAs: today),
                isFuture: date > today
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return cells
    }

    private func dayCell(_ cell: MonthWorkCell) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(calendar.component(.day, from: cell.date))")
                    .font(.caption.weight(cell.isToday ? .bold : .regular))
                Spacer()
                if cell.isToday {
                    Text("今天")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
            if cell.duration > 0, cell.isInVisibleMonth {
                Text(WorkDurationFormat.short(cell.duration))
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(cell.duration >= 4 * 3_600 ? .white : .primary)
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(dayColor(cell), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(cell.isToday ? Color.green.opacity(0.85) : Color.secondary.opacity(0.10))
        }
        .opacity(cell.isInVisibleMonth ? 1 : 0.38)
        .help("\(cell.date.formatted(date: .long, time: .omitted))：\(WorkDurationFormat.compact(cell.duration))")
    }

    private func dayColor(_ cell: MonthWorkCell) -> Color {
        guard !cell.isFuture, cell.isInVisibleMonth else { return Color.secondary.opacity(0.06) }
        switch cell.duration {
        case ...0: return Color.secondary.opacity(0.10)
        case ..<3_600: return Color.green.opacity(0.24)
        case ..<(4 * 3_600): return Color.green.opacity(0.45)
        case ..<(8 * 3_600): return Color.green.opacity(0.68)
        default: return Color.green.opacity(0.92)
        }
    }

    private var canMoveToPreviousMonth: Bool {
        guard let firstDate = days.first?.date else { return false }
        return visibleMonth > monthStart(firstDate)
    }

    private var canMoveToNextMonth: Bool {
        visibleMonth < monthStart(Date())
    }

    private func moveMonth(by value: Int) {
        guard let next = calendar.date(byAdding: .month, value: value, to: visibleMonth) else { return }
        visibleMonth = monthStart(next)
    }

    private func monthStart(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            ?? calendar.startOfDay(for: date)
    }
}

private struct MonthWorkCell: Identifiable {
    let date: Date
    let duration: TimeInterval
    let isInVisibleMonth: Bool
    let isToday: Bool
    let isFuture: Bool

    var id: Date { date }
}

enum WorkDurationFormat {
    static func compact(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时" }
        return "\(minutes) 分钟"
    }

    static func short(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes > 0 ? "\(hours)时\(minutes)分" : "\(hours)小时" }
        return "\(minutes)分钟"
    }
}
