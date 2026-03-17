import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("baseCurrency")       private var baseCurrency       = "EUR"
    @AppStorage("theme")              private var theme              = "system"
    @AppStorage("isSignedIn")         private var isSignedIn         = false
    @AppStorage("notifPriceAlerts")   private var notifPriceAlerts   = true
    @AppStorage("notifWeeklySummary") private var notifWeeklySummary = false
    @AppStorage("showCentsAlways")    private var showCentsAlways    = true

    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var showSignOutAlert = false

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
                    Toggle(isOn: $showCentsAlways) {
                        Label("Always Show Decimals", systemImage: "textformat.123")
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
            .task { await checkNotificationStatus() }
            .alert("Sign Out?", isPresented: $showSignOutAlert) {
                Button("Sign Out", role: .destructive) { isSignedIn = false }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to sign back in to access your portfolio.")
            }
        }
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
