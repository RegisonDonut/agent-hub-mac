import AppKit
import Combine
import SwiftUI

@main
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(AgentHubAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AgentHubAppDelegate: NSObject, NSApplicationDelegate {
    private let store = QuotaStore()
    private let sub2API = Sub2APIServiceManager()
    private let workDurationStore = WorkDurationStore()
    private var statusItem: NSStatusItem?
    private var managerWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        ExecutableLocator.installBundledCodexCommandIfNeeded()
        installStatusItem()
        observeStatusData()
        store.start()
        sub2API.start()
        workDurationStore.start()
        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<90 where !sub2API.state.isRunning {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await sub2API.refreshManagedCodexAccounts(forceQuotaRefresh: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openCodexManager()
        return true
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(openCodexManager)
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageOnly
        statusItem = item
        updateStatusItem()
    }

    private func observeStatusData() {
        store.$snapshot
            .combineLatest(
                sub2API.$managedCodexAccounts,
                sub2API.$codexRoutingEnabled,
                sub2API.$quotaRefreshErrors
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        let remaining: Double?
        if sub2API.codexRoutingEnabled {
            remaining = ManagedCodexAccount.poolTotalRemainingPercent(sub2API.managedCodexAccounts)
        } else {
            remaining = store.snapshot.codexWeekly?.remainingPercent
        }
        statusItem?.button?.image = StatusBarImage.make(codexRemaining: remaining)
        statusItem?.button?.toolTip = sub2API.codexRoutingEnabled
            ? "Codex 多账号池总剩余额度 · 点击打开管理"
            : "Codex 官方登录 · 点击打开管理"
    }

    @objc private func openCodexManager() {
        let window: NSWindow
        if let existing = managerWindow {
            window = existing
        } else {
            let content = AgentHubRootView(
                service: sub2API,
                quotaStore: store,
                workStore: workDurationStore
            )
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "AgentHub"
            created.contentView = NSHostingView(rootView: content)
            created.isReleasedWhenClosed = false
            created.setFrameAutosaveName("AgentHubCodexManager")
            created.center()
            managerWindow = created
            window = created
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
