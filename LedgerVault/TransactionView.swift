import SwiftUI

// ── TransactionDetailView ─────────────────────────────────────────────────────
struct TransactionDetailView: View {
    let tx: APIService.TransactionEvent
    let accounts: [APIService.Account]
    let assets: [APIService.Asset]
    let legs: [APIService.TransactionLeg]
    let cryptoImages: [String: String]
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAlert = false
    @State private var isDeleting = false

    private var txLegs: [APIService.TransactionLeg] {
        legs.filter { $0.event_id == tx.id && $0.fee_flag != "true" }
    }

    private var isTrade: Bool { tx.event_type.lowercased() == "trade" }
    private var isIncome: Bool { tx.event_type.lowercased() == "income" }
    private var isExpense: Bool { tx.event_type.lowercased() == "expense" }

    private var tradeAssetLeg: APIService.TransactionLeg? {
        txLegs.first(where: { $0.quantity > 0 })
    }
    private var tradeFiatLeg: APIService.TransactionLeg? {
        txLegs.first(where: { $0.quantity < 0 })
    }
    private var tradeAsset: APIService.Asset? {
        guard let id = tradeAssetLeg?.asset_id else { return nil }
        return assets.first(where: { $0.id == id })
    }
    private var isStock: Bool {
        ["stock", "etf"].contains(tradeAsset?.asset_class.lowercased() ?? "")
    }
    private var isCrypto: Bool {
        tradeAsset?.asset_class.lowercased() == "crypto"
    }

    // Primary leg for amount display
    private var primaryLeg: APIService.TransactionLeg? {
        if isTrade { return tradeFiatLeg ?? txLegs.first }
        return txLegs.first(where: { $0.quantity > 0 }) ?? txLegs.first
    }
    private var primaryAmount: Double { abs(primaryLeg?.quantity ?? 0) }
    private var primaryAccount: APIService.Account? {
        accounts.first(where: { $0.id == primaryLeg?.account_id })
    }
    private func currencySymbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "USD": return "$"; case "GBP": return "£"; case "CHF": return "CHF "
        case "JPY": return "¥"; case "CAD": return "C$"; case "AUD": return "A$"
        case "PLN": return "zł "; case "SEK": return "kr "; case "NOK": return "kr "
        case "CZK": return "Kč "; default: return "€"
        }
    }

    private var amtColor: Color {
        isIncome ? .green : isExpense ? .red : .primary
    }

    private func formatPrice(_ price: Double) -> String {
        if price < 0.01 { return "$\(price.formatted(.number.precision(.fractionLength(6))))" }
        if price < 1    { return "$\(price.formatted(.number.precision(.fractionLength(4))))" }
        return "$\(price.formatted(.number.precision(.fractionLength(2))))"
    }

    @ViewBuilder
    private func legRow(_ leg: APIService.TransactionLeg) -> some View {
        let legAccount = accounts.first(where: { $0.id == leg.account_id })
        let legAsset: APIService.Asset? = {
            guard let aid = leg.asset_id, !aid.isEmpty else { return nil }
            return assets.first(where: { $0.id == aid })
        }()
        let sym        = legAsset == nil ? currencySymbol(for: legAccount?.base_currency ?? "USD") : ""
        let assetLabel = legAsset.map { " \($0.symbol)" } ?? ""
        let sign       = leg.quantity >= 0 ? "+" : ""

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(legAccount?.name ?? "Unknown").font(.subheadline)
                if let asset = legAsset {
                    Text(asset.name).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Text("\(sign)\(sym)\(abs(leg.quantity).formatted(.number.precision(.fractionLength(0...8))))\(assetLabel)")
                .font(.subheadline.bold())
                .foregroundColor(leg.quantity >= 0 ? .green : .red)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Hero section ──────────────────────────────────────────
                Section {
                    VStack(spacing: 12) {
                        // Icon
                        ZStack {
                            Circle()
                                .fill(eventColor(tx.event_type).opacity(0.15))
                                .frame(width: 70, height: 70)
                            if let asset = tradeAsset, isStock {
                                AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(asset.symbol)?format=jpg")) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                            .frame(width: 54, height: 54).clipShape(Circle())
                                    default:
                                        Image(systemName: eventIcon(tx.event_type))
                                            .foregroundColor(eventColor(tx.event_type))
                                            .font(.system(size: 30))
                                    }
                                }
                            } else if let asset = tradeAsset, isCrypto,
                                      let imgURL = cryptoImages[asset.symbol.uppercased()],
                                      let url = URL(string: imgURL) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFit()
                                            .frame(width: 54, height: 54).clipShape(Circle())
                                    default:
                                        Image(systemName: eventIcon(tx.event_type))
                                            .foregroundColor(eventColor(tx.event_type))
                                            .font(.system(size: 30))
                                    }
                                }
                            } else {
                                Image(systemName: eventIcon(tx.event_type))
                                    .foregroundColor(eventColor(tx.event_type))
                                    .font(.system(size: 30))
                            }
                        }

                        // Description + amount
                        VStack(spacing: 4) {
                            Text(tx.description ?? tx.event_type.capitalized)
                                .font(.title3.bold())
                                .multilineTextAlignment(.center)

                            if isTrade, let asset = tradeAsset, let leg = tradeAssetLeg {
                                Text("+\(abs(leg.quantity).formatted(.number.precision(.fractionLength(0...8)))) \(asset.symbol)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }

                            if primaryAmount > 0 {
                                Text("\(isExpense || isTrade ? "-" : isIncome ? "+" : "")\(currencySymbol(for: primaryAccount?.base_currency ?? "EUR"))\(primaryAmount.formatted(.number.precision(.fractionLength(2))))")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundColor(amtColor)
                            }
                        }

                        // Type badge
                        Text(tx.event_type.capitalized)
                            .font(.caption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(eventColor(tx.event_type).opacity(0.12))
                            .foregroundColor(eventColor(tx.event_type))
                            .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                // ── Details ───────────────────────────────────────────────
                Section("Details") {
                    LabeledContent("Date", value: tx.date)

                    if let cat = tx.category, !cat.isEmpty {
                        LabeledContent("Category", value: cat)
                    }

                    if let account = primaryAccount {
                        LabeledContent("Account", value: account.name)
                    }

                    if isTrade, let leg = tradeAssetLeg, let price = leg.unit_price, price > 0,
                       let asset = tradeAsset {
                        LabeledContent("Price per \(asset.symbol)", value: formatPrice(price))
                    }

                    if let note = tx.note, !note.isEmpty {
                        LabeledContent("Note", value: note)
                    }

                    if !tx.source.isEmpty {
                        LabeledContent("Source", value: tx.source)
                    }
                }

                // ── Legs breakdown ────────────────────────────────────────
                if !txLegs.isEmpty {
                    Section("Movements") {
                        ForEach(txLegs) { leg in legRow(leg) }
                    }
                }

                // ── Delete ────────────────────────────────────────────────
                Section {
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Label(isDeleting ? "Deleting…" : "Delete Transaction",
                                  systemImage: "trash")
                            Spacer()
                        }
                    }
                    .disabled(isDeleting)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Delete Transaction?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    Task {
                        isDeleting = true
                        try? await APIService.shared.deleteTransactionEvent(id: tx.id)
                        onDeleted()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \"\(tx.description ?? tx.event_type)\" and all its legs.")
            }
        }
    }

    private func eventIcon(_ t: String) -> String {
        switch t.lowercased() {
        case "income":   return "arrow.down.circle.fill"
        case "expense":  return "arrow.up.circle.fill"
        case "transfer": return "arrow.left.arrow.right.circle.fill"
        case "trade":    return "chart.line.uptrend.xyaxis.circle.fill"
        default:         return "circle.fill"
        }
    }

    private func eventColor(_ t: String) -> Color {
        switch t.lowercased() {
        case "income":  return .green
        case "expense": return .red
        case "trade":   return .orange
        default:        return .blue
        }
    }
}

// ── TransactionsView ──────────────────────────────────────────────────────────
struct TransactionsView: View {
    @AppStorage("baseCurrency") private var baseCurrency = "EUR"
    @State private var transactions: [APIService.TransactionEvent] = []
    @State private var accounts: [APIService.Account] = []
    @State private var assets: [APIService.Asset] = []
    @State private var legs: [APIService.TransactionLeg] = []
    @State private var cryptoImages: [String: String] = [:]
    @State private var showAdd = false
    @State private var selectedTx: APIService.TransactionEvent?
    @State private var errorMessage: String?
    @State private var filterType = "All"

    let filters = ["All", "Income", "Expense", "Transfer", "Trade"]

    var filtered: [APIService.TransactionEvent] {
        filterType == "All" ? transactions : transactions.filter {
            $0.event_type.lowercased() == filterType.lowercased()
        }
    }

    // ── Date grouping ──────────────────────────────────────────────────────────
    private var groupedTransactions: [(String, [APIService.TransactionEvent])] {
        let dict = Dictionary(grouping: filtered) { $0.date }
        return dict.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    private func sectionTitle(for dateString: String) -> String {
        let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dateString) else { return dateString }
        if Calendar.current.isDateInToday(date)     { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter(); fmt.dateFormat = "EEEE, d MMM"
        return fmt.string(from: date)
    }

    // ── Summary totals ─────────────────────────────────────────────────────────
    private var totalIncome: Double {
        filtered.filter { $0.event_type.lowercased() == "income" }.reduce(0) { $0 + txAmount($1) }
    }
    private var totalExpenses: Double {
        filtered.filter { $0.event_type.lowercased() == "expense" }.reduce(0) { $0 + txAmount($1) }
    }
    private var baseCurrencySymbol: String {
        switch baseCurrency.uppercased() {
        case "USD": return "$"; case "GBP": return "£"; case "CHF": return "CHF "
        case "JPY": return "¥"; case "CAD": return "C$"; case "AUD": return "A$"
        default: return "€"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── Filter pills with count badges ─────────────────────────────
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filters, id: \.self) { f in
                            let count = f == "All" ? transactions.count
                                : transactions.filter { $0.event_type.lowercased() == f.lowercased() }.count
                            Button {
                                withAnimation(.spring(duration: 0.2)) { filterType = f }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(f).font(.subheadline.weight(.semibold))
                                    if count > 0 {
                                        Text("\(count)")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(filterType == f
                                                        ? Color.white.opacity(0.22)
                                                        : Color(.systemGray4))
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(filterType == f ? Color.primary : Color(.systemGray6))
                                .foregroundColor(filterType == f ? Color(.systemBackground) : .primary)
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }

                // ── Income / Expense summary strip ─────────────────────────────
                if totalIncome > 0 || totalExpenses > 0 {
                    HStack(spacing: 0) {
                        if totalIncome > 0 {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle().fill(Color.green.opacity(0.12)).frame(width: 32, height: 32)
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundColor(.green).font(.system(size: 14))
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Income").font(.caption2).foregroundColor(.secondary)
                                    Text("+\(baseCurrencySymbol)\(totalIncome.formatted(.number.precision(.fractionLength(2))))")
                                        .font(.caption.bold()).foregroundColor(.green)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                        }
                        if totalIncome > 0 && totalExpenses > 0 {
                            Divider().frame(height: 32)
                        }
                        if totalExpenses > 0 {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle().fill(Color.red.opacity(0.12)).frame(width: 32, height: 32)
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundColor(.red).font(.system(size: 14))
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Expenses").font(.caption2).foregroundColor(.secondary)
                                    Text("-\(baseCurrencySymbol)\(totalExpenses.formatted(.number.precision(.fractionLength(2))))")
                                        .font(.caption.bold()).foregroundColor(.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, totalIncome > 0 ? 12 : 16)
                        }
                    }
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                    Divider()
                }

                Divider()

                // ── List or empty state ────────────────────────────────────────
                if filtered.isEmpty {
                    VStack(spacing: 14) {
                        Spacer()
                        Image(systemName: filterType == "All"
                              ? "tray" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 52)).foregroundColor(.secondary.opacity(0.3))
                        Text(filterType == "All" ? "No transactions yet"
                             : "No \(filterType.lowercased()) transactions")
                            .font(.title3.bold())
                        Text("Tap + to record one")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGroupedBackground))
                } else {
                    List {
                        ForEach(groupedTransactions, id: \.0) { dateStr, txs in
                            Section {
                                ForEach(txs, id: \.id) { tx in
                                    Button { selectedTx = tx } label: { txRow(tx) }
                                        .buttonStyle(.plain)
                                }
                                .onDelete { offsets in
                                    Task { await deleteItems(offsets, from: txs) }
                                }
                            } header: {
                                Text(sectionTitle(for: dateStr))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                    .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Transactions")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                AddTransactionView { Task { await load() } }
            }
            .sheet(item: $selectedTx) { tx in
                TransactionDetailView(
                    tx: tx,
                    accounts: accounts,
                    assets: assets,
                    legs: legs,
                    cryptoImages: cryptoImages,
                    onDeleted: { Task { await load() } }
                )
            }
            .refreshable { await load() }
        }
    }

    // ── Row ────────────────────────────────────────────────────────────────────
    @ViewBuilder
    private func txRow(_ tx: APIService.TransactionEvent) -> some View {
        let amt       = txAmount(tx)
        let symbol    = txCurrencySymbol(tx)
        let accName   = txAccountName(tx)
        let isIncome  = tx.event_type.lowercased() == "income"
        let isExpense = tx.event_type.lowercased() == "expense"
        let isTrade   = tx.event_type.lowercased() == "trade"
        let amtColor: Color = isIncome ? .green : isExpense ? .red : .primary
        let asset     = isTrade ? tradeAsset(tx) : nil
        let isStock   = ["stock", "etf"].contains(asset?.asset_class.lowercased() ?? "")
        let isCrypto  = asset?.asset_class.lowercased() == "crypto"

        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(eventColor(tx.event_type).opacity(0.13))
                    .frame(width: 48, height: 48)
                if let asset, isStock {
                    AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(asset.symbol)?format=jpg")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 36, height: 36).clipShape(Circle())
                        default:
                            Text(String(asset.symbol.prefix(2)))
                                .font(.caption.bold()).foregroundColor(.green)
                        }
                    }
                } else if let asset, isCrypto {
                    if let imgURL = cryptoImages[asset.symbol.uppercased()], let url = URL(string: imgURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFit()
                                    .frame(width: 36, height: 36).clipShape(Circle())
                            default:
                                Text(String(asset.symbol.prefix(2)))
                                    .font(.caption.bold()).foregroundColor(.orange)
                            }
                        }
                    } else {
                        Text(String(asset.symbol.prefix(2)))
                            .font(.caption.bold()).foregroundColor(.orange)
                    }
                } else {
                    Image(systemName: eventIcon(tx.event_type))
                        .foregroundColor(eventColor(tx.event_type))
                        .font(.system(size: 19))
                }
            }

            // Description + subtitle
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.description ?? tx.event_type.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if isTrade, let price = tradeUnitPrice(tx), let qty = tradeAssetQty(tx) {
                    Text("\(qty.formatted(.number.precision(.fractionLength(0...6)))) \(asset?.symbol ?? "units") @ $\(price.formatted(.number.precision(.fractionLength(2))))")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 4) {
                        if let cat = tx.category, !cat.isEmpty {
                            Text(cat).font(.caption2).foregroundColor(.secondary)
                            if accName != nil { Text("·").font(.caption2).foregroundColor(.secondary.opacity(0.5)) }
                        }
                        if let name = accName {
                            Text(name).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }

            Spacer()

            // Amount + type badge
            VStack(alignment: .trailing, spacing: 3) {
                if amt > 0 {
                    Text("\(isExpense || isTrade ? "−" : isIncome ? "+" : "")\(symbol)\(amt.formatted(.number.precision(.fractionLength(2))))")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(amtColor)
                }
                Text(tx.event_type.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(eventColor(tx.event_type))
            }
        }
        .padding(.vertical, 5)
    }

    // ── Data loading ───────────────────────────────────────────────────────────
    private func load() async {
        do {
            async let txFetch    = APIService.shared.fetchTransactionEvents()
            async let accFetch   = APIService.shared.fetchAccounts()
            async let assetFetch = APIService.shared.fetchAssets()
            async let legsFetch  = APIService.shared.fetchTransactionLegs()
            transactions = try await txFetch
            accounts     = try await accFetch
            assets       = try await assetFetch
            legs         = try await legsFetch
            let cryptoSymbols = assets
                .filter { $0.asset_class.lowercased() == "crypto" }
                .map { $0.symbol.uppercased() }
            await loadCryptoImages(for: cryptoSymbols)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCryptoImages(for symbols: [String]) async {
        let unique = Array(Set(symbols))
        await withTaskGroup(of: (String, String?).self) { group in
            for symbol in unique {
                group.addTask {
                    guard let results = try? await APIService.shared.searchCrypto(query: symbol),
                          let match = results.first(where: { $0.symbol.uppercased() == symbol }) ?? results.first
                    else { return (symbol, nil) }
                    let url = match.thumb?.replacingOccurrences(of: "/thumb/", with: "/small/")
                    return (symbol, url)
                }
            }
            for await (symbol, url) in group {
                if let url { cryptoImages[symbol] = url }
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    private func primaryLeg(_ tx: APIService.TransactionEvent) -> APIService.TransactionLeg? {
        let txLegs = legs.filter { $0.event_id == tx.id && $0.fee_flag != "true" }
        if tx.event_type.lowercased() == "trade" {
            return txLegs.first(where: { $0.quantity < 0 }) ?? txLegs.first
        }
        return txLegs.first(where: { $0.quantity > 0 }) ?? txLegs.first
    }

    private func tradeAssetLeg(_ tx: APIService.TransactionEvent) -> APIService.TransactionLeg? {
        legs.filter { $0.event_id == tx.id && $0.fee_flag != "true" }
            .first(where: { $0.quantity > 0 })
    }

    private func tradeAsset(_ tx: APIService.TransactionEvent) -> APIService.Asset? {
        guard let assetId = tradeAssetLeg(tx)?.asset_id else { return nil }
        return assets.first(where: { $0.id == assetId })
    }

    private func tradeUnitPrice(_ tx: APIService.TransactionEvent) -> Double? {
        tradeAssetLeg(tx)?.unit_price
    }

    private func tradeAssetQty(_ tx: APIService.TransactionEvent) -> Double? {
        tradeAssetLeg(tx).map { abs($0.quantity) }
    }

    private func txAmount(_ tx: APIService.TransactionEvent) -> Double {
        abs(primaryLeg(tx)?.quantity ?? 0)
    }

    private func txAccountName(_ tx: APIService.TransactionEvent) -> String? {
        guard let leg = primaryLeg(tx) else { return nil }
        return accounts.first(where: { $0.id == leg.account_id })?.name
    }

    private func txCurrencySymbol(_ tx: APIService.TransactionEvent) -> String {
        guard let leg = primaryLeg(tx),
              let currency = accounts.first(where: { $0.id == leg.account_id })?.base_currency
        else { return "€" }
        switch currency.uppercased() {
        case "USD": return "$"; case "GBP": return "£"; case "CHF": return "CHF "
        default: return "€"
        }
    }

    private func deleteItems(_ offsets: IndexSet, from txs: [APIService.TransactionEvent]) async {
        for tx in offsets.map({ txs[$0] }) {
            try? await APIService.shared.deleteTransactionEvent(id: tx.id)
        }
        await load()
    }

    private func eventIcon(_ t: String) -> String {
        switch t.lowercased() {
        case "income":   return "arrow.down.circle.fill"
        case "expense":  return "arrow.up.circle.fill"
        case "transfer": return "arrow.left.arrow.right.circle.fill"
        case "trade":    return "chart.line.uptrend.xyaxis.circle.fill"
        default:         return "circle.fill"
        }
    }

    private func eventColor(_ t: String) -> Color {
        switch t.lowercased() {
        case "income":  return .green
        case "expense": return .red
        case "trade":   return .orange
        default:        return .blue
        }
    }
}
