import SwiftUI

struct AddCryptoBuyView: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @FocusState private var focusedField: Field?
    private enum Field { case amount, price }

    @State private var searchText = ""
    @State private var selectedResult: APIService.CryptoSearchResult?
    @State private var selectedAsset: APIService.Asset?
    @State private var amountToDeduct: Double?
    @State private var purchasePricePerUnit: Double?
    @State private var selectedPlatformId = ""
    @State private var selectedDeductId = ""
    @State private var note = ""

    @State private var accounts: [APIService.Account] = []
    @State private var isSaving = false
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchResults: [APIService.CryptoSearchResult] = []
    @State private var rates: APIService.RatesResponse?
    @State private var lockToLivePrice = true
    @State private var isRefreshingPrice = false
    @State private var priceLastUpdated: Date?
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var accountBalances: [String: Double] = [:]   // account_id -> native balance

    private let liveUpdateIntervalSeconds: TimeInterval = 15
    private let fiatAccountTypes = ["bank", "cash", "stablecoin_wallet", "exchange"]

    private var estimatedUnits: Double? {
        guard let amount = amountToDeduct, amount > 0,
              let price = purchasePricePerUnit, price > 0,
              let result = selectedResult,
              let funding = accounts.first(where: { $0.id == selectedDeductId }) else { return nil }
        let quoteAmount = convert(amount: amount, from: funding.base_currency, to: result.quote_currency)
        guard let q = quoteAmount else { return nil }
        return q / price
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 16) {
                        assetCard
                        accountsCard
                        if (amountToDeduct != nil || !selectedDeductId.isEmpty) { amountCard }
                        if selectedResult != nil { priceCard }
                        if !note.isEmpty || selectedResult != nil { noteCard }
                        if let err = errorMessage {
                            Text(err)
                                .font(.caption).foregroundStyle(.red)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08)).cornerRadius(12)
                        }
                        Spacer().frame(height: 100)
                    }
                    .padding(16)
                }
                saveBanner
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Buy Crypto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }.font(.body.bold())
                }
            }
            .task { await loadAccounts() }
            .task { await startLivePriceLoop() }
            .onChange(of: lockToLivePrice) { _, v in if v { Task { await refreshPrice() } } }
        }
    }

    // MARK: - Asset card

    private var assetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHAT ARE YOU BUYING?")
                .font(.caption.bold()).foregroundStyle(.secondary)

            if let result = selectedResult {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.orange.opacity(0.15))
                            .frame(width: 46, height: 46)
                        if let rawThumb = result.thumb,
                           let url = URL(string: rawThumb.replacingOccurrences(of: "/thumb/", with: "/small/")) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFit()
                                        .frame(width: 38, height: 38).clipShape(Circle())
                                } else {
                                    Text(String(result.symbol.prefix(3))).font(.caption.bold()).foregroundColor(.orange)
                                }
                            }
                        } else {
                            Text(String(result.symbol.prefix(3))).font(.caption.bold()).foregroundColor(.orange)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.symbol).font(.headline.bold())
                        Text(result.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let rank = result.market_cap_rank {
                            Text("Rank #\(rank)").font(.caption2.bold())
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12)).foregroundColor(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    Spacer()
                    Button {
                        selectedResult = nil; selectedAsset = nil; searchText = ""; purchasePricePerUnit = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color(.tertiaryLabel)).font(.title3)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Symbol or name (BTC, Ethereum…)", text: $searchText)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: searchText) { _, new in triggerSearch(new) }
                    if isSearching { ProgressView().scaleEffect(0.8) }
                }
                .padding(11)
                .background(Color(.tertiarySystemFill))
                .cornerRadius(10)

                if !searchResults.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(searchResults.prefix(6).enumerated()), id: \.offset) { idx, r in
                            Button { selectResult(r) } label: {
                                HStack(spacing: 10) {
                                    ZStack {
                                        Circle().fill(Color.orange.opacity(0.12))
                                            .frame(width: 32, height: 32)
                                        if let rawThumb = r.thumb,
                                           let url = URL(string: rawThumb.replacingOccurrences(of: "/thumb/", with: "/small/")) {
                                            AsyncImage(url: url) { phase in
                                                if case .success(let img) = phase {
                                                    img.resizable().scaledToFit()
                                                        .frame(width: 26, height: 26).clipShape(Circle())
                                                } else {
                                                    Text(String(r.symbol.prefix(2))).font(.caption2.bold()).foregroundColor(.orange)
                                                }
                                            }
                                        } else {
                                            Text(String(r.symbol.prefix(2))).font(.caption2.bold()).foregroundColor(.orange)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.symbol).font(.subheadline.bold()).foregroundStyle(.primary)
                                        Text(r.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let price = r.price_usd {
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text("$\(smartNum(price, maxDec: 4))").font(.subheadline.bold()).foregroundStyle(.primary)
                                            if let rank = r.market_cap_rank {
                                                Text("Rank #\(rank)").font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                            }
                            if idx < min(searchResults.count, 6) - 1 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                    .background(Color(.tertiarySystemFill))
                    .cornerRadius(10)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    // MARK: - Accounts card

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ACCOUNTS").font(.caption.bold()).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                // FROM
                VStack(alignment: .leading, spacing: 6) {
                    Text("FROM").font(.caption2.bold()).foregroundStyle(.secondary)
                    Menu {
                        ForEach(accounts.filter { fiatAccountTypes.contains($0.account_type) }) { acc in
                            Button { selectedDeductId = acc.id } label: {
                                let bal = accountBalances[acc.id] ?? 0
                                Label("\(acc.name)  \(ccySymbol(acc.base_currency))\(smartNum(bal))",
                                      systemImage: "building.columns")
                            }
                        }
                    } label: {
                        accountPill(
                            id: selectedDeductId,
                            fallback: "Select account",
                            showBalance: true,
                            walletLabel: "Wallet"
                        )
                    }
                }
                .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                // TO
                VStack(alignment: .leading, spacing: 6) {
                    Text("TO").font(.caption2.bold()).foregroundStyle(.secondary)
                    Menu {
                        ForEach(accounts.filter { $0.account_type == "crypto_wallet" }) { acc in
                            Button { selectedPlatformId = acc.id } label: {
                                Label(acc.name, systemImage: "bitcoinsign.circle.fill")
                            }
                        }
                    } label: {
                        accountPill(
                            id: selectedPlatformId,
                            fallback: "Select wallet",
                            showBalance: false,
                            walletLabel: "Wallet"
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    @ViewBuilder
    private func accountPill(id: String, fallback: String, showBalance: Bool, walletLabel: String) -> some View {
        if let acc = accounts.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(acc.name)
                        .font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                if showBalance {
                    let bal = accountBalances[acc.id] ?? 0
                    Text("\(ccySymbol(acc.base_currency))\(smartNum(bal))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(walletLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill))
            .cornerRadius(10)
        } else {
            HStack {
                Text(fallback).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(.tertiarySystemFill))
            .cornerRadius(10)
        }
    }

    // MARK: - Amount card

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AMOUNT TO INVEST").font(.caption.bold()).foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(deductCurrencySymbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
                TextField("0", value: $amountToDeduct, format: .number)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .amount)
                    .minimumScaleFactor(0.5)
            }

            Divider()

            if let acc = accounts.first(where: { $0.id == selectedDeductId }) {
                let bal = accountBalances[acc.id] ?? 0
                let isInsufficient = (amountToDeduct ?? 0) > bal && (amountToDeduct ?? 0) > 0
                HStack(spacing: 6) {
                    if isInsufficient {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text("Available: \(ccySymbol(acc.base_currency))\(smartNum(bal))")
                        .font(.caption)
                        .foregroundStyle(isInsufficient ? .orange : .secondary)
                }
            }

            if let fxLine = fxInfoLine {
                Text(fxLine).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    // MARK: - Price card

    private var priceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PRICE").font(.caption.bold()).foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lockToLivePrice ? "Live Market Price" : "Manual Price")
                        .font(.subheadline.bold())
                    Text(lockToLivePrice ? "Syncs automatically" : "Enter the price you paid")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $lockToLivePrice).labelsHidden()
            }

            Divider()

            if lockToLivePrice {
                if let price = purchasePricePerUnit, price > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(ccySymbol(selectedResult?.quote_currency ?? "USD"))
                                    .font(.title2).foregroundStyle(.secondary)
                                Text(smartNum(price, maxDec: 6))
                                    .font(.title2.bold())
                            }
                            if let result = selectedResult {
                                Text(result.symbol).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if isRefreshingPrice {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Button { Task { await refreshPrice() } } label: {
                                    Image(systemName: "arrow.clockwise")
                                }.foregroundStyle(.secondary)
                            }
                            if let ts = priceLastUpdated {
                                Text(ts.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.85)
                        Text("Fetching live price…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ccySymbol(selectedResult?.quote_currency ?? "USD"))
                        .font(.title2).foregroundStyle(.secondary)
                    TextField("0", value: $purchasePricePerUnit, format: .number)
                        .font(.title2.bold())
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .price)
                }
            }

            if let units = estimatedUnits, let result = selectedResult {
                Divider()
                HStack {
                    Text("Estimated units").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(smartNum(units, maxDec: 8)) \(result.symbol)").font(.subheadline.bold())
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    // MARK: - Note card

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTE (OPTIONAL)").font(.caption.bold()).foregroundStyle(.secondary)
            TextField("Add a note…", text: $note)
                .font(.subheadline)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    // MARK: - Save banner

    private var saveBanner: some View {
        Button { Task { await save() } } label: {
            Group {
                if isSaving {
                    HStack(spacing: 10) { ProgressView().tint(.white); Text("Saving…") }
                } else {
                    Text("Buy \(selectedResult?.symbol ?? "Crypto")")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canSave ? Color(red: 1, green: 0.55, blue: 0) : Color(.systemFill))
            .cornerRadius(16)
        }
        .disabled(!canSave || isSaving)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(
            Color(.systemGroupedBackground)
                .shadow(color: .black.opacity(0.08), radius: 10, y: -4)
                .ignoresSafeArea()
        )
    }

    private var canSave: Bool {
        selectedResult != nil &&
        (amountToDeduct ?? 0) > 0 &&
        (purchasePricePerUnit ?? 0) > 0 &&
        !selectedPlatformId.isEmpty &&
        !selectedDeductId.isEmpty
    }

    // MARK: - Smart number formatting

    private func smartNum(_ v: Double, maxDec: Int = 2) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 { return String(format: "%.0f", v) }
        var s = String(format: "%.\(maxDec)f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private func ccySymbol(_ code: String) -> String {
        switch code.uppercased() {
        case "USD": return "$"; case "GBP": return "£"; case "EUR": return "€"
        case "CHF": return "Fr"; case "JPY": return "¥"; case "AUD": return "A$"
        case "CAD": return "C$"; case "HKD": return "HK$"; case "AED": return "د.إ"
        default: return code
        }
    }

    // MARK: - Search

    private func triggerSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)   // 400ms debounce
            guard !Task.isCancelled else { return }
            await MainActor.run { isSearching = true }
            do {
                let results = try await APIService.shared.searchCrypto(query: q)
                await MainActor.run { searchResults = results; isSearching = false }
            } catch {
                await MainActor.run { isSearching = false }
            }
        }
    }

    private func selectResult(_ result: APIService.CryptoSearchResult) {
        selectedResult = result
        searchText = result.symbol
        searchResults = []
        if lockToLivePrice, let price = result.price_usd {
            purchasePricePerUnit = price
            priceLastUpdated = Date()
        }
    }

    // MARK: - Price refresh

    private func refreshPrice() async {
        guard !isRefreshingPrice, let result = selectedResult else { return }
        isRefreshingPrice = true
        defer { isRefreshingPrice = false }
        do {
            let newRates = try await APIService.shared.fetchRates()
            rates = newRates
            priceLastUpdated = Date()
            if let price = newRates.prices[result.symbol] {
                if lockToLivePrice { purchasePricePerUnit = price }
                if selectedResult != nil { searchResults = [] }
            }
        } catch {}
    }

    private func startLivePriceLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(liveUpdateIntervalSeconds * 1_000_000_000))
            guard selectedResult != nil else { continue }
            await refreshPrice()
        }
    }

    // MARK: - Data

    private func loadAccounts() async {
        do {
            async let accFetch  = APIService.shared.fetchAccounts()
            async let rateFetch = APIService.shared.fetchRates()
            async let legFetch  = APIService.shared.fetchTransactionLegs()
            let (fetchedAccounts, fetchedRates, allLegs) = try await (accFetch, rateFetch, legFetch)

            accounts = fetchedAccounts
            rates    = fetchedRates

            // Compute fiat balances from transaction legs
            for acc in accounts where fiatAccountTypes.contains(acc.account_type) {
                let bal = allLegs.filter { $0.account_id == acc.id }.reduce(0.0) { $0 + $1.quantity }
                accountBalances[acc.id] = bal
            }

            if let first = accounts.first(where: { fiatAccountTypes.contains($0.account_type) }) { selectedDeductId = first.id }
            if let first = accounts.first(where: { $0.account_type == "crypto_wallet" }) { selectedPlatformId = first.id }
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true; defer { isSaving = false }
        do {
            guard let result = selectedResult,
                  let amount = amountToDeduct, amount > 0,
                  let price = purchasePricePerUnit, price > 0,
                  let funding = accounts.first(where: { $0.id == selectedDeductId })
            else { throw URLError(.badServerResponse) }

            guard let quoteAmount = convert(amount: amount, from: funding.base_currency, to: result.quote_currency)
            else { throw NSError(domain:"FX",code:0,userInfo:[NSLocalizedDescriptionKey:"FX rate missing. Try again."]) }

            let quantity = quoteAmount / price

            // Ensure asset exists in DB
            let asset = try await APIService.shared.createAsset(
                symbol: result.symbol,
                name: result.name,
                assetClass: result.asset_class,
                quoteCurrency: result.quote_currency
            )

            let legs: [APIService.TransactionLegCreate] = [
                .init(account_id: selectedDeductId, asset_id: "", quantity: -amount, unit_price: nil, fee_flag: false),
                .init(account_id: selectedPlatformId, asset_id: asset.id, quantity: quantity, unit_price: price, fee_flag: false)
            ]

            _ = try await APIService.shared.createTransactionEvent(
                eventType: "trade", category: nil,
                description: "Bought \(result.symbol)",
                date: Date().formatted(.iso8601.dateSeparator(.dash).year().month().day()),
                note: note.isEmpty ? nil : note, legs: legs)

            onSaved(); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Currency helpers

    private var deductCurrencySymbol: String {
        guard let acc = accounts.first(where: { $0.id == selectedDeductId }) else { return "€" }
        switch acc.base_currency.uppercased() {
        case "USD": return "$"; case "GBP": return "£"; case "CHF": return "CHF"
        default: return "€"
        }
    }

    // MARK: - FX helpers

    private func convert(amount: Double, from: String, to: String) -> Double? {
        let f = from.uppercased(), t = to.uppercased()
        if f == t { return amount }
        guard let rates else { return nil }
        let fx = rates.fx_to_usd
        guard let fRate = fx[f], let tRate = fx[t], fRate > 0, tRate > 0 else { return nil }
        // fx_to_usd stores "USD per currency unit" (e.g. fx["EUR"] ≈ 1.15 means 1 EUR = $1.15).
        // To convert A→B: multiply by fRate to get USD, divide by tRate to get target currency.
        // e.g. EUR→USD: 100 * (1.15 / 1.0) = $115; USD→EUR: 100 * (1.0 / 1.15) ≈ €87
        return amount * (fRate / tRate)
    }

    private var fxInfoLine: String? {
        guard let amount = amountToDeduct, amount > 0,
              let result = selectedResult,
              let funding = accounts.first(where: { $0.id == selectedDeductId }),
              funding.base_currency.uppercased() != result.quote_currency.uppercased(),
              let converted = convert(amount: amount, from: funding.base_currency, to: result.quote_currency)
        else { return nil }
        return "FX: \(amount.formatted(.number.precision(.fractionLength(2)))) \(funding.base_currency) ≈ \(converted.formatted(.number.precision(.fractionLength(2)))) \(result.quote_currency)"
    }
}
