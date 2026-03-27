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

    private var isTrade:    Bool { tx.event_type.lowercased() == "trade" }
    private var isIncome:   Bool { tx.event_type.lowercased() == "income" }
    private var isExpense:  Bool { tx.event_type.lowercased() == "expense" }
    private var isTransfer: Bool { tx.event_type.lowercased() == "transfer" }

    private var tradeAssetLeg: APIService.TransactionLeg? { txLegs.first(where: { $0.quantity > 0 }) }
    private var tradeFiatLeg:  APIService.TransactionLeg? { txLegs.first(where: { $0.quantity < 0 }) }
    private var tradeAsset: APIService.Asset? {
        guard let id = tradeAssetLeg?.asset_id else { return nil }
        return assets.first(where: { $0.id == id })
    }
    private var isStock:  Bool { ["stock","etf"].contains(tradeAsset?.asset_class.lowercased() ?? "") }
    private var isCrypto: Bool { tradeAsset?.asset_class.lowercased() == "crypto" }

    private var primaryLeg: APIService.TransactionLeg? {
        if isTrade { return tradeFiatLeg ?? txLegs.first }
        return txLegs.first(where: { $0.quantity > 0 }) ?? txLegs.first
    }
    private var primaryAmount: Double { abs(primaryLeg?.quantity ?? 0) }
    private var primaryAccount: APIService.Account? {
        accounts.first(where: { $0.id == primaryLeg?.account_id })
    }

    // sym, formatPrice → global ccySymbol / fmtPrice in LVFormatting.swift
    private func sym(_ currency: String) -> String { ccySymbol(currency) }
    private func formatPrice(_ p: Double) -> String { fmtPrice(p) }

    private var amtPrefix: String {
        isExpense || isTrade ? "−" : isIncome ? "+" : ""
    }
    private var amtColor: Color {
        isIncome ? .green : isExpense ? .red : isTrade ? .orange : .blue
    }

    // ── Date formatting ───────────────────────────────────────────────────────
    private var formattedDate: String {
        let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"
        guard let d = parser.date(from: tx.date) else { return tx.date }
        let fmt = DateFormatter(); fmt.dateStyle = .long; fmt.timeStyle = .none
        return fmt.string(from: d)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {

                    // ── Hero card ─────────────────────────────────────────
                    VStack(spacing: 16) {
                        // Icon
                        ZStack {
                            Circle()
                                .fill(amtColor.opacity(0.12))
                                .frame(width: 80, height: 80)
                            if let asset = tradeAsset, isStock {
                                AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(asset.symbol)?format=jpg")) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                            .frame(width: 60, height: 60).clipShape(Circle())
                                    default:
                                        Image(systemName: eventIcon(tx.event_type))
                                            .font(.system(size: 32)).foregroundColor(amtColor)
                                    }
                                }
                            } else if let asset = tradeAsset, isCrypto,
                                      let imgURL = cryptoImages[asset.symbol.uppercased()],
                                      let url = URL(string: imgURL) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFit()
                                            .frame(width: 60, height: 60).clipShape(Circle())
                                    default:
                                        Image(systemName: eventIcon(tx.event_type))
                                            .font(.system(size: 32)).foregroundColor(amtColor)
                                    }
                                }
                            } else {
                                Image(systemName: eventIcon(tx.event_type))
                                    .font(.system(size: 32)).foregroundColor(amtColor)
                            }
                        }

                        VStack(spacing: 6) {
                            // Type badge
                            Text(tx.event_type.uppercased())
                                .font(.caption2.bold())
                                .tracking(1)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(amtColor.opacity(0.12))
                                .foregroundColor(amtColor)
                                .clipShape(Capsule())

                            // Description
                            Text(tx.description ?? tx.event_type.capitalized)
                                .font(.title3.bold())
                                .multilineTextAlignment(.center)

                            // Trade quantity line
                            if isTrade, let asset = tradeAsset, let leg = tradeAssetLeg {
                                Text("+\(abs(leg.quantity).formatted(.number.precision(.fractionLength(0...8)))) \(asset.symbol)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }

                            // Amount
                            if primaryAmount > 0 {
                                Text("\(amtPrefix)\(sym(primaryAccount?.base_currency ?? "EUR"))\(primaryAmount.formatted(.number.precision(.fractionLength(2))))")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundColor(amtColor)
                            }

                            // Date below amount
                            Text(formattedDate)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(20)

                    // ── Details card ──────────────────────────────────────
                    VStack(spacing: 0) {
                        detailRow(label: "Type", value: tx.event_type.capitalized, icon: "tag.fill", color: amtColor)
                        if let cat = tx.category, !cat.isEmpty {
                            Divider().padding(.leading, 52)
                            detailRow(label: "Category", value: cat, icon: "folder.fill", color: .secondary)
                        }
                        if let account = primaryAccount {
                            Divider().padding(.leading, 52)
                            detailRow(label: "Account", value: account.name, icon: "creditcard.fill", color: .blue)
                        }
                        if isTrade, let leg = tradeAssetLeg, let price = leg.unit_price, price > 0,
                           let asset = tradeAsset {
                            Divider().padding(.leading, 52)
                            detailRow(label: "Price per \(asset.symbol)", value: formatPrice(price), icon: "chart.line.uptrend.xyaxis", color: .orange)
                        }
                        if let note = tx.note, !note.isEmpty {
                            Divider().padding(.leading, 52)
                            detailRow(label: "Note", value: note, icon: "note.text", color: .secondary)
                        }
                        if !tx.source.isEmpty {
                            Divider().padding(.leading, 52)
                            detailRow(label: "Source", value: tx.source, icon: "doc.text.fill", color: .secondary)
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    // ── Movements card ────────────────────────────────────
                    if !txLegs.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Movements")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 8)

                            ForEach(Array(txLegs.enumerated()), id: \.element.id) { idx, leg in
                                if idx > 0 { Divider().padding(.leading, 52) }
                                legRow(leg)
                            }
                            .padding(.bottom, 4)
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                    }

                    // ── Delete button ─────────────────────────────────────
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "trash")
                            Text(isDeleting ? "Deleting…" : "Delete Transaction")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(16)
                    }
                    .disabled(isDeleting)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
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

    // ── Detail row helper ─────────────────────────────────────────────────────
    @ViewBuilder
    private func detailRow(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.1))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundColor(.secondary)
                Text(value).font(.subheadline)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // ── Leg row helper ────────────────────────────────────────────────────────
    @ViewBuilder
    private func legRow(_ leg: APIService.TransactionLeg) -> some View {
        let legAccount = accounts.first(where: { $0.id == leg.account_id })
        let legAsset: APIService.Asset? = {
            guard let aid = leg.asset_id, !aid.isEmpty else { return nil }
            return assets.first(where: { $0.id == aid })
        }()
        let currency   = legAccount?.base_currency ?? "EUR"
        let symStr     = legAsset == nil ? sym(currency) : ""
        let assetLabel = legAsset.map { " \($0.symbol)" } ?? ""
        let sign       = leg.quantity >= 0 ? "+" : "−"
        let rowColor: Color = leg.quantity >= 0 ? .green : .red

        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(rowColor.opacity(0.10))
                    .frame(width: 32, height: 32)
                Image(systemName: leg.quantity >= 0 ? "arrow.down" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(rowColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(legAccount?.name ?? "Unknown").font(.subheadline)
                if let asset = legAsset {
                    Text(asset.name).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Text("\(sign)\(symStr)\(abs(leg.quantity).formatted(.number.precision(.fractionLength(0...8))))\(assetLabel)")
                .font(.subheadline.bold())
                .foregroundColor(rowColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
    @State private var filterType   = "All"
    @State private var filterPeriod = "All"
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd:   Date = Date()
    @State private var showDateRangePicker = false

    let filters = ["All", "Income", "Expense", "Transfer", "Trade"]
    let periods: [(label: String, key: String)] = [
        ("All Time", "All"),
        ("Today",    "Today"),
        ("Week",     "Week"),
        ("Month",    "Month"),
        ("Period",   "Custom")
    ]

    // ── Period date range helper ───────────────────────────────────────────────
    private func parseTxDate(_ str: String) -> Date? {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: str)
    }

    private var periodStart: Date? {
        let cal = Calendar.current; let now = Date()
        switch filterPeriod {
        case "Today":  return cal.startOfDay(for: now)
        case "Week":   return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        case "Month":  return cal.date(from: cal.dateComponents([.year, .month], from: now))
        case "Custom": return cal.startOfDay(for: customStart)
        default:       return nil
        }
    }
    private var periodEnd: Date? {
        guard filterPeriod == "Custom" else { return nil }
        return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customEnd))
    }

    private var customRangeLabel: String {
        let fmt = DateFormatter(); fmt.dateFormat = "d MMM"
        return "\(fmt.string(from: customStart)) – \(fmt.string(from: customEnd))"
    }

    var filtered: [APIService.TransactionEvent] {
        var base = transactions
        if let start = periodStart {
            base = base.filter {
                guard let d = parseTxDate($0.date) else { return false }
                if let end = periodEnd { return d >= start && d < end }
                return d >= start
            }
        }
        if filterType != "All" {
            base = base.filter { $0.event_type.lowercased() == filterType.lowercased() }
        }
        return base
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

    private func dayNet(for txs: [APIService.TransactionEvent]) -> Double {
        txs.reduce(0.0) { total, tx in
            switch tx.event_type.lowercased() {
            case "income":  return total + txAmount(tx)
            case "expense": return total - txAmount(tx)
            default:        return total
            }
        }
    }

    // ── Summary totals ─────────────────────────────────────────────────────────
    private var totalIncome: Double {
        filtered.filter { $0.event_type.lowercased() == "income" }.reduce(0) { $0 + txAmount($1) }
    }
    private var totalExpenses: Double {
        filtered.filter { $0.event_type.lowercased() == "expense" }.reduce(0) { $0 + txAmount($1) }
    }
    private var baseCurrencySymbol: String { ccySymbol(baseCurrency) }

    // ── Filter header (pinned) ─────────────────────────────────────────────────
    private var filterHeader: some View {
        VStack(spacing: 0) {
            // Type pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filters, id: \.self) { f in
                        let count = f == "All" ? filtered.count
                            : filtered.filter { $0.event_type.lowercased() == f.lowercased() }.count
                        Button {
                            hapticLight()
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
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            }

            // Period pills — fixed row, no scroll bounce
            HStack(spacing: 6) {
                ForEach(periods, id: \.key) { period in
                    Button {
                        filterPeriod = period.key
                        if period.key == "Custom" { showDateRangePicker = true }
                    } label: {
                        HStack(spacing: 4) {
                            if period.key == "Custom" {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.caption2.bold())
                            }
                            Text(filterPeriod == "Custom" && period.key == "Custom"
                                 ? customRangeLabel : period.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(filterPeriod == period.key ? Color.blue.opacity(0.15) : Color(.systemGray6))
                        .foregroundColor(filterPeriod == period.key ? .blue : .secondary)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                filterPeriod == period.key ? Color.blue.opacity(0.4) : Color.clear,
                                lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)

            // Income / Expense summary strip
            if filterType == "All" || filterType == "Income" || filterType == "Expense" {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.green.opacity(0.12)).frame(width: 32, height: 32)
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green).font(.system(size: 14))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Income").font(.caption2).foregroundColor(.secondary)
                            Text(totalIncome > 0 ? "+" + fmtCurrency(totalIncome, currency: baseCurrency) : "—")
                                .font(.subheadline.bold())
                                .foregroundColor(totalIncome > 0 ? .green : .secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)

                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.red.opacity(0.12)).frame(width: 32, height: 32)
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.red).font(.system(size: 14))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Expenses").font(.caption2).foregroundColor(.secondary)
                            Text(totalExpenses > 0 ? "−" + fmtCurrency(totalExpenses, currency: baseCurrency) : "—")
                                .font(.subheadline.bold())
                                .foregroundColor(totalExpenses > 0 ? .red : .secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Divider()
        }
        .background(Color(.systemGroupedBackground))
    }

    var body: some View {
        NavigationStack {
            Group {
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
                    .safeAreaInset(edge: .top, spacing: 0) { filterHeader }
                } else {
                    List {
                        ForEach(groupedTransactions, id: \.0) { dateStr, txs in
                            Section {
                                ForEach(txs, id: \.id) { tx in
                                    Button { selectedTx = tx } label: { txRow(tx) }
                                        .buttonStyle(.plain)
                                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                }
                                .onDelete { offsets in
                                    Task { await deleteItems(offsets, from: txs) }
                                }
                            } header: {
                                let net = dayNet(for: txs)
                                HStack {
                                    Text(sectionTitle(for: dateStr))
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary)
                                        .textCase(nil)
                                    Spacer()
                                    if net != 0 {
                                        Text((net >= 0 ? "+" : "−") + fmtCurrency(abs(net), currency: baseCurrency))
                                            .font(.caption2.bold())
                                            .foregroundColor(net >= 0 ? .green : .red)
                                            .textCase(nil)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .safeAreaInset(edge: .top, spacing: 0) { filterHeader }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Transactions")
            .navigationBarTitleDisplayMode(.inline)
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
            .sheet(isPresented: $showDateRangePicker) {
                NavigationStack {
                    Form {
                        Section("Date Range") {
                            DatePicker("From", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                            DatePicker("To",   selection: $customEnd,   in: customStart...,  displayedComponents: .date)
                        }
                        Section {
                            Text("Showing transactions from \(customRangeLabel)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .navigationTitle("Custom Range")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDateRangePicker = false }
                                .fontWeight(.semibold)
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                filterPeriod = "All"
                                showDateRangePicker = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
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
        let isTransfer = tx.event_type.lowercased() == "transfer"
        let amtColor: Color = isIncome ? .green : isExpense ? .red : isTrade ? .orange : .blue
        let asset     = isTrade ? tradeAsset(tx) : nil
        let isStock   = ["stock", "etf"].contains(asset?.asset_class.lowercased() ?? "")
        let isCrypto  = asset?.asset_class.lowercased() == "crypto"
        let evColor   = eventColor(tx.event_type)

        HStack(spacing: 14) {
            // ── Icon ──────────────────────────────────────────────────────
            ZStack {
                Circle()
                    .fill(evColor.opacity(0.12))
                    .frame(width: 46, height: 46)
                if let asset, isStock {
                    AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(asset.symbol)?format=jpg")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 34, height: 34).clipShape(Circle())
                        default:
                            Image(systemName: eventIcon(tx.event_type))
                                .foregroundColor(evColor).font(.system(size: 18))
                        }
                    }
                } else if let asset, isCrypto,
                          let imgURL = cryptoImages[asset.symbol.uppercased()],
                          let url = URL(string: imgURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(width: 34, height: 34).clipShape(Circle())
                        default:
                            Image(systemName: eventIcon(tx.event_type))
                                .foregroundColor(evColor).font(.system(size: 18))
                        }
                    }
                } else {
                    Image(systemName: eventIcon(tx.event_type))
                        .foregroundColor(evColor)
                        .font(.system(size: 18, weight: .semibold))
                }
            }

            // ── Left content ──────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text(tx.description ?? tx.event_type.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if isTrade, let qty = tradeAssetQty(tx), let price = tradeUnitPrice(tx) {
                        Text("\(qty.formatted(.number.precision(.fractionLength(0...5)))) \(asset?.symbol ?? "") @ $\(price.formatted(.number.precision(.fractionLength(2))))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        if let cat = tx.category, !cat.isEmpty {
                            Text(cat)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(evColor.opacity(0.10))
                                .foregroundColor(evColor)
                                .clipShape(Capsule())
                        }
                        if let name = accName {
                            Text(name)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            // ── Right content ─────────────────────────────────────────────
            VStack(alignment: .trailing, spacing: 3) {
                if amt > 0 {
                    Text("\(isExpense || isTrade ? "−" : isIncome ? "+" : isTransfer ? "⇄ " : "")\(symbol)\(amt.formatted(.number.precision(.fractionLength(2))))")
                        .font(.callout.weight(.bold))
                        .foregroundColor(amtColor)
                }
                if isTrade, let asset {
                    Text(asset.symbol)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                } else if let accName {
                    Text(accName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
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
        hapticWarning()
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
