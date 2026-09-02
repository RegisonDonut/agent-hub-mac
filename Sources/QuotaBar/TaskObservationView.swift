import SwiftUI

struct TaskObservationView: View {
    @ObservedObject var store: TaskObservationStore
    @State private var expandedTaskIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("任务观测")
                        .font(.headline)
                    Text("持续任务与需求任务的本机运行状态")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(store.isRefreshing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    if store.tasks.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.tasks) { task in
                            taskRow(task)
                        }
                    }
                    skillCard
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .task { store.start() }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            observationMetric("已注册任务", value: "\(store.tasks.count)", icon: "list.bullet.rectangle")
            observationMetric("近 24 小时活跃", value: "\(store.tasks.filter { ($0.lastActiveAt ?? .distantPast) >= Date().addingTimeInterval(-24 * 3600) }.count)", icon: "bolt.fill")
            observationMetric("近 14 天 Sessions", value: "\(store.tasks.reduce(0) { $0 + $1.sessionCount })", icon: "bubble.left.and.bubble.right")
        }
    }

    private func observationMetric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func taskRow(_ task: ObservedTask) -> some View {
        let expanded = expandedTaskIDs.contains(task.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded { expandedTaskIDs.remove(task.id) } else { expandedTaskIDs.insert(task.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.bold)).frame(width: 12)
                    Circle().fill(task.isActive ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.name).font(.subheadline.weight(.semibold))
                        Text(task.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    taskStat("最近活跃", task.lastActiveAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    taskStat("14 天额度", quotaPercent(task.totalQuotaPercent))
                    taskStat("Sessions", "\(task.sessionCount)")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(11)
            if expanded {
                Divider().padding(.leading, 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text("最近 14 天").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(task.daily) { day in
                        HStack(spacing: 8) {
                            Text(day.date.formatted(.dateTime.month().day())).frame(width: 48, alignment: .leading)
                            ProgressView(value: min(1, day.quotaPercent / 100))
                                .tint(day.quotaPercent > 0 ? .green : .secondary)
                                .frame(maxWidth: .infinity)
                            Text(quotaPercent(day.quotaPercent)).frame(width: 58, alignment: .trailing)
                            Text(WorkDurationFormat.compact(day.workDuration)).frame(width: 70, alignment: .trailing)
                            Text("\(day.sessionCount) 次").frame(width: 46, alignment: .trailing)
                        }
                        .font(.caption2.monospacedDigit())
                    }
                }
                .padding(.horizontal, 42)
                .padding(.vertical, 9)
                .background(.black.opacity(0.03))
            }
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func taskStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
        .frame(minWidth: 75, alignment: .trailing)
    }

    private func quotaPercent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "eye.slash").font(.title2).foregroundStyle(.secondary)
            Text("暂无已注册任务").font(.headline)
            Text("复制下方 Skill，并在任务开始时注册即可在这里观测")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
    }

    private var skillCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AgentHub 任务观测 Skill", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.skillText, forType: .string)
                } label: { Label("复制 Skill", systemImage: "doc.on.clipboard") }
            }
            Text("将这段 Markdown 放入本地 Codex Skill 后，任务即可通过 agenthub-task 注册和上报状态。")
                .font(.caption).foregroundStyle(.secondary)
            Text(Self.skillText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(12)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private static let skillText = """
# AgentHub 任务观测规范

较长的任务必须注册；较短的任务（例如修复 Bug）无需注册；需求开发类任务应尽量注册；定时任务必须注册。用户也可以明确要求某个定时任务注册。

注册任务：`agenthub-task register <任务ID> \"<任务名称>\"`
开始一个 Codex Session：`agenthub-task session-start <任务ID> [SessionID]`
任务运行中每隔一段时间发送：`agenthub-task heartbeat <任务ID> [SessionID] --quota-percent 1.2 --work-seconds 60`
结束 Session：`agenthub-task session-end <任务ID> [SessionID] --work-seconds 120`

任务 ID 应稳定且可复用；一个任务 ID 可以对应多个 Codex Session。AgentHub 会按任务聚合最近活跃时间、每日额度消耗比例、每日工作时间和触发/新增 Session 数，并可展开查看近 14 天明细。
"""
}
