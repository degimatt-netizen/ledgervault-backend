import SwiftUI

struct AddStockView: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @FocusState private var focusedField: Field?
    private enum Field { case amount, price }

    @State private var searchText = ""
    @State private var selectedAsset: APIService.Asset?
    @State private var amountToDeduct: Double?
    @State private var purchasePricePerUnit: Double?
    @State private var selectedBrokerId = ""
    @State private var selectedDeductId = ""
    @State private var note = ""

    @State private var accounts: [APIService.Account] = []
    @State private var assets:   [APIService.Asset] = []
    @State private var isSaving = false
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var rates: APIService.RatesResponse?
    @State private var searchResults: [APIService.Asset] = []
    @State private var lockToLivePrice = true
    @State private var autoUpdateLivePrice = true
    @State private var isRefreshingPrice = false
    @State private var priceLastUpdated: Date?
    @State private var searchTask: Task<Void, Never>? = nil

    private let liveUpdateIntervalSeconds: TimeInterval = 15

    private var estimatedShares: Double? {
        guard let amountFunding = amountToDeduct, amountFunding > 0,
              let unitPrice = purchasePricePerUnit, unitPrice > 0,
              let asset = selectedAsset,
              let funding = accounts.first(where: { $0.id == selectedDeductId })
        else { return nil }
        let quoteAmount = convert(amount: amountFunding, from: funding.base_currency, to: asset.quote_currency)
        guard let quoteAmount else { return nil }
        return quoteAmount / unitPrice
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Search ───────────────────────────────────────────────
                Section("Search Stocks") {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("AAPL, TSLA, NVDA, MSFT...", text: $searchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .onChange(of: searchText) { _, newVal in
                                selectedAsset = nil
                                scheduleSearch(newVal)
                            }
                        if isSearching {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                }

                // ── Search Results ───────────────────────────────────────
                if !searchResults.isEmpty && selectedAsset == nil {
                    Section("Results") {
                        ForEach(searchResults) { asset in
                            Button {
                                selectedAsset = asset
                                searchText = asset.symbol
                                searchResults = []
                                focusedField = nil          // ✅ dismiss keyboard
                                Task { await loadLivePrice(for: asset) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(asset.symbol).font(.headline)
                                        Text(asset.name).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(asset.asset_class.uppercased())
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Color.green.opacity(0.12))
                                        .foregroundColor(.green)
                                        .cornerRadius(6)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // ── Selected Asset ───────────────────────────────────────
                if let selected = selectedAsset {
                    Section("Selected Stock") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selected.symbol).font(.title2.bold())
                                Text(selected.name).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                selectedAsset = nil
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Text("LIVE PRICE")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.green)
                            Spacer()
                            if let live = livePriceInQuoteCurrency(for: selected) {
                                Text("$\(live.formatted(.number.precision(.fractionLength(2))))")
                                    .font(.title3.bold())
                            } else {
                                Text("Loading...").foregroundColor(.secondary)
                            }
                        }

                        if let priceLastUpdated {
                            Text("Updated \(priceLastUpdated.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    Section("Buy Details") {
                        TextField("Amount to Deduct", value: $amountToDeduct, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .amount)

                        TextField("Price per Share (USD)", value: $purchasePricePerUnit, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .price)
                            .disabled(lockToLivePrice)

                        Toggle("Lock to live price", isOn: $lockToLivePrice)
                        Toggle("Auto-refresh every 15s", isOn: $autoUpdateLivePrice)

                        HStack {
                            Button(isRefreshingPrice ? "Refreshing..." : "Refresh Now") {
                                Task { await refreshRatesAndMaybePrice(forceUpdatePrice: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRefreshingPrice)
                            Spacer()
                            if let priceLastUpdated {
                                Text(priceLastUpdated.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }

                        if let shares = estimatedShares {
                            HStack {
                                Text("Estimated Shares")
                                Spacer()
                                Text(shares.formatted(.number.precision(.fractionLength(0...4))))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Picker("Broker / Platform", selection: $selectedBrokerId) {
                            ForEach(accounts.filter { $0.account_type == "broker" }) { acc in
                                Text(acc.name).tag(acc.id)
                            }
                        }

                        Picker("Deduct from", selection: $selectedDeductId) {
                            ForEach(accounts.filter { ["bank","cash","stablecoin_wallet"].contains($0.account_type) }) { acc in
                                Text("\(acc.name) (\(acc.base_currency))").tag(acc.id)
                            }
                        }

                        if let fxInfo = fxInfoLine {
                            Text(fxInfo).font(.caption).foregroundColor(.secondary)
                        }
                    }

                    Section("Note (optional)") {
                        TextField("Any additional notes...", text: $note)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Buy Stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") { Task { await save() } }
                        .disabled(isSaving || selectedAsset == nil || amountToDeduct == nil || purchasePricePerUnit == nil || selectedBrokerId.isEmpty || selectedDeductId.isEmpty)
                }
                ToolbarItem(placement: .keyboard) {
                    HStack { Spacer(); Button("Done") { focusedField = nil }.font(.body.bold()) }
                }
            }
            .task { await loadData() }
            .task { await startLivePriceLoop() }
            .onChange(of: lockToLivePrice) { _, newValue in
                if newValue, let asset = selectedAsset { Task { await loadLivePrice(for: asset) } }
            }
        }
    }

    // MARK: - Live Search (debounced 400ms)

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(q)
        }
    }

    private func performSearch(_ q: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await APIService.shared.searchAssets(query: q)
            searchResults = results.filter { ["stock","etf"].contains($0.asset_class.lowercased()) }
        } catch {
            searchResults = []
        }
    }

    // MARK: - Load & Save

    private func loadData() async {
        do {
            async let accs  = APIService.shared.fetchAccounts()
            async let assts = APIService.shared.fetchAssets()
            async let rts   = APIService.shared.fetchRates()
            accounts = try await accs
            assets   = try await assts
            rates    = try? await rts
            if let broker = accounts.first(where: { $0.account_type == "broker" }) {
                selectedBrokerId = broker.id
            }
            if let funding = accounts.first(where: { ["bank","cash","stablecoin_wallet"].contains($0.account_type) }) {
                selectedDeductId = funding.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            guard let amountFunding = amountToDeduct, amountFunding > 0,
                  let unitPrice = purchasePricePerUnit, unitPrice > 0,
                  let asset = selectedAsset,
                  let funding = accounts.first(where: { $0.id == selectedDeductId })
            else { throw makeError("Missing required fields") }

            guard let quoteAmount = convert(amount: amountFunding, from: funding.base_currency, to: asset.quote_currency) else {
                throw makeError("FX rate missing for \(funding.base_currency) → \(asset.quote_currency)")
            }

            let quantity = quoteAmount / unitPrice

            // Look up the fiat asset UUID for the deduct account's currency
            let deductAssetId = assets.first(where: {
                $0.symbol.uppercased() == funding.base_currency.uppercased()
            })?.id

            let legs: [APIService.TransactionLegCreate] = [
                .init(account_id: selectedDeductId, asset_id: deductAssetId, quantity: -amountFunding, unit_price: nil,       fee_flag: false),
                .init(account_id: selectedBrokerId, asset_id: asset.id,      quantity:  quantity,      unit_price: unitPrice, fee_flag: false),
            ]

            _ = try await APIService.shared.createTransactionEvent(
                eventType: "trade", category: nil,
                description: "Bought \(asset.symbol)",
                date: Date().formatted(.iso8601.dateSeparator(.dash).year().month().day()),
                note: note.isEmpty ? nil : note, legs: legs
            )
            onSaved(); dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Price Helpers

    private func livePriceInQuoteCurrency(for asset: APIService.Asset) -> Double? {
        guard let rates else { return nil }
        guard let usdPrice = rates.prices[asset.symbol] else { return nil }
        if asset.quote_currency.uppercased() == "USD" { return usdPrice }
        guard let quoteToUsd = rates.fx_to_usd[asset.quote_currency.uppercased()], quoteToUsd > 0 else { return nil }
        return usdPrice / quoteToUsd
    }

    private func convert(amount: Double, from: String, to: String) -> Double? {
        let fromC = from.uppercased(); let toC = to.uppercased()
        if fromC == toC { return amount }
        guard let rates else { return nil }
        let fx = rates.fx_to_usd
        guard let fromToUsd = fx[fromC], let toToUsd = fx[toC], fromToUsd > 0, toToUsd > 0 else { return nil }
        return amount * (fromToUsd / toToUsd)
    }

    private var fxInfoLine: String? {
        guard let amountFunding = amountToDeduct, amountFunding > 0,
              let asset = selectedAsset,
              let funding = accounts.first(where: { $0.id == selectedDeductId }),
              funding.base_currency.uppercased() != asset.quote_currency.uppercased(),
              let quoteAmount = convert(amount: amountFunding, from: funding.base_currency, to: asset.quote_currency)
        else { return nil }
        return "FX: \(amountFunding.formatted(.number.precision(.fractionLength(2)))) \(funding.base_currency) ≈ \(quoteAmount.formatted(.number.precision(.fractionLength(2)))) \(asset.quote_currency)"
    }

    private func loadLivePrice(for asset: APIService.Asset) async {
        isRefreshingPrice = true
        defer { isRefreshingPrice = false }
        do {
            // ✅ Use dedicated endpoint — bypasses cache, always fresh
            let (priceUSD, fxMap) = try await APIService.shared.fetchSymbolPrice(symbol: asset.symbol)
            // Merge into rates
            if rates == nil {
                rates = APIService.RatesResponse(base_reference: "USD",
                                                  prices: [asset.symbol: priceUSD],
                                                  fx_to_usd: fxMap)
            } else {
                var newPrices = rates!.prices
                newPrices[asset.symbol.uppercased()] = priceUSD
                rates = APIService.RatesResponse(base_reference: "USD",
                                                  prices: newPrices,
                                                  fx_to_usd: fxMap)
            }
            priceLastUpdated = Date()
            if priceUSD > 0 {
                let live = livePriceInQuoteCurrency(for: asset)
                if lockToLivePrice, let l = live { purchasePricePerUnit = l }
            }
        } catch {}
    }

    private func refreshRatesAndMaybePrice(forceUpdatePrice: Bool) async {
        guard !isRefreshingPrice else { return }
        if let asset = selectedAsset {
            await loadLivePrice(for: asset)
        } else {
            isRefreshingPrice = true
            defer { isRefreshingPrice = false }
            do {
                let newRates = try await APIService.shared.fetchRates()
                rates = newRates
                priceLastUpdated = Date()
            } catch {}
        }
    }

    private func startLivePriceLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(liveUpdateIntervalSeconds * 1_000_000_000))
            guard autoUpdateLivePrice, selectedAsset != nil else { continue }
            await refreshRatesAndMaybePrice(forceUpdatePrice: lockToLivePrice)
        }
    }

    private func makeError(_ msg: String) -> Error {
        NSError(domain: "LedgerVault", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
