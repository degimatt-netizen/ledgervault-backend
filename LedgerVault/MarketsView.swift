import SwiftUI

// MARK: - Asset Avatar

struct AssetAvatar: View {
    let symbol: String

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .cyan, .red, .yellow]
        return palette[abs(symbol.hashValue) % palette.count]
    }

    private var letters: String {
        let clean = symbol.replacingOccurrences(of: "-USD", with: "")
                          .replacingOccurrences(of: ".L", with: "")
                          .replacingOccurrences(of: ".AS", with: "")
        return String(clean.prefix(2)).uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(color.opacity(0.18))
                .frame(width: 38, height: 38)
            Text(letters)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Sparkline

struct SparklineShape: Shape {
    let prices: [Double]
    func path(in rect: CGRect) -> Path {
        guard prices.count >= 2 else { return Path() }
        let minP = prices.min()!
        let maxP = prices.max()!
        let range = maxP == minP ? 1.0 : maxP - minP
        var path = Path()
        for (i, price) in prices.enumerated() {
            let x = rect.width * CGFloat(i) / CGFloat(prices.count - 1)
            let y = rect.height * (1 - CGFloat((price - minP) / range))
            i == 0 ? path.move(to: .init(x: x, y: y)) : path.addLine(to: .init(x: x, y: y))
        }
        return path
    }
}

struct SparklineView: View {
    let symbol: String
    @State private var prices: [Double] = []
    @State private var loaded = false

    private var isPositive: Bool {
        guard prices.count >= 2 else { return true }
        return (prices.last ?? 0) >= (prices.first ?? 0)
    }

    var body: some View {
        ZStack {
            if prices.count >= 2 {
                SparklineShape(prices: prices)
                    .stroke(
                        isPositive ? Color.green : Color.red,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: (isPositive ? Color.green : Color.red).opacity(0.4), radius: 3)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.05))
            }
        }
        .frame(width: 64, height: 32)
        .task(id: symbol) {
            guard !loaded else { return }
            if let resp = try? await APIService.shared.fetchSparkline(symbol: symbol) {
                prices = resp.prices
            }
            loaded = true
        }
    }
}

// MARK: - Market Row

struct MarketRowView: View {
    let quote: APIService.MarketQuote
    let onRemove: () -> Void

    private var changeColor: Color { quote.change_pct >= 0 ? .green : Color(red: 1, green: 0.3, blue: 0.3) }
    private var changeBg: Color    { quote.change_pct >= 0 ? Color.green.opacity(0.12) : Color.red.opacity(0.12) }

    var body: some View {
        HStack(spacing: 12) {
            // Logo avatar
            AssetAvatar(symbol: quote.symbol)

            // Symbol + company name
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(quote.symbol)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    if let pos = quote.position, abs(pos) > 1e-8 {
                        Text("HELD")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                Text(quote.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Sparkline
            SparklineView(symbol: quote.symbol)

            // Price + change pill
            VStack(alignment: .trailing, spacing: 4) {
                Text(formatPrice(quote.last, currency: quote.currency))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)

                Text(formatPct(quote.change_pct))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(changeColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(changeBg)
                    .cornerRadius(6)
            }
            .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if quote.in_watchlist == true, (quote.position ?? 0) == 0 {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
        }
    }

    private func formatPrice(_ v: Double, currency: String?) -> String {
        let sym = currency == "GBP" ? "£" : currency == "EUR" ? "€" : "$"
        if v >= 1000 { return "\(sym)\(String(format: "%.2f", v))" }
        if v >= 1    { return "\(sym)\(String(format: "%.2f", v))" }
        return "\(sym)\(String(format: "%.4f", v))"
    }
    private func formatPct(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))%"
    }
}

// MARK: - Add Symbol Sheet

struct AddWatchlistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query       = ""
    @State private var results:    [APIService.StockSearchResult] = []
    @State private var isSearching = false
    @State private var isAdding    = false
    @State private var searchTask: Task<Void, Never>?
    let onAdd: (String) async -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    // Search field
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search ticker or company…", text: $query)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: query) { _, val in
                                searchTask?.cancel()
                                let q = val.trimmingCharacters(in: .whitespaces)
                                guard q.count >= 1 else { results = []; return }
                                searchTask = Task {
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    guard !Task.isCancelled else { return }
                                    isSearching = true
                                    results = (try? await APIService.shared.searchStocks(query: q)) ?? []
                                    isSearching = false
                                }
                            }
                        if isSearching {
                            ProgressView().scaleEffect(0.8)
                        } else if !query.isEmpty {
                            Button { query = ""; results = [] } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .padding()

                    if results.isEmpty && !query.isEmpty && !isSearching {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No results for "\(query)"")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                    } else {
                        List(results) { result in
                            Button {
                                isAdding = true
                                Task {
                                    await onAdd(result.symbol)
                                    isAdding = false
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    AssetAvatar(symbol: result.symbol)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.symbol)
                                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        Text(result.name)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if let exch = result.exchange {
                                        Text(exch)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.secondary.opacity(0.12))
                                            .cornerRadius(5)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.plain)
                    }

                    Spacer()
                }
            }
            .navigationTitle("Add Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isAdding {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView("Adding…").padding(24)
                            .background(.regularMaterial)
                            .cornerRadius(12)
                    }
                }
            }
        }
    }
}

// MARK: - Section Header

struct MarketSectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)
            Text("\(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.07))
                .cornerRadius(5)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Sort

enum MarketSortField { case symbol, last, changePct }

// MARK: - Main View

struct MarketsView: View {
    @State private var quotes:    [APIService.MarketQuote] = []
    @State private var isLoading  = false
    @State private var error:     String?
    @State private var showAdd    = false
    @State private var sortField  = MarketSortField.symbol
    @State private var sortAsc    = true
    @State private var searchText = ""

    private var sorted: [APIService.MarketQuote] {
        let base = searchText.isEmpty ? quotes : quotes.filter {
            $0.symbol.localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return base.sorted { a, b in
            let r: Bool
            switch sortField {
            case .symbol:    r = a.symbol < b.symbol
            case .last:      r = a.last < b.last
            case .changePct: r = a.change_pct < b.change_pct
            }
            return sortAsc ? r : !r
        }
    }

    private var heldQuotes:      [APIService.MarketQuote] { sorted.filter { ($0.position ?? 0) != 0 } }
    private var watchlistQuotes: [APIService.MarketQuote] { sorted.filter { ($0.position ?? 0) == 0 && $0.in_watchlist == true } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea()

                VStack(spacing: 0) {
                    sortBar

                    if isLoading && quotes.isEmpty {
                        Spacer()
                        ProgressView().tint(.white)
                        Spacer()
                    } else if let err = error {
                        errorView(err)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                if !heldQuotes.isEmpty {
                                    MarketSectionHeader(title: "My Holdings", count: heldQuotes.count)
                                    ForEach(heldQuotes) { q in
                                        MarketRowView(quote: q) {
                                            Task { await removeFromWatchlist(q.symbol) }
                                        }
                                    }
                                }

                                if !watchlistQuotes.isEmpty {
                                    MarketSectionHeader(title: "Watchlist", count: watchlistQuotes.count)
                                    ForEach(watchlistQuotes) { q in
                                        MarketRowView(quote: q) {
                                            Task { await removeFromWatchlist(q.symbol) }
                                        }
                                    }
                                }

                                if sorted.isEmpty { emptyState }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 24)
                        }
                        .refreshable { await loadData() }
                    }
                }
            }
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search symbol or name")
            .navigationTitle("Markets")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await loadData() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white.opacity(isLoading ? 0.3 : 0.7))
                    }
                    .disabled(isLoading)
                }
            }
            .sheet(isPresented: $showAdd) {
                AddWatchlistSheet { sym in await addToWatchlist(sym) }
            }
            .task { await loadData() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sort bar

    private var sortBar: some View {
        HStack(spacing: 0) {
            sortButton("INSTRUMENT", .symbol, align: .leading)
            Spacer()
            sortButton("LAST", .last, align: .trailing)
            sortButton("CHG %", .changePct, align: .trailing).frame(width: 90)
            Text("TREND")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 72, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.04))
    }

    private func sortButton(_ label: String, _ field: MarketSortField, align: HorizontalAlignment) -> some View {
        Button {
            if sortField == field { sortAsc.toggle() } else { sortField = field; sortAsc = true }
        } label: {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(sortField == field ? .white : .white.opacity(0.3))
                if sortField == field {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 80, alignment: align == .leading ? .leading : .trailing)
    }

    // MARK: Empty / Error

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.15))
            Text("No instruments yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("Connect a broker or exchange to see your holdings,\nor tap + to add symbols to your watchlist.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
            Button { showAdd = true } label: {
                Label("Add Symbol", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Color.green.opacity(0.18))
                    .foregroundStyle(.green)
                    .cornerRadius(22)
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func errorView(_ msg: String) -> some View {
        Spacer()
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(.orange)
            Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await loadData() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        Spacer()
    }

    // MARK: Data

    private func loadData() async {
        isLoading = true; error = nil
        do {
            let result = try await APIService.shared.fetchMarketData()
            quotes = result.quotes
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func addToWatchlist(_ symbol: String) async {
        _ = try? await APIService.shared.addToWatchlist(symbol: symbol)
        await loadData()
    }

    private func removeFromWatchlist(_ symbol: String) async {
        try? await APIService.shared.removeFromWatchlist(symbol: symbol)
        await loadData()
    }
}
