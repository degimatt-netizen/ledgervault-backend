import SwiftUI

// ── BrokerDetailView ──────────────────────────────────────────────────────────
struct BrokerDetailView: View {
    let account: APIService.Account
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var liveAccount: APIService.Account
    @State private var items: [APIService.ValuationPortfolioItem] = []
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
                        Image(systemName: "chart.bar")
                            .font(.system(size: 56)).foregroundColor(.green.opacity(0.35))
                        Text("No Holdings Yet").font(.title2.bold())
                        Text("Use \"Buy Stock\" to add your first position.")
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
                            .accessibilityLabel("Edit account")
                        Button(role: .destructive) { showDeleteAlert = true } label: {
                            Image(systemName: "trash").foregroundColor(.red)
                        }
                        .accessibilityLabel("Delete account")
                    }
                }
            }
            .alert("Delete \(liveAccount.name)?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await APIService.shared.deleteAccount(id: account.id)
                            onDeleted()
                            dismiss()
                        } catch {
                            hapticError()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This will permanently delete this broker account and all its holdings.") }
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
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 46, height: 46)
                AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(item.symbol)?format=jpg")) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    default:
                        Text(String(item.symbol.prefix(3)))
                            .font(.caption.bold()).foregroundColor(.green)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.symbol).font(.headline)
                Text(item.asset_name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Text("\(item.quantity.formatted(.number.precision(.fractionLength(0...4)))) shares")
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
                    Text("avg $\(item.avg_cost.formatted(.number.precision(.fractionLength(2)))) · now $\(item.price_usd.formatted(.number.precision(.fractionLength(2))))")
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
        } catch { errorMessage = error.localizedDescription }
    }
}

// ── StocksView ────────────────────────────────────────────────────────────────
struct StocksView: View {
    @AppStorage("baseCurrency") private var baseCurrency = "USD"
    @State private var accounts: [APIService.Account] = []
    @State private var valuation: APIService.ValuationResponse?
    @State private var fxRates: [String: Double] = [:]
    @State private var showAdd = false
    @State private var showAddStock = false
    @State private var selectedAccount: APIService.Account?
    @State private var errorMessage: String?
    @State private var orderedIds: [String] = []

    private let orderKey = "stocks_account_order"

    var brokers: [APIService.Account] {
        let filtered = accounts.filter { $0.account_type == "broker" }
        if orderedIds.isEmpty { return filtered }
        let ordered = orderedIds.compactMap { id in filtered.first { $0.id == id } }
        let new     = filtered.filter { !orderedIds.contains($0.id) }
        return ordered + new
    }

    private func loadOrder() {
        orderedIds = (UserDefaults.standard.array(forKey: orderKey) as? [String]) ?? []
    }
    private func saveOrder(_ ids: [String]) {
        orderedIds = ids
        UserDefaults.standard.set(ids, forKey: orderKey)
    }
    private func moveAccounts(from source: IndexSet, to destination: Int) {
        var ids = brokers.map { $0.id }
        ids.move(fromOffsets: source, toOffset: destination)
        saveOrder(ids)
    }

    private func accountValue(for broker: APIService.Account) -> Double {
        valuation?.portfolio
            .filter { $0.account_id == broker.id && $0.quantity > 0.000001 }
            .reduce(0) { $0 + $1.value_in_base } ?? 0
    }

    /// Converts a value already in `baseCurrency` into the account's native currency.
    private func nativeAccountValue(_ valueInBase: Double, for account: APIService.Account) -> Double {
        let base   = baseCurrency.uppercased()
        let target = account.base_currency.uppercased()
        guard base != target else { return valueInBase }
        let usdPerBase   = fxRates[base]   ?? 1.0
        let usdPerTarget = fxRates[target] ?? 1.0
        guard usdPerTarget > 0 else { return valueInBase }
        return (valueInBase * usdPerBase) / usdPerTarget
    }

    private func holdingCount(for broker: APIService.Account) -> Int {
        valuation?.portfolio
            .filter { $0.account_id == broker.id && $0.quantity > 0.000001 }
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
                if brokers.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 60)).foregroundColor(.green.opacity(0.3))
                        Text("No Broker Accounts").font(.title2.bold())
                        Text("Add a broker account to start tracking your stock portfolio.")
                            .multilineTextAlignment(.center).foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                        Button("Add Broker Account") { showAdd = true }
                            .buttonStyle(.borderedProminent).tint(.green)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(brokers) { broker in
                            Button { selectedAccount = broker } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.green.opacity(0.12))
                                            .frame(width: 50, height: 50)
                                        Image(systemName: "chart.bar.fill")
                                            .foregroundColor(.green)
                                            .font(.system(size: 22))
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(broker.name)
                                                .font(.headline).foregroundColor(.primary)
                                            if broker.exclude_from_total ?? false {
                                                Image(systemName: "eye.slash.fill")
                                                    .font(.caption2)
                                                    .foregroundColor(.orange)
                                            }
                                        }
                                        Text("Broker · \(broker.base_currency)")
                                            .font(.caption).foregroundColor(.secondary)
                                        let count = holdingCount(for: broker)
                                        if count > 0 {
                                            Text("\(count) holding\(count == 1 ? "" : "s")")
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        let value = nativeAccountValue(accountValue(for: broker), for: broker)
                                        if value > 0 {
                                            Text(fmtValue(value, currency: broker.base_currency))
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
                                    Task { await deleteAccount(broker) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .onMove(perform: moveAccounts)
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Stocks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add Broker Account") { showAdd = true }
                        Button("Buy Stock") { showAddStock = true }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .task { loadOrder(); await load() }
            .sheet(isPresented: $showAdd) {
                AddAccountView(onSaved: { Task { await load() } }, defaultType: "broker")
            }
            .sheet(isPresented: $showAddStock) {
                AddStockView(onSaved: { Task { await load() } })
            }
            .sheet(item: $selectedAccount) { account in
                BrokerDetailView(account: account, onDeleted: { Task { await load() } })
            }
        }
    }

    private func load() async {
        do {
            async let accFetch = APIService.shared.fetchAccounts()
            async let valFetch = APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            async let fxFetch  = APIService.shared.fetchRates()
            let (accs, val, rates) = try await (accFetch, valFetch, fxFetch)
            accounts  = accs
            valuation = val
            var merged: [String: Double] = [:]
            for (k, v) in rates.fx_to_usd { merged[k.uppercased()] = v }
            for (k, v) in rates.prices    { merged[k.uppercased()] = v }
            fxRates = merged
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteAccount(_ account: APIService.Account) async {
        do { try await APIService.shared.deleteAccount(id: account.id); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}
