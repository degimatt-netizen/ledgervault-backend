import SwiftUI

struct StablecoinsView: View {
    @State private var accounts: [APIService.Account] = []
    @State private var showAdd = false
    @State private var selectedAccount: APIService.Account?
    @State private var errorMessage: String?

    var stableWallets: [APIService.Account] {
        accounts.filter { ["cash", "stablecoin_wallet"].contains($0.account_type) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(stableWallets) { wallet in
                    Button {
                        selectedAccount = wallet
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.indigo.opacity(0.12))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "link.circle.fill")
                                    .foregroundColor(.indigo)
                                    .font(.system(size: 16))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(wallet.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("Stablecoin Wallet · \(wallet.base_currency)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
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
            .sheet(item: $selectedAccount) { account in
                BankDetailView(account: account, onDeleted: {
                    Task { await load() }
                })
                .onDisappear { Task { await load() } }
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
