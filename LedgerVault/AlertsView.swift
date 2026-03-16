import SwiftUI
import Combine
import UserNotifications

// ── Price Alert Model ─────────────────────────────────────────────────────────
struct PriceAlert: Codable, Identifiable {
    let id: String
    var symbol:    String
    var assetName: String
    var targetPrice: Double
    var condition:   String   // "above" or "below"
    var isActive:    Bool
    var triggered:   Bool
    var createdAt:   String

    var conditionLabel: String { condition == "above" ? "≥" : "≤" }
    var conditionIcon:  String { condition == "above" ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
    var conditionColor: Color  { condition == "above" ? .green : .red }
}

// ── Alerts Manager ────────────────────────────────────────────────────────────
class AlertsManager: ObservableObject {
    static let shared = AlertsManager()
    private let key = "price_alerts_v1"

    @Published var alerts: [PriceAlert] = []
    @Published var notificationsEnabled = false

    init() {
        load()
        checkNotificationStatus()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PriceAlert].self, from: data) else { return }
        alerts = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ alert: PriceAlert) {
        alerts.insert(alert, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        alerts.remove(atOffsets: offsets)
        save()
    }

    func toggle(_ id: String) {
        if let i = alerts.firstIndex(where: { $0.id == id }) {
            alerts[i].isActive.toggle()
            if !alerts[i].isActive { alerts[i].triggered = false }
            save()
        }
    }

    func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationsEnabled = settings.authorizationStatus == .authorized
            }
        }
    }

    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await MainActor.run { notificationsEnabled = granted }
            return granted
        } catch {
            return false
        }
    }

    // Called from background price check
    func checkPrices(_ prices: [String: Double]) {
        var changed = false
        for i in alerts.indices {
            guard alerts[i].isActive && !alerts[i].triggered else { continue }
            let sym = alerts[i].symbol.uppercased()
            guard let current = prices[sym] else { continue }
            let hit = alerts[i].condition == "above"
                ? current >= alerts[i].targetPrice
                : current <= alerts[i].targetPrice

            if hit {
                alerts[i].triggered = true
                changed = true
                sendNotification(alerts[i], currentPrice: current)
            }
        }
        if changed { save() }
    }

    private func sendNotification(_ alert: PriceAlert, currentPrice: Double) {
        let content = UNMutableNotificationContent()
        content.title = "🔔 Price Alert: \(alert.symbol)"
        content.body  = "\(alert.symbol) is \(alert.condition == "above" ? "above" : "below") \(String(format: "$%.2f", alert.targetPrice)). Current: \(String(format: "$%.2f", currentPrice))"
        content.sound = .default
        content.badge = 1

        let request = UNNotificationRequest(
            identifier: "alert_\(alert.id)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// ── Alerts View ───────────────────────────────────────────────────────────────
struct AlertsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = AlertsManager.shared
    @State private var showAdd       = false
    @State private var showPermissionBanner = false
    @State private var rates: APIService.RatesResponse?

    private var activeAlerts:    [PriceAlert] { manager.alerts.filter {  $0.isActive && !$0.triggered } }
    private var triggeredAlerts: [PriceAlert] { manager.alerts.filter { $0.triggered } }
    private var inactiveAlerts:  [PriceAlert] { manager.alerts.filter { !$0.isActive && !$0.triggered } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Notification permission banner
                if !manager.notificationsEnabled {
                    Button {
                        Task {
                            let _ = await manager.requestPermission()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bell.badge.fill").foregroundColor(.orange)
                            Text("Enable notifications to receive price alerts")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Enable →").font(.caption.weight(.bold)).foregroundColor(.blue)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.1))
                    }
                    Divider()
                }

                if manager.alerts.isEmpty {
                    // Empty state
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "bell.slash").font(.system(size: 56)).foregroundColor(.secondary.opacity(0.4))
                        Text("No Price Alerts").font(.title3.bold())
                        Text("Tap + to set an alert for any stock or crypto")
                            .foregroundColor(.secondary).multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity).padding()
                } else {
                    List {
                        // Triggered alerts
                        if !triggeredAlerts.isEmpty {
                            Section {
                                ForEach(triggeredAlerts) { alert in
                                    alertRow(alert, status: "triggered")
                                }
                            } header: {
                                Label("TRIGGERED", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }

                        // Active alerts
                        if !activeAlerts.isEmpty {
                            Section {
                                ForEach(activeAlerts) { alert in
                                    alertRow(alert, status: "active")
                                }
                                .onDelete { manager.delete(at: $0) }
                            } header: {
                                Label("ACTIVE", systemImage: "bell.fill").foregroundColor(.blue)
                            }
                        }

                        // Paused alerts
                        if !inactiveAlerts.isEmpty {
                            Section {
                                ForEach(inactiveAlerts) { alert in
                                    alertRow(alert, status: "paused")
                                }
                                .onDelete { manager.delete(at: $0) }
                            } header: {
                                Label("PAUSED", systemImage: "pause.circle").foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Price Alerts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .task { await loadRates() }
            .sheet(isPresented: $showAdd) {
                AddAlertView(rates: rates) { alert in
                    manager.add(alert)
                }
            }
        }
        .onAppear { manager.checkNotificationStatus() }
    }

    @ViewBuilder
    private func alertRow(_ alert: PriceAlert, status: String) -> some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(alert.conditionColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: alert.conditionIcon)
                    .foregroundColor(alert.conditionColor)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alert.symbol).font(.subheadline.weight(.bold))
                    Text(alert.assetName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Text("\(alert.condition == "above" ? "Price ≥" : "Price ≤") $\(String(format: "%.2f", alert.targetPrice))")
                    .font(.subheadline)

                // Current price
                if let price = rates?.prices[alert.symbol.uppercased()] {
                    Text("Current: $\(String(format: "%.2f", price))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if status == "triggered" {
                    Text("HIT ✓")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                } else if status == "active" {
                    Toggle("", isOn: Binding(
                        get: { alert.isActive },
                        set: { _ in manager.toggle(alert.id) }
                    ))
                    .labelsHidden()
                } else {
                    Toggle("", isOn: Binding(
                        get: { alert.isActive },
                        set: { _ in manager.toggle(alert.id) }
                    ))
                    .labelsHidden()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func loadRates() async {
        rates = try? await APIService.shared.fetchRates()
        // Check alerts against current prices
        if let r = rates { manager.checkPrices(r.prices) }
    }
}

// ── Add Alert View ────────────────────────────────────────────────────────────
struct AddAlertView: View {
    @Environment(\.dismiss) private var dismiss
    let rates: APIService.RatesResponse?
    let onAdd: (PriceAlert) -> Void

    @State private var searchText  = ""
    @State private var selectedSym = ""
    @State private var selectedName = ""
    @State private var targetPrice: Double?
    @State private var condition   = "above"
    @State private var isSearching = false
    @State private var searchResults: [APIService.Asset] = []
    @State private var searchTask: Task<Void, Never>?

    private var currentPrice: Double? { rates?.prices[selectedSym.uppercased()] }

    var body: some View {
        NavigationStack {
            Form {
                Section("Search Asset") {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("TSLA, BTC, ETH, NVDA...", text: $searchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .onChange(of: searchText) { _, q in scheduleSearch(q) }
                        if isSearching { ProgressView().scaleEffect(0.8) }
                    }
                }

                if !searchResults.isEmpty && selectedSym.isEmpty {
                    Section("Results") {
                        ForEach(searchResults.prefix(6)) { asset in
                            Button {
                                selectedSym  = asset.symbol
                                selectedName = asset.name
                                searchText   = asset.symbol
                                searchResults = []
                                if let price = currentPrice { targetPrice = price }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(asset.symbol).font(.headline).foregroundColor(.primary)
                                        Text(asset.name).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if let price = rates?.prices[asset.symbol.uppercased()] {
                                        Text("$\(String(format: "%.2f", price))")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if !selectedSym.isEmpty {
                    Section("Alert Details") {
                        HStack {
                            Text(selectedSym).font(.headline.bold())
                            Text(selectedName).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            if let price = currentPrice {
                                Text("Now: $\(String(format: "%.2f", price))")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }

                        Picker("Condition", selection: $condition) {
                            Text("Price rises above").tag("above")
                            Text("Price falls below").tag("below")
                        }

                        HStack {
                            Text("$")
                            TextField("Target Price", value: $targetPrice,
                                      format: .number.precision(.fractionLength(2)))
                                .keyboardType(.decimalPad)
                        }

                        if let current = currentPrice, let target = targetPrice {
                            let diff = ((target - current) / current) * 100
                            Label(
                                String(format: "%@%.1f%% from current price",
                                       diff >= 0 ? "+" : "", diff),
                                systemImage: diff >= 0 ? "arrow.up.right" : "arrow.down.right"
                            )
                            .font(.caption)
                            .foregroundColor(diff >= 0 ? .green : .red)
                        }
                    }
                }
            }
            .navigationTitle("New Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Alert") {
                        guard !selectedSym.isEmpty, let price = targetPrice, price > 0 else { return }
                        let alert = PriceAlert(
                            id: UUID().uuidString,
                            symbol: selectedSym.uppercased(),
                            assetName: selectedName,
                            targetPrice: price,
                            condition: condition,
                            isActive: true,
                            triggered: false,
                            createdAt: Date().formatted(.iso8601.dateSeparator(.dash).year().month().day())
                        )
                        onAdd(alert)
                        dismiss()
                    }
                    .disabled(selectedSym.isEmpty || targetPrice == nil)
                }
            }
        }
    }

    private func scheduleSearch(_ query: String) {
        selectedSym = ""; selectedName = ""
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            if let results = try? await APIService.shared.searchAssets(query: q) {
                searchResults = results
            }
        }
    }
}
