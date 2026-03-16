import SwiftUI

// Presented as a SHEET from BanksView and StablecoinsView.
struct BankDetailView: View {
    let account: APIService.Account
    let onDeleted: () -> Void

    @AppStorage("baseCurrency") private var baseCurrency = "EUR"
    @Environment(\.dismiss) private var dismiss

    @State private var balance: Double = 0
    @State private var transactions: [APIService.TransactionEvent] = []
    @State private var isLoading = true
    @State private var showDeleteAlert = false
    @State private var showEdit = false
    @State private var errorMessage: String?

    private var accountIcon: String {
        switch account.account_type {
        case "bank": return "building.columns.fill"
        default: return "link.circle.fill"
        }
    }

    private var accountColor: Color {
        switch account.account_type {
        case "bank": return .blue
        default: return .indigo
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundColor(.red)
                        Text(err).multilineTextAlignment(.center).foregroundColor(.secondary)
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 16) {

                            // ── Balance card ──────────────────────────────
                            VStack(spacing: 8) {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(accountColor.opacity(0.15))
                                            .frame(width: 52, height: 52)
                                        Image(systemName: accountIcon)
                                            .font(.title3)
                                            .foregroundColor(accountColor)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.name).font(.title3.bold())
                                        Text(account.account_type == "bank" ? "Bank Account" : "Stablecoin Wallet")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(account.base_currency)
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(accountColor.opacity(0.12))
                                        .foregroundColor(accountColor)
                                        .clipShape(Capsule())
                                }

                                Divider()

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Current Balance")
                                            .font(.caption).foregroundColor(.secondary)
                                        Text(fmt(balance))
                                            .font(.title2.bold())
                                            .foregroundColor(accountColor)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("Transactions")
                                            .font(.caption).foregroundColor(.secondary)
                                        Text("\(transactions.count)")
                                            .font(.title2.bold())
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color(.systemBackground))
                            .cornerRadius(20)
                            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)

                            // ── Transactions ──────────────────────────────
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Transactions")
                                    .font(.headline)
                                    .padding(.bottom, 12)

                                if transactions.isEmpty {
                                    VStack(spacing: 12) {
                                        Image(systemName: "tray")
                                            .font(.system(size: 40))
                                            .foregroundColor(.secondary.opacity(0.4))
                                        Text("No transactions yet")
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 32)
                                } else {
                                    ForEach(Array(transactions.enumerated()), id: \.element.id) { idx, tx in
                                        txRow(tx)
                                        if idx < transactions.count - 1 {
                                            Divider().padding(.leading, 54)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color(.systemGray6))
                            .cornerRadius(20)
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showEdit = true } label: {
                            Image(systemName: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red)
                        }
                    }
                }
            }
            .alert("Delete \(account.name)?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    Task {
                        try? await APIService.shared.deleteAccount(id: account.id)
                        onDeleted()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete this account and all its data.")
            }
            .sheet(isPresented: $showEdit) {
                EditAccountView(account: account, onSaved: {
                    Task { await load() }
                })
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func txRow(_ tx: APIService.TransactionEvent) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(eventColor(tx.event_type).opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: eventIcon(tx.event_type))
                    .foregroundColor(eventColor(tx.event_type))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.description ?? tx.event_type.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(tx.event_type.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(eventColor(tx.event_type).opacity(0.12))
                        .foregroundColor(eventColor(tx.event_type))
                        .cornerRadius(6)
                    if let cat = tx.category {
                        Text(cat).font(.caption).foregroundColor(.secondary)
                    }
                    Text("·").font(.caption2).foregroundColor(.secondary)
                    Text(tx.date).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let valFetch = APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            async let txFetch  = APIService.shared.fetchTransactionEvents()

            let (val, allTx) = try await (valFetch, txFetch)

            // Balance = sum of portfolio holdings for this account
            balance = val.portfolio
                .filter { $0.account_id == account.id }
                .reduce(0) { $0 + $1.value_in_base }

            transactions = allTx
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fmt(_ v: Double) -> String {
        switch account.base_currency.uppercased() {
        case "USD": return "$\(v.formatted(.number.precision(.fractionLength(2))))"
        case "GBP": return "£\(v.formatted(.number.precision(.fractionLength(2))))"
        case "EUR": return "€\(v.formatted(.number.precision(.fractionLength(2))))"
        default:    return "\(account.base_currency) \(v.formatted(.number.precision(.fractionLength(2))))"
        }
    }

    private func eventIcon(_ t: String) -> String {
        switch t.lowercased() {
        case "income":   return "arrow.down.circle.fill"
        case "expense":  return "arrow.up.circle.fill"
        case "transfer": return "arrow.left.arrow.right.circle.fill"
        case "trade":    return "chart.line.uptrend.xyaxis.circle.fill"
        default:         return "circle.fill"
        }
    }

    private func eventColor(_ t: String) -> Color {
        switch t.lowercased() {
        case "income":  return .green
        case "expense": return .red
        case "trade":   return .orange
        default:        return .blue
        }
    }
}
