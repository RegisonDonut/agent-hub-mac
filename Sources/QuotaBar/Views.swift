import SwiftUI
import ServiceManagement

struct BatteryGauge: View {
    let remaining: Double?
    var compact = false

    private var color: Color {
        guard let remaining else { return .secondary }
        if remaining < 20 { return .red }
        if remaining < 50 { return .orange }
        return .green
    }

    private var text: String {
        guard let remaining else { return "--" }
        return "\(Int(remaining.rounded()))%"
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: compact ? 2.5 : 4)
                .strokeBorder(.primary.opacity(0.65), lineWidth: 1)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: compact ? 1.5 : 3)
                    .fill(color)
                    .frame(width: max(0, (geometry.size.width - 4) * ((remaining ?? 0) / 100)))
                    .padding(2)
            }
            Text(text)
                .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .foregroundStyle(.primary)
        }
        .frame(width: compact ? 38 : 65, height: compact ? 13 : 21)
        .accessibilityLabel("剩余额度 \(text)")
    }
}

struct StatusLabelView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        Image(nsImage: StatusBarImage.make(
            codexRemaining: store.snapshot.codexWeekly?.remainingPercent,
            claudeRemaining: store.snapshot.claudeSessionForDisplay?.remainingPercent
        ))
        .renderingMode(.original)
        .help("CX：Codex 周额度 · CC：Claude Code 日/会话额度")
    }
}

struct QuotaPanelView: View {
    @ObservedObject var store: QuotaStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AgentHub").font(.title2.bold())
                    Text("Local coding agent control center")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(refreshText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("立即刷新")
            }

            Divider()
            providerSection(
                title: "Claude Code",
                rows: [store.snapshot.claudeSessionForDisplay, store.snapshot.claudeWeekly].compactMap { $0 },
                error: store.snapshot.claudeError
            )
            Divider()
            providerSection(
                title: "Codex",
                rows: [store.snapshot.codexWeekly].compactMap { $0 },
                error: store.snapshot.codexError
            )
            Divider()

            Toggle("登录时启动", isOn: Binding(
                get: { launchAtLogin },
                set: setLaunchAtLogin
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack {
                Text("每 5 分钟自动刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    private func providerSection(title: String, rows: [QuotaWindow], error: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(nsImage: title == "Claude Code" ? BrandAssets.claude(size: 18) : BrandAssets.openAI(size: 18))
                    .renderingMode(.original)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline)
                    Text(title == "Claude Code" ? "Anthropic" : "OpenAI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, quota in
                QuotaRow(quota: quota)
            }
            if rows.isEmpty && error == nil {
                HStack { ProgressView().controlSize(.small); Text("正在读取…") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var refreshText: String {
        if store.isRefreshing { return "正在刷新…" }
        guard let date = store.snapshot.refreshedAt else { return "等待首次刷新" }
        return "更新于 \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct QuotaRow: View {
    let quota: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quota.windowName).font(.subheadline.weight(.medium))
                    Text("已用 \(Int(quota.usedPercent.rounded()))% · 剩余 \(Int(quota.remainingPercent.rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                BatteryGauge(remaining: quota.remainingPercent)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(resetText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetText(now: Date) -> String {
        guard let reset = quota.resetsAt else { return "当前无明确重置时间" }
        let interval = reset.timeIntervalSince(now)
        if interval <= 0 { return "即将重置" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        let duration = formatter.string(from: interval) ?? "很快"
        return "约 \(duration) 后重置（\(reset.formatted(date: .abbreviated, time: .shortened))）"
    }
}
