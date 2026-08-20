import SwiftUI

@main
struct AgentHubApp: App {
    @StateObject private var store = QuotaStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPanelView(store: store)
                .task { store.start() }
        } label: {
            StatusLabelView(store: store)
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
