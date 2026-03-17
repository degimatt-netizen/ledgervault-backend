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
                    ContentUnavailableView {
                        Label("No Connections", systemImage: "link.badge.plus")
                    } description: {
                        Text("Connect an exchange to auto-import your trade history.")
                    } actions: {
                        Button("Add Connection") { showAddSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
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

    // MARK: - Helpers

    private func exchangeIcon(_ exchange: String) -> String {
        switch exchange {
        case "binance":  return "bitcoinsign.circle.fill"
        case "kraken":   return "k.circle.fill"
        case "coinbase": return "c.circle.fill"
        case "bybit":    return "triangle.circle.fill"
        case "kucoin":   return "square.circle.fill"
        case "okx":      return "o.circle.fill"
        default:         return "link.circle.fill"
        }
    }

    private func exchangeColor(_ exchange: String) -> Color {
        switch exchange {
        case "binance":  return .yellow
        case "kraken":   return .indigo
        case "coinbase": return .blue
        case "bybit":    return .orange
        case "kucoin":   return .green
        case "okx":      return .teal
        default:         return .gray
        }
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

    let exchanges       = ["binance", "kraken", "coinbase", "bybit", "kucoin", "okx"]
    let needsPassphrase = Set(["kucoin", "okx"])

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
                        ForEach(exchanges, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedExchange) { e in connectionName = e.capitalized }
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
                        SecureField("Passphrase", text: $passphrase)
                            .textInputAutocapitalization(.never)
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
                                Text("Connect \(selectedExchange.capitalized)")
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
