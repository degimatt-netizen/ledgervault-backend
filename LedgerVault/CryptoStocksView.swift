import SwiftUI

// ── CryptoWalletDetailView ────────────────────────────────────────────────────
struct CryptoWalletDetailView: View {
    let account: APIService.Account
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var liveAccount: APIService.Account
    @State private var items: [APIService.ValuationPortfolioItem] = []
    @State private var cryptoImages: [String: String] = [:]
    @State private var isLoading = true
    @State private var showDeleteAlert = false
    @State private var showEdit = false
    @State private var errorMessage: String?

    init(account: APIService.Account, onDeleted: @escaping () -> Void) {
        self.account = account
        self.onDeleted = onDeleted
        _liveAccount = State(initialValue: account)
    }

    private var effectiveCurrency: String { liveAccount.base_currency }

    private func fmtValue(_ v: Double) -> String {
        let sym: String
        switch effectiveCurrency.uppercased() {
        case "USD": sym = "$";    case "GBP": sym = "£";   case "CHF": sym = "CHF "
        case "JPY": sym = "¥";    case "CAD": sym = "C$";  case "AUD": sym = "A$"
        case "PLN": sym = "zł ";  case "SEK": sym = "kr "; case "NOK": sym = "kr "
        case "CZK": sym = "Kč ";  case "EUR": sym = "€"
        default: sym = effectiveCurrency + " "
        }
        return sym + v.formatted(.number.precision(.fractionLength(2)))
    }

    private func fmtPrice(_ p: Double) -> String {
        if p < 0.01 { return "$\(p.formatted(.number.precision(.fractionLength(6))))" }
        if p < 1    { return "$\(p.formatted(.number.precision(.fractionLength(4))))" }
        return "$\(p.formatted(.number.precision(.fractionLength(2))))"
    }

    // ── Portfolio summary ──────────────────────────────────────────────────────
    private var totalValue: Double { items.reduce(0) { $0 + $1.value_in_base } }
    private var totalCost: Double {
        items.reduce(0) { sum, item in
            guard item.price_usd > 0 else { return sum }
            return sum + item.value_in_base * (item.avg_cost / item.price_usd)
        }
    }
    private var totalPL: Double { totalValue - totalCost }
    private var totalPLPct: Double { totalCost > 0 ? (totalPL / totalCost) * 100 : 0 }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading holdings…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundColor(.red)
                        Text(err).multilineTextAlignment(.center).foregroundColor(.secondary)
                        Button("Retry") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }.padding()
                } else if items.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "bitcoinsign.circle")
                            .font(.system(size: 56)).foregroundColor(.orange.opacity(0.35))
                        Text("No Holdings Yet").font(.title2.bold())
                        Text("Use \"Buy Crypto\" to add your first position.")
                            .multilineTextAlignment(.center).foregroundColor(.secondary)
                        Spacer()
                    }.frame(maxWidth: .infinity).padding()
                } else {
                    List {
                        // ── Summary card ──────────────────────────────────
                        Section {
                            VStack(spacing: 14) {
                                VStack(spacing: 2) {
                                    Text("Total Value")
                                        .font(.caption).foregroundColor(.secondary)
                                    Text(fmtValue(totalValue))
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                }
                                HStack(spacing: 0) {
                                    Spacer()
                                    VStack(spacing: 2) {
                                        Text("P&L")
                                            .font(.caption2).foregroundColor(.secondary)
                                        Text((totalPL >= 0 ? "+" : "") + fmtValue(totalPL))
                                            .font(.subheadline.bold())
                                            .foregroundColor(totalPL >= 0 ? .green : .red)
                                        Text((totalPLPct >= 0 ? "+" : "") + "\(totalPLPct.formatted(.number.precision(.fractionLength(2))))%")
                                            .font(.caption2.bold())
                                            .foregroundColor(totalPLPct >= 0 ? .green : .red)
                                    }
                                    Spacer()
                                    Divider().frame(height: 36)
                                    Spacer()
                                    VStack(spacing: 2) {
                                        Text("Invested")
                                            .font(.caption2).foregroundColor(.secondary)
                                        Text(fmtValue(totalCost))
                                            .font(.subheadline.bold())
                                    }
                                    Spacer()
                                    Divider().frame(height: 36)
                                    Spacer()
                                    VStack(spacing: 2) {
                                        Text("Holdings")
                                            .font(.caption2).foregroundColor(.secondary)
                                        Text("\(items.count)")
                                            .font(.subheadline.bold())
                                    }
                                    Spacer()
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))

                        // ── Positions ─────────────────────────────────────
                        Section("Positions") {
                            ForEach(items) { item in
                                holdingRow(item)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(liveAccount.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showEdit = true } label: { Image(systemName: "pencil") }
                        Button(role: .destructive) { showDeleteAlert = true } label: {
                            Image(systemName: "trash").foregroundColor(.red)
                        }
                    }
                }
            }
            .alert("Delete \(liveAccount.name)?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    Task {
                        try? await APIService.shared.deleteAccount(id: account.id)
                        onDeleted()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This will permanently delete this wallet and all its holdings.") }
            .sheet(isPresented: $showEdit) {
                EditAccountView(account: liveAccount, onSaved: { Task { await load() } })
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func holdingRow(_ item: APIService.ValuationPortfolioItem) -> some View {
        let pl = item.avg_cost > 0
            ? ((item.price_usd - item.avg_cost) / item.avg_cost) * 100 : 0.0
        let costInBase = item.price_usd > 0
            ? item.value_in_base * (item.avg_cost / item.price_usd) : 0.0
        let plBase = item.value_in_base - costInBase

        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 46, height: 46)
                if let imgURL = cryptoImages[item.symbol.uppercased()],
                   let url = URL(string: imgURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(width: 34, height: 34).clipShape(Circle())
                        default:
                            Text(String(item.symbol.prefix(3)))
                                .font(.caption.bold()).foregroundColor(.orange)
                        }
                    }
                } else {
                    Text(String(item.symbol.prefix(3)))
                        .font(.caption.bold()).foregroundColor(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.symbol).font(.headline)
                Text(item.asset_name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Text("\(item.quantity.formatted(.number.precision(.fractionLength(0...8)))) units")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(fmtValue(item.value_in_base))
                    .font(.subheadline.bold())
                HStack(spacing: 4) {
                    Text((plBase >= 0 ? "+" : "") + fmtValue(plBase))
                        .font(.caption.bold())
                        .foregroundColor(pl >= 0 ? .green : .red)
                    Text("(\(pl >= 0 ? "+" : "")\(pl.formatted(.number.precision(.fractionLength(2))))%)")
                        .font(.caption.bold())
                        .foregroundColor(pl >= 0 ? .green : .red)
                }
                if item.avg_cost > 0 {
                    Text("avg \(fmtPrice(item.avg_cost)) · now \(fmtPrice(item.price_usd))")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if costInBase > 0 {
                    Text("invested \(fmtValue(costInBase))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        isLoading = true; errorMessage = nil; defer { isLoading = false }
        do {
            let allAccounts = try await APIService.shared.fetchAccounts()
            if let updated = allAccounts.first(where: { $0.id == account.id }) {
                liveAccount = updated
            }
            let val = try await APIService.shared.fetchValuation(baseCurrency: effectiveCurrency)
            items = val.portfolio.filter { $0.account_id == account.id && $0.quantity > 0.000001 }
            await loadCryptoImages()
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadCryptoImages() async {
        let symbols = Array(Set(items.map { $0.symbol.uppercased() }))
        await withTaskGroup(of: (String, String?).self) { group in
            for symbol in symbols {
                group.addTask {
                    guard let results = try? await APIService.shared.searchCrypto(query: symbol),
                          let match = results.first(where: { $0.symbol.uppercased() == symbol }) ?? results.first
                    else { return (symbol, nil) }
                    let url = match.thumb?.replacingOccurrences(of: "/thumb/", with: "/small/")
                    return (symbol, url)
                }
            }
            for await (symbol, url) in group {
                if let url { cryptoImages[symbol] = url }
            }
        }
    }
}

// ── CryptoStocksView ──────────────────────────────────────────────────────────
struct CryptoStocksView: View {
    @AppStorage("baseCurrency") private var baseCurrency = "EUR"
    @State private var accounts: [APIService.Account] = []
    @State private var valuation: APIService.ValuationResponse?
    @State private var showAdd = false
    @State private var showAddCrypto = false
    @State private var selectedAccount: APIService.Account?
    @State private var errorMessage: String?

    var cryptoWallets: [APIService.Account] {
        accounts.filter { $0.account_type == "crypto_wallet" }
    }

    private func accountValue(for wallet: APIService.Account) -> Double {
        valuation?.portfolio
            .filter { $0.account_id == wallet.id && $0.quantity > 0.000001 }
            .reduce(0) { $0 + $1.value_in_base } ?? 0
    }

    private func holdingCount(for wallet: APIService.Account) -> Int {
        valuation?.portfolio
            .filter { $0.account_id == wallet.id && $0.quantity > 0.000001 }
            .count ?? 0
    }

    private func fmtValue(_ v: Double, currency: String) -> String {
        let sym: String
        switch currency.uppercased() {
        case "USD": sym = "$";    case "GBP": sym = "£";   case "CHF": sym = "CHF "
        case "JPY": sym = "¥";    case "CAD": sym = "C$";  case "AUD": sym = "A$"
        case "PLN": sym = "zł ";  case "SEK": sym = "kr "; case "NOK": sym = "kr "
        case "CZK": sym = "Kč ";  case "EUR": sym = "€"
        default: sym = currency + " "
        }
        return sym + v.formatted(.number.precision(.fractionLength(2)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if cryptoWallets.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "bitcoinsign.circle.fill")
                            .font(.system(size: 60)).foregroundColor(.orange.opacity(0.3))
                        Text("No Crypto Wallets").font(.title2.bold())
                        Text("Add a crypto wallet to start tracking your crypto portfolio.")
                            .multilineTextAlignment(.center).foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                        Button("Add Crypto Wallet") { showAdd = true }
                            .buttonStyle(.borderedProminent).tint(.orange)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(cryptoWallets) { wallet in
                            Button { selectedAccount = wallet } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.orange.opacity(0.12))
                                            .frame(width: 50, height: 50)
                                        Image(systemName: "bitcoinsign.circle.fill")
                                            .foregroundColor(.orange)
                                            .font(.system(size: 22))
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(wallet.name)
                                            .font(.headline).foregroundColor(.primary)
                                        Text("Crypto Wallet · \(wallet.base_currency)")
                                            .font(.caption).foregroundColor(.secondary)
                                        let count = holdingCount(for: wallet)
                                        if count > 0 {
                                            Text("\(count) holding\(count == 1 ? "" : "s")")
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        let value = accountValue(for: wallet)
                                        if value > 0 {
                                            Text(fmtValue(value, currency: baseCurrency))
                                                .font(.subheadline.bold()).foregroundColor(.primary)
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await deleteAccount(wallet) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Crypto")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add Crypto Wallet") { showAdd = true }
                        Button("Buy Crypto") { showAddCrypto = true }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                AddAccountView(onSaved: { Task { await load() } }, defaultType: "crypto_wallet")
            }
            .sheet(isPresented: $showAddCrypto) {
                AddCryptoBuyView(onSaved: { Task { await load() } })
            }
            .sheet(item: $selectedAccount) { account in
                CryptoWalletDetailView(account: account, onDeleted: { Task { await load() } })
            }
        }
    }

    private func load() async {
        do {
            async let accFetch = APIService.shared.fetchAccounts()
            async let valFetch = APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            accounts  = try await accFetch
            valuation = try await valFetch
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteAccount(_ account: APIService.Account) async {
        do { try await APIService.shared.deleteAccount(id: account.id); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}
