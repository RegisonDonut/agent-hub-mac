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
            claudeRemaining: store.snapshot.claudeSessionForDisplay?.remainingPercent,
            subscriptionWarning: store.accounts.map { $0.subscriptionWarning() }.max() ?? .none
        ))
        .renderingMode(.original)
        .help("Codex 与 Claude Code 额度、订阅到期提醒")
    }
}

private enum PanelTab: String, CaseIterable {
    case status = "当前状态"
    case accounts = "账号看板"
}

struct QuotaPanelView: View {
    @ObservedObject var store: QuotaStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var selectedTab = PanelTab.status

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
                if store.accounts.contains(where: { $0.subscriptionWarning() != .none }) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(store.accounts.contains(where: { $0.subscriptionWarning() == .urgent }) ? .red : .orange)
                        .help("有账号订阅即将到期")
                }
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
            Picker("视图", selection: $selectedTab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if selectedTab == .status {
                currentStatusContent
            } else {
                AccountDashboardView(store: store)
            }
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
        .frame(width: 430)
    }

    @ViewBuilder
    private var currentStatusContent: some View {
        providerSection(
            title: "Claude Code",
            account: store.accounts.first { $0.provider == .claudeCode && $0.isCurrent },
            rows: [store.snapshot.claudeSessionForDisplay, store.snapshot.claudeWeekly].compactMap { $0 },
            error: store.snapshot.claudeError
        )
        Divider()
        providerSection(
            title: "Codex",
            account: store.accounts.first { $0.provider == .codex && $0.isCurrent },
            rows: [store.snapshot.codexWeekly].compactMap { $0 },
            error: store.snapshot.codexError
        )
    }

    @ViewBuilder
    private func providerSection(title: String, account: AccountRecord?, rows: [QuotaWindow], error: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(nsImage: title == "Claude Code" ? BrandAssets.claude(size: 18) : BrandAssets.openAI(size: 18))
                    .renderingMode(.original)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline)
                    Text(title == "Claude Code" ? "Anthropic" : "OpenAI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let account {
                        Text(account.email)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
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

private struct AccountDashboardView: View {
    @ObservedObject var store: QuotaStore
    @State private var editingAccount: AccountRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地账号记录").font(.headline)
                    Text("退出或切换后仍保留额度与重置时间")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("仅存本机")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if store.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("暂无账号记录").font(.headline)
                    Text("登录 Claude Code 或 Codex 后点刷新，账号会自动加入看板。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.accounts) { account in
                            AccountCard(account: account) {
                                editingAccount = account
                            }
                        }
                    }
                }
                .frame(maxHeight: 390)
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountEditorView(store: store, account: account)
        }
    }
}

private struct AccountCard: View {
    let account: AccountRecord
    let edit: () -> Void

    private var warningColor: Color {
        switch account.subscriptionWarning() {
        case .urgent: return .red
        case .soon: return .orange
        case .none: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(nsImage: account.provider == .claudeCode ? BrandAssets.claude(size: 20) : BrandAssets.openAI(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.provider.displayName).font(.subheadline.bold())
                        if account.isCurrent {
                            Text("当前登录")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.16), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text(account.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let plan = account.planName, !plan.isEmpty {
                        Text(plan).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Circle()
                    .fill(warningColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: warningColor.opacity(0.65), radius: account.subscriptionWarning() == .none ? 0 : 4)
                    .help(subscriptionText)
                Button(action: edit) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("设置订阅到期日或删除记录")
            }

            HStack {
                Label(subscriptionText, systemImage: "calendar.badge.clock")
                    .foregroundStyle(account.subscriptionWarning() == .urgent ? .red : account.subscriptionWarning() == .soon ? .orange : .secondary)
                Spacer()
                Text("记录于 \(account.lastRefreshedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)

            ForEach(Array(account.quotas.enumerated()), id: \.offset) { _, quota in
                HistoricalQuotaRow(quota: quota, isCurrent: account.isCurrent)
            }
        }
        .padding(11)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.09)))
    }

    private var subscriptionText: String {
        guard let date = account.subscriptionExpiresAt,
              let days = account.subscriptionDaysRemaining() else {
            return "订阅到期日未提供，可手动设置"
        }
        if days < 0 { return "订阅已过期 \(-days) 天（\(date.formatted(date: .abbreviated, time: .omitted))）" }
        if days == 0 { return "订阅今天到期" }
        return "订阅剩余 \(days) 天（\(date.formatted(date: .abbreviated, time: .omitted))）"
    }
}

private struct HistoricalQuotaRow: View {
    let quota: QuotaWindow
    let isCurrent: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quota.windowName).font(.caption.weight(.medium))
                    Text(resetStatus(now: context.date))
                        .font(.caption2)
                        .foregroundStyle(resetPassed(now: context.date) ? .green : .secondary)
                }
                Spacer()
                BatteryGauge(remaining: quota.remainingPercent, compact: true)
            }
        }
    }

    private func resetPassed(now: Date) -> Bool {
        quota.resetsAt.map { $0 <= now } ?? false
    }

    private func resetStatus(now: Date) -> String {
        guard let reset = quota.resetsAt else { return "未记录重置时间" }
        if reset <= now {
            return isCurrent ? "重置时间已到，等待刷新确认" : "额度应已刷新，可切回此账号确认"
        }
        return "预计 \(reset.formatted(date: .abbreviated, time: .shortened)) 重置"
    }
}

private struct AccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: QuotaStore
    let account: AccountRecord
    @State private var hasExpiration: Bool
    @State private var expirationDate: Date

    init(store: QuotaStore, account: AccountRecord) {
        self.store = store
        self.account = account
        _hasExpiration = State(initialValue: account.subscriptionExpiresAt != nil)
        _expirationDate = State(initialValue: account.subscriptionExpiresAt ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("管理账号").font(.title3.bold())
            Text(account.email).font(.subheadline).textSelection(.enabled)
            Text("官方本地接口目前不提供订阅账单到期日。这里保存的是你在本机设置的日期，不会上传。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("记录订阅到期日", isOn: $hasExpiration)
            if hasExpiration {
                DatePicker("到期日", selection: $expirationDate, displayedComponents: .date)
            }

            HStack {
                Button("删除历史记录", role: .destructive) {
                    store.removeAccount(accountID: account.id)
                    dismiss()
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    store.setSubscriptionExpiration(accountID: account.id, date: hasExpiration ? expirationDate : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
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
