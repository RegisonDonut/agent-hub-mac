import AppKit
import SwiftUI
import WebKit

struct Sub2APIManagerView: View {
    @ObservedObject var service: Sub2APIServiceManager
    @AppStorage("sub2apiRiskAcknowledged") private var riskAcknowledged = false
    @State private var reloadToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if !riskAcknowledged {
                riskNotice
            } else if service.state.isRunning {
                Sub2APIWebView(
                    service: service,
                    reloadToken: reloadToken
                )
            } else {
                servicePlaceholder
            }
        }
        .frame(minWidth: 920, minHeight: 650)
        .task { service.start() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(service.state.isRunning ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sub2API · Codex 管理器")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(service.state.isRunning ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(service.state.title)
                    Text("· v\(Sub2APIServiceManager.pinnedVersion)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if service.state.isRunning {
                Button {
                    reloadToken = UUID()
                } label: {
                    Label("刷新页面", systemImage: "arrow.clockwise")
                }

            }

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var riskNotice: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("启用本地订阅中转前请确认")
                .font(.title2.bold())
            Text("Sub2API 会在本机 PostgreSQL 中保存 Codex OAuth access token 与 refresh token，并把订阅请求转换成兼容 API。该方式不是 OpenAI 公布的通用订阅 API，可能触发账号限制或封禁。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Label("服务只监听 127.0.0.1:\(Sub2APIServiceManager.hostPort)", systemImage: "lock.fill")
                Label("PostgreSQL 与 Redis 不暴露宿主机端口", systemImage: "externaldrive.fill.badge.checkmark")
                Label("Token 仍由 Sub2API 原样保存在本地数据库中", systemImage: "key.horizontal.fill")
                Label("不要导入不属于你的账号，也不要向他人分发本地 API Key", systemImage: "person.2.slash.fill")
            }
            .font(.callout)

            HStack {
                Button("停止服务") {
                    Task { await service.stopService() }
                }
                Spacer()
                Button("我理解风险，进入本地管理器") {
                    riskAcknowledged = true
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var servicePlaceholder: some View {
        VStack(spacing: 14) {
            if case .starting = service.state {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: "server.rack")
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

private struct Sub2APIWebView: NSViewRepresentable {
    let service: Sub2APIServiceManager
    let reloadToken: UUID

    func makeCoordinator() -> Coordinator { Coordinator(service: service) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: service.baseURL.appendingPathComponent("login")))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.prepareForSessionBootstrap()
            webView.load(URLRequest(url: service.baseURL.appendingPathComponent("login")))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let service: Sub2APIServiceManager
        private var isEstablishingSession = false
        private var hasEstablishedSession = false
        var lastReloadToken = UUID()

        init(service: Sub2APIServiceManager) {
            self.service = service
        }

        func prepareForSessionBootstrap() {
            hasEstablishedSession = false
            isEstablishingSession = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasEstablishedSession, !isEstablishingSession else { return }
            isEstablishingSession = true
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let session = try await service.createAdminWebSession()
                    _ = try await webView.evaluateJavaScript(session.bootstrapJavaScript)
                    hasEstablishedSession = true
                    isEstablishingSession = false
                } catch {
                    isEstablishingSession = false
                    let message = error.localizedDescription
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                    webView.loadHTMLString(
                        "<main style='font:16px -apple-system;padding:40px'><h2>无法进入本地管理器</h2><p>\(message)</p><p>请点击上方刷新按钮重试。</p></main>",
                        baseURL: service.baseURL
                    )
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
            NSWorkspace.shared.open(url)
            return nil
        }
    }
}
