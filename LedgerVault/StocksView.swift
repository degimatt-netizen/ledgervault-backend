import SwiftUI

// ── BrokerDetailView ──────────────────────────────────────────────────────────
struct BrokerDetailView: View {
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
                    List(items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.symbol).font(.headline)
                                Text("\(item.quantity.formatted(.number.precision(.fractionLength(0...4)))) shares")
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
            .alert("Delete \(account.name)?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    Task {
                        try? await APIService.shared.deleteAccount(id: account.id)
                        onDeleted()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This will permanently delete this broker account and all its holdings.") }
            .sheet(isPresented: $showEdit) {
                EditAccountView(account: account, onSaved: {})
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true; errorMessage = nil; defer { isLoading = false }
        do {
            let val = try await APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            items = val.portfolio.filter { $0.account_id == account.id }
        } catch { errorMessage = error.localizedDescription }
    }
}

// ── StocksView ────────────────────────────────────────────────────────────────
struct StocksView: View {
    @State private var accounts: [APIService.Account] = []
    @State private var showAdd = false
    @State private var showAddStock = false
    @State private var selectedAccount: APIService.Account?
    @State private var errorMessage: String?

    var brokers: [APIService.Account] {
        accounts.filter { $0.account_type == "broker" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 16) {
                    ForEach(brokers) { broker in
                        Button { selectedAccount = broker } label: {
                            VStack(alignment: .leading) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.title2).foregroundColor(.green)
                                Text(broker.name).font(.headline)
                                Text("Broker").font(.caption).foregroundColor(.secondary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemBackground))
                            .cornerRadius(20)
                            .shadow(radius: 5)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { Task { await deleteAccount(broker) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding()
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
            .task { await load() }
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
        do { accounts = try await APIService.shared.fetchAccounts(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func deleteAccount(_ account: APIService.Account) async {
        do { try await APIService.shared.deleteAccount(id: account.id); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}
