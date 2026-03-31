import SwiftUI

struct StablecoinsView: View {
    @AppStorage("baseCurrency") private var baseCurrency = "EUR"
    @State private var accounts: [APIService.Account] = []
    @State private var legs: [APIService.TransactionLeg] = []
    @State private var fxRates: [String: Double] = [:]
    @State private var showAdd = false
    @State private var selectedAccount: APIService.Account?
    @State private var errorMessage: String?
    @State private var orderedIds: [String] = []

    private let orderKey = "stablecoins_account_order"

    var stableWallets: [APIService.Account] {
        let filtered = accounts.filter { ["cash", "stablecoin_wallet"].contains($0.account_type) }
        if orderedIds.isEmpty { return filtered }
        let ordered = orderedIds.compactMap { id in filtered.first { $0.id == id } }
        let new     = filtered.filter { !orderedIds.contains($0.id) }
        return ordered + new
    }

    private func loadOrder() {
        orderedIds = (UserDefaults.standard.array(forKey: orderKey) as? [String]) ?? []
    }
    private func saveOrder(_ ids: [String]) {
        orderedIds = ids
        UserDefaults.standard.set(ids, forKey: orderKey)
    }
    private func moveAccounts(from source: IndexSet, to destination: Int) {
        var ids = stableWallets.map { $0.id }
        ids.move(fromOffsets: source, toOffset: destination)
        saveOrder(ids)
    }

    // Native balance (in the account's own currency — no FX conversion)
    private func accountBalance(for account: APIService.Account) -> Double {
        legs.filter { $0.account_id == account.id }.reduce(0.0) { $0 + $1.quantity }
    }

    private func txCount(for account: APIService.Account) -> Int {
        Set(legs.filter { $0.account_id == account.id }.map { $0.event_id }).count
    }

    private func fmtBalance(_ v: Double, currency: String) -> String {
        fmtCurrency(v, currency: currency)
    }

    var body: some View {
        NavigationStack {
            Group {
                if stableWallets.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "dollarsign.circle")
                            .font(.system(size: 60)).foregroundColor(.indigo.opacity(0.3))
                        Text("No Stablecoin Wallets").font(.title2.bold())
                        Text("Add a stablecoin wallet to track USDT, USDC and other stable assets.")
                            .multilineTextAlignment(.center).foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                        Button("Add Stablecoin Wallet") { showAdd = true }
                            .buttonStyle(.borderedProminent).tint(.indigo)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(stableWallets) { wallet in
                            Button { selectedAccount = wallet } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.indigo.opacity(0.12))
                                            .frame(width: 50, height: 50)
                                        Image(systemName: "dollarsign.circle.fill")
                                            .foregroundColor(.indigo)
                                            .font(.system(size: 22))
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(wallet.name)
                                                .font(.headline).foregroundColor(.primary)
                                            let bal = accountBalance(for: wallet)
                                            if bal < 0 {
                                                Text("OFFSET")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundColor(.red)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(Color.red.opacity(0.12))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text("Stablecoin · \(wallet.base_currency)")
                                            .font(.caption).foregroundColor(.secondary)
                                        let count = txCount(for: wallet)
                                        if count > 0 {
                                            Text("\(count) transaction\(count == 1 ? "" : "s")")
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        let bal = accountBalance(for: wallet)
                                        Text(fmtBalance(bal, currency: wallet.base_currency))
                                            .font(.subheadline.bold())
                                            .foregroundColor(bal >= 0 ? .primary : .red)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await deleteAccount(wallet) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .onMove(perform: moveAccounts)
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Stablecoins")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .task { loadOrder(); await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showAdd) {
                AddAccountView(onSaved: { Task { await load() } }, defaultType: "cash")
            }
            .sheet(item: $selectedAccount) { account in
                BankDetailView(account: account, onDeleted: { Task { await load() } })
                    .onDisappear { Task { await load() } }
            }
        }
    }

    private func load() async {
        do {
            async let accFetch  = APIService.shared.fetchAccounts()
            async let legsFetch = APIService.shared.fetchTransactionLegs()
            async let fxFetch   = APIService.shared.fetchRates()
            let (accs, ls, rates) = try await (accFetch, legsFetch, fxFetch)
            accounts = accs
            legs     = ls
            var merged: [String: Double] = [:]
            for (k, v) in rates.fx_to_usd { merged[k.uppercased()] = v }
            for (k, v) in rates.prices    { merged[k.uppercased()] = v }
            fxRates = merged
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteAccount(_ account: APIService.Account) async {
        do { try await APIService.shared.deleteAccount(id: account.id); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}
