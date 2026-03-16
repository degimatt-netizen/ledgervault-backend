import SwiftUI

// Presented as a SHEET from CryptoStocksView.
// Has its own NavigationStack for title + toolbar. No back button issues possible.
struct CryptoWalletDetailView: View {
    let account: APIService.Account
    let onDeleted: () -> Void

    @AppStorage("baseCurrency") private var baseCurrency = "EUR"
    @Environment(\.dismiss) private var dismiss

    @State private var items: [APIService.ValuationPortfolioItem] = []
    @State private var isLoading = true
    @State private var showDeleteAlert = false
    @State private var showEdit = false
    @State private var errorMessage: String?

    var body: some View {
        // ✅ Own NavigationStack — correct for sheets, gives title + toolbar
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
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if items.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "bitcoinsign.circle")
                            .font(.system(size: 56))
                            .foregroundColor(.orange.opacity(0.35))
                        Text("No Holdings Yet")
                            .font(.title2.bold())
                        Text("Use \"Buy Crypto\" from the CryptoStocks tab\nto add your first position.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    List(items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.symbol).font(.headline)
                                Text("\(item.quantity.formatted(.number.precision(.fractionLength(0...8)))) units")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(item.value_in_base.formatted(.currency(code: baseCurrency)))
                                    .font(.title3.bold())
                                let pl = item.avg_cost > 0
                                    ? ((item.price_usd - item.avg_cost) / item.avg_cost) * 100 : 0.0
                                Text((pl >= 0 ? "+" : "") + pl.formatted(.number.precision(.fractionLength(1))) + "%")
                                    .font(.caption.bold())
                                    .foregroundColor(pl >= 0 ? .green : .red)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Close button on the left (sheet style)
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                // Edit + Delete on the right
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
                Text("This will permanently delete this wallet and all its holdings.")
            }
            .sheet(isPresented: $showEdit) {
                EditAccountView(account: account, onSaved: {})
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let val = try await APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            items = val.portfolio.filter { $0.account_id == account.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
