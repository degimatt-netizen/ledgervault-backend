import SwiftUI

// ── BankDetailView ────────────────────────────────────────────────────────────
struct BankDetailView: View {
    let account: APIService.Account
    let onDeleted: () -> Void
    var displayCurrency: String = ""   // "" = use account's native currency

    @AppStorage("baseCurrency") private var baseCurrency = "EUR"
    @Environment(\.dismiss) private var dismiss

    @State private var liveAccount: APIService.Account
    @State private var balance: Double = 0
    @State private var transactions: [APIService.TransactionEvent] = []
    @State private var legs: [APIService.TransactionLeg] = []
    @State private var fxRates: [String: Double] = [:]
    @State private var isLoading = true
    @State private var showDeleteAlert = false
    @State private var showEdit = false
    @State private var errorMessage: String?

    init(account: APIService.Account, onDeleted: @escaping () -> Void, displayCurrency: String = "") {
        self.account = account
        self.onDeleted = onDeleted
        self.displayCurrency = displayCurrency
        _liveAccount = State(initialValue: account)
    }

    private var effectiveCurrency: String {
        displayCurrency.isEmpty ? liveAccount.base_currency : displayCurrency
    }

    private var accountColor: Color { liveAccount.account_type == "bank" ? .blue : .indigo }
    private var accountIcon: String  { liveAccount.account_type == "bank" ? "building.columns.fill" : "link.circle.fill" }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // ── Summary card ──────────────────────────────────
                        Section {
                            VStack(spacing: 14) {
                                VStack(spacing: 2) {
                                    Text("Balance")
                                        .font(.caption).foregroundColor(.secondary)
                                    Text(fmt(balance))
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .foregroundColor(balance >= 0 ? .primary : .red)
                                    if liveAccount.exclude_from_total ?? false {
                                        HStack(spacing: 4) {
                                            Image(systemName: "eye.slash.fill")
                                                .font(.caption2)
                                            Text("Excluded from Net Worth")
                                                .font(.caption2.weight(.medium))
                                        }
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(Color.orange.opacity(0.1))
                                        .clipShape(Capsule())
                                    }
                                }
                                HStack(spacing: 0) {
                                    Spacer()
                                    VStack(spacing: 2) {
                                        Text("Inflow")
                                            .font(.caption2).foregroundColor(.secondary)
                                        let inflow = legs.filter { $0.account_id == liveAccount.id && $0.quantity > 0 && $0.fee_flag != "true" }.reduce(0) { $0 + $1.quantity }
                                        Text(fmt(inflow))
                                            .font(.subheadline.bold()).foregroundColor(.green)
                                    }
                                    Spacer()
                                    Divider().frame(height: 36)
                                    Spacer()
                                    VStack(spacing: 2) {
                                        Text("Outflow")
                                            .font(.caption2).foregroundColor(.secondary)
                                        let outflow = abs(legs.filter { $0.account_id == liveAccount.id && $0.quantity < 0 && $0.fee_flag != "true" }.reduce(0) { $0 + $1.quantity })
                                        Text(fmt(outflow))
                                            .font(.subheadline.bold()).foregroundColor(.red)
                                    }
                                    Spacer()
                                    Divider().frame(height: 36)
                                    Spacer()
                                    VStack(spacing: 2) {
                                        Text("Transactions")
                                            .font(.caption2).foregroundColor(.secondary)
                                        Text("\(transactions.count)")
                                            .font(.subheadline.bold())
                                    }
                                    Spacer()
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))

                        // ── Transaction history ───────────────────────────
                        Section("Transactions") {
                            if transactions.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "tray")
                                        .font(.system(size: 38)).foregroundColor(.secondary.opacity(0.35))
                                    Text("No transactions yet").foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 28)
                            } else {
                                ForEach(transactions) { tx in txRow(tx) }
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
            } message: { Text("This will permanently delete this account and all its transactions.") }
            .sheet(isPresented: $showEdit) {
                EditAccountView(account: liveAccount, onSaved: {
                    Task { await load() }
                })
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func txRow(_ tx: APIService.TransactionEvent) -> some View {
        let amt = txAmount(tx)
        let isIncome  = tx.event_type.lowercased() == "income"
        let isExpense = tx.event_type.lowercased() == "expense"
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(eventColor(tx.event_type).opacity(0.13))
                    .frame(width: 44, height: 44)
                Image(systemName: eventIcon(tx.event_type))
                    .foregroundColor(eventColor(tx.event_type))
                    .font(.system(size: 18))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.description ?? tx.event_type.capitalized)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if let cat = tx.category, !cat.isEmpty {
                        Text(cat)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(eventColor(tx.event_type).opacity(0.10))
                            .foregroundColor(eventColor(tx.event_type))
                            .clipShape(Capsule())
                    }
                    Text(tx.date).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            if amt > 0 {
                Text("\(isIncome ? "+" : isExpense ? "-" : "")\(fmt(amt))")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(isIncome ? .green : isExpense ? .red : .primary)
            }
        }
        .padding(.vertical, 6)
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            let allAccounts = try await APIService.shared.fetchAccounts()
            if let updated = allAccounts.first(where: { $0.id == account.id }) { liveAccount = updated }

            async let txFetch    = APIService.shared.fetchTransactionEvents()
            async let legsFetch  = APIService.shared.fetchTransactionLegs()
            async let ratesFetch = APIService.shared.fetchRates()
            let (allTx, allLegs, rates) = try await (txFetch, legsFetch, ratesFetch)

            var merged: [String: Double] = [:]
            for (k, v) in rates.fx_to_usd { merged[k.uppercased()] = v }
            for (k, v) in rates.prices    { merged[k.uppercased()] = v }
            fxRates = merged

            let accountLegs = allLegs.filter { $0.account_id == liveAccount.id }
            balance = accountLegs.reduce(0) { $0 + $1.quantity }
            let accountEventIds = Set(accountLegs.map { $0.event_id })
            transactions = allTx
                .filter { accountEventIds.contains($0.id) }
                .sorted { $0.date > $1.date }
            legs = allLegs
        } catch { errorMessage = error.localizedDescription }
    }

    private func txAmount(_ tx: APIService.TransactionEvent) -> Double {
        abs(legs.first { $0.event_id == tx.id && $0.account_id == liveAccount.id && $0.fee_flag != "true" }?.quantity ?? 0)
    }

    private func toDisplay(_ amount: Double) -> Double {
        let native  = liveAccount.base_currency.uppercased()
        let display = effectiveCurrency.uppercased()
        guard native != display else { return amount }
        let usdPerNative  = fxRates[native]  ?? 1.0
        let usdPerDisplay = fxRates[display] ?? 1.0
        guard usdPerDisplay > 0 else { return amount }
        return (amount * usdPerNative) / usdPerDisplay
    }

    private func fmt(_ v: Double) -> String {
        let converted = toDisplay(v)
        switch effectiveCurrency.uppercased() {
        case "USD": return "$\(converted.formatted(.number.precision(.fractionLength(2))))"
        case "GBP": return "£\(converted.formatted(.number.precision(.fractionLength(2))))"
        case "EUR": return "€\(converted.formatted(.number.precision(.fractionLength(2))))"
        default:    return "\(effectiveCurrency) \(converted.formatted(.number.precision(.fractionLength(2))))"
        }
    }
    private func eventIcon(_ t: String) -> String {
        switch t.lowercased() {
        case "income":   return "arrow.down.circle.fill"
        case "expense":  return "arrow.up.circle.fill"
        case "transfer": return "arrow.left.arrow.right.circle.fill"
        default:         return "circle.fill"
        }
    }
    private func eventColor(_ t: String) -> Color {
        switch t.lowercased() {
        case "income":  return .green
        case "expense": return .red
        default:        return .blue
        }
    }
}

// ── BanksView ─────────────────────────────────────────────────────────────────
struct BanksView: View {
    @State private var accounts: [APIService.Account] = []
    @State private var legs: [APIService.TransactionLeg] = []
    @State private var showAddAccount = false
    @State private var selectedAccount: APIService.Account?
    @State private var errorMessage: String?
    @State private var orderedBankIds: [String] = []   // custom drag-sort order

    private let orderKey = "banks_account_order"

    var banks: [APIService.Account] {
        let filtered = accounts.filter { $0.account_type == "bank" }
        if orderedBankIds.isEmpty { return filtered }
        let ordered = orderedBankIds.compactMap { id in filtered.first { $0.id == id } }
        let new     = filtered.filter { !orderedBankIds.contains($0.id) }
        return ordered + new
    }

    private func loadOrder() {
        orderedBankIds = (UserDefaults.standard.array(forKey: orderKey) as? [String]) ?? []
    }
    private func saveOrder(_ ids: [String]) {
        orderedBankIds = ids
        UserDefaults.standard.set(ids, forKey: orderKey)
    }
    private func moveAccounts(from source: IndexSet, to destination: Int) {
        var ids = banks.map { $0.id }
        ids.move(fromOffsets: source, toOffset: destination)
        saveOrder(ids)
    }

    // Net balance always in the account's own native currency
    private func accountBalance(for account: APIService.Account) -> Double {
        legs
            .filter { $0.account_id == account.id }
            .reduce(0.0) { $0 + $1.quantity }
    }

    private func txCount(for account: APIService.Account) -> Int {
        Set(legs.filter { $0.account_id == account.id }.map { $0.event_id }).count
    }

    private func fmtBalance(_ v: Double, currency: String) -> String {
        switch currency.uppercased() {
        case "USD": return "$\(v.formatted(.number.precision(.fractionLength(2))))"
        case "GBP": return "£\(v.formatted(.number.precision(.fractionLength(2))))"
        case "EUR": return "€\(v.formatted(.number.precision(.fractionLength(2))))"
        default:    return "\(currency) \(v.formatted(.number.precision(.fractionLength(2))))"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if banks.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "building.columns")
                            .font(.system(size: 60)).foregroundColor(.blue.opacity(0.3))
                        Text("No Bank Accounts").font(.title2.bold())
                        Text("Add a bank account to track your cash and transactions.")
                            .multilineTextAlignment(.center).foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                        Button("Add Bank Account") { showAddAccount = true }
                            .buttonStyle(.borderedProminent).tint(.blue)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(banks) { account in
                            Button { selectedAccount = account } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.blue.opacity(0.12))
                                            .frame(width: 50, height: 50)
                                        Image(systemName: "building.columns.fill")
                                            .foregroundColor(.blue)
                                            .font(.system(size: 22))
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(account.name)
                                                .font(.headline).foregroundColor(.primary)
                                            if account.exclude_from_total ?? false {
                                                Image(systemName: "eye.slash.fill")
                                                    .font(.caption2)
                                                    .foregroundColor(.orange)
                                            }
                                        }
                                        Text("Bank · \(account.base_currency)")
                                            .font(.caption).foregroundColor(.secondary)
                                        let count = txCount(for: account)
                                        if count > 0 {
                                            Text("\(count) transaction\(count == 1 ? "" : "s")")
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        let bal = accountBalance(for: account)
                                        Text(fmtBalance(bal, currency: account.base_currency))
                                            .font(.subheadline.bold())
                                            .foregroundColor(bal >= 0 ? .primary : .red)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await deleteAccount(account) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .onMove(perform: moveAccounts)
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Banks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddAccount = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .task { loadOrder(); await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showAddAccount) {
                AddAccountView(onSaved: { Task { await load() } }, defaultType: "bank")
            }
            .sheet(item: $selectedAccount) { account in
                BankDetailView(account: account, onDeleted: { Task { await load() } })
                    .onDisappear { Task { await load() } }
            }
        }
    }

    private func load() async {
        do {
            async let accFetch  = APIService.shared.fetchAccounts()
            async let legsFetch = APIService.shared.fetchTransactionLegs()
            let (accs, ls) = try await (accFetch, legsFetch)
            accounts = accs
            legs     = ls
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteAccount(_ account: APIService.Account) async {
        do { try await APIService.shared.deleteAccount(id: account.id); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}
