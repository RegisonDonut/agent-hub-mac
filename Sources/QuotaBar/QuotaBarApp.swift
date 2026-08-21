import SwiftUI

@main
struct AgentHubApp: App {
    @StateObject private var store = QuotaStore()
    @StateObject private var sub2API = Sub2APIServiceManager()

    var body: some Scene {
        MenuBarExtra {
            QuotaPanelView(store: store, sub2API: sub2API)
                .task {
                    store.start()
                    sub2API.start()
                }
        } label: {
            StatusLabelView(store: store)
                .task {
                    store.start()
                    sub2API.start()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Sub2API · Codex 管理器", id: "sub2api-manager") {
            Sub2APIManagerView(service: sub2API)
        }
        .defaultSize(width: 1_080, height: 760)
    }
}
