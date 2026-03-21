import SwiftUI

// MARK: - Main View

struct ExchangeConnectionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var connections: [APIService.ExchangeConnectionResponse] = []
    @State private var accounts:    [APIService.Account] = []
    @State private var isLoading    = false
    @State private var error:       String?

    @State private var showAddSheet    = false
    @State private var syncingID:      String?
    @State private var syncResult:     APIService.SyncResultResponse?
    @State private var showSyncResult  = false
    @State private var deleteID:       String?
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && connections.isEmpty {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if connections.isEmpty {
                    exchangeEmptyState
                } else {
                    List {
                        Section {
                            ForEach(connections) { conn in
                                connectionRow(conn)
                            }
                            .onDelete { offsets in
                                if let i = offsets.first {
                                    deleteID        = connections[i].id
                                    showDeleteAlert = true
                                }
                            }
                        }

                        Section {
                            Button { showAddSheet = true } label: {
                                Label("Add Exchange Connection", systemImage: "plus.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Exchange Connections")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showAddSheet) {
                AddExchangeConnectionView(accounts: accounts) { Task { await load() } }
            }
            .alert("Delete Connection?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let id = deleteID { Task { await deleteConnection(id: id) } }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The connection will be removed. Your imported transactions will remain.")
            }
            .alert("Sync Complete", isPresented: $showSyncResult) {
                Button("OK") { }
            } message: {
                if let r = syncResult {
                    let errNote = r.errors.isEmpty ? "" : "\nErrors: " + r.errors.prefix(2).joined(separator: "; ")
                    Text("Imported \(r.imported) trade(s). Skipped \(r.skipped).\(errNote)")
                }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    // MARK: - Empty State

    private var exchangeEmptyState: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.orange.opacity(0.25), Color.yellow.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 130, height: 130)
                    Image(systemName: "bitcoinsign.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(LinearGradient(
                            colors: [.orange, .yellow],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .padding(.top, 36).padding(.bottom, 22)

                Text("Connect an Exchange")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text("Add a read-only API key from your exchange to auto-import your trade history.")
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32).padding(.top, 8)

                // Exchange grid
                let cols = [GridItem(.adaptive(minimum: 130), spacing: 12)]
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(ExchangeConnectionsView.supportedExchanges, id: \.id) { ex in
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(ex.color.opacity(0.13))
                                    .frame(width: 34, height: 34)
                                Image(systemName: ex.icon)
                                    .foregroundColor(ex.color)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(ex.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 24)

                Button { showAddSheet = true } label: {
                    Label("Connect Exchange", systemImage: "link.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 20).padding(.top, 24)

                Text("Use a read-only API key. LedgerVault never trades on your behalf.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32).padding(.top, 10).padding(.bottom, 40)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func connectionRow(_ conn: APIService.ExchangeConnectionResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(exchangeColor(conn.exchange).opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: exchangeIcon(conn.exchange))
                        .foregroundColor(exchangeColor(conn.exchange))
                        .font(.system(size: 18, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(conn.name).font(.subheadline.weight(.semibold))
                        statusBadge(conn.status)
                    }
                    Text(conn.exchange.capitalized + " · " + conn.api_key_masked)
                        .font(.caption).foregroundColor(.secondary)
                    if let synced = conn.last_synced {
                        Text("Synced " + formatSyncDate(synced))
                            .font(.caption2).foregroundColor(.secondary)
                    } else {
                        Text("Never synced")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }

                Spacer()

                Button {
                    Task { await syncConnection(id: conn.id) }
                } label: {
                    if syncingID == conn.id {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                }
                .disabled(syncingID != nil)
                .buttonStyle(.plain)
            }

            if let msg = conn.status_message, conn.status == "error" {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let info: (String, Color) = {
            switch status {
            case "active": return ("Active", .green)
            case "error":  return ("Error",  .red)
            default:       return ("Inactive", .secondary)
            }
        }()
        Text(info.0)
            .font(.caption2.weight(.semibold))
            .foregroundColor(info.1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(info.1.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Supported Exchanges

    struct SupportedExchange {
        let id: String
        let displayName: String
        let icon: String
        let color: Color
    }

    static let supportedExchanges: [SupportedExchange] = [
        // ── Tier 1: Major exchanges ──
        SupportedExchange(id: "binance",    displayName: "Binance",      icon: "bitcoinsign.circle.fill",  color: .yellow),
        SupportedExchange(id: "coinbase",   displayName: "Coinbase",     icon: "c.circle.fill",            color: .blue),
        SupportedExchange(id: "kraken",     displayName: "Kraken",       icon: "k.circle.fill",            color: .indigo),
        SupportedExchange(id: "bybit",      displayName: "Bybit",        icon: "triangle.circle.fill",     color: .orange),
        SupportedExchange(id: "kucoin",     displayName: "KuCoin",       icon: "square.circle.fill",       color: .green),
        SupportedExchange(id: "okx",        displayName: "OKX",          icon: "o.circle.fill",            color: .teal),
        // ── Tier 2 ──
        SupportedExchange(id: "gate",       displayName: "Gate.io",      icon: "g.circle.fill",            color: .cyan),
        SupportedExchange(id: "bitfinex",   displayName: "Bitfinex",     icon: "b.circle.fill",            color: .purple),
        SupportedExchange(id: "gemini",     displayName: "Gemini",       icon: "sparkles",                 color: Color(red: 0.0, green: 0.44, blue: 0.86)),
        SupportedExchange(id: "htx",        displayName: "HTX",          icon: "h.circle.fill",            color: .red),
        SupportedExchange(id: "mexc",       displayName: "MEXC",         icon: "m.circle.fill",            color: Color(red: 0.05, green: 0.55, blue: 0.95)),
        SupportedExchange(id: "cryptocom",  displayName: "Crypto.com",   icon: "creditcard.and.123",       color: .indigo),
        SupportedExchange(id: "bitstamp",   displayName: "Bitstamp",     icon: "s.circle.fill",            color: Color(red: 0.0, green: 0.49, blue: 0.96)),
        SupportedExchange(id: "bitmart",    displayName: "BitMart",      icon: "chart.bar.fill",           color: Color(red: 0.18, green: 0.82, blue: 0.50)),
        SupportedExchange(id: "phemex",     displayName: "Phemex",       icon: "p.circle.fill",            color: Color(red: 0.06, green: 0.60, blue: 0.92)),
        SupportedExchange(id: "coinex",     displayName: "CoinEx",       icon: "e.circle.fill",            color: Color(red: 0.07, green: 0.72, blue: 0.65)),
        SupportedExchange(id: "lbank",      displayName: "LBank",        icon: "l.circle.fill",            color: Color(red: 0.78, green: 0.20, blue: 0.95)),
        // ── Broker ──
        SupportedExchange(id: "alpaca",     displayName: "Alpaca",       icon: "chart.line.uptrend.xyaxis.circle.fill", color: Color(red: 0.93, green: 0.26, blue: 0.21)),
    ]

    // MARK: - Helpers

    private func exchangeIcon(_ exchange: String) -> String {
        Self.supportedExchanges.first { $0.id == exchange }?.icon ?? "link.circle.fill"
    }

    private func exchangeColor(_ exchange: String) -> Color {
        Self.supportedExchanges.first { $0.id == exchange }?.color ?? .gray
    }

    private func formatSyncDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let c = APIService.shared.fetchExchangeConnections()
            async let a = APIService.shared.fetchAccounts()
            (connections, accounts) = try await (c, a)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func syncConnection(id: String) async {
        syncingID = id
        defer { syncingID = nil }
        do {
            syncResult     = try await APIService.shared.syncExchangeConnection(id: id)
            showSyncResult = true
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteConnection(id: String) async {
        do {
            try await APIService.shared.deleteExchangeConnection(id: id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Add Connection Sheet

struct AddExchangeConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    let accounts: [APIService.Account]
    let onSaved:  () -> Void

    let exchanges       = ExchangeConnectionsView.supportedExchanges.map { $0.id }
    let exchangeNames   = Dictionary(uniqueKeysWithValues: ExchangeConnectionsView.supportedExchanges.map { ($0.id, $0.displayName) })
    let needsPassphrase = Set(["kucoin", "okx", "gate", "cryptocom", "bitmart"])

    @State private var selectedExchange  = "binance"
    @State private var connectionName    = "Binance"
    @State private var apiKey            = ""
    @State private var apiSecret         = ""
    @State private var passphrase        = ""
    @State private var selectedAccountID = ""
    @State private var isSaving          = false
    @State private var error:            String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Exchange") {
                    Picker("Exchange", selection: $selectedExchange) {
                        ForEach(exchanges, id: \.self) { id in
                            Text(exchangeNames[id] ?? id.capitalized).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedExchange) { _, e in
                        connectionName = exchangeNames[e] ?? e.capitalized
                    }
                }

                Section("Credentials") {
                    TextField("Label", text: $connectionName)
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    SecureField("API Secret", text: $apiSecret)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    if needsPassphrase.contains(selectedExchange) {
                        let label = selectedExchange == "bitmart" ? "Memo" : "Passphrase"
                        SecureField(label, text: $passphrase)
                            .textInputAutocapitalization(.never)
                    }
                    if selectedExchange == "alpaca" {
                        Picker("Environment", selection: $passphrase) {
                            Text("Live Trading").tag("live")
                            Text("Paper Trading").tag("paper")
                        }
                        .onAppear { if passphrase.isEmpty { passphrase = "live" } }
                    }
                }

                Section {
                    Picker("Linked Account", selection: $selectedAccountID) {
                        Text("None").tag("")
                        ForEach(accounts) { acc in
                            Text("\(acc.name) (\(acc.base_currency))").tag(acc.id)
                        }
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Trades will be imported into this account. Use a read-only API key.")
                }

                if let e = error {
                    Section {
                        Label(e, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundColor(.red)
                    }
                }

                Section {
                    Button { Task { await save() } } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Connect \(exchangeNames[selectedExchange] ?? selectedExchange.capitalized)")
                                    .fontWeight(.semibold)
                                    .foregroundColor(isValid ? .white : .secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(isValid ? Color.accentColor : Color.gray.opacity(0.2))
                    .disabled(!isValid || isSaving)
                }
            }
            .navigationTitle("Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            .onAppear { selectedAccountID = accounts.first?.id ?? "" }
        }
    }

    private var isValid: Bool {
        !connectionName.isEmpty && !apiKey.isEmpty && !apiSecret.isEmpty &&
        (!needsPassphrase.contains(selectedExchange) || !passphrase.isEmpty)
    }

    private func save() async {
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            _ = try await APIService.shared.createExchangeConnection(
                exchange:   selectedExchange,
                name:       connectionName,
                apiKey:     apiKey,
                apiSecret:  apiSecret,
                passphrase: needsPassphrase.contains(selectedExchange) ? passphrase : nil,
                accountID:  selectedAccountID.isEmpty ? nil : selectedAccountID
            )
            onSaved(); dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
