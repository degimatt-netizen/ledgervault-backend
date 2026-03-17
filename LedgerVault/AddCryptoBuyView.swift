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

    private let liveUpdateIntervalSeconds: TimeInterval = 15

    private var estimatedUnits: Double? {
        guard let amount = amountToDeduct, amount > 0,
              let price = purchasePricePerUnit, price > 0,
              let result = selectedResult,
              let funding = accounts.first(where: { $0.id == selectedDeductId }) else { return nil }
        let quoteAmount = convert(amount: amount, from: funding.base_currency, to: result.quote_currency)
        guard let q = quoteAmount else { return nil }
        return q / price
    }

    var body: some View {
        NavigationStack {
            Form {

                // ── Search ────────────────────────────────────────────────
                Section("Search Crypto") {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Symbol or name (BTC, Ethereum…)", text: $searchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: searchText) { _, new in triggerSearch(new) }
                    }
                    if isSearching {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Searching…").foregroundColor(.secondary).font(.caption)
                        }
                    }
                }

                // ── Results ───────────────────────────────────────────────
                if !searchResults.isEmpty && selectedResult == nil {
                    Section("Results") {
                        ForEach(searchResults) { result in
                            Button {
                                selectResult(result)
                            } label: {
                                HStack(spacing: 12) {
                                    // Coin icon placeholder
                                    ZStack {
                                        Circle().fill(Color.orange.opacity(0.15)).frame(width: 36, height: 36)
                                        Text(String(result.symbol.prefix(2)))
                                            .font(.caption.bold()).foregroundColor(.orange)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.symbol).font(.headline).foregroundColor(.primary)
                                        Text(result.name).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if let price = result.price_usd {
                                            Text("$\(price.formatted(.number.precision(.fractionLength(2))))")
                                                .font(.subheadline.bold()).foregroundColor(.primary)
                                        }
                                        if let rank = result.market_cap_rank {
                                            Text("Rank #\(rank)").font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Selected asset ────────────────────────────────────────
                if let result = selectedResult {
                    Section {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(Color.orange.opacity(0.15)).frame(width: 44, height: 44)
                                Text(String(result.symbol.prefix(2)))
                                    .font(.subheadline.bold()).foregroundColor(.orange)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.symbol).font(.title3.bold())
                                Text(result.name).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                selectedResult = nil
                                selectedAsset = nil
                                searchText = ""
                                purchasePricePerUnit = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Label("LIVE PRICE", systemImage: "circle.fill")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                                .labelStyle(.titleAndIcon)
                            Spacer()
                            if let price = result.price_usd {
                                Text("$\(price.formatted(.number.precision(.fractionLength(4))))")
                                    .font(.title3.bold())
                            } else {
                                Text("Loading…").foregroundColor(.secondary)
                            }
                        }

                        if let updated = priceLastUpdated {
                            Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } header: { Text("Selected Asset") }
                }

                // ── Buy details ───────────────────────────────────────────
                if selectedResult != nil {
                    Section("Buy Details") {
                        TextField("Amount to deduct", value: $amountToDeduct, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .amount)

                        TextField("Price per coin (quote currency)", value: $purchasePricePerUnit, format: .number.precision(.fractionLength(4)))
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .price)
                            .disabled(lockToLivePrice)

                        Toggle("Lock to live price", isOn: $lockToLivePrice)

                        HStack {
                            Button(isRefreshingPrice ? "Refreshing…" : "Refresh Price") {
                                Task { await refreshPrice() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRefreshingPrice)
                            Spacer()
                            if let updated = priceLastUpdated {
                                Text(updated.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }

                        if let units = estimatedUnits {
                            HStack {
                                Text("Estimated units")
                                Spacer()
                                Text(units.formatted(.number.precision(.fractionLength(0...8))))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Picker("Crypto Wallet", selection: $selectedPlatformId) {
                            ForEach(accounts.filter { $0.account_type == "crypto_wallet" }) { acc in
                                Text(acc.name).tag(acc.id)
                            }
                        }

                        Picker("Deduct from", selection: $selectedDeductId) {
                            ForEach(accounts.filter { ["bank","cash","stablecoin_wallet"].contains($0.account_type) }) { acc in
                                Text("\(acc.name) (\(acc.base_currency))").tag(acc.id)
                            }
                        }

                        if let fxLine = fxInfoLine { Text(fxLine).font(.caption).foregroundColor(.secondary) }
                    }

                    Section("Note (optional)") {
                        TextField("Any notes…", text: $note)
                    }
                }

                if let err = errorMessage {
                    Section { Text(err).foregroundColor(.red) }
                }
            }
            .navigationTitle("Buy Crypto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(isSaving || selectedResult == nil || amountToDeduct == nil || purchasePricePerUnit == nil || selectedPlatformId.isEmpty || selectedDeductId.isEmpty)
                }
                ToolbarItem(placement: .keyboard) {
                    HStack { Spacer(); Button("Done") { focusedField = nil }.font(.body.bold()) }
                }
            }
            .task { await loadAccounts() }
            .task { await startLivePriceLoop() }
            .onChange(of: lockToLivePrice) { _, newValue in
                if newValue { Task { await refreshPrice() } }
            }
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
                // Update the result's price in place
                if var updated = selectedResult {
                    searchResults = []
                }
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
            accounts = try await APIService.shared.fetchAccounts()
            rates = try? await APIService.shared.fetchRates()
            if let first = accounts.first(where: { ["bank","cash","stablecoin_wallet"].contains($0.account_type) }) { selectedDeductId = first.id }
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

    // MARK: - FX helpers

    private func convert(amount: Double, from: String, to: String) -> Double? {
        let f = from.uppercased(), t = to.uppercased()
        if f == t { return amount }
        guard let rates else { return nil }
        let fx = rates.fx_to_usd
        guard let fRate = fx[f], let tRate = fx[t], fRate > 0, tRate > 0 else { return nil }
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
