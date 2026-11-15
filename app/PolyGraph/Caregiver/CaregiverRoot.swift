import SwiftUI

enum CaregiverTab: Hashable {
    case meds, alerts, graph, week, feed
}

/// Modul aparținător: cinci tab-uri, fiecare cu stiva lui și titlu mare.
/// Butoanele din tab bar se găsesc în testele UI după etichetă („Medicamente”, „Alerte”, „Graf”, „Săptămâna”,
/// „Noutăți”).
struct CaregiverRoot: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: CaregiverTab = .meds
    @State private var graphPath: [CaregiverRoute] = []
    /// sursa tranziției zoom card → detaliu din tab-ul Alerte
    @Namespace private var alertsZoom

    var body: some View {
        TabView(selection: $tab) {
            Tab("Medicamente", systemImage: "pills", value: CaregiverTab.meds) {
                NavigationStack {
                    MedsListView(showAlerts: { tab = .alerts })
                        .caregiverDestinations()
                }
                .accessibilityIdentifier("tab.meds")
            }
            Tab("Alerte", systemImage: "exclamationmark.triangle", value: CaregiverTab.alerts) {
                NavigationStack {
                    AlertsView(zoom: alertsZoom)
                        .caregiverDestinations(zoom: alertsZoom)
                }
                .accessibilityIdentifier("tab.alerts")
            }
            Tab("Graf", systemImage: "point.3.connected.trianglepath.dotted", value: CaregiverTab.graph) {
                NavigationStack(path: $graphPath) {
                    GraphView(open: { graphPath.append($0) })
                        .caregiverDestinations()
                }
                .accessibilityIdentifier("tab.graph")
            }
            Tab("Săptămâna", systemImage: "calendar", value: CaregiverTab.week) {
                NavigationStack {
                    WeekView(audience: .caregiver)
                        .pgSettingsToolbar()
                }
                .accessibilityIdentifier("tab.week")
            }
            Tab("Noutăți", systemImage: "bell", value: CaregiverTab.feed) {
                NavigationStack {
                    FeedView()
                        .caregiverDestinations()
                }
                .accessibilityIdentifier("tab.feed")
            }
            .badge(store.feed.pendingNew.count)
        }
        // haptic pe același trigger cu inserarea cardului grav
        .sensoryFeedback(.warning, trigger: store.feed.alarmCount)
        // polling-ul merge pe orice tab, cât timp aplicația e deschisă (fără APNs)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await FeedAlerts.requestPermissionIfNeeded()
            while !Task.isCancelled {
                await store.feed.poll()
                try? await Task.sleep(for: FeedModel.interval)
            }
        }
    }
}
