import SwiftUI

// ── AccountDetailView ─────────────────────────────────────────────────────────
// Shows full transaction history + holdings for any account type.
// Used by Banks, Stablecoins, Stocks, Crypto tap actions.

struct AccountDetailView: View {
    let account: APIService.Account

    @Environment(\.dismiss) private var dismiss
    @AppStorage("baseCurrency") private var baseCurrency = "EUR"

    @State private var liveAccount:  APIService.Account
    @State private var transactions: [APIService.TransactionEvent] = []
    @State private var legs:         [APIService.TransactionLeg]   = []
    @State private var holdings:     [APIService.ValuationPortfolioItem] = []
    @State private var isLoading     = false
    @State private var showEdit      = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?
    @State private var txSearch  = ""
    @State private var showAllTx = false

    enum HoldingSort: String, CaseIterable {
        case value = "Value", gain = "Gain %", name = "Name"
    }
    @State private var holdingSort: HoldingSort = .value

    init(account: APIService.Account) {
        self.account = account
        _liveAccount = State(initialValue: account)
    }

    // ── Filtered / sorted data ────────────────────────────────────────────────
    private var filteredTx: [APIService.TransactionEvent] {
        guard !txSearch.isEmpty else { return transactions }
        let q = txSearch.lowercased()
        return transactions.filter {
            ($0.description?.lowercased().contains(q) ?? false) ||
            $0.event_type.lowercased().contains(q) ||
            ($0.category?.lowercased().contains(q) ?? false) ||
            $0.date.contains(q)
        }
    }

    private var displayedTx: [APIService.TransactionEvent] {
        showAllTx || !txSearch.isEmpty ? filteredTx : Array(filteredTx.prefix(20))
    }

    private var sortedHoldings: [APIService.ValuationPortfolioItem] {
        switch holdingSort {
        case .value: return holdings.sorted { $0.value_in_base > $1.value_in_base }
        case .gain:
            return holdings.sorted { a, b in
                let pa = a.avg_cost > 0 ? ((a.price_usd - a.avg_cost) / a.avg_cost) : 0
                let pb = b.avg_cost > 0 ? ((b.price_usd - b.avg_cost) / b.avg_cost) : 0
                return pa > pb
            }
        case .name: return holdings.sorted { $0.symbol < $1.symbol }
        }
    }

    // ── Derived totals ────────────────────────────────────────────────────────
    private var holdingsValue: Double {
        holdings.reduce(0) { $0 + $1.value_in_base }
    }

    private var incomeCount: Int {
        transactions.filter { $0.event_type.lowercased() == "income" }.count
    }

    private var expenseCount: Int {
        transactions.filter { $0.event_type.lowercased() == "expense" }.count
    }

    private var accountColor: Color {
        switch liveAccount.account_type {
        case "bank":              return .blue
        case "cash", "stablecoin_wallet": return .indigo
        case "broker":            return .green
        case "crypto_wallet":     return .orange
        default:                  return .secondary
        }
    }

    private var accountIcon: String {
        switch liveAccount.account_type {
        case "bank":              return "building.columns.fill"
        case "cash", "stablecoin_wallet": return "link.circle.fill"
        case "broker":            return "chart.bar.fill"
        case "crypto_wallet":     return "bitcoinsign.circle.fill"
        default:                  return "creditcard.fill"
        }
    }

    private var accountLabel: String {
        switch liveAccount.account_type {
        case "bank":              return "Bank Account"
        case "cash":              return "Cash Wallet"
        case "stablecoin_wallet": return "Stablecoin Wallet"
        case "broker":            return "Broker Account"
        case "crypto_wallet":     return "Crypto Wallet"
        default:                  return liveAccount.account_type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // ── Body ──────────────────────────────────────────────────────────────────
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // Header card
                    headerCard

                    // Holdings section (stocks/crypto/stablecoin)
                    if !holdings.isEmpty {
                        holdingsSection
                    }


                    // Recent transactions
                    transactionsSection
                }
                .padding()
            }
            .navigationTitle(liveAccount.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showEdit = true
                        } label: {
                            Label("Edit Account", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label("Delete Account", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showEdit) {
                EditAccountView(account: liveAccount) {
                    Task { await load() }
                }
            }
            .alert("Delete Account?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    Task {
                        try? await APIService.shared.deleteAccount(id: account.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \(liveAccount.name) and all associated data.")
            }
        }
    }

    // ── Header card ───────────────────────────────────────────────────────────
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accountColor.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: accountIcon)
                        .font(.title2)
                        .foregroundColor(accountColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(liveAccount.name)
                        .font(.title3.bold())
                    Text(accountLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(liveAccount.base_currency)
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accountColor.opacity(0.12))
                    .foregroundColor(accountColor)
                    .clipShape(Capsule())
            }

            Divider()

            // Summary row
            HStack(spacing: 0) {
                summaryPill(label: "Holdings Value",
                            value: holdingsValue > 0 ? currencyString(holdingsValue) : "—",
                            color: accountColor)
                Divider().frame(height: 36)
                summaryPill(label: "Income txns",
                            value: "\(incomeCount)",
                            color: .green)
                Divider().frame(height: 36)
                summaryPill(label: "Expense txns",
                            value: "\(expenseCount)",
                            color: .red)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(22)
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
    }

    @ViewBuilder
    private func summaryPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // ── Holdings section ──────────────────────────────────────────────────────
    private var holdingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Holdings")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(HoldingSort.allCases, id: \.self) { mode in
                        Button {
                            holdingSort = mode
                        } label: {
                            Label(mode.rawValue,
                                  systemImage: holdingSort == mode ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(holdingSort.rawValue)
                            .font(.caption.bold())
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
                    .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 4)

            ForEach(sortedHoldings) { item in
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(accountColor.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Text(String(item.symbol.prefix(3)))
                            .font(.caption.bold())
                            .foregroundColor(accountColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.symbol)
                            .font(.headline)
                        Text(item.asset_name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(currencyString(item.value_in_base))
                            .font(.headline)
                        let pl = item.avg_cost > 0
                            ? ((item.price_usd - item.avg_cost) / item.avg_cost) * 100
                            : 0.0
                        Text((pl >= 0 ? "+" : "") + pl.formatted(.number.precision(.fractionLength(2))) + "%")
                            .font(.caption.bold())
                            .foregroundColor(pl >= 0 ? .green : .red)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color(.systemBackground))
                .cornerRadius(14)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(22)
    }

    // ── Transactions section ──────────────────────────────────────────────────
    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Text("\(filteredTx.count) event\(filteredTx.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Search transactions…", text: $txSearch)
                    .font(.subheadline)
                if !txSearch.isEmpty {
                    Button { txSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
            .cornerRadius(10)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if filteredTx.isEmpty {
                Text(txSearch.isEmpty ? "No transactions yet" : "No results for \"\(txSearch)\"")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                ForEach(displayedTx) { tx in
                    txRow(tx)
                }

                // Load More / Show Less
                if filteredTx.count > 20 && txSearch.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAllTx.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(showAllTx
                                 ? "Show less"
                                 : "Show all \(filteredTx.count) transactions")
                                .font(.subheadline.bold())
                            Image(systemName: showAllTx ? "chevron.up" : "chevron.down")
                                .font(.caption.bold())
                        }
                        .foregroundColor(accountColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(22)
    }

    @ViewBuilder
    private func txRow(_ tx: APIService.TransactionEvent) -> some View {
        let color  = colorForEvent(tx.event_type)
        let net    = txNetAmount(tx)

        HStack(spacing: 12) {
            // Icon bubble
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: iconForEvent(tx.event_type))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(color)
            }

            // Description + meta
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.description ?? tx.event_type.capitalized)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(shortDate(tx.date))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let cat = tx.category {
                        Text("· \(cat)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Amount — right-aligned, color-coded
            if let net {
                let isPositive = net >= 0
                VStack(alignment: .trailing, spacing: 1) {
                    Text((isPositive ? "+" : "−") +
                         fmtCurrency(abs(net), currency: liveAccount.base_currency))
                        .font(.subheadline.bold())
                        .foregroundColor(isPositive ? .green : .red)
                    Text(tx.event_type.capitalized)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text(tx.event_type.capitalized)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12))
                    .foregroundColor(color)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 6)
    }

    // ── Data loading ──────────────────────────────────────────────────────────
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            async let txFetch       = APIService.shared.fetchTransactionEvents()
            async let legsFetch     = APIService.shared.fetchTransactionLegs()
            async let valuationFetch = APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            async let accFetch      = APIService.shared.fetchAccounts()

            let (allTx, allLegs, valuation, allAccounts) = try await (txFetch, legsFetch, valuationFetch, accFetch)

            // Refresh account data so edits (name, currency, type) are reflected
            if let updated = allAccounts.first(where: { $0.id == account.id }) {
                liveAccount = updated
            }

            transactions = allTx
            legs         = allLegs
            holdings     = valuation.portfolio.filter { $0.account_id == account.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    private func currencyString(_ value: Double) -> String {
        fmtCurrency(value, currency: baseCurrency)
    }

    /// Net amount this account received/sent for a given transaction (non-fee legs only).
    private func txNetAmount(_ tx: APIService.TransactionEvent) -> Double? {
        let relevant = legs.filter {
            $0.event_id  == tx.id &&
            $0.account_id == account.id &&
            $0.fee_flag  != "true"
        }
        guard !relevant.isEmpty else { return nil }
        return relevant.reduce(0) { $0 + $1.quantity * ($1.unit_price ?? 1.0) }
    }

    /// "27 Mar" or "27 Mar 24" for past years.
    private func shortDate(_ iso: String) -> String {
        let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: iso) else { return iso }
        let f = DateFormatter()
        let thisYear = Calendar.current.component(.year, from: Date())
        let txYear   = Calendar.current.component(.year, from: d)
        f.dateFormat = txYear == thisYear ? "d MMM" : "d MMM yy"
        return f.string(from: d)
    }

    private func iconForEvent(_ type: String) -> String {
        switch type.lowercased() {
        case "income":   return "arrow.down.circle.fill"
        case "expense":  return "arrow.up.circle.fill"
        case "transfer": return "arrow.left.arrow.right.circle.fill"
        case "trade":    return "chart.line.uptrend.xyaxis.circle.fill"
        default:         return "circle.fill"
        }
    }

    private func colorForEvent(_ type: String) -> Color {
        switch type.lowercased() {
        case "income":   return .green
        case "expense":  return .red
        case "trade":    return .orange
        default:         return .blue
        }
    }
}
