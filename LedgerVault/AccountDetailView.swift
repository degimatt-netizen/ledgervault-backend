import SwiftUI

// ── AccountDetailView ─────────────────────────────────────────────────────────
// Shows full transaction history + holdings for any account type.
// Used by Banks, Stablecoins, Stocks, Crypto tap actions.

struct AccountDetailView: View {
    let account: APIService.Account

    @Environment(\.dismiss) private var dismiss
    @AppStorage("baseCurrency") private var baseCurrency = "EUR"

    @State private var transactions: [APIService.TransactionEvent] = []
    @State private var holdings:     [APIService.ValuationPortfolioItem] = []
    @State private var isLoading     = false
    @State private var showEdit      = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?

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
        switch account.account_type {
        case "bank":              return .blue
        case "cash", "stablecoin_wallet": return .indigo
        case "broker":            return .green
        case "crypto_wallet":     return .orange
        default:                  return .secondary
        }
    }

    private var accountIcon: String {
        switch account.account_type {
        case "bank":              return "building.columns.fill"
        case "cash", "stablecoin_wallet": return "link.circle.fill"
        case "broker":            return "chart.bar.fill"
        case "crypto_wallet":     return "bitcoinsign.circle.fill"
        default:                  return "creditcard.fill"
        }
    }

    private var accountLabel: String {
        switch account.account_type {
        case "bank":              return "Bank Account"
        case "cash":              return "Cash Wallet"
        case "stablecoin_wallet": return "Stablecoin Wallet"
        case "broker":            return "Broker Account"
        case "crypto_wallet":     return "Crypto Wallet"
        default:                  return account.account_type.replacingOccurrences(of: "_", with: " ").capitalized
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
            .navigationTitle(account.name)
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
                EditAccountView(account: account) {
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
                Text("This will permanently delete \(account.name) and all associated data.")
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
                    Text(account.name)
                        .font(.title3.bold())
                    Text(accountLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(account.base_currency)
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
            Text("Holdings")
                .font(.headline)
                .padding(.horizontal, 4)

            ForEach(holdings) { item in
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
                Text("Recent Activity")
                    .font(.headline)
                Spacer()
                Text("\(transactions.count) events")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if transactions.isEmpty {
                Text("No transactions yet")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                ForEach(transactions.prefix(20)) { tx in
                    txRow(tx)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(22)
    }

    @ViewBuilder
    private func txRow(_ tx: APIService.TransactionEvent) -> some View {
        HStack(spacing: 14) {
            Image(systemName: iconForEvent(tx.event_type))
                .font(.title3)
                .foregroundColor(colorForEvent(tx.event_type))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(tx.description ?? tx.event_type.capitalized)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(tx.date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let cat = tx.category {
                        Text("·")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(cat)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Text(tx.event_type.capitalized)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(colorForEvent(tx.event_type).opacity(0.12))
                .foregroundColor(colorForEvent(tx.event_type))
                .clipShape(Capsule())
        }
        .padding(.vertical, 6)
    }

    // ── Data loading ──────────────────────────────────────────────────────────
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            // Load both in parallel
            async let txFetch       = APIService.shared.fetchTransactionEvents()
            async let valuationFetch = APIService.shared.fetchValuation(baseCurrency: baseCurrency)

            let (allTx, valuation) = try await (txFetch, valuationFetch)

            // All events (we can't filter server-side; show all for now)
            transactions = allTx

            // Filter portfolio items to this account only
            holdings = valuation.portfolio.filter { $0.account_id == account.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    private func currencyString(_ value: Double) -> String {
        let symbol: String
        switch baseCurrency {
        case "EUR": symbol = "€"
        case "USD": symbol = "$"
        case "GBP": symbol = "£"
        default:    symbol = "\(baseCurrency) "
        }
        return "\(symbol)\(value.formatted(.number.precision(.fractionLength(2))))"
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
