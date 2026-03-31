import SwiftUI

struct ContentView: View {
    @StateObject private var profileManager = ProfileManager()

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "arrow.left.arrow.right") }

            MarketsView()
                .tabItem { Label("Markets", systemImage: "chart.bar.fill") }

            InvestmentDashboardView()
                .tabItem { Label("Portfolio", systemImage: "chart.line.uptrend.xyaxis") }

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
        }
        .tint(LVBrand.green)
        .environmentObject(profileManager)
        .task { await profileManager.load() }
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
    @State private var showCategories    = false
    @State private var showReset         = false
    @State private var showFAQ           = false
    @State private var showPrivacy       = false

    @StateObject private var alertsManager = AlertsManager.shared
    private var alertBadge: Int {
        alertsManager.alerts.filter { $0.isActive && !$0.triggered }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // ── Insights ──────────────────────────────────────────
                    sectionCard("Insights") {
                        moreRow("Market Analysis",    "sparkles",        .purple, badge: nil) { showMarket   = true }
                        rowDivider()
                        moreRow("Portfolio Analysis", "chart.bar.xaxis", .blue,   badge: nil) { showAnalysis = true }
                        rowDivider()
                        moreRow("Price Alerts",       "bell.fill",       .orange,
                                badge: alertBadge > 0 ? alertBadge : nil)                    { showAlerts   = true }
                    }

                    // ── Tools ─────────────────────────────────────────────
                    sectionCard("Tools") {
                        moreRow("Export / Import", "square.and.arrow.up.on.square", .teal,   badge: nil) { showExportImport = true }
                        rowDivider()
                        moreRow("Recurring",       "repeat",                         .cyan,   badge: nil) { showRecurring    = true }
                        rowDivider()
                        moreRow("Categories",      "folder.fill",                 .orange,  badge: nil) { showCategories   = true }
                        rowDivider()
                        moreRow("Integrations",    "puzzlepiece.extension.fill",   .indigo,  badge: nil) { showIntegrations = true }
                    }

                    // ── Account ───────────────────────────────────────────
                    sectionCard("Account") {
                        moreRow("Profile",  "person.circle.fill", .blue, badge: nil) { showProfile  = true }
                        rowDivider()
                        moreRow("Settings", "gearshape.fill",     .gray, badge: nil) { showSettings = true }
                        rowDivider()
                        moreRow("Security", "lock.shield.fill",   .gray, badge: nil) { showSecurity = true }
                    }

                    // ── Data ──────────────────────────────────────────────
                    sectionCard("Data") {
                        moreRow("FAQ",             "questionmark.circle.fill", .mint, badge: nil) { showFAQ     = true }
                        rowDivider()
                        moreRow("Privacy & Legal", "hand.raised.fill",         .blue, badge: nil) { showPrivacy = true }
                        rowDivider()
                        moreRow("Reset Data",      "trash.fill",               .red,  badge: nil) { showReset   = true }
                    }

                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
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
            .sheet(isPresented: $showCategories)   { CategoryManagerView() }
            .sheet(isPresented: $showReset)        { ResetDataView() }
            .sheet(isPresented: $showFAQ)          { FAQView() }
            .sheet(isPresented: $showPrivacy)      { PrivacyPoliciesView() }
        }
    }

    // ── Card container ────────────────────────────────────────────────────────
    @ViewBuilder
    private func sectionCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
    }

    @ViewBuilder
    private func rowDivider() -> some View {
        Divider().padding(.leading, 66)
    }

    // ── Row ───────────────────────────────────────────────────────────────────
    @ViewBuilder
    private func moreRow(_ title: String, _ icon: String, _ color: Color,
                         badge: Int?, action: @escaping () -> Void) -> some View {
        Button {
            hapticLight()
            action()
        } label: {
            HStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)

                    if let b = badge, b > 0 {
                        Text("\(b)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.red)
                            .clipShape(Circle())
                            .offset(x: 7, y: -7)
                    }
                }
                Text(title)
                    .foregroundColor(.primary)
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
