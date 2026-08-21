import AppKit
import Foundation
import Security

struct Sub2APIWebSession {
    let accessToken: String
    let refreshToken: String
    let expiresAtMilliseconds: Int64
    let userJSON: String

    var bootstrapJavaScript: String {
        """
        (() => {
          localStorage.setItem('auth_token', \(Self.javaScriptLiteral(accessToken)));
          localStorage.setItem('refresh_token', \(Self.javaScriptLiteral(refreshToken)));
          localStorage.setItem('token_expires_at', '\(expiresAtMilliseconds)');
          localStorage.setItem('auth_user', \(Self.javaScriptLiteral(userJSON)));
          window.location.replace('/admin/accounts');
        })();
        """
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "''"
        }
        return encoded
    }
}

enum Sub2APIServiceState: Equatable {
    case stopped
    case starting(String)
    case running
    case failed(String)
    case dockerUnavailable(String)

    var title: String {
        switch self {
        case .stopped: return "已停止"
        case .starting(let message): return message
        case .running: return "运行中"
        case .failed: return "启动失败"
        case .dockerUnavailable: return "Docker 不可用"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var detail: String? {
        switch self {
        case .failed(let message), .dockerUnavailable(let message): return message
        default: return nil
        }
    }
}

@MainActor
final class Sub2APIServiceManager: ObservableObject {
    static let pinnedVersion = "0.1.179"
    static let hostPort = 18_080

    @Published private(set) var state: Sub2APIServiceState = .stopped
    @Published private(set) var adminEmail = "admin@agenthub.local"
    @Published private(set) var adminPassword = ""
    @Published private(set) var lastCheckedAt: Date?

    let baseURL = URL(string: "http://127.0.0.1:\(hostPort)")!

    private var lifecycleTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private let fileManager = FileManager.default

    private var supportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentHub/Sub2API", isDirectory: true)
    }

    private var composeURL: URL { supportDirectory.appendingPathComponent("docker-compose.yml") }
    private var environmentURL: URL { supportDirectory.appendingPathComponent(".env") }

    func start() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await startService()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                await refreshState()
            }
        }
    }

    func startService() async {
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            await self?.performStart()
        }
        await operationTask?.value
        operationTask = nil
    }

    func restartService() async {
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            state = .starting("正在重启 Sub2API…")
            do {
                try ensureConfiguration()
                _ = try await runDocker(composeArguments(["up", "-d", "--remove-orphans", "--force-recreate"]), timeout: 600)
                try await enforceLoopbackBinding()
                try await waitUntilHealthy(timeout: 180)
                state = .running
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        await operationTask?.value
        operationTask = nil
    }

    func stopService() async {
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            state = .starting("正在停止 Sub2API…")
            do {
                try ensureConfiguration()
                _ = try await runDocker(composeArguments(["stop"]), timeout: 90)
                state = .stopped
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        await operationTask?.value
        operationTask = nil
    }

    func refreshState() async {
        if await isHealthy() {
            do {
                try await enforceLoopbackBinding()
                state = .running
            } catch {
                state = .failed(error.localizedDescription)
            }
        } else if state.isRunning {
            state = .stopped
        }
        lastCheckedAt = Date()
    }

    func createAdminWebSession() async throws -> Sub2APIWebSession {
        guard !adminEmail.isEmpty, !adminPassword.isEmpty else {
            throw QuotaError.processFailed("本地管理员凭据尚未准备完成")
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": adminEmail,
            "password": adminPassword
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["code"] as? Int) == 0,
              let payload = envelope["data"] as? [String: Any],
              let accessToken = payload["access_token"] as? String,
              let refreshToken = payload["refresh_token"] as? String,
              let user = payload["user"] as? [String: Any] else {
            throw QuotaError.processFailed("无法建立本地 Sub2API 管理会话")
        }

        let expiresIn = (payload["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        let expiresAt = Int64((Date().timeIntervalSince1970 + expiresIn) * 1_000)
        let userData = try JSONSerialization.data(withJSONObject: user)
        guard let userJSON = String(data: userData, encoding: .utf8) else {
            throw QuotaError.processFailed("无法读取本地管理员资料")
        }
        return Sub2APIWebSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMilliseconds: expiresAt,
            userJSON: userJSON
        )
    }

    func revealDataDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([supportDirectory])
    }

    private func performStart() async {
        state = .starting("正在准备本地服务…")
        do {
            try ensureConfiguration()
            if await isHealthy() {
                try await enforceLoopbackBinding()
                state = .running
                return
            }

            guard let docker = ExecutableLocator.find("docker") else {
                state = .dockerUnavailable("未找到 Docker。请先安装并启动 Docker Desktop。")
                return
            }
            guard await ensureDockerReady(docker) else {
                state = .dockerUnavailable("Docker Desktop 无法启动，请打开 Docker Desktop 后重试。")
                return
            }

            state = .starting("首次运行可能需要下载本地服务镜像…")
            _ = try await runDocker(composeArguments(["up", "-d", "--remove-orphans"]), timeout: 900)
            try await enforceLoopbackBinding()
            state = .starting("正在等待数据库迁移和服务就绪…")
            try await waitUntilHealthy(timeout: 180)
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func ensureConfiguration() throws {
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if !fileManager.fileExists(atPath: environmentURL.path) {
            let password = try secureRandomString(byteCount: 24)
            let postgresPassword = try secureRandomString(byteCount: 32)
            let redisPassword = try secureRandomString(byteCount: 32)
            let jwtSecret = try secureRandomHex(byteCount: 32)
            let totpKey = try secureRandomHex(byteCount: 32)
            let contents = """
            SUB2API_VERSION=\(Self.pinnedVersion)
            SERVER_PORT=\(Self.hostPort)
            RUN_MODE=simple
            SIMPLE_MODE_CONFIRM=true
            POSTGRES_USER=sub2api
            POSTGRES_PASSWORD=\(postgresPassword)
            POSTGRES_DB=sub2api
            REDIS_PASSWORD=\(redisPassword)
            ADMIN_EMAIL=\(adminEmail)
            ADMIN_PASSWORD=\(password)
            JWT_SECRET=\(jwtSecret)
            TOTP_ENCRYPTION_KEY=\(totpKey)
            TZ=Asia/Shanghai
            """
            try contents.write(to: environmentURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environmentURL.path)
        } else {
            try updateEnvironmentValue("SUB2API_VERSION", value: Self.pinnedVersion)
        }

        if !fileManager.fileExists(atPath: composeURL.path) ||
            (try? String(contentsOf: composeURL)).map({ $0 != Self.composeFile }) == true {
            try Self.composeFile.write(to: composeURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: composeURL.path)
        }
        loadCredentials()
    }

    private func updateEnvironmentValue(_ key: String, value: String) throws {
        var contents = try String(contentsOf: environmentURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = lines.firstIndex(where: { $0.hasPrefix("\(key)=") }) {
            lines[index] = "\(key)=\(value)"
        } else {
            lines.append("\(key)=\(value)")
        }
        contents = lines.joined(separator: "\n")
        try contents.write(to: environmentURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environmentURL.path)
    }

    private func loadCredentials() {
        guard let contents = try? String(contentsOf: environmentURL, encoding: .utf8) else { return }
        var values: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        adminEmail = values["ADMIN_EMAIL"] ?? adminEmail
        adminPassword = values["ADMIN_PASSWORD"] ?? ""
    }

    private func composeArguments(_ arguments: [String]) -> [String] {
        [
            "compose", "--project-name", "agenthub-sub2api",
            "--env-file", environmentURL.path,
            "--file", composeURL.path
        ] + arguments
    }

    private func runDocker(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        guard let docker = ExecutableLocator.find("docker") else {
            throw QuotaError.processFailed("未找到 Docker")
        }
        let result = try await ProcessRunner.run(executable: docker, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let message = [stderr, stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Docker 命令失败"
            throw QuotaError.processFailed(String(message.suffix(1_200)))
        }
        return result
    }

    private func ensureDockerReady(_ docker: URL) async -> Bool {
        if await dockerIsReady(docker) { return true }

        let dockerApplications = [
            URL(fileURLWithPath: "/Applications/Docker.app"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Docker.app")
        ]
        guard let dockerApp = dockerApplications.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return false
        }

        state = .starting("正在启动 Docker Desktop…")
        _ = try? await NSWorkspace.shared.openApplication(at: dockerApp, configuration: .init())
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await dockerIsReady(docker) { return true }
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
        }
        return false
    }

    private func dockerIsReady(_ docker: URL) async -> Bool {
        guard let result = try? await ProcessRunner.run(
            executable: docker,
            arguments: ["info", "--format", "{{.ServerVersion}}"],
            timeout: 15
        ) else { return false }
        return result.exitCode == 0
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func waitUntilHealthy(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if await isHealthy() { return }
            try await Task.sleep(nanoseconds: 2 * 1_000_000_000)
        }
        throw QuotaError.processFailed("Sub2API 在 \(Int(timeout)) 秒内未能启动，请查看服务日志")
    }

    private func enforceLoopbackBinding() async throws {
        let result = try await runDocker([
            "inspect", "--format", "{{json .HostConfig.PortBindings}}", "agenthub-sub2api"
        ], timeout: 15)
        guard Self.portBindingsAreLoopbackOnly(result.stdout) else {
            _ = try? await runDocker(["stop", "agenthub-sub2api"], timeout: 30)
            throw QuotaError.processFailed("安全拦截：检测到 Sub2API 端口并非仅绑定本机，服务已自动停止")
        }
    }

    static func portBindingsAreLoopbackOnly(_ data: Data) -> Bool {
        struct Binding: Decodable {
            let hostIP: String
            let hostPort: String

            enum CodingKeys: String, CodingKey {
                case hostIP = "HostIp"
                case hostPort = "HostPort"
            }
        }

        guard let bindings = try? JSONDecoder().decode([String: [Binding]].self, from: data),
              bindings.count == 1,
              let httpBindings = bindings["8080/tcp"],
              httpBindings.count == 1,
              let binding = httpBindings.first else {
            return false
        }
        return (binding.hostIP == "127.0.0.1" || binding.hostIP == "::1") &&
            binding.hostPort == String(hostPort)
    }

    private func secureRandomHex(byteCount: Int) throws -> String {
        try secureRandomData(byteCount: byteCount).map { String(format: "%02x", $0) }.joined()
    }

    private func secureRandomString(byteCount: Int) throws -> String {
        try secureRandomData(byteCount: byteCount)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func secureRandomData(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw QuotaError.processFailed("无法生成本地服务密钥")
        }
        return Data(bytes)
    }

    static let composeFile = """
    services:
      sub2api:
        image: weishaw/sub2api:${SUB2API_VERSION}
        container_name: agenthub-sub2api
        restart: unless-stopped
        security_opt:
          - no-new-privileges:true
        ports:
          - "127.0.0.1:${SERVER_PORT}:8080"
        volumes:
          - sub2api_data:/app/data
        environment:
          AUTO_SETUP: "true"
          SERVER_HOST: "0.0.0.0"
          SERVER_PORT: "8080"
          SERVER_MODE: "release"
          RUN_MODE: "${RUN_MODE}"
          SIMPLE_MODE_CONFIRM: "${SIMPLE_MODE_CONFIRM}"
          DATABASE_HOST: "postgres"
          DATABASE_PORT: "5432"
          DATABASE_USER: "${POSTGRES_USER}"
          DATABASE_PASSWORD: "${POSTGRES_PASSWORD}"
          DATABASE_DBNAME: "${POSTGRES_DB}"
          DATABASE_SSLMODE: "disable"
          REDIS_HOST: "redis"
          REDIS_PORT: "6379"
          REDIS_PASSWORD: "${REDIS_PASSWORD}"
          REDIS_DB: "0"
          ADMIN_EMAIL: "${ADMIN_EMAIL}"
          ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
          JWT_SECRET: "${JWT_SECRET}"
          JWT_EXPIRE_HOUR: "24"
          TOTP_ENCRYPTION_KEY: "${TOTP_ENCRYPTION_KEY}"
          TZ: "${TZ}"
        depends_on:
          postgres:
            condition: service_healthy
          redis:
            condition: service_healthy
        networks:
          - internal
        healthcheck:
          test: ["CMD", "wget", "-q", "-T", "5", "-O", "/dev/null", "http://localhost:8080/health"]
          interval: 10s
          timeout: 5s
          retries: 12
          start_period: 30s

      postgres:
        image: postgres:18-alpine
        container_name: agenthub-sub2api-postgres
        restart: unless-stopped
        environment:
          PGDATA: "/var/lib/postgresql/data"
          POSTGRES_USER: "${POSTGRES_USER}"
          POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
          POSTGRES_DB: "${POSTGRES_DB}"
          TZ: "${TZ}"
        volumes:
          - postgres_data:/var/lib/postgresql/data
        networks:
          - internal
        healthcheck:
          test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
          interval: 5s
          timeout: 5s
          retries: 12

      redis:
        image: redis:8-alpine
        container_name: agenthub-sub2api-redis
        restart: unless-stopped
        command: ["redis-server", "--save", "60", "1", "--appendonly", "yes", "--appendfsync", "everysec", "--requirepass", "${REDIS_PASSWORD}"]
        environment:
          REDISCLI_AUTH: "${REDIS_PASSWORD}"
          TZ: "${TZ}"
        volumes:
          - redis_data:/data
        networks:
          - internal
        healthcheck:
          test: ["CMD", "redis-cli", "ping"]
          interval: 5s
          timeout: 5s
          retries: 12

    volumes:
      sub2api_data:
      postgres_data:
      redis_data:

    networks:
      internal:
        driver: bridge
    """
}
