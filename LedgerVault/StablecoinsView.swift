import SwiftUI

struct StablecoinsView: View {
    @State private var accounts: [APIService.Account] = []
    @State private var showAdd = false
    @State private var editingAccount: APIService.Account?
    @State private var errorMessage: String?

    var stableWallets: [APIService.Account] {
        accounts.filter { $0.account_type == "cash" }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(stableWallets) { wallet in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(wallet.name)
                            .font(.headline)
                        Text("Stablecoin Wallet")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .swipeActions {
                        Button {
                            editingAccount = wallet
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)

                        Button(role: .destructive) {
                            Task { await deleteAccount(wallet) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("StableCoins")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                AddAccountView(onSaved: { Task { await load() } }, defaultType: "cash")
            }
            .sheet(item: $editingAccount) { account in
                EditAccountView(account: account) { Task { await load() } }
            }
            
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
                    .frame(maxWidth: .infinity)
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
