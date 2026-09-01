import Foundation
import AgentHubTOTPKit
import AppKit
import Combine

@MainActor
final class TOTPStore: ObservableObject {
    @Published private(set) var entries: [TOTPEntryMetadata]
    @Published private(set) var isUnlocked = false
    @Published var message: String?
    @Published var errorMessage: String?
    @Published private(set) var revealedCodes: [String: String] = [:]

    private let vault: TOTPVault
    private let pageAuthorizer: SessionUserPresenceAuthorizer

    init(vault: TOTPVault? = nil, pageAuthorizer: SessionUserPresenceAuthorizer = SessionUserPresenceAuthorizer()) {
        self.pageAuthorizer = pageAuthorizer
        self.vault = vault ?? TOTPVault(secretStore: KeychainTOTPSecretStore(authorizer: pageAuthorizer))
        self.entries = self.vault.entries
    }

    func enterPage() {
        guard !isUnlocked else { return }
        do {
            try pageAuthorizer.unlock(reason: "AgentHub 需要打开验证码管理")
            isUnlocked = true
            refreshRevealedCodes(includeMissing: true)
            message = "已通过系统授权打开验证码管理"
            errorMessage = nil
        } catch {
            isUnlocked = false
            errorMessage = error.localizedDescription
            message = nil
        }
    }

    func leavePage() {
        pageAuthorizer.lock()
        vault.clearCachedSecrets()
        isUnlocked = false
        revealedCodes.removeAll()
    }

    @discardableResult
    func add(issuer: String, account: String, secret: String) -> Bool {
        guard isUnlocked else { errorMessage = "请先通过系统授权打开验证码管理"; return false }
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
        guard isUnlocked else { errorMessage = "请先通过系统授权打开验证码管理"; return false }
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
        guard isUnlocked else { errorMessage = "请先通过系统授权打开验证码管理"; return }
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

    func refreshRevealedCodes(at date: Date = Date(), includeMissing: Bool = false) {
        guard isUnlocked else { return }
        for entry in entries {
            // A failed initial read must not retry every second and spam
            // Keychain authorization dialogs. Explicit copy/reveal retries.
            guard includeMissing || revealedCodes[entry.id] != nil else { continue }
            do {
                revealedCodes[entry.id] = try vault.code(for: entry.id, at: date)
            } catch {
                revealedCodes.removeValue(forKey: entry.id)
            }
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
        guard isUnlocked else { errorMessage = "请先通过系统授权打开验证码管理"; return }
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
