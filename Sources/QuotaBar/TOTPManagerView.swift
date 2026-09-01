import AgentHubTOTPKit
import AppKit
import SwiftUI

enum TOTPCountdown {
    static func remainingSeconds(at date: Date, period: Int) -> Int {
        guard period > 0 else { return 0 }
        let elapsed = Int(floor(date.timeIntervalSince1970))
        let remainder = ((elapsed % period) + period) % period
        return period - remainder
    }

    static func progress(at date: Date, period: Int) -> Double {
        guard period > 0 else { return 0 }
        return Double(remainingSeconds(at: date, period: period)) / Double(period)
    }
}

enum TOTPDeleteConfirmation {
    static let phrase = "确认删除"

    static func isValid(input: String) -> Bool {
        input == phrase
    }
}

struct TOTPManagerView: View {
    @ObservedObject var store: TOTPStore
    @State private var issuer = ""
    @State private var account = ""
    @State private var secret = ""
    @State private var uri = ""
    @State private var isAddSectionExpanded = false
    @State private var now = Date()
    @State private var pendingDelete: TOTPEntryMetadata?
    @State private var deleteConfirmation = ""
    @State private var isDeleteConfirmationPresented = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !store.isUnlocked {
                        lockedSection
                    }
                    addSection
                    if let message = store.message {
                        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    entriesSection
                    securityNote
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .onAppear {
            now = Date()
            store.enterPage()
            if store.isUnlocked {
                activateAgentHubWindow()
            }
        }
        .onChange(of: store.isUnlocked) { unlocked in
            if unlocked {
                activateAgentHubWindow()
            }
        }
        .onReceive(ticker) { date in
            now = date
            store.refreshRevealedCodes(at: date)
        }
        .alert("确认删除验证码", isPresented: $isDeleteConfirmationPresented) {
            TextField("请输入“确认删除”", text: $deleteConfirmation)
            Button("取消", role: .cancel) { cancelDelete() }
            Button("确认删除", role: .destructive) { confirmDelete() }
                .disabled(!TOTPDeleteConfirmation.isValid(input: deleteConfirmation))
        } message: {
            let label = [pendingDelete?.issuer ?? "此", pendingDelete?.account ?? "验证码"].joined(separator: " / ")
            Text("删除 \(label) 后不可恢复。请输入“确认删除”继续。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("验证码管理").font(.headline)
                Text(store.isUnlocked ? "本机 Agent 使用的 TOTP 保管库 · 当前页面已授权" : "进入页面需要 Touch ID 或本机密码")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isAddSectionExpanded.toggle()
                }
            } label: {
                Label(isAddSectionExpanded ? "收起添加" : "添加", systemImage: isAddSectionExpanded ? "chevron.up" : "plus")
                    .font(.headline)
            }
            .buttonStyle(.borderless)

            if isAddSectionExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("发行方，例如 AWS", text: $issuer)
                        TextField("账号或用途", text: $account)
                        SecureField("Base32 密钥", text: $secret)
                        Button("保存") {
                            if store.add(issuer: issuer, account: account, secret: secret) {
                                issuer = ""; account = ""; secret = ""
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isAddSectionExpanded = false
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(issuer.trimmingCharacters(in: .whitespaces).isEmpty || account.trimmingCharacters(in: .whitespaces).isEmpty || secret.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    DisclosureGroup("从 otpauth URI 导入") {
                        HStack {
                            TextField("otpauth://totp/...", text: $uri)
                            Button("导入") {
                                if store.add(uri: uri) {
                                    uri = ""
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        isAddSectionExpanded = false
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 5)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(15)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .disabled(!store.isUnlocked)
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已保存条目").font(.headline)
            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "lock.slash").font(.title2).foregroundStyle(.secondary)
                    Text("还没有验证码").font(.body.weight(.medium))
                    Text("添加一个 TOTP 条目后，本地 agent 就可以通过 CLI 请求读取")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(store.entries) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.issuer).font(.body.weight(.medium))
                            Text(entry.account).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let code = store.revealedCodes[entry.id] {
                            Text(code).font(.system(.title3, design: .monospaced)).monospacedDigit()
                        }
                        countdownView(for: entry)
                        Button {
                            store.copy(entry)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制当前验证码")
                        Button(role: .destructive) { beginDelete(entry) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("删除验证码条目")
                    }
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                }
            }
        }
    }

    private var securityNote: some View {
        Label("安全边界：进入页面时需要一次系统授权，停留期间读取和复制复用本次授权；TOTP 密钥仅保存于 macOS Keychain。CLI 的 get 命令独立请求授权，不会输出密钥。", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func beginDelete(_ entry: TOTPEntryMetadata) {
        pendingDelete = entry
        deleteConfirmation = ""
        isDeleteConfirmationPresented = true
    }

    private func cancelDelete() {
        pendingDelete = nil
        deleteConfirmation = ""
    }

    private func confirmDelete() {
        guard let pendingDelete,
              TOTPDeleteConfirmation.isValid(input: deleteConfirmation) else { return }
        store.delete(pendingDelete)
        cancelDelete()
    }

    private var lockedSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("验证码管理已锁定").font(.body.weight(.medium))
            Spacer()
            Button("授权进入") { store.enterPage() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    @MainActor
    private func activateAgentHubWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "AgentHub" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func countdownView(for entry: TOTPEntryMetadata) -> some View {
        let remaining = TOTPCountdown.remainingSeconds(at: now, period: entry.period)
        let progress = TOTPCountdown.progress(at: now, period: entry.period)
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(progress <= 0.2 ? .orange : .blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .frame(width: 34, height: 34)
        .help("每 \(entry.period) 秒自动刷新")
    }
}
