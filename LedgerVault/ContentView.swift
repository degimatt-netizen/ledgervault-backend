import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "arrow.left.arrow.right") }

            MarketsView()
                .tabItem { Label("Markets", systemImage: "chart.bar.fill") }

            InvestmentDashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.line.uptrend.xyaxis") }

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
        }
    }
}

// ── More tab ──────────────────────────────────────────────────────────────────
struct MoreView: View {
    @State private var showAnalysis      = false
    @State private var showAlerts        = false
    @State private var showMarket        = false
    @State private var showSettings      = false
    @State private var showProfile       = false
    @State private var showExportImport  = false
    @State private var showSecurity      = false
    @State private var showIntegrations  = false
    @State private var showRecurring     = false
    @State private var showReset         = false
    @State private var showFAQ           = false
    @State private var showPrivacy       = false

    @StateObject private var alertsManager = AlertsManager.shared
    private var alertBadge: Int {
        alertsManager.alerts.filter { $0.isActive && !$0.triggered }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Insights") {
                    moreRow("Market Analysis",    "sparkles",            .purple,  badge: nil) { showMarket   = true }
                    moreRow("Portfolio Analysis", "chart.bar.xaxis",     .blue,    badge: nil) { showAnalysis = true }
                    moreRow("Price Alerts",       "bell.fill",           .orange,
                             badge: alertBadge > 0 ? alertBadge : nil)                        { showAlerts   = true }
                }

                Section("Tools") {
                    moreRow("Export / Import",    "square.and.arrow.up.on.square", .teal,   badge: nil) { showExportImport = true }
                    moreRow("Recurring",          "repeat",                         .cyan,   badge: nil) { showRecurring    = true }
                }

                Section("Integrations") {
                    moreRow("Integrations", "puzzlepiece.extension.fill", .indigo, badge: nil) { showIntegrations = true }
                }

                Section("Account") {
                    moreRow("Settings", "gearshape.fill",  .gray, badge: nil) { showSettings = true }
                    moreRow("Security", "lock.shield.fill", .gray, badge: nil) { showSecurity = true }
                    moreRow("Profile",  "person.circle",   .gray, badge: nil) { showProfile  = true }
                }

                Section("Data") {
                    moreRow("FAQ",             "questionmark.circle.fill", .mint,  badge: nil) { showFAQ     = true }
                    moreRow("Privacy & Legal", "hand.raised.fill",         .blue,  badge: nil) { showPrivacy = true }
                    moreRow("Reset Data",      "trash.fill",               .red,   badge: nil) { showReset   = true }
                }
            }
            .navigationTitle("More")
            .sheet(isPresented: $showMarket)       { MarketAnalysisView() }
            .sheet(isPresented: $showAnalysis)     { PortfolioAnalysisView() }
            .sheet(isPresented: $showAlerts)       { AlertsView() }
            .sheet(isPresented: $showSettings)     { SettingsView() }
            .sheet(isPresented: $showProfile)      { ProfileView() }
            .sheet(isPresented: $showExportImport) { ExportImportView() }
            .sheet(isPresented: $showSecurity)     { SecurityView() }
            .sheet(isPresented: $showIntegrations) { IntegrationsHubView() }
            .sheet(isPresented: $showRecurring)    { RecurringTransactionsView() }
            .sheet(isPresented: $showReset)        { ResetDataView() }
            .sheet(isPresented: $showFAQ)          { FAQView() }
            .sheet(isPresented: $showPrivacy)      { PrivacyPoliciesView() }
        }
    }

    @ViewBuilder
    private func moreRow(_ title: String, _ icon: String, _ color: Color,
                         badge: Int?, action: @escaping () -> Void) -> some View {
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
