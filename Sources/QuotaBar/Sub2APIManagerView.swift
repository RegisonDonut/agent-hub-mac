import AppKit
import SwiftUI

struct Sub2APIManagerView: View {
    @ObservedObject var service: Sub2APIServiceManager

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
            service.start()
            await service.refreshManagedCodexAccounts()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.title3)
                .foregroundStyle(service.state.isRunning ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex 多账号管理")
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
                Task { await service.refreshManagedCodexAccounts() }
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
            }
            .padding(20)
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
                    ? "新启动的 Codex 会从下面启用的账号中自动选择"
                    : "使用 Codex CLI 当前的官方授权账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .disabled(service.isUpdatingCodexRouting ||
                (!service.codexRoutingEnabled && service.managedCodexAccounts.isEmpty))
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
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(account.isAvailable ? Color.green.opacity(0.18) : Color.secondary.opacity(0.13))
                Image(systemName: "terminal.fill")
                    .foregroundStyle(account.isAvailable ? .green : .secondary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.email)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Circle()
                        .fill(account.isAvailable ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(account.isAvailable ? "可调度" : (account.isEnabled ? "当前不可用" : "已停用"))
                    if let plan = account.planType, !plan.isEmpty {
                        Text("· \(plan)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let used = account.weeklyUsedPercent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("周额度剩余 \(Int(max(0, 100 - used).rounded()))%")
                        .font(.caption.weight(.medium))
                    if let reset = account.weeklyResetAt {
                        Text("\(reset, style: .relative)后重置")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("等待额度数据")
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
