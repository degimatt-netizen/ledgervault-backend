import SwiftUI
import UserNotifications

// ── Market feed status ────────────────────────────────────────────────────────
private enum FeedStatus {
    case loading, live, error

    var color: Color {
        switch self {
        case .loading: return .orange
        case .live:    return .green
        case .error:   return .red
        }
    }
    var label: String {
        switch self {
        case .loading: return "Checking…"
        case .live:    return "Live"
        case .error:   return "Unavailable"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("baseCurrency")       private var baseCurrency       = "EUR"
    @AppStorage("theme")              private var theme              = "dark"
    @AppStorage("isSignedIn")         private var isSignedIn         = false
    @AppStorage("notifPriceAlerts")   private var notifPriceAlerts   = true
    @AppStorage("notifWeeklySummary") private var notifWeeklySummary = false

    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var showSignOutAlert = false

    // Market data status
    @State private var fxStatus:     FeedStatus = .loading
    @State private var cryptoStatus: FeedStatus = .loading
    @State private var stockStatus:  FeedStatus = .loading
    @State private var lastChecked:  Date?      = nil
    @State private var isRefreshing             = false

    let currencies = ["EUR","USD","GBP","CHF","CAD","AUD","JPY","PLN","SEK","NOK","CZK"]

    var body: some View {
        NavigationStack {
            Form {

                // ── Display ───────────────────────────────────────────────────
                Section {
                    Picker("Base Currency", selection: $baseCurrency) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Appearance", selection: $theme) {
                        Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                        Label("Light",  systemImage: "sun.max.fill").tag("light")
                        Label("Dark",   systemImage: "moon.fill").tag("dark")
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Base currency is used for all dashboard totals and portfolio summaries.")
                }

                // ── Notifications ──────────────────────────────────────────────
                Section {
                    Toggle(isOn: $notifPriceAlerts) {
                        Label("Price Alerts", systemImage: "bell.badge.fill")
                    }
                    .disabled(notifStatus == .denied)

                    Toggle(isOn: $notifWeeklySummary) {
                        Label("Weekly Portfolio Summary", systemImage: "chart.bar.doc.horizontal")
                    }
                    .disabled(notifStatus == .denied)

                    if notifStatus == .denied {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Notifications are disabled. Enable them in iOS Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Open") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    } else if notifStatus == .notDetermined {
                        Button {
                            Task { await requestNotifications() }
                        } label: {
                            Label("Enable Notifications", systemImage: "bell.fill")
                                .foregroundColor(.blue)
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Price alert notifications fire when a tracked asset hits your target.")
                }

                // ── Account ───────────────────────────────────────────────────
                Section("Account") {
                    Button(role: .destructive) {
                        showSignOutAlert = true
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                // ── Market Data ───────────────────────────────────────────────
                Section {
                    marketRow("FX Rates",    source: "open.er-api.com", status: fxStatus)
                    marketRow("Crypto",      source: "CoinGecko",       status: cryptoStatus)
                    marketRow("Stocks",      source: "Yahoo Finance",    status: stockStatus)

                    Button {
                        Task { await checkMarketStatus() }
                    } label: {
                        HStack {
                            if isRefreshing {
                                ProgressView().scaleEffect(0.75)
                                Text("Refreshing…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if let ts = lastChecked {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("Refresh · last checked \(ts.formatted(.relative(presentation: .numeric)))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("Refresh")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isRefreshing)
                } header: {
                    Text("Market Data Status")
                } footer: {
                    Text("Prices refresh automatically. Tap to check current feed status.")
                }

                // ── About ─────────────────────────────────────────────────────
                Section("About") {
                    LabeledContent("App",     value: "LedgerVault")
                    LabeledContent("Version", value: "4.2.0")
                    LabeledContent("Backend", value: "Railway · FastAPI")
                    LabeledContent("API",     value: "v4.2")
                    Text("All portfolio data is stored securely on your private backend. Prices are fetched in real time from public market data sources.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await checkNotificationStatus()
                await checkMarketStatus()
            }
            .alert("Sign Out?", isPresented: $showSignOutAlert) {
                Button("Sign Out", role: .destructive) { isSignedIn = false }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to sign back in to access your portfolio.")
            }
        }
    }

    // MARK: - Market Data

    @ViewBuilder
    private func marketRow(_ name: String, source: String, status: FeedStatus) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.subheadline)
            Spacer()
            HStack(spacing: 6) {
                if case .loading = status {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                }
                Text(status.label)
                    .font(.caption.weight(.medium))
                    .foregroundColor(status.color)
            }
        }
    }

    private func checkMarketStatus() async {
        guard !isRefreshing else { return }
        isRefreshing  = true
        fxStatus      = .loading
        cryptoStatus  = .loading
        stockStatus   = .loading

        do {
            let rates = try await APIService.shared.fetchRates()
            fxStatus     = rates.fx_to_usd.count > 5 ? .live : .error
            cryptoStatus = rates.prices.count    > 3 ? .live : .error
        } catch {
            fxStatus     = .error
            cryptoStatus = .error
        }

        do {
            _ = try await APIService.shared.fetchStockQuote(symbol: "AAPL")
            stockStatus = .live
        } catch {
            stockStatus = .error
        }

        lastChecked  = Date()
        isRefreshing = false
    }

    // MARK: - Notifications

    private func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifStatus = settings.authorizationStatus
    }

    private func requestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            notifStatus = granted ? .authorized : .denied
        } catch {
            notifStatus = .denied
        }
    }
}
