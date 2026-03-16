import SwiftUI

struct CryptoStocksView: View {
    @State private var accounts: [APIService.Account] = []
    @State private var showAdd = false
    @State private var showAddCrypto = false
    @State private var selectedAccount: APIService.Account?
    @State private var errorMessage: String?

    var cryptoWallets: [APIService.Account] {
        accounts.filter { $0.account_type == "crypto_wallet" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 16) {
                    ForEach(cryptoWallets) { wallet in
                        Button {
                            selectedAccount = wallet
                        } label: {
                            VStack(alignment: .leading) {
                                Image(systemName: "bitcoinsign.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.orange)
                                Text(wallet.name)
                                    .font(.headline)
                                Text("Crypto Investment Wallet")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemBackground))
                            .cornerRadius(20)
                            .shadow(radius: 5)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await deleteAccount(wallet) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("CryptoStocks")
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
                CryptoWalletDetailView(account: account, onDeleted: {
                    Task { await load() }
                })
            }
        }
    }

    private func load() async {
        do {
            accounts = try await APIService.shared.fetchAccounts()
            errorMessage = nil
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
