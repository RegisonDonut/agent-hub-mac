import AppKit
import ServiceManagement
import SwiftUI

struct Sub2APIManagerView: View {
    @ObservedObject var service: Sub2APIServiceManager
    @ObservedObject var store: QuotaStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if service.state.isRunning {
                managerContent
            } else {
                servicePlaceholder
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .task {
            store.start()
            service.start()
            await store.refresh()
            await service.refreshManagedCodexAccounts(forceQuotaRefresh: true)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.title3)
                .foregroundStyle(service.state.isRunning ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex 管理中心")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(service.state.isRunning ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(service.state.isRunning ? "本地服务运行中" : service.state.title)
                    Text("· 仅限本机访问")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    async let officialRefresh: Void = store.refresh()
                    async let poolRefresh: Void = service.refreshManagedCodexAccounts(forceQuotaRefresh: true)
                    _ = await (officialRefresh, poolRefresh)
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(service.isRefreshingManagedAccounts)

            Menu {
                Button("显示本地数据目录") { service.revealDataDirectory() }
                Divider()
                Button("重启本地服务") {
                    Task { await service.restartService() }
                }
                Button("停止本地服务") {
                    Task { await service.stopService() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var managerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                routingSection
                officialCodexSection

                if service.oauthLoginFlow != nil {
                    oauthFlowSection
                } else {
                    accountHeader
                }

                if service.managedCodexAccounts.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(service.managedCodexAccounts) { account in
                            managedAccountCard(account)
                        }
                    }
                }

                if let message = service.managedAccountsMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("多账号模式的授权凭据和连接 Key 只保存在这台 Mac 的本地容器与 AgentHub 数据目录中。Codex 官方登录凭据不会被删除，关闭多账号模式即可切回。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                appControls
            }
            .padding(20)
        }
    }

    private var officialCodexSection: some View {
        let account = store.accounts.first { $0.provider == .codex && $0.isCurrent }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: BrandAssets.openAI(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 官方登录")
                        .font(.headline)
                    Text(account?.email ?? "尚未识别当前官方账号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Text(service.codexRoutingEnabled ? "备用线路" : "当前线路")
                    .font(.caption2.bold())
                    .foregroundStyle(service.codexRoutingEnabled ? Color.secondary : Color.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((service.codexRoutingEnabled ? Color.secondary : Color.blue).opacity(0.12), in: Capsule())
                Button(account == nil ? "登录" : "检查授权") {
                    Task {
                        await service.signInToOfficialCodex()
                        await store.refresh()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.isUpdatingCodexRouting)
            }

            if let quota = store.snapshot.codexWeekly {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("官方账号周额度")
                            .font(.caption.weight(.medium))
                        Text(officialResetText(quota))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    BatteryGauge(remaining: quota.remainingPercent)
                }
            } else if let error = store.snapshot.codexError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在读取官方账号状态…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var appControls: some View {
        HStack(spacing: 14) {
            Toggle("登录时启动", isOn: Binding(
                get: { launchAtLogin },
                set: setLaunchAtLogin
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("官方与多账号额度每 5 分钟自动刷新")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出 AgentHub") { NSApplication.shared.terminate(nil) }
        }
        .padding(.top, 2)
    }

    private func officialResetText(_ quota: QuotaWindow) -> String {
        guard let reset = quota.resetsAt else { return "剩余 \(Int(quota.remainingPercent.rounded()))% · 暂无重置时间" }
        let interval = max(0, reset.timeIntervalSinceNow)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        let duration = formatter.string(from: interval) ?? "很快"
        return "剩余 \(Int(quota.remainingPercent.rounded()))% · \(duration) 后重置"
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

    private var routingSection: some View {
        HStack(spacing: 14) {
            Image(systemName: service.codexRoutingEnabled ? "point.3.connected.trianglepath.dotted" : "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(service.codexRoutingEnabled ? .green : .blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(service.codexRoutingEnabled ? "当前线路：Codex 多账号" : "当前线路：Codex 官方登录")
                    .font(.headline)
                Text(service.codexRoutingEnabled
                    ? "新线程自动选可用账号；可重建的续聊会在额度耗尽后迁移"
                    : "使用 Codex CLI 当前的官方授权账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service.codexRoutingEnabled {
                    Text("切换线路前已打开的线程仍使用原线路；进行中的工具调用链无法跨账号迁移。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if service.isUpdatingCodexRouting {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: Binding(
                get: { service.codexRoutingEnabled },
                set: { enabled in
                    Task { await service.setCodexRoutingEnabled(enabled) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(service.isUpdatingCodexRouting)
        }
        .padding(15)
        .background(.quaternary.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(service.codexRoutingEnabled ? Color.green.opacity(0.35) : Color.secondary.opacity(0.18))
        }
    }

    private var accountHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 账号池")
                    .font(.title3.bold())
                Text("已添加 \(service.managedCodexAccounts.count) 个账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await service.beginCodexAccountLogin() }
            } label: {
                if service.isStartingOAuthLogin {
                    ProgressView().controlSize(.small)
                } else {
                    Label("添加账号", systemImage: "plus")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(service.isStartingOAuthLogin)
        }
    }

    private var oauthFlowSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("添加 Codex 账号", systemImage: "person.badge.plus")
                    .font(.title3.bold())
                Spacer()
                Button("取消") { service.cancelCodexAccountLogin() }
                    .disabled(service.isCompletingOAuthLogin)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("第一步：打开官方登录页并完成授权", systemImage: "1.circle.fill")
                    .font(.callout.weight(.semibold))
                if let url = service.oauthLoginFlow?.authorizationURL {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                HStack {
                    Button {
                        service.copyCodexAuthorizationURL()
                    } label: {
                        Label("复制登录链接", systemImage: "doc.on.doc")
                    }
                    Button {
                        service.openCodexAuthorizationURL()
                    } label: {
                        Label("打开浏览器", systemImage: "safari")
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("第二步：粘贴浏览器地址栏中的最终回调链接", systemImage: "2.circle.fill")
                    .font(.callout.weight(.semibold))
                Text("登录成功后浏览器可能停在无法打开的 localhost 页面，这是正常现象。复制地址栏中的完整链接并粘贴到这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $service.oauthCallbackInput)
                    .font(.caption.monospaced())
                    .frame(minHeight: 72)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.secondary.opacity(0.25))
                    }
                HStack {
                    if let message = service.oauthLoginMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        Task { await service.completeCodexAccountLogin() }
                    } label: {
                        if service.isCompletingOAuthLogin {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("完成添加")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isCompletingOAuthLogin ||
                        service.oauthCallbackInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.28))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("还没有 Codex 多账号")
                .font(.headline)
            Text("添加第一个账号后，AgentHub 会自动准备本机连接并启用多账号模式。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if service.oauthLoginFlow == nil {
                Button("添加 Codex 账号") {
                    Task { await service.beginCodexAccountLogin() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func managedAccountCard(_ account: ManagedCodexAccount) -> some View {
        let status = accountStatus(account)
        return HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(status.color.opacity(0.18))
                Image(systemName: "terminal.fill")
                    .foregroundStyle(status.color)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.email)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                    Text(status.title)
                    if let plan = account.planType, !plan.isEmpty {
                        Text("· \(plan)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if service.isRefreshingQuota(for: account.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在验证额度")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let error = service.quotaRefreshErrors[account.id] {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("额度获取失败")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(error)
                }
                .frame(maxWidth: 220, alignment: .trailing)
            } else if let used = account.weeklyUsedPercent {
                VStack(alignment: .trailing, spacing: 4) {
                    BatteryGauge(remaining: max(0, 100 - used))
                    if let reset = account.weeklyResetAt {
                        Text("\(reset, style: .relative)后重置")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("额度尚未验证")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("", isOn: Binding(
                get: { account.isEnabled },
                set: { enabled in
                    Task { await service.setManagedCodexAccountEnabled(account, enabled: enabled) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(13)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func accountStatus(_ account: ManagedCodexAccount) -> (title: String, color: Color) {
        if !account.isEnabled { return ("已停用", .secondary) }
        if service.isRefreshingQuota(for: account.id) {
            if account.hasVerifiedQuota {
                return account.isQuotaExhausted
                    ? ("正在更新 · 上次已用完", .red)
                    : ("正在更新 · 上次可用", .green)
            }
            return ("额度验证中", .orange)
        }
        if service.quotaRefreshErrors[account.id] != nil { return ("额度未知", .orange) }
        if !account.hasVerifiedQuota { return ("额度未验证", .secondary) }
        if account.isQuotaExhausted { return ("额度已用完", .red) }
        if !account.schedulable { return ("当前不可调度", .secondary) }
        return ("可调度", .green)
    }

    private var servicePlaceholder: some View {
        VStack(spacing: 14) {
            if case .starting = service.state {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
            }
            Text(service.state.title)
                .font(.title3.bold())
            if let detail = service.state.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            Button("启动本地服务") {
                Task { await service.startService() }
            }
            .buttonStyle(.borderedProminent)
            if case .dockerUnavailable = service.state {
                Button("下载 Docker Desktop") {
                    NSWorkspace.shared.open(URL(string: "https://www.docker.com/products/docker-desktop/")!)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
