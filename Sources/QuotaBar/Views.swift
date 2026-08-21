import SwiftUI
import ServiceManagement

struct BatteryGauge: View {
    let remaining: Double?
    var compact = false
    var muted = false

    private var color: Color {
        if muted { return .secondary }
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
                    .fill(color.opacity(muted ? 0.45 : 0.62))
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
        .help("Codex 与 Claude Code 额度")
    }
}

private enum PanelTab: String, CaseIterable {
    case status = "当前状态"
    case accounts = "账号看板"
}

private enum ProviderFilter: String, CaseIterable {
    case all = "全部平台"
    case claude = "Claude Code"
    case codex = "Codex"
}

private enum AvailabilityFilter: String, CaseIterable {
    case all = "全部状态"
    case available = "可用账号"
    case unavailable = "无额度"
    case current = "当前登录"
}

struct QuotaPanelView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var sub2API: Sub2APIServiceManager
    @Environment(\.openWindow) private var openWindow
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
                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "sub2api-manager")
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(sub2API.state.isRunning ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("管理后台")
                                .font(.caption.bold())
                            Text(sub2API.state.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .help("打开本地 Sub2API 管理网页")
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
    @State private var providerFilter = ProviderFilter.all
    @State private var availabilityFilter = AvailabilityFilter.all
    @State private var searchText = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            dashboard(now: context.date)
        }
    }

    @ViewBuilder
    private func dashboard(now: Date) -> some View {
        let visibleAccounts = filteredAccounts(now: now)
        let refreshedCount = store.accounts.filter { $0.availability(now: now) == .estimatedRefreshed }.count

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

            if refreshedCount > 0 {
                Label("\(refreshedCount) 个历史账号预计已刷新，可切回确认", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }

            if let message = store.loginStatusMessage {
                Label(message, systemImage: store.loggingInAccountID == nil ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.clock")
                    .font(.caption)
                    .foregroundStyle(store.loggingInAccountID == nil ? .orange : .secondary)
            }

            HStack(spacing: 8) {
                Picker("平台", selection: $providerFilter) {
                    ForEach(ProviderFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 118)

                Picker("状态", selection: $availabilityFilter) {
                    ForEach(AvailabilityFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 112)

                TextField("搜索邮箱", text: $searchText)
                    .textFieldStyle(.roundedBorder)
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
            } else if visibleAccounts.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("没有符合筛选条件的账号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
            } else {
                VStack(spacing: 10) {
                    ForEach(visibleAccounts) { account in
                        AccountCard(
                            account: account,
                            now: now,
                            isLoggingIn: store.loggingInAccountID == account.id,
                            acceptsAuthorizationCode: store.loggingInAccountID == account.id && store.loginAcceptsAuthorizationCode,
                            login: { store.login(to: account) },
                            submitAuthorizationCode: { store.submitClaudeAuthorizationCode($0) },
                            cancelLogin: { store.cancelLogin() },
                            delete: { store.removeAccount(accountID: account.id) }
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func filteredAccounts(now: Date) -> [AccountRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.accounts.filter { account in
            let providerMatches: Bool
            switch providerFilter {
            case .all: providerMatches = true
            case .claude: providerMatches = account.provider == .claudeCode
            case .codex: providerMatches = account.provider == .codex
            }

            let availability = account.availability(now: now)
            let statusMatches: Bool
            switch availabilityFilter {
            case .all: statusMatches = true
            case .available: statusMatches = availability.isAvailable
            case .unavailable: statusMatches = availability.isUnavailable
            case .current: statusMatches = account.isCurrent
            }
            let searchMatches = query.isEmpty || account.email.lowercased().contains(query)
            return providerMatches && statusMatches && searchMatches
        }.sorted { lhs, rhs in
            let left = lhs.availability(now: now)
            let right = rhs.availability(now: now)
            if left.sortPriority != right.sortPriority { return left.sortPriority < right.sortPriority }
            return lhs.lastRefreshedAt > rhs.lastRefreshedAt
        }
    }
}

private struct AccountCard: View {
    let account: AccountRecord
    let now: Date
    let isLoggingIn: Bool
    let acceptsAuthorizationCode: Bool
    let login: () -> Void
    let submitAuthorizationCode: (String) -> Void
    let cancelLogin: () -> Void
    let delete: () -> Void
    @State private var isHovering = false
    @State private var authorizationCode = ""

    private var availability: AccountAvailability { account.availability(now: now) }
    private var canLogin: Bool { !account.isCurrent && !isLoggingIn }

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
                AvailabilityBadge(availability: availability)
                if isLoggingIn {
                    ProgressView().controlSize(.small)
                    Button(action: cancelLogin) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("取消登录授权")
                } else if !account.isCurrent {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                }
            }

            Text(statusDetail)
                .font(.caption.weight(.medium))
                .foregroundStyle(availability.isAvailable ? .green : .secondary)

            if acceptsAuthorizationCode {
                HStack(spacing: 7) {
                    SecureField("粘贴网页显示的一次性登录代码", text: $authorizationCode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submitCode)
                    Button("确认", action: submitCode)
                        .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("代码只会传给本次 Claude CLI 登录，不会保存到 AgentHub。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("记录于 \(account.lastRefreshedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(Array(account.quotas.enumerated()), id: \.offset) { _, quota in
                HistoricalQuotaRow(quota: quota, isCurrent: account.isCurrent, now: now)
            }
        }
        .padding(11)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background(isHovering && canLogin ? Color.accentColor.opacity(0.09) : .primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isHovering && canLogin ? Color.accentColor : .primary.opacity(0.09), lineWidth: isHovering && canLogin ? 1.5 : 1))
        .onTapGesture {
            if canLogin { login() }
        }
        .onHover { inside in
            guard canLogin, inside != isHovering else { return }
            isHovering = inside
            if inside { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .onDisappear {
            if isHovering { NSCursor.pop() }
        }
        .help(account.isCurrent ? "当前登录账号" : "点击后在后台启动官方网页登录")
        .contextMenu {
            if isLoggingIn {
                Button("取消登录授权", action: cancelLogin)
                Divider()
            }
            Button("删除本地账号记录", role: .destructive, action: delete)
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func submitCode() {
        let code = authorizationCode
        authorizationCode = ""
        submitAuthorizationCode(code)
    }

    private var statusDetail: String {
        switch availability {
        case .liveAvailable: return "实时额度可用"
        case .liveExhausted: return "实时额度已用完"
        case .lastKnownAvailable: return "已退出 · 上次记录仍有额度，实际状态需登录确认"
        case .estimatedRefreshed: return "已退出 · 重置时间已到，预计可用，登录后确认"
        case .waitingForReset(let date): return "已退出 · 约 \(duration(until: date)) 后预计可用"
        case .unknown: return "已退出 · 历史数据不足，无法判断当前额度"
        }
    }

    private func duration(until date: Date) -> String {
        let interval = max(0, date.timeIntervalSince(now))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? "很短时间"
    }
}

private struct AvailabilityBadge: View {
    let availability: AccountAvailability

    private var title: String {
        switch availability {
        case .liveAvailable: return "可用"
        case .liveExhausted: return "无额度"
        case .lastKnownAvailable: return "上次可用"
        case .estimatedRefreshed: return "预计已刷新"
        case .waitingForReset: return "等待重置"
        case .unknown: return "状态未知"
        }
    }

    private var color: Color { availability.isAvailable ? .green : .secondary }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption2.bold())
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct HistoricalQuotaRow: View {
    let quota: QuotaWindow
    let isCurrent: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isCurrent ? quota.windowName : "上次记录 · \(quota.windowName)")
                    .font(.caption.weight(.medium))
                Text(resetStatus(now: now))
                    .font(.caption2)
                    .foregroundStyle(resetPassed(now: now) && !isCurrent ? .green : .secondary)
            }
            Spacer()
            BatteryGauge(remaining: quota.remainingPercent, compact: true, muted: !isCurrent)
        }
    }

    private func resetPassed(now: Date) -> Bool {
        quota.resetsAt.map { $0 <= now } ?? false
    }

    private func resetStatus(now: Date) -> String {
        guard let reset = quota.resetsAt else { return "未记录重置时间" }
        if reset <= now {
            return isCurrent ? "重置时间已到，等待刷新确认" : "计划重置时间已到"
        }
        return "预计 \(reset.formatted(date: .abbreviated, time: .shortened)) 重置"
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
