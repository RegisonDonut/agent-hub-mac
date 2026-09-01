import Charts
import SwiftUI

struct WorkDashboardView: View {
    @ObservedObject var store: WorkDurationStore
    @ObservedObject var quotaUsageStore: QuotaUsageStore
    @ObservedObject var service: Sub2APIServiceManager
    @State private var granularity: QuotaUsageGranularity = .hourly

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    metrics
                    quotaUsageChart
                    workloadCalendar

                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .task { store.start() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("数据看板")
                    .font(.headline)
                Text("本机 Codex 会话 · 每分钟自动更新")
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
                Task {
                    await service.refreshManagedCodexAccounts(forceQuotaRefresh: true)
                    quotaUsageStore.record(service.managedCodexAccounts)
                    await store.refresh()
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing || service.isRefreshingManagedAccounts)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var metrics: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            metricCard(
                title: "过去 24 小时工作时长",
                value: WorkDurationFormat.compact(store.snapshot.last24Hours),
                systemImage: "clock"
            )
            metricCard(
                title: "过去 7 天工作时长",
                value: WorkDurationFormat.compact(store.snapshot.last7Days),
                systemImage: "calendar.badge.clock"
            )
            quotaMetricCard(title: "过去 24 小时额度消耗", duration: 24 * 3_600)
            quotaMetricCard(title: "过去 7 天额度消耗", duration: 7 * 24 * 3_600)
        }
    }

    private func metricCard(
        title: String,
        value: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 24, height: 24)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func quotaMetricCard(title: String, duration: TimeInterval) -> some View {
        let summary = quotaUsageStore.aggregateSummary(duration: duration)
        metricCard(
            title: title,
            value: summary.usedPercent.map(QuotaUsageFormat.percent) ?? "—",
            systemImage: "gauge.with.dots.needle.50percent"
        )
    }

    private var quotaUsageChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("额度使用分布")
                    .font(.headline)
                Spacer()
                Picker("时间粒度", selection: $granularity) {
                    ForEach(QuotaUsageGranularity.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 264)
            }

            if !quotaUsageStore.accounts.isEmpty {
                let buckets = quotaUsageStore.aggregateBuckets(granularity: granularity)
                let hasRecordedUsage = buckets.contains { $0.usedPercent > 0 }
                ZStack {
                    Chart(buckets) { bucket in
                        LineMark(
                            x: .value("时间", bucket.start),
                            y: .value("额度消耗", bucket.usedPercent)
                        )
                        .foregroundStyle(Color.green)
                        .interpolationMethod(.monotone)

                        PointMark(
                            x: .value("时间", bucket.start),
                            y: .value("额度消耗", bucket.usedPercent)
                        )
                        .foregroundStyle(Color.green)
                        .symbolSize(bucket.usedPercent > 0 ? 20 : 8)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let percent = value.as(Double.self) {
                                    Text(QuotaUsageFormat.axisPercent(percent))
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 7)) { value in
                            AxisGridLine()
                            AxisValueLabel(format: granularity == .daily || granularity == .weekly
                                ? .dateTime.month().day()
                                : .dateTime.day().hour()
                            )
                        }
                    }
                    .frame(height: 176)

                    if !hasRecordedUsage {
                        Text(quotaUsageStore.aggregateSummary(duration: granularity.visibleDuration).coveredAccounts == 0
                            ? "额度历史正在积累，下一次额度刷新后开始形成曲线"
                            : "所选时间范围内没有检测到额度变化"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                Text(granularity.rangeLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无额度历史")
                        .font(.headline)
                    Text("额度刷新完成后会自动开始记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 176)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var workloadCalendar: some View {
        VStack(alignment: .leading, spacing: 9) {
            if store.isRefreshing && store.snapshot.calendarDays.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在读取会话记录…")
                        .controlSize(.small)
                    Spacer()
                }
                .frame(height: 100)
            } else {
                WorkCalendarView(days: store.snapshot.calendarDays)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WorkCalendarView: View {
    let days: [WorkDay]
    @State private var visibleMonth: Date

    private let calendar = Calendar.autoupdatingCurrent
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                Text("工作量日历")
                    .font(.headline)
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

            LazyVGrid(columns: columns, spacing: 5) {
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
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .background(dayColor(cell), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
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

enum QuotaUsageFormat {
    static func percent(_ value: Double) -> String {
        if value >= 10 || value.rounded() == value { return String(format: "%.0f%%", value) }
        return String(format: "%.1f%%", value)
    }

    static func axisPercent(_ value: Double) -> String {
        value < 1 && value > 0 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }
}
