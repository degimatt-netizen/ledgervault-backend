import SwiftUI

struct AddStockView: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @FocusState private var focusedField: Field?
    private enum Field { case amount, price }

    @State private var searchText = ""
    @State private var selectedResult: APIService.StockSearchResult?
    @State private var amountToDeduct: Double?
    @State private var purchasePricePerUnit: Double?
    @State private var selectedBrokerId = ""
    @State private var selectedDeductId = ""
    @State private var note = ""

    @State private var accounts: [APIService.Account] = []
    @State private var isSaving = false
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchResults: [APIService.StockSearchResult] = []
    @State private var rates: APIService.RatesResponse?
    @State private var liveQuote: APIService.StockQuote?
    @State private var lockToLivePrice = true
    @State private var isRefreshingPrice = false
    @State private var priceLastUpdated: Date?
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var accountBalances: [String: Double] = [:]   // account_id -> native balance

    private let liveUpdateIntervalSeconds: TimeInterval = 30
    private let fiatAccountTypes = ["bank", "cash", "stablecoin_wallet", "exchange"]

    private var estimatedShares: Double? {
        guard let amount = amountToDeduct, amount > 0,
              let price = purchasePricePerUnit, price > 0,
              let result = selectedResult,
              let funding = accounts.first(where: { $0.id == selectedDeductId }) else { return nil }
        let quoteAmount = convert(amount: amount, from: funding.base_currency, to: result.quote_currency)
        guard let q = quoteAmount else { return nil }
        return q / price
    }

    // Always use time-based ET detection once we have a live quote.
    // Yahoo Finance's market_state is unreliable (returns "CLOSED" during after-hours
    // and varies by device timezone), so we don't trust it.
    private var resolvedMarketState: String {
        if liveQuote != nil { return timeBasedMarketState() }
        // While still loading, use search result state only for active sessions (PRE/REGULAR/POST)
        let hint = selectedResult?.market_state?.uppercased() ?? ""
        if ["REGULAR", "PRE", "PREPRE", "POST", "POSTPOST"].contains(hint) { return hint }
        return ""   // still loading
    }

    /// Derives market session from current time in Eastern Time (handles DST automatically)
    private func timeBasedMarketState() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let comps = cal.dateComponents([.hour, .minute, .weekday], from: Date())
        let weekday = comps.weekday ?? 1        // 1 = Sun, 7 = Sat
        guard weekday != 1, weekday != 7 else { return "CLOSED" }
        let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        switch mins {
        case 240..<570:   return "PRE"      // 4:00 – 9:30 AM ET
        case 570..<960:   return "REGULAR"  // 9:30 AM – 4:00 PM ET
        case 960..<1200:  return "POST"     // 4:00 – 8:00 PM ET
        default:          return "CLOSED"
        }
    }

    private var marketStateLabel: String {
        switch resolvedMarketState {
        case "REGULAR":            return "Market Open"
        case "PRE", "PREPRE":     return "Pre-Market"
        case "POST", "POSTPOST":  return "After Hours"
        case "CLOSED":             return "Market Closed"
        default:                   return "Checking market…"
        }
    }

    private var marketStateIcon: String {
        switch resolvedMarketState {
        case "REGULAR":            return "circle.fill"
        case "PRE", "PREPRE":     return "sunrise.fill"
        case "POST", "POSTPOST":  return "moon.fill"
        case "CLOSED":             return "xmark.circle"
        default:                   return "ellipsis"
        }
    }

    private var marketStateColor: Color {
        switch resolvedMarketState {
        case "REGULAR":            return .green
        case "PRE", "PREPRE":     return .orange
        case "POST", "POSTPOST":  return .blue
        case "CLOSED":             return .secondary
        default:                   return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            Form {

                // ── Search ────────────────────────────────────────────────
                Section("Search Stocks & ETFs") {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Symbol or company (AAPL, Tesla…)", text: $searchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
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
                            Button { selectResult(result) } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)).frame(width: 36, height: 36)
                                        AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(result.symbol)?format=jpg")) { phase in
                                            switch phase {
                                            case .success(let img):
                                                img.resizable().scaledToFill()
                                                    .frame(width: 28, height: 28)
                                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                            default:
                                                Text(String(result.symbol.prefix(3)))
                                                    .font(.caption2.bold()).foregroundColor(.green)
                                            }
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(result.symbol).font(.headline).foregroundColor(.primary)
                                            if let exch = result.exchange, !exch.isEmpty {
                                                Text(exch)
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(Color.blue.opacity(0.12))
                                                    .foregroundColor(.blue)
                                                    .clipShape(Capsule())
                                            }
                                            if let type = result.type {
                                                Text(type)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(Color.gray.opacity(0.12))
                                                    .foregroundColor(.secondary)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(result.name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let price = result.price_usd {
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text("$\(price.formatted(.number.precision(.fractionLength(2))))")
                                                .font(.subheadline.bold()).foregroundColor(.primary)
                                            if let chg = result.change_pct {
                                                Text((chg >= 0 ? "+" : "") + "\(chg.formatted(.number.precision(.fractionLength(2))))%")
                                                    .font(.caption2.bold())
                                                    .foregroundColor(chg >= 0 ? .green : .red)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Selected stock ────────────────────────────────────────
                if let result = selectedResult {
                    Section {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)).frame(width: 44, height: 44)
                                AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(result.symbol)?format=jpg")) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                            .frame(width: 36, height: 36)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    default:
                                        Text(String(result.symbol.prefix(3)))
                                            .font(.caption.bold()).foregroundColor(.green)
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.symbol).font(.title3.bold())
                                Text(result.name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let exch = result.exchange, !exch.isEmpty {
                                        Label(exch, systemImage: "building.2.fill")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.1))
                                            .foregroundColor(.blue)
                                            .clipShape(Capsule())
                                    }
                                    Label(marketStateLabel, systemImage: marketStateIcon)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(marketStateColor.opacity(0.1))
                                        .foregroundColor(marketStateColor)
                                        .clipShape(Capsule())
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                            Spacer()
                            Button {
                                selectedResult = nil
                                liveQuote = nil
                                searchText = ""
                                purchasePricePerUnit = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                        }

                        if let quote = liveQuote {
                            HStack {
                                Label("LIVE PRICE", systemImage: "circle.fill")
                                    .font(.caption.bold()).foregroundColor(.green)
                                    .labelStyle(.titleAndIcon)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("$\(quote.price.formatted(.number.precision(.fractionLength(2))))")
                                        .font(.title3.bold())
                                    Text((quote.change_pct >= 0 ? "+" : "") + "\(quote.change_pct.formatted(.number.precision(.fractionLength(2))))% today")
                                        .font(.caption.bold())
                                        .foregroundColor(quote.change_pct >= 0 ? .green : .red)
                                }
                            }
                        } else {
                            HStack {
                                Text("Loading live price…").foregroundColor(.secondary).font(.caption)
                                Spacer()
                                ProgressView().scaleEffect(0.7)
                            }
                        }

                        if let updated = priceLastUpdated {
                            Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } header: { Text("Selected Stock") }
                }

                // ── Buy details ───────────────────────────────────────────
                if selectedResult != nil {
                    Section("Buy Details") {
                        HStack(spacing: 4) {
                            Text(deductCurrencySymbol)
                                .foregroundColor(.secondary)
                                .font(.body)
                            TextField("Amount to deduct", value: $amountToDeduct, format: .number.precision(.fractionLength(2)))
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .amount)
                        }

                        TextField("Price per share (USD)", value: $purchasePricePerUnit, format: .number.precision(.fractionLength(2)))
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

                        if let shares = estimatedShares {
                            HStack {
                                Text("Estimated shares")
                                Spacer()
                                Text(shares.formatted(.number.precision(.fractionLength(0...4))))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Picker("Broker", selection: $selectedBrokerId) {
                            ForEach(accounts.filter { $0.account_type == "broker" }) { acc in
                                Text(acc.name).tag(acc.id)
                            }
                        }

                        Picker("Deduct from", selection: $selectedDeductId) {
                            ForEach(accounts.filter { fiatAccountTypes.contains($0.account_type) }) { acc in
                                let bal = accountBalances[acc.id] ?? 0
                                Text("\(acc.name) — \(bal.formatted(.number.precision(.fractionLength(2)))) \(acc.base_currency)").tag(acc.id)
                            }
                        }

                        // Balance warning
                        if let amount = amountToDeduct, amount > 0,
                           let bal = accountBalances[selectedDeductId], bal < amount {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Insufficient balance (\(bal.formatted(.number.precision(.fractionLength(2)))) available)")
                                    .font(.caption)
                                    .foregroundColor(.orange)
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Buy Stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(isSaving || selectedResult == nil || amountToDeduct == nil || purchasePricePerUnit == nil || selectedBrokerId.isEmpty || selectedDeductId.isEmpty)
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
        guard q.count >= 1 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { isSearching = true }
            do {
                let results = try await APIService.shared.searchStocks(query: q)
                await MainActor.run { searchResults = results; isSearching = false }
            } catch {
                await MainActor.run { isSearching = false }
            }
        }
    }

    private func selectResult(_ result: APIService.StockSearchResult) {
        selectedResult = result
        searchText = result.symbol
        searchResults = []
        Task { await refreshPrice() }
    }

    // MARK: - Price refresh

    private func refreshPrice() async {
        guard !isRefreshingPrice, let result = selectedResult else { return }
        isRefreshingPrice = true
        defer { isRefreshingPrice = false }
        do {
            async let quoteFetch = APIService.shared.fetchStockQuote(symbol: result.symbol)
            async let ratesFetch = APIService.shared.fetchRates()
            let (quote, newRates) = try await (quoteFetch, ratesFetch)
            liveQuote = quote
            rates = newRates
            priceLastUpdated = Date()
            if lockToLivePrice { purchasePricePerUnit = quote.price }
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

            // Compute fiat balances from transaction legs (accurate for bank/stablecoin/exchange)
            for acc in accounts where fiatAccountTypes.contains(acc.account_type) {
                let bal = allLegs.filter { $0.account_id == acc.id }.reduce(0.0) { $0 + $1.quantity }
                accountBalances[acc.id] = bal
            }

            if let b = accounts.first(where: { $0.account_type == "broker" }) { selectedBrokerId = b.id }
            if let f = accounts.first(where: { fiatAccountTypes.contains($0.account_type) }) { selectedDeductId = f.id }
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

            // Balance check (native currency)
            let availableBalance = accountBalances[selectedDeductId] ?? 0
            guard availableBalance >= amount else {
                throw NSError(domain: "Balance", code: 0, userInfo: [NSLocalizedDescriptionKey: "Insufficient funds. Available: \(availableBalance.formatted(.number.precision(.fractionLength(2)))) \(funding.base_currency)"])
            }

            guard let quoteAmount = convert(amount: amount, from: funding.base_currency, to: result.quote_currency)
            else { throw NSError(domain:"FX",code:0,userInfo:[NSLocalizedDescriptionKey:"FX rate missing. Try again."]) }

            let quantity = quoteAmount / price

            let asset = try await APIService.shared.createAsset(
                symbol: result.symbol,
                name: result.name,
                assetClass: result.asset_class,
                quoteCurrency: result.quote_currency
            )

            let legs: [APIService.TransactionLegCreate] = [
                .init(account_id: selectedDeductId, asset_id: "", quantity: -amount, unit_price: nil, fee_flag: false),
                .init(account_id: selectedBrokerId, asset_id: asset.id, quantity: quantity, unit_price: price, fee_flag: false)
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
