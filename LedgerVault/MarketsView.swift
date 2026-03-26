import SwiftUI

// MARK: - Sparkline

struct SparklineShape: Shape {
    let prices: [Double]

    func path(in rect: CGRect) -> Path {
        guard prices.count >= 2 else { return Path() }
        let minP = prices.min()!
        let maxP = prices.max()!
        let range = maxP - minP == 0 ? 1 : maxP - minP
        var path = Path()
        for (i, price) in prices.enumerated() {
            let x = rect.width * CGFloat(i) / CGFloat(prices.count - 1)
            let y = rect.height * (1 - CGFloat((price - minP) / range))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else       { path.addLine(to: CGPoint(x: x, y: y)) }
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
        return prices.last! >= prices.first!
    }

    var body: some View {
        ZStack {
            if prices.count >= 2 {
                SparklineShape(prices: prices)
                    .stroke(isPositive ? Color.green : Color.red, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else if !loaded {
                Rectangle().fill(Color.white.opacity(0.06))
                    .cornerRadius(2)
            }
        }
        .frame(width: 60, height: 28)
        .task(id: symbol) {
            guard !loaded else { return }
            if let resp = try? await APIService.shared.fetchSparkline(symbol: symbol) {
                prices = resp.prices
            }
            loaded = true
        }
    }
}

// MARK: - Sort

enum MarketSortField: String {
    case symbol, name, last, change, changePct
}

// MARK: - Column header

struct ColHeader: View {
    let title: String
    let field: MarketSortField
    @Binding var sort: MarketSortField
    @Binding var asc: Bool

    var body: some View {
        Button {
            if sort == field { asc.toggle() }
            else { sort = field; asc = true }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(sort == field ? Color.white : Color.white.opacity(0.4))
                if sort == field {
                    Image(systemName: asc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

// MARK: - Row

struct MarketRowView: View {
    let quote: APIService.MarketQuote
    let onRemove: () -> Void

    private var changeColor: Color {
        quote.change_pct >= 0 ? .green : .red
    }

    var body: some View {
        HStack(spacing: 0) {
            // Symbol + name
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.symbol)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(quote.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)

            // Bid / Ask
            VStack(alignment: .trailing, spacing: 2) {
                Text(quote.bid.map { formatPrice($0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Text(quote.ask.map { formatPrice($0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 72, alignment: .trailing)

            // Last
            Text(formatPrice(quote.last))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 76, alignment: .trailing)

            // Change
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatChange(quote.change))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(changeColor)
                Text(formatPct(quote.change_pct))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(changeColor)
            }
            .frame(width: 72, alignment: .trailing)

            // Sparkline
            SparklineView(symbol: quote.symbol)
                .frame(width: 70)
                .padding(.horizontal, 6)

            // Position
            VStack(alignment: .trailing, spacing: 2) {
                if let pos = quote.position, abs(pos) > 1e-8 {
                    Text(formatQty(pos))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                    if let avg = quote.avg_price, avg > 0 {
                        Text(formatPrice(avg))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                } else {
                    Text("—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if quote.in_watchlist == true {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
        }
    }

    private func formatPrice(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.2f", v) }
        if v >= 1    { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }
    private func formatChange(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))"
    }
    private func formatPct(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))%"
    }
    private func formatQty(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1_000_000 { return String(format: "%.0f", v) }
        return String(format: "%.4f", v)
    }
}

// MARK: - Add Watchlist Sheet

struct AddWatchlistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isAdding = false
    @State private var error: String?
    let onAdd: (String) async -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter a ticker symbol")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("e.g. AAPL, NVDA, BTC-USD", text: $input)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(10)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal)

                    if let err = error {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    Button {
                        let sym = input.trimmingCharacters(in: .whitespaces).uppercased()
                        guard !sym.isEmpty else { return }
                        isAdding = true
                        Task {
                            await onAdd(sym)
                            isAdding = false
                            dismiss()
                        }
                    } label: {
                        Group {
                            if isAdding {
                                ProgressView().tint(.white)
                            } else {
                                Text("Add to Watchlist")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(input.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.green)
                        .cornerRadius(12)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.top, 20)
            }
            .navigationTitle("Add Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Main View

struct MarketsView: View {
    @State private var quotes:       [APIService.MarketQuote] = []
    @State private var watchlist:    [String] = []
    @State private var isLoading     = false
    @State private var error:        String?
    @State private var showAdd       = false
    @State private var sortField     = MarketSortField.symbol
    @State private var sortAsc       = true
    @State private var searchText    = ""

    private var filtered: [APIService.MarketQuote] {
        let base = searchText.isEmpty ? quotes : quotes.filter {
            $0.symbol.localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return base.sorted { a, b in
            let result: Bool
            switch sortField {
            case .symbol:    result = a.symbol < b.symbol
            case .name:      result = a.name < b.name
            case .last:      result = a.last < b.last
            case .change:    result = a.change < b.change
            case .changePct: result = a.change_pct < b.change_pct
            }
            return sortAsc ? result : !result
        }
    }

    private var heldQuotes: [APIService.MarketQuote] {
        filtered.filter { ($0.position ?? 0) != 0 }
    }
    private var watchlistQuotes: [APIService.MarketQuote] {
        filtered.filter { ($0.position ?? 0) == 0 && $0.in_watchlist == true }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

                VStack(spacing: 0) {
                    // Column headers (sticky)
                    columnHeaders

                    if isLoading && quotes.isEmpty {
                        Spacer()
                        ProgressView().tint(.white)
                        Spacer()
                    } else if let err = error {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(.orange)
                            Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Retry") { Task { await loadData() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding()
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4, pinnedViews: []) {
                                if !heldQuotes.isEmpty {
                                    sectionLabel("My Holdings")
                                    ForEach(heldQuotes) { q in
                                        MarketRowView(quote: q) {
                                            Task { await removeFromWatchlist(q.symbol) }
                                        }
                                    }
                                }
                                if !watchlistQuotes.isEmpty {
                                    sectionLabel("Watchlist")
                                    ForEach(watchlistQuotes) { q in
                                        MarketRowView(quote: q) {
                                            Task { await removeFromWatchlist(q.symbol) }
                                        }
                                    }
                                }
                                if filtered.isEmpty {
                                    emptyState
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 20)
                        }
                        .refreshable { await loadData() }
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search symbol or name")
            .navigationTitle("Markets")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await loadData() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .disabled(isLoading)
                }
            }
            .sheet(isPresented: $showAdd) {
                AddWatchlistSheet { sym in
                    await addToWatchlist(sym)
                }
            }
            .task { await loadData() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Column headers bar
    private var columnHeaders: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ColHeader(title: "INSTRUMENT", field: .symbol, sort: $sortField, asc: $sortAsc)
                    .frame(width: 120, alignment: .leading)
                Text("BID / ASK")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 72, alignment: .trailing)
                ColHeader(title: "LAST", field: .last, sort: $sortField, asc: $sortAsc)
                    .frame(width: 76, alignment: .trailing)
                ColHeader(title: "CHG / CHG%", field: .changePct, sort: $sortField, asc: $sortAsc)
                    .frame(width: 72, alignment: .trailing)
                Text("TREND")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 82, alignment: .center)
                Text("POS / AVG")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.2))
            Text("No instruments yet")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.5))
            Text("Connect a broker or exchange to see your holdings,\nor tap + to add symbols to your watchlist.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
            Button {
                showAdd = true
            } label: {
                Label("Add Symbol", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.2))
                    .foregroundStyle(.green)
                    .cornerRadius(20)
            }
        }
        .padding(40)
    }

    // MARK: Data loading

    private func loadData() async {
        isLoading = true
        error = nil
        do {
            let result = try await APIService.shared.fetchMarketData()
            quotes    = result.quotes
            watchlist = result.watchlist
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
