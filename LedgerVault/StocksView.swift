import SwiftUI

struct StocksView: View {
    @State private var accounts: [APIService.Account] = []
    @State private var showAdd = false
    @State private var showAddStock = false
    @State private var editingAccount: APIService.Account?
    @State private var errorMessage: String?

    var brokers: [APIService.Account] {
        accounts.filter { $0.account_type == "broker" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 16) {
                    ForEach(brokers) { broker in
                        Button {
                            editingAccount = broker
                        } label: {
                            VStack(alignment: .leading) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.title2)
                                    .foregroundColor(.green)
                                Text(broker.name)
                                    .font(.headline)
                                Text("Broker")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemBackground))
                            .cornerRadius(20)
                            .shadow(radius: 5)
                        }
                        .buttonStyle(.plain)   // keeps the clean card look
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await deleteAccount(broker) }
                            } label: {
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
            .sheet(item: $editingAccount) { account in
                EditAccountView(account: account) { Task { await load() } }
            }
        }
    }

    private func load() async {
        do {
            accounts = try await APIService.shared.fetchAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAccount(_ account: APIService.Account) async {
        do {
            try await APIService.shared.deleteAccount(id: account.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
