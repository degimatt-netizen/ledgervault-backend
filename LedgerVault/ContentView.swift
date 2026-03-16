import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "arrow.left.arrow.right") }

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
        }
    }
}

// ── More tab ──────────────────────────────────────────────────────────────────
struct MoreView: View {
    @State private var showAnalysis = false
    @State private var showAlerts   = false
    @State private var showMarket   = false
    @State private var showSettings = false
    @State private var showProfile  = false

    // Badge: count of active (non-triggered) alerts
    @StateObject private var alertsManager = AlertsManager.shared
    private var alertBadge: Int {
        alertsManager.alerts.filter { $0.isActive && !$0.triggered }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Insights") {
                    moreRow("Market Analysis",    "sparkles",            .purple,  badge: nil)   { showMarket   = true }
                    moreRow("Portfolio Analysis", "chart.bar.xaxis",     .blue,    badge: nil)   { showAnalysis = true }
                    moreRow("Price Alerts",       "bell.fill",           .orange,  badge: alertBadge > 0 ? alertBadge : nil) { showAlerts = true }
                }
                Section("Account") {
                    moreRow("Settings", "gearshape.fill", .gray, badge: nil) { showSettings = true }
                    moreRow("Profile",  "person.circle",  .gray, badge: nil) { showProfile  = true }
                }
            }
            .navigationTitle("More")
            .sheet(isPresented: $showMarket)   { MarketAnalysisView() }
            .sheet(isPresented: $showAnalysis) { PortfolioAnalysisView() }
            .sheet(isPresented: $showAlerts)   { AlertsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showProfile)  { ProfileView() }
        }
    }

    @ViewBuilder
    private func moreRow(_ title: String, _ icon: String, _ color: Color, badge: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)

                    if let b = badge, b > 0 {
                        Text("\(b)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.red)
                            .clipShape(Circle())
                            .offset(x: 6, y: -6)
                    }
                }
                Text(title).foregroundColor(.primary).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
