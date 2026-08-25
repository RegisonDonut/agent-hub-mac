import SwiftUI

private enum AgentHubPage: String, CaseIterable, Identifiable {
    case quota = "额度管理"
    case dashboard = "数据看板"

    var id: Self { self }
}

struct AgentHubRootView: View {
    @ObservedObject var service: Sub2APIServiceManager
    @ObservedObject var quotaStore: QuotaStore
    @ObservedObject var workStore: WorkDurationStore
    @State private var page: AgentHubPage = .quota

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("页面", selection: $page) {
                    ForEach(AgentHubPage.allCases) { page in
                        Text(page.rawValue).tag(page)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch page {
            case .quota:
                Sub2APIManagerView(service: service, store: quotaStore)
            case .dashboard:
                WorkDashboardView(store: workStore)
            }
        }
        .frame(minWidth: 820, minHeight: 680)
    }
}
