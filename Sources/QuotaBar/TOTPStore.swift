import Foundation
import AgentHubTOTPKit
import AppKit
import Combine

@MainActor
final class TOTPStore: ObservableObject {
    @Published private(set) var entries: [TOTPEntryMetadata]
    @Published var message: String?
    @Published var errorMessage: String?
    @Published private(set) var revealedCodes: [String: String] = [:]

    private let vault: TOTPVault

    init(vault: TOTPVault = TOTPVault()) {
        self.vault = vault
        self.entries = vault.entries
    }

    @discardableResult
    func add(issuer: String, account: String, secret: String) -> Bool {
        do {
            _ = try vault.add(issuer: issuer, account: account, secret: secret)
            entries = vault.entries
            message = "验证码已安全保存到本机 Keychain"
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            message = nil
            return false
        }
    }

    @discardableResult
    func add(uri: String) -> Bool {
        do {
            _ = try vault.add(otpauthURI: uri)
            entries = vault.entries
            message = "验证码已从 otpauth URI 导入"
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            message = nil
            return false
        }
    }

    func reveal(_ entry: TOTPEntryMetadata) {
        do {
            let code = try vault.code(for: entry.id)
            revealedCodes[entry.id] = code
            message = "已通过系统授权读取验证码"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            message = nil
        }
    }

    func copy(_ entry: TOTPEntryMetadata) {
        reveal(entry)
        guard let code = revealedCodes[entry.id], code.count == entry.digits else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        message = "验证码已复制到剪贴板"
    }

    func delete(_ entry: TOTPEntryMetadata) {
        do {
            try vault.delete(id: entry.id)
            entries = vault.entries
            revealedCodes.removeValue(forKey: entry.id)
            message = "验证码条目已删除"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            message = nil
        }
    }
}
