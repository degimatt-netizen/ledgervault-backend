import SwiftUI

struct BanksView: View {
    @State private var accounts: [APIService.Account] = []
    @State private var showAddAccount = false
    @State private var editingAccount: APIService.Account?
    @State private var errorMessage: String?

    var banks: [APIService.Account] {
        accounts.filter { $0.account_type == "bank" }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(banks) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account.name)
                            .font(.headline)
                        Text(account.base_currency)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .swipeActions {
                        Button {
                            editingAccount = account
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)

                        Button(role: .destructive) {
                            Task { await deleteAccount(account) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Banks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddAccount = true
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showAddAccount) {
                AddAccountView(onSaved: { Task { await load() } }, defaultType: "bank")
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
