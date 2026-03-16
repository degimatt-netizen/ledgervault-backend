import SwiftUI

struct BanksView: View {
    @State private var accounts: [APIService.Account] = []
    @State private var showAddAccount = false
    @State private var selectedAccount: APIService.Account?
    @State private var errorMessage: String?

    var banks: [APIService.Account] {
        accounts.filter { $0.account_type == "bank" }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(banks) { account in
                    Button {
                        selectedAccount = account
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.12))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "building.columns.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 16))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(account.base_currency)
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
