import SwiftUI

// MARK: - Chain metadata
private struct ChainInfo {
    let name: String
    let symbol: String
    let color: Color
    let icon: String      // SF Symbol fallback
    let supportsTokens: Bool
}

private let chains: [ChainInfo] = [
    ChainInfo(name: "Bitcoin",       symbol: "BTC",   color: Color(red:1,green:0.6,blue:0),    icon: "bitcoinsign.circle.fill", supportsTokens: false),
    ChainInfo(name: "Ethereum",      symbol: "ETH",   color: Color(red:0.4,green:0.4,blue:1),  icon: "e.circle.fill",           supportsTokens: true),
    ChainInfo(name: "Tron",          symbol: "TRX",   color: Color(red:1,green:0.2,blue:0.2),  icon: "t.circle.fill",           supportsTokens: true),
    ChainInfo(name: "BNB Chain",     symbol: "BNB",   color: Color(red:1,green:0.8,blue:0),    icon: "b.circle.fill",           supportsTokens: true),
    ChainInfo(name: "Solana",        symbol: "SOL",   color: Color(red:0.6,green:0.3,blue:1),  icon: "s.circle.fill",           supportsTokens: true),
    ChainInfo(name: "Polygon",       symbol: "MATIC", color: Color(red:0.5,green:0.3,blue:0.9),icon: "m.circle.fill",           supportsTokens: true),
    ChainInfo(name: "XRP Ledger",    symbol: "XRP",   color: Color(red:0,green:0.6,blue:1),    icon: "x.circle.fill",           supportsTokens: false),
    ChainInfo(name: "Litecoin",      symbol: "LTC",   color: Color(red:0.7,green:0.7,blue:0.7),icon: "l.circle.fill",           supportsTokens: false),
]

private func chainInfo(_ symbol: String) -> ChainInfo {
    chains.first { $0.symbol == symbol.uppercased() }
    ?? ChainInfo(name: symbol, symbol: symbol, color: .gray, icon: "questionmark.circle.fill", supportsTokens: false)
}

// MARK: - Main View
struct CryptoWalletsView: View {
    @State private var wallets: [APIService.CryptoWallet] = []
    @State private var syncResults: [String: APIService.WalletSyncResponse] = [:]  // wallet_id → result
    @State private var loading = false
    @State private var syncing: Set<String> = []
    @State private var showAdd = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()

                if loading && wallets.isEmpty {
                    ProgressView("Loading wallets…")
                } else if wallets.isEmpty {
                    emptyState
                } else {
                    walletList
                }
            }
            .navigationTitle("Crypto Wallets")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.4))
                    }
                }
            }
            .sheet(isPresented: $showAdd, onDismiss: { Task { await loadWallets() } }) {
                AddWalletSheet()
            }
            .alert("Error", isPresented: .constant(errorMsg != nil), actions: {
                Button("OK") { errorMsg = nil }
            }, message: { Text(errorMsg ?? "") })
            .task { await loadWallets() }
        }
    }

    // MARK: Empty state
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No wallets added yet")
                .font(.title3.weight(.semibold))
            Text("Add your public wallet addresses to track balances across BTC, ETH, TRX, BNB, SOL and more.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showAdd = true
            } label: {
                Label("Add Wallet", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.2, green: 0.8, blue: 0.4))
                    .cornerRadius(14)
            }
        }
        .padding(.top, 60)
    }

    // MARK: Wallet list
    private var walletList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(wallets) { wallet in
                    WalletCard(
                        wallet: wallet,
                        syncResult: syncResults[wallet.id],
                        isSyncing: syncing.contains(wallet.id),
                        onSync: { await syncWallet(wallet) },
                        onDelete: { await deleteWallet(wallet) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable { await loadWallets() }
    }

    // MARK: Actions
    private func loadWallets() async {
        loading = true
        defer { loading = false }
        do {
            wallets = try await APIService.shared.fetchWallets()
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    private func syncWallet(_ wallet: APIService.CryptoWallet) async {
        syncing.insert(wallet.id)
        defer { syncing.remove(wallet.id) }
        do {
            let result = try await APIService.shared.syncWallet(id: wallet.id)
            syncResults[wallet.id] = result
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    private func deleteWallet(_ wallet: APIService.CryptoWallet) async {
        do {
            try await APIService.shared.deleteWallet(id: wallet.id)
            wallets.removeAll { $0.id == wallet.id }
            syncResults.removeValue(forKey: wallet.id)
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}

// MARK: - Wallet Card
private struct WalletCard: View {
    let wallet: APIService.CryptoWallet
    let syncResult: APIService.WalletSyncResponse?
    let isSyncing: Bool
    let onSync: () async -> Void
    let onDelete: () async -> Void

    @State private var showDeleteConfirm = false
    private let info: ChainInfo

    init(wallet: APIService.CryptoWallet, syncResult: APIService.WalletSyncResponse?,
         isSyncing: Bool, onSync: @escaping () async -> Void, onDelete: @escaping () async -> Void) {
        self.wallet = wallet
        self.syncResult = syncResult
        self.isSyncing = isSyncing
        self.onSync = onSync
        self.onDelete = onDelete
        self.info = chainInfo(wallet.chain)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header row ───────────────────────────────────────────────────
            HStack(spacing: 12) {
                // Chain icon circle
                Circle()
                    .fill(info.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(String(wallet.chain.prefix(1)))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(info.color)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(wallet.chain)
                            .font(.system(size: 15, weight: .bold))
                        if let label = wallet.label, !label.isEmpty {
                            Text("· \(label)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(shortAddress(wallet.address))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSyncing {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button {
                        Task { await onSync() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)

            // ── Holdings (after sync) ─────────────────────────────────────────
            if let result = syncResult, !result.holdings.isEmpty {
                Divider().padding(.horizontal, 14)

                VStack(spacing: 0) {
                    ForEach(Array(result.holdings.prefix(10).enumerated()), id: \.offset) { idx, holding in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(holding.symbol)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Text(holding.name.isEmpty ? holding.symbol : holding.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatBalance(holding.balance, symbol: holding.symbol))
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                if holding.value_usd > 0 {
                                    Text(formatUSD(holding.value_usd))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        if idx < result.holdings.prefix(10).count - 1 {
                            Divider().padding(.horizontal, 14)
                        }
                    }

                    if result.total_usd > 0 {
                        Divider().padding(.horizontal, 14)
                        HStack {
                            Text("Total value")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatUSD(result.total_usd))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.4))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            } else if syncResult == nil {
                // Not yet synced
                Button {
                    Task { await onSync() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("Sync to see balances")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 14)
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .contextMenu {
            Button(role: .destructive) {
                Task { await onDelete() }
            } label: {
                Label("Remove Wallet", systemImage: "trash")
            }
        }
    }

    private func shortAddress(_ addr: String) -> String {
        guard addr.count > 12 else { return addr }
        return "\(addr.prefix(8))…\(addr.suffix(6))"
    }

    private func formatBalance(_ val: Double, symbol: String) -> String {
        if val >= 1000 { return String(format: "%.2f %@", val, symbol) }
        if val >= 1    { return String(format: "%.4f %@", val, symbol) }
        return String(format: "%.6f %@", val, symbol)
    }

    private func formatUSD(_ val: Double) -> String {
        if val >= 1000 { return String(format: "$%.0f", val) }
        return String(format: "$%.2f", val)
    }
}

// MARK: - Add Wallet Sheet
struct AddWalletSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedChain = "BTC"
    @State private var address = ""
    @State private var label = ""
    @State private var isAdding = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Chain") {
                    Picker("Blockchain", selection: $selectedChain) {
                        ForEach(chains, id: \.symbol) { c in
                            HStack {
                                Text(c.symbol)
                                    .font(.system(.body, design: .monospaced))
                                Text("· \(c.name)")
                                    .foregroundStyle(.secondary)
                            }
                            .tag(c.symbol)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 120)
                }

                Section {
                    TextField("Public wallet address", text: $address)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Label (optional)", text: $label)
                } header: {
                    Text("Address")
                } footer: {
                    Text("Only your public address is needed — never your private key or seed phrase.")
                        .foregroundStyle(.secondary)
                }

                if let err = errorMsg {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Add Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await addWallet() }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
                }
            }
            .overlay {
                if isAdding {
                    Color.black.opacity(0.1).ignoresSafeArea()
                    ProgressView()
                }
            }
        }
    }

    private func addWallet() async {
        isAdding = true
        defer { isAdding = false }
        let addr = address.trimmingCharacters(in: .whitespaces)
        let lbl  = label.trimmingCharacters(in: .whitespaces)
        do {
            _ = try await APIService.shared.addWallet(
                chain: selectedChain,
                address: addr,
                label: lbl.isEmpty ? nil : lbl
            )
            dismiss()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
