import AgentHubTOTPKit
import SwiftUI

struct TOTPManagerView: View {
    @ObservedObject var store: TOTPStore
    @State private var issuer = ""
    @State private var account = ""
    @State private var secret = ""
    @State private var uri = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("验证码管理").font(.headline)
                Text("本机 Agent 使用的 TOTP 保管库 · 每次读取都需要 Touch ID 或本机密码")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("添加验证码", systemImage: "plus.circle").font(.headline)
            HStack(spacing: 10) {
                TextField("发行方，例如 AWS", text: $issuer)
                TextField("账号或用途", text: $account)
                SecureField("Base32 密钥", text: $secret)
                Button("保存") {
                    if store.add(issuer: issuer, account: account, secret: secret) {
                        issuer = ""; account = ""; secret = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(issuer.trimmingCharacters(in: .whitespaces).isEmpty || account.trimmingCharacters(in: .whitespaces).isEmpty || secret.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            DisclosureGroup("从 otpauth URI 导入") {
                HStack {
                    TextField("otpauth://totp/...", text: $uri)
                    Button("导入") { if store.add(uri: uri) { uri = "" } }
                        .buttonStyle(.bordered)
                        .disabled(uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 5)
            }
            .font(.caption)
        }
        .padding(15)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
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
                        Button {
                            store.reveal(entry)
                        } label: {
                            Label("读取", systemImage: "touchid")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            store.copy(entry)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("通过 Touch ID 后复制当前验证码")
                        Button(role: .destructive) { store.delete(entry) } label: { Image(systemName: "trash") }
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
        Label("安全边界：条目列表只保存发行方和账号；TOTP 密钥仅保存于 macOS Keychain。CLI 的 get 命令不会输出密钥，后台任务在没有可交互 Touch ID 会话时会安全失败。", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
