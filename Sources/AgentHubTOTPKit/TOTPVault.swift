import CryptoKit
import Foundation
import LocalAuthentication
import Security

public struct TOTPEntryMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var issuer: String
    public var account: String
    public var digits: Int
    public var period: Int
    public var algorithm: String

    public init(
        id: String? = nil,
        issuer: String,
        account: String,
        digits: Int = 6,
        period: Int = 30,
        algorithm: String = "SHA1"
    ) throws {
        let issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !issuer.isEmpty, !account.isEmpty else { throw TOTPError.invalidEntry("发行方和账号不能为空") }
        guard (6...8).contains(digits), period > 0 else { throw TOTPError.invalidEntry("验证码参数无效") }
        guard algorithm.uppercased() == "SHA1" else { throw TOTPError.unsupportedAlgorithm(algorithm) }
        self.id = id ?? Self.makeID(issuer: issuer, account: account)
        self.issuer = issuer
        self.account = account
        self.digits = digits
        self.period = period
        self.algorithm = "SHA1"
    }

    public static func makeID(issuer: String, account: String) -> String {
        let normalize: (String) -> String = { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "[^a-z0-9._@-]+", with: "-", options: .regularExpression)
        }
        return "totp:\(normalize(issuer)):\(normalize(account))"
    }
}

public enum TOTPError: LocalizedError, Equatable {
    case invalidEntry(String)
    case invalidSecret
    case invalidURI(String)
    case duplicateEntry
    case entryNotFound
    case keychain(OSStatus)
    case unsupportedAlgorithm(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEntry(let message): return message
        case .invalidSecret: return "TOTP 密钥不是有效的 Base32 字符串"
        case .invalidURI(let message): return "无法解析 otpauth URI：\(message)"
        case .duplicateEntry: return "该验证码条目已经存在"
        case .entryNotFound: return "找不到该验证码条目"
        case .keychain(let status): return "Keychain 访问失败（错误码 \(status)）；可能需要完成 Touch ID 或输入本机密码"
        case .unsupportedAlgorithm(let algorithm): return "暂不支持 \(algorithm)，目前支持 SHA1"
        case .storage(let message): return "验证码条目存储失败：\(message)"
        }
    }
}

public protocol TOTPSecretStore: AnyObject {
    func save(secret: Data, for id: String) throws
    func readSecret(for id: String, reason: String) throws -> Data
    func deleteSecret(for id: String) throws
}

public protocol UserPresenceAuthorizer: AnyObject {
    func authorize(reason: String) throws
}

public protocol AuthenticationContextProviding: AnyObject {
    var authenticationContext: LAContext? { get }
}

public final class LocalUserPresenceAuthorizer: UserPresenceAuthorizer, AuthenticationContextProviding {
    public private(set) var authenticationContext: LAContext?

    public init() {}

    public func authorize(reason: String) throws {
        let context = LAContext()
        var authorized = false
        var authorizationError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            authorized = success
            authorizationError = error
            semaphore.signal()
        }
        semaphore.wait()
        guard authorized else {
            authenticationContext = nil
            if let laError = authorizationError as? LAError, laError.code == .userCancel {
                throw TOTPError.keychain(errSecUserCanceled)
            }
            throw TOTPError.keychain(errSecAuthFailed)
        }
        authenticationContext = context
    }
}

public final class SessionUserPresenceAuthorizer: UserPresenceAuthorizer, AuthenticationContextProviding {
    private let underlying: UserPresenceAuthorizer
    private var isUnlocked = false

    public var authenticationContext: LAContext? {
        (underlying as? AuthenticationContextProviding)?.authenticationContext
    }

    public init(underlying: UserPresenceAuthorizer = LocalUserPresenceAuthorizer()) {
        self.underlying = underlying
    }

    public func unlock(reason: String) throws {
        try underlying.authorize(reason: reason)
        isUnlocked = true
    }

    public func authorize(reason: String) throws {
        if !isUnlocked {
            try unlock(reason: reason)
        }
    }

    public func lock() {
        isUnlocked = false
    }
}

public final class KeychainTOTPSecretStore: TOTPSecretStore {
    private let service: String
    private let authorizer: UserPresenceAuthorizer

    public init(
        service: String = "com.regisondonut.AgentHub.totp",
        authorizer: UserPresenceAuthorizer = LocalUserPresenceAuthorizer()
    ) {
        self.service = service
        self.authorizer = authorizer
    }

    public func save(secret: Data, for id: String) throws {
        let query = try Self.makeSaveQuery(secret: secret, for: id, service: service)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw TOTPError.keychain(status) }
    }

    static func makeSaveQuery(secret: Data, for id: String, service: String) throws -> [String: Any] {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],
            nil
        ) else { throw TOTPError.keychain(errSecParam) }

        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecValueData as String: secret,
            kSecAttrAccessControl as String: access,
        ]
    }

    public func readSecret(for id: String, reason: String) throws -> Data {
        try authorizer.authorize(reason: reason)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true
        ]
        // Reuse the context that unlocked the page/CLI so legacy userPresence
        // ACLs do not show a second Keychain prompt.
        if let context = (authorizer as? AuthenticationContextProviding)?.authenticationContext {
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw TOTPError.keychain(status) }
        return data
    }

    public func deleteSecret(for id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TOTPError.keychain(status) }
    }
}

public enum TOTPGenerator {
    public static func code(secret: String, at date: Date = Date(), digits: Int = 6, period: Int = 30) throws -> String {
        guard (6...8).contains(digits), period > 0 else { throw TOTPError.invalidEntry("验证码参数无效") }
        let key = try Base32.decode(secret)
        let counter = UInt64(max(0, floor(date.timeIntervalSince1970 / Double(period))))
        var message = counter.bigEndian
        let data = Data(bytes: &message, count: MemoryLayout<UInt64>.size)
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key))
        let bytes = Array(digest)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        let binary = (UInt32(bytes[offset]) & 0x7f) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        let value = binary % UInt32(pow(10.0, Double(digits)))
        return String(format: "%0*d", digits, value)
    }
}

public final class TOTPVault {
    public private(set) var entries: [TOTPEntryMetadata]
    private let secretStore: TOTPSecretStore
    private var cachedSecrets: [String: Data] = [:]
    private let metadataURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        metadataURL: URL? = nil,
        secretStore: TOTPSecretStore = KeychainTOTPSecretStore()
    ) {
        self.secretStore = secretStore
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentHub", isDirectory: true)
        self.metadataURL = metadataURL ?? support.appendingPathComponent("totp-entries.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.entries = (try? Self.loadEntries(from: self.metadataURL, decoder: decoder)) ?? []
    }

    public func add(issuer: String, account: String, secret: String, digits: Int = 6, period: Int = 30) throws -> TOTPEntryMetadata {
        _ = try Base32.decode(secret)
        let entry = try TOTPEntryMetadata(issuer: issuer, account: account, digits: digits, period: period)
        guard !entries.contains(where: { $0.issuer.caseInsensitiveCompare(entry.issuer) == .orderedSame && $0.account.caseInsensitiveCompare(entry.account) == .orderedSame }) else {
            throw TOTPError.duplicateEntry
        }
        try secretStore.save(secret: Data(secret.normalizedBase32.utf8), for: entry.id)
        do {
            entries.append(entry)
            try persist()
        } catch {
            try? secretStore.deleteSecret(for: entry.id)
            entries.removeAll { $0.id == entry.id }
            throw error
        }
        return entry
    }

    public func add(otpauthURI: String) throws -> TOTPEntryMetadata {
        guard let components = URLComponents(string: otpauthURI), components.scheme?.lowercased() == "otpauth", components.host?.lowercased() == "totp" else {
            throw TOTPError.invalidURI("scheme 或类型不正确")
        }
        let label = String(components.path.dropFirst()).removingPercentEncoding ?? ""
        let parts = label.split(separator: ":", maxSplits: 1).map(String.init)
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") })
        guard let secret = query["secret"], !secret.isEmpty else { throw TOTPError.invalidURI("缺少 secret") }
        let issuer = query["issuer"] ?? (parts.count > 1 ? parts[0] : "Authenticator")
        let account = parts.count > 1 ? parts[1] : (parts.first ?? "Agent")
        let digits = Int(query["digits"] ?? "6") ?? 6
        let period = Int(query["period"] ?? "30") ?? 30
        return try add(issuer: issuer, account: account, secret: secret, digits: digits, period: period)
    }

    public func delete(id: String) throws {
        guard entries.contains(where: { $0.id == id }) else { throw TOTPError.entryNotFound }
        try secretStore.deleteSecret(for: id)
        cachedSecrets.removeValue(forKey: id)
        entries.removeAll { $0.id == id }
        try persist()
    }

    public func code(for id: String, at date: Date = Date()) throws -> String {
        guard let entry = entries.first(where: { $0.id == id }) else { throw TOTPError.entryNotFound }
        let data: Data
        if let cached = cachedSecrets[id] {
            data = cached
        } else {
            data = try secretStore.readSecret(for: id, reason: "AgentHub 需要读取 \(entry.issuer) 的验证码")
            cachedSecrets[id] = data
        }
        guard let secret = String(data: data, encoding: .utf8) else { throw TOTPError.invalidSecret }
        return try TOTPGenerator.code(secret: secret, at: date, digits: entry.digits, period: entry.period)
    }

    /// Clear decrypted secrets when the management page is left or locked.
    public func clearCachedSecrets() {
        cachedSecrets.removeAll(keepingCapacity: false)
    }

    public func metadata(for id: String) -> TOTPEntryMetadata? { entries.first { $0.id == id } }

    public func metadata(issuer: String, account: String) -> TOTPEntryMetadata? {
        let id = TOTPEntryMetadata.makeID(issuer: issuer, account: account)
        return metadata(for: id)
    }

    private func persist() throws {
        do {
            try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: metadataURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        } catch { throw TOTPError.storage(error.localizedDescription) }
    }

    private static func loadEntries(from url: URL, decoder: JSONDecoder) throws -> [TOTPEntryMetadata] {
        try decoder.decode([TOTPEntryMetadata].self, from: Data(contentsOf: url))
    }
}

private enum Base32 {
    static func decode(_ input: String) throws -> Data {
        let value = input.normalizedBase32
        guard !value.isEmpty else { throw TOTPError.invalidSecret }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer = 0
        var bits = 0
        var output = Data()
        for character in value {
            guard let index = alphabet.firstIndex(of: character) else { throw TOTPError.invalidSecret }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        guard !output.isEmpty else { throw TOTPError.invalidSecret }
        return output
    }
}

private extension String {
    var normalizedBase32: String {
        replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .uppercased()
    }
}
