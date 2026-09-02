import SwiftUI

private enum AgentHubPage: String, CaseIterable, Identifiable {
    case quota = "额度管理"
    case dashboard = "数据看板"
    case observations = "任务观测"
    case totp = "验证码管理"

    var id: Self { self }
}

struct AgentHubRootView: View {
    @ObservedObject var service: Sub2APIServiceManager
    @ObservedObject var quotaStore: QuotaStore
    @ObservedObject var workStore: WorkDurationStore
    @ObservedObject var quotaUsageStore: QuotaUsageStore
    @ObservedObject var observationStore: TaskObservationStore
    @ObservedObject var totpStore: TOTPStore
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
                .frame(width: 390)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch page {
            case .quota:
                Sub2APIManagerView(service: service, store: quotaStore)
            case .dashboard:
                WorkDashboardView(
                    store: workStore,
                    quotaUsageStore: quotaUsageStore,
                    service: service
                )
            case .observations:
                TaskObservationView(store: observationStore)
            case .totp:
                TOTPManagerView(store: totpStore)
            }
        }
        .frame(minWidth: 820, minHeight: 680)
    }
}
