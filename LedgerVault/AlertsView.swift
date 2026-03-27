import SwiftUI
import Combine
import UserNotifications

// ── Price Alert Model ─────────────────────────────────────────────────────────
struct PriceAlert: Codable, Identifiable {
    let id: String
    var symbol:      String
    var assetName:   String
    var targetPrice: Double
    var condition:   String   // "above" or "below" — auto-derived from target vs current
    var isActive:    Bool
    var triggered:   Bool
    var createdAt:   String
    var imageURL:    String?  // thumbnail for display

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

    init() { load(); checkNotificationStatus() }

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

    func add(_ alert: PriceAlert) { hapticSuccess(); alerts.insert(alert, at: 0); save() }

    func delete(at offsets: IndexSet) { hapticWarning(); alerts.remove(atOffsets: offsets); save() }

    func toggle(_ id: String) {
        if let i = alerts.firstIndex(where: { $0.id == id }) {
            alerts[i].isActive.toggle()
            if !alerts[i].isActive { alerts[i].triggered = false }
            save()
        }
    }

    /// Reset a triggered alert back to active (re-arm it)
    func rearm(_ id: String) {
        if let i = alerts.firstIndex(where: { $0.id == id }) {
            alerts[i].triggered = false
            alerts[i].isActive  = true
            hapticSuccess()
            save()
        }
    }

    func deleteById(_ id: String) {
        hapticWarning()
        alerts.removeAll { $0.id == id }
        save()
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
        } catch { return false }
    }

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
        guard UserDefaults.standard.object(forKey: "notifPriceAlerts") as? Bool != false else { return }
        let content = UNMutableNotificationContent()
        content.title = "🔔 Price Alert: \(alert.symbol)"
        content.body  = "\(alert.symbol) hit \(alert.conditionLabel) $\(String(format: "%.2f", alert.targetPrice)). Now: $\(String(format: "%.2f", currentPrice))"
        content.sound = .default
        content.badge = 1
        let request = UNNotificationRequest(identifier: "alert_\(alert.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// ── Alerts View ───────────────────────────────────────────────────────────────
struct AlertsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = AlertsManager.shared
    @State private var showAdd = false
    @State private var rates: APIService.RatesResponse?

    private var activeAlerts:    [PriceAlert] { manager.alerts.filter {  $0.isActive && !$0.triggered } }
    private var triggeredAlerts: [PriceAlert] { manager.alerts.filter {  $0.triggered } }
    private var inactiveAlerts:  [PriceAlert] { manager.alerts.filter { !$0.isActive && !$0.triggered } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Notification permission banner
                if !manager.notificationsEnabled {
                    Button { Task { let _ = await manager.requestPermission() } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bell.badge.fill").foregroundColor(.orange)
                            Text("Enable notifications to receive price alerts")
                                .font(.caption.weight(.semibold)).foregroundColor(.primary)
                            Spacer()
                            Text("Enable →").font(.caption.weight(.bold)).foregroundColor(.blue)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.1))
                    }
                    Divider()
                }

                if manager.alerts.isEmpty {
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
                        if !triggeredAlerts.isEmpty {
                            Section {
                                ForEach(triggeredAlerts) { alert in
                                    alertRow(alert, status: "triggered")
                                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                            Button {
                                                manager.rearm(alert.id)
                                            } label: {
                                                Label("Re-arm", systemImage: "arrow.clockwise.circle.fill")
                                            }
                                            .tint(.blue)
                                        }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                manager.deleteById(alert.id)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            } header: {
                                Label("TRIGGERED", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                            } footer: {
                                Text("Swipe right to re-arm an alert")
                                    .font(.caption2)
                            }
                        }
                        if !activeAlerts.isEmpty {
                            Section {
                                ForEach(activeAlerts) { alertRow($0, status: "active") }
                                    .onDelete { manager.delete(at: $0) }
                            } header: {
                                Label("ACTIVE", systemImage: "bell.fill").foregroundColor(.blue)
                            }
                        }
                        if !inactiveAlerts.isEmpty {
                            Section {
                                ForEach(inactiveAlerts) { alertRow($0, status: "paused") }
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
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .task { await loadRates() }
            .sheet(isPresented: $showAdd) {
                AddAlertView(rates: rates) { manager.add($0) }
            }
        }
        .onAppear { manager.checkNotificationStatus() }
    }

    @ViewBuilder
    private func alertRow(_ alert: PriceAlert, status: String) -> some View {
        HStack(spacing: 14) {
            // Thumbnail or condition icon
            ZStack {
                Circle()
                    .fill(alert.conditionColor.opacity(0.10))
                    .frame(width: 46, height: 46)
                if let urlStr = alert.imageURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 34, height: 34).clipShape(Circle())
                        default:
                            Image(systemName: alert.conditionIcon)
                                .foregroundColor(alert.conditionColor).font(.title3)
                        }
                    }
                } else {
                    Image(systemName: alert.conditionIcon)
                        .foregroundColor(alert.conditionColor).font(.title3)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alert.symbol).font(.subheadline.weight(.bold))
                    Text(alert.assetName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: alert.condition == "above" ? "arrow.up" : "arrow.down")
                        .font(.caption2.bold())
                        .foregroundColor(alert.conditionColor)
                    Text("Price \(alert.conditionLabel) $\(String(format: "%.2f", alert.targetPrice))")
                        .font(.subheadline)
                }
                if let price = rates?.prices[alert.symbol.uppercased()] {
                    Text("Current: $\(String(format: price < 1 ? "%.4f" : "%.2f", price))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            if status == "triggered" {
                VStack(spacing: 4) {
                    Text("HIT ✓")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                    Button {
                        manager.rearm(alert.id)
                    } label: {
                        Text("Re-arm")
                            .font(.caption2.bold())
                            .foregroundColor(.blue)
                    }
                }
            } else {
                Toggle("", isOn: Binding(
                    get: { alert.isActive },
                    set: { _ in manager.toggle(alert.id) }
                )).labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }

    private func loadRates() async {
        rates = try? await APIService.shared.fetchRates()
        if let r = rates { manager.checkPrices(r.prices) }
    }
}

// ── Asset Hit (search result with image) ─────────────────────────────────────
private struct AssetHit: Identifiable {
    let id   = UUID().uuidString
    let symbol: String
    let name:   String
    let imageURL: String?
    let price:    Double?
}

// ── Add Alert View ────────────────────────────────────────────────────────────
struct AddAlertView: View {
    @Environment(\.dismiss) private var dismiss
    let rates: APIService.RatesResponse?
    let onAdd: (PriceAlert) -> Void

    @FocusState private var priceFocused: Bool

    @State private var searchText    = ""
    @State private var selectedSym   = ""
    @State private var selectedName  = ""
    @State private var selectedImage: String? = nil
    @State private var targetPrice:  Double?
    @State private var isSearching   = false
    @State private var searchResults: [AssetHit] = []
    @State private var searchTask:   Task<Void, Never>?

    private var currentPrice: Double? { rates?.prices[selectedSym.uppercased()] }

    // Auto-derive condition from target vs current
    private var condition: String {
        guard let t = targetPrice, let c = currentPrice else { return "above" }
        return t >= c ? "above" : "below"
    }
    private var conditionColor: Color  { condition == "above" ? .green : .red }
    private var conditionIcon:  String { condition == "above" ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }

    private var canAdd: Bool { !selectedSym.isEmpty && (targetPrice ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                        .frame(width: 40, height: 40)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .clipShape(Circle())
                }
                Spacer()
                Text("New Alert").font(.headline)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 12) {

                    // ── Search card ───────────────────────────────────────
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            TextField("TSLA, BTC, ETH, NVDA…", text: $searchText)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                                .onChange(of: searchText) { _, q in scheduleSearch(q) }
                            if isSearching {
                                ProgressView().scaleEffect(0.75)
                            } else if !searchText.isEmpty {
                                Button {
                                    selectedSym = ""; selectedName = ""; selectedImage = nil
                                    targetPrice = nil; searchText = ""
                                    searchResults = []
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(16)

                        // ── Search results ────────────────────────────────
                        if !searchResults.isEmpty && selectedSym.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(searchResults.prefix(8).enumerated()), id: \.element.id) { idx, hit in
                                    Button { select(hit) } label: {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle()
                                                    .fill(Color.blue.opacity(0.10))
                                                    .frame(width: 40, height: 40)
                                                if let urlStr = hit.imageURL, let url = URL(string: urlStr) {
                                                    AsyncImage(url: url) { phase in
                                                        switch phase {
                                                        case .success(let img):
                                                            img.resizable().scaledToFill()
                                                                .frame(width: 30, height: 30).clipShape(Circle())
                                                        default:
                                                            Text(String(hit.symbol.prefix(2)))
                                                                .font(.caption2.bold()).foregroundColor(.blue)
                                                        }
                                                    }
                                                } else {
                                                    Text(String(hit.symbol.prefix(2)))
                                                        .font(.caption2.bold()).foregroundColor(.blue)
                                                }
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(hit.symbol).font(.subheadline.bold()).foregroundColor(.primary)
                                                Text(hit.name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                            }
                                            Spacer()
                                            if let price = hit.price {
                                                Text(fmtPrice(price))
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.secondary)
                                            }
                                            Image(systemName: "chevron.right")
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                    }
                                    if idx < min(searchResults.count, 8) - 1 {
                                        Divider().padding(.leading, 68)
                                    }
                                }
                            }
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(16)
                            .padding(.top, 8)
                        }
                    }

                    // ── Selected asset card ───────────────────────────────
                    if !selectedSym.isEmpty {
                        VStack(spacing: 0) {
                            // Asset row
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(conditionColor.opacity(0.12))
                                        .frame(width: 52, height: 52)
                                    if let urlStr = selectedImage, let url = URL(string: urlStr) {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case .success(let img):
                                                img.resizable().scaledToFill()
                                                    .frame(width: 40, height: 40).clipShape(Circle())
                                            default:
                                                Text(String(selectedSym.prefix(2)))
                                                    .font(.subheadline.bold()).foregroundColor(conditionColor)
                                            }
                                        }
                                    } else {
                                        Text(String(selectedSym.prefix(2)))
                                            .font(.subheadline.bold()).foregroundColor(conditionColor)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(selectedSym).font(.headline.bold())
                                        Text(selectedName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    if let price = currentPrice {
                                        Text("Current  \(fmtPrice(price))")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                // Condition badge
                                HStack(spacing: 4) {
                                    Image(systemName: condition == "above" ? "arrow.up" : "arrow.down")
                                        .font(.caption2.bold())
                                    Text(condition == "above" ? "ABOVE" : "BELOW")
                                        .font(.caption2.bold())
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(conditionColor.opacity(0.12))
                                .foregroundColor(conditionColor)
                                .clipShape(Capsule())
                            }
                            .padding(16)

                            Divider().padding(.horizontal, 16)

                            // Target price input
                            HStack(spacing: 10) {
                                Image(systemName: "target")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                                Text("Target price")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                HStack(spacing: 4) {
                                    Text("$").foregroundColor(.secondary)
                                    TextField("0.00", value: $targetPrice,
                                              format: .number.precision(.fractionLength(2)))
                                        .keyboardType(.decimalPad)
                                        .focused($priceFocused)
                                        .font(.headline.bold())
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 120)
                                }
                            }
                            .padding(16)

                            // Direction indicator
                            if let current = currentPrice, let target = targetPrice, target > 0 {
                                let diff = ((target - current) / current) * 100
                                Divider().padding(.horizontal, 16)
                                HStack(spacing: 8) {
                                    Image(systemName: diff >= 0 ? "arrow.up.right" : "arrow.down.right")
                                        .font(.caption.bold())
                                        .foregroundColor(diff >= 0 ? .green : .red)
                                    Text(String(format: "%@%.1f%% from current — fires when price %@",
                                                diff >= 0 ? "+" : "", diff,
                                                diff >= 0 ? "rises above" : "falls below"))
                                        .font(.caption)
                                        .foregroundColor(diff >= 0 ? .green : .red)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .animation(.spring(response: 0.35), value: selectedSym)
                    }

                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
            .scrollDismissesKeyboard(.interactively)

            // ── Pinned Add button ─────────────────────────────────────────
            Button {
                guard canAdd, let price = targetPrice else { return }
                onAdd(PriceAlert(
                    id: UUID().uuidString,
                    symbol: selectedSym.uppercased(),
                    assetName: selectedName,
                    targetPrice: price,
                    condition: condition,
                    isActive: true,
                    triggered: false,
                    createdAt: Date().formatted(.iso8601.dateSeparator(.dash).year().month().day()),
                    imageURL: selectedImage
                ))
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                    Text(selectedSym.isEmpty ? "Set Alert" : "Alert \(selectedSym) \(condition == "above" ? "≥" : "≤") \(targetPrice.map { fmtPrice($0) } ?? "…")")
                        .lineLimit(1)
                }
                .font(.headline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(canAdd ? Color.orange : Color.orange.opacity(0.3))
                .foregroundColor(canAdd ? .white : .white.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .disabled(!canAdd)
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
            .background(Color(UIColor.systemGroupedBackground))
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { priceFocused = false }.font(.body.bold())
            }
        }
    }

    private func select(_ hit: AssetHit) {
        selectedSym   = hit.symbol
        selectedName  = hit.name
        selectedImage = hit.imageURL
        searchText    = hit.symbol
        searchResults = []
        if let p = hit.price ?? currentPrice { targetPrice = p }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { priceFocused = true }
    }

    private func scheduleSearch(_ query: String) {
        selectedSym = ""; selectedName = ""; selectedImage = nil
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { isSearching = true }

            // Search crypto and stocks concurrently
            async let cryptoSearch = try? APIService.shared.searchCrypto(query: q)
            async let stockSearch  = try? APIService.shared.searchStocks(query: q)
            let (cryptos, stocks)  = await (cryptoSearch, stockSearch)

            var hits: [AssetHit] = []

            // Crypto results — use CoinGecko small image
            if let c = cryptos {
                for r in c.prefix(5) {
                    let imgURL = r.thumb?.replacingOccurrences(of: "/thumb/", with: "/small/")
                    hits.append(AssetHit(
                        symbol: r.symbol.uppercased(),
                        name: r.name,
                        imageURL: imgURL,
                        price: r.price_usd ?? rates?.prices[r.symbol.uppercased()]
                    ))
                }
            }

            // Stock results — use Parqet logo
            if let s = stocks {
                for r in s.prefix(5) {
                    let imgURL = "https://assets.parqet.com/logos/symbol/\(r.symbol)?format=jpg"
                    hits.append(AssetHit(
                        symbol: r.symbol.uppercased(),
                        name: r.name,
                        imageURL: imgURL,
                        price: r.price_usd ?? rates?.prices[r.symbol.uppercased()]
                    ))
                }
            }

            // Fallback: any matching symbol from rates dict (if both API searches returned nothing)
            if hits.isEmpty, let r = rates {
                let uq = q.uppercased()
                let rateHits = r.prices.keys
                    .filter { $0.contains(uq) }
                    .sorted().prefix(6)
                    .map { sym in AssetHit(symbol: sym, name: sym, imageURL: nil, price: r.prices[sym]) }
                hits = Array(rateHits)
            }

            // Deduplicate by symbol
            var seen = Set<String>()
            let deduped = hits.filter { seen.insert($0.symbol).inserted }
            await MainActor.run { searchResults = deduped; isSearching = false }
        }
    }
}
