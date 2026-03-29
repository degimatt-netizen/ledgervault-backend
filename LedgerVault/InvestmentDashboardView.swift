import SwiftUI
import Charts

// ── InvestmentDashboardView ───────────────────────────────────────────────────
struct InvestmentDashboardView: View {

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("baseCurrency") private var appBaseCurrency = "USD"
    @State private var localCurrency: String = ""

    @State private var valuation:    APIService.ValuationResponse?
    @State private var accounts:     [APIService.Account] = []
    @State private var cryptoImages: [String: String]     = [:]
    @State private var isLoading     = true
    @State private var errorMessage: String?

    private var baseCurrency: String { localCurrency.isEmpty ? appBaseCurrency : localCurrency }

    enum SortMode: String, CaseIterable {
        case value = "Value", gain = "Gain %", name = "Name"
    }
    @State private var sortMode: SortMode = .value

    private static let currencies = [
        "USD","EUR","GBP","AED","AUD","CAD","CHF","JPY",
        "NOK","SEK","PLN","CZK","DKK","SGD","HKD","NZD"
    ]

    // ── Account type sets ──────────────────────────────────────────────────────
    private var brokerIDs: Set<String> {
        Set(accounts.filter { $0.account_type == "broker" }.map { $0.id })
    }
    private var cryptoIDs: Set<String> {
        Set(accounts.filter { $0.account_type == "crypto_wallet" }.map { $0.id })
    }

    // ── Sort helper ───────────────────────────────────────────────────────────
    private func applySortMode(_ items: [APIService.ValuationPortfolioItem]) -> [APIService.ValuationPortfolioItem] {
        switch sortMode {
        case .value: return items.sorted { $0.value_in_base > $1.value_in_base }
        case .gain:
            return items.sorted { a, b in
                let pa = a.avg_cost > 0 ? ((a.price_usd - a.avg_cost) / a.avg_cost) : 0
                let pb = b.avg_cost > 0 ? ((b.price_usd - b.avg_cost) / b.avg_cost) : 0
                return pa > pb
            }
        case .name: return items.sorted { $0.symbol < $1.symbol }
        }
    }

    // ── Holdings ──────────────────────────────────────────────────────────────
    private var stockItems: [APIService.ValuationPortfolioItem] {
        let raw = (valuation?.portfolio ?? [])
            .filter { brokerIDs.contains($0.account_id) && $0.quantity > 0.000001 }
        return applySortMode(raw)
    }
    private var cryptoItems: [APIService.ValuationPortfolioItem] {
        let raw = (valuation?.portfolio ?? [])
            .filter { cryptoIDs.contains($0.account_id) && $0.quantity > 0.000001 }
        return applySortMode(raw)
    }
    private var allItems: [APIService.ValuationPortfolioItem] { stockItems + cryptoItems }

    // ── Totals ────────────────────────────────────────────────────────────────
    private var totalStocks: Double { stockItems.reduce(0) { $0 + $1.value_in_base } }
    private var totalCrypto: Double { cryptoItems.reduce(0) { $0 + $1.value_in_base } }
    private var totalValue:  Double { totalStocks + totalCrypto }
    private var totalCost: Double {
        allItems.reduce(0) { sum, item in
            guard item.price_usd > 0 else { return sum }
            return sum + item.value_in_base * (item.avg_cost / item.price_usd)
        }
    }
    private var totalPL:    Double { totalValue - totalCost }
    private var totalPLPct: Double { totalCost > 0 ? (totalPL / totalCost) * 100 : 0 }

    // ── Formatting ────────────────────────────────────────────────────────────
    private func fmtValue(_ v: Double) -> String { fmtCurrency(v, currency: baseCurrency) }

    // ── Body ──────────────────────────────────────────────────────────────────
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading dashboard…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundColor(.red)
                        Text(err)
                            .multilineTextAlignment(.center).foregroundColor(.secondary)
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }.padding()
                } else if allItems.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            totalCard
                            allocationCards
                            allocationChart
                            if !stockItems.isEmpty {
                                holdingsSection(title: "Stocks", items: stockItems, isStock: true)
                            }
                            if !cryptoItems.isEmpty {
                                holdingsSection(title: "Crypto", items: cryptoItems, isStock: false)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        // Sort menu
                        Menu {
                            ForEach(SortMode.allCases, id: \.self) { mode in
                                Button {
                                    withAnimation { sortMode = mode }
                                } label: {
                                    Label(mode.rawValue,
                                          systemImage: sortMode == mode ? "checkmark" : "")
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption.bold())
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                                .foregroundColor(.primary)
                        }

                        // Currency menu (local to Portfolio only)
                        Menu {
                            ForEach(Self.currencies, id: \.self) { currency in
                                Button {
                                    localCurrency = currency
                                    Task { await load() }
                                } label: {
                                    Label(currency,
                                          systemImage: baseCurrency == currency ? "checkmark" : "")
                                }
                            }
                        } label: {
                            Text(baseCurrency)
                                .font(.caption.bold())
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .task {
                if localCurrency.isEmpty { localCurrency = appBaseCurrency }
                await load()
            }
            .refreshable { await load() }
        }
    }

    // ── Empty state ────────────────────────────────────────────────────────────
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 64))
                .foregroundColor(.blue.opacity(0.3))
            Text("No Holdings Yet").font(.title2.bold())
            Text("Add broker accounts in the Stocks tab or crypto wallets in the Crypto tab to see your dashboard.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // ── Allocation donut chart ────────────────────────────────────────────────
    private struct SliceData: Identifiable {
        let id    = UUID()
        let label: String
        let value: Double
        let color: Color
    }

    private var allocationChart: some View {
        // Build up to top-5 holdings + "Other" slice
        let topN   = 5
        let sorted = allItems.sorted { $0.value_in_base > $1.value_in_base }
        var slices: [SliceData] = []

        // Assign a colour to each of the top-N holdings
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .yellow]
        for (i, item) in sorted.prefix(topN).enumerated() {
            slices.append(SliceData(
                label: item.symbol,
                value: item.value_in_base,
                color: palette[i % palette.count]
            ))
        }
        let otherValue = sorted.dropFirst(topN).reduce(0) { $0 + $1.value_in_base }
        if otherValue > 0 {
            slices.append(SliceData(label: "Other", value: otherValue, color: .secondary))
        }

        return VStack(alignment: .leading, spacing: 14) {
            Text("Allocation")
                .font(.headline)
                .padding(.horizontal, 2)

            HStack(alignment: .center, spacing: 24) {
                // Donut
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Value", slice.value),
                        innerRadius: .ratio(0.58),
                        angularInset: 2
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(5)
                }
                .frame(width: 140, height: 140)
                .overlay {
                    VStack(spacing: 2) {
                        Text(fmtValue(totalValue))
                            .font(.caption2.bold())
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("Total")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                }

                // Legend
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(slices) { slice in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(slice.color)
                                .frame(width: 12, height: 12)
                            Text(slice.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(totalValue > 0
                                 ? String(format: "%.1f%%", (slice.value / totalValue) * 100)
                                 : "—")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(20)
    }

    // ── Total portfolio card ───────────────────────────────────────────────────
    private var totalCard: some View {
        let plPositive = totalPL >= 0

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Investments")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 0.4, green: 1.0, blue: 0.6)).frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.caption2.bold())
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
            }

            // Value
            Text(fmtValue(totalValue))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.6).lineLimit(1)
                .padding(.top, 8)

            Text(baseCurrency)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.5))
                .padding(.top, 2)

            // Allocation bar
            if totalValue > 0 {
                GeometryReader { geo in
                    HStack(spacing: 3) {
                        if totalStocks > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 0.4, green: 1.0, blue: 0.7))
                                .frame(width: max(4, geo.size.width * (totalStocks / totalValue)))
                        }
                        if totalCrypto > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 1.0, green: 0.70, blue: 0.3))
                                .frame(width: max(4, geo.size.width * (totalCrypto / totalValue)))
                        }
                    }
                }
                .frame(height: 5)
                .padding(.top, 18)

                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Circle().fill(Color(red: 0.4, green: 1.0, blue: 0.7)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Stocks").font(.caption2).foregroundColor(.white.opacity(0.6))
                            Text("\(totalValue > 0 ? Int((totalStocks / totalValue) * 100) : 0)%")
                                .font(.caption2.bold()).foregroundColor(.white.opacity(0.9))
                        }
                    }
                    HStack(spacing: 5) {
                        Circle().fill(Color(red: 1.0, green: 0.70, blue: 0.3)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Crypto").font(.caption2).foregroundColor(.white.opacity(0.6))
                            Text("\(totalValue > 0 ? Int((totalCrypto / totalValue) * 100) : 0)%")
                                .font(.caption2.bold()).foregroundColor(.white.opacity(0.9))
                        }
                    }
                    Spacer()
                    // P&L inline badge
                    HStack(spacing: 4) {
                        Image(systemName: plPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2.bold())
                        Text((plPositive ? "+" : "") + pctStr(totalPLPct))
                            .font(.caption.bold())
                    }
                    .foregroundColor(plPositive ? Color(red: 0.4, green: 1.0, blue: 0.6) : Color(red: 1.0, green: 0.5, blue: 0.5))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }
                .padding(.top, 10)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.48, blue: 0.32),
                        Color(red: 0.04, green: 0.34, blue: 0.52)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.white.opacity(0.10), Color.clear],
                    center: .topTrailing, startRadius: 0, endRadius: 220
                )
            }
        )
        .cornerRadius(26)
        .shadow(color: Color(red: 0.04, green: 0.38, blue: 0.28).opacity(0.4), radius: 16, x: 0, y: 6)
        .padding(.top, 8)
    }

    // ── 2×2 stat tile grid ────────────────────────────────────────────────────
    private var allocationCards: some View {
        let plColor: Color = totalPL >= 0 ? Color(red: 0.09, green: 0.70, blue: 0.45)
                                          : Color(red: 0.97, green: 0.25, blue: 0.36)
        let topHolding  = allItems.max(by: { $0.value_in_base < $1.value_in_base })
        let topPL: Double = {
            guard let t = topHolding, t.avg_cost > 0 else { return 0 }
            return ((t.price_usd - t.avg_cost) / t.avg_cost) * 100
        }()

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Stocks tile
                statTile(
                    icon: "chart.bar.fill", accent: Color(red: 0.09, green: 0.70, blue: 0.45),
                    title: "Stocks",
                    value: fmtValue(totalStocks),
                    badge: totalValue > 0
                        ? "\(Int((totalStocks / totalValue) * 100))%"
                        : "—"
                )
                // Crypto tile
                statTile(
                    icon: "bitcoinsign.circle.fill", accent: .orange,
                    title: "Crypto",
                    value: fmtValue(totalCrypto),
                    badge: totalValue > 0
                        ? "\(Int((totalCrypto / totalValue) * 100))%"
                        : "—"
                )
            }
            HStack(spacing: 12) {
                // P&L tile
                statTile(
                    icon: totalPL >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill",
                    accent: plColor,
                    title: "P&L",
                    value: (totalPL >= 0 ? "+" : "") + fmtValue(totalPL),
                    badge: pctStr(totalPLPct),
                    valueColor: plColor
                )
                // Top holding tile
                if let top = topHolding {
                    let tColor: Color = topPL >= 0
                        ? Color(red: 0.09, green: 0.70, blue: 0.45)
                        : Color(red: 0.97, green: 0.25, blue: 0.36)
                    statTile(
                        icon: "star.fill", accent: Color(red: 0.85, green: 0.65, blue: 0.10),
                        title: "Best Hold",
                        value: top.symbol,
                        badge: pctStr(topPL),
                        badgeColor: tColor
                    )
                } else {
                    statTile(
                        icon: "list.bullet.circle.fill", accent: .indigo,
                        title: "Positions",
                        value: "\(allItems.count)",
                        badge: "\(stockItems.count) stocks · \(cryptoItems.count) crypto"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func statTile(
        icon: String, accent: Color, title: String,
        value: String, badge: String,
        valueColor: Color? = nil, badgeColor: Color? = nil
    ) -> some View {

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accent.opacity(0.13))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Spacer()
                Text(badge)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(badgeColor ?? accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background((badgeColor ?? accent).opacity(0.10))
                    .clipShape(Capsule())
            }

            Spacer()

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(valueColor ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.top, 14)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.top, 3)

            Text("Investment")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color(red: 0.83, green: 0.67, blue: 0.22).opacity(0.5), lineWidth: 1.5)
        )
    }

    // ── Holdings section ───────────────────────────────────────────────────────
    private func holdingsSection(
        title: String,
        items: [APIService.ValuationPortfolioItem],
        isStock: Bool
    ) -> some View {
        let accent: Color = isStock ? Color(red: 0.18, green: 0.80, blue: 0.44) : .orange
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent.opacity(0.12))
                            .frame(width: 28, height: 28)
                        Image(systemName: isStock ? "chart.bar.fill" : "bitcoinsign.circle.fill")
                            .foregroundColor(accent)
                            .font(.caption.bold())
                    }
                    Text(title).font(.headline)
                }
                Spacer()
                Text("\(items.count) position\(items.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(items) { item in
                    holdingRow(item, isStock: isStock)
                    if item.id != items.last?.id {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(20)
        }
    }

    @ViewBuilder
    private func holdingRow(_ item: APIService.ValuationPortfolioItem, isStock: Bool) -> some View {
        let pl       = item.avg_cost > 0 ? ((item.price_usd - item.avg_cost) / item.avg_cost) * 100 : 0.0
        let costBase = item.price_usd > 0 ? item.value_in_base * (item.avg_cost / item.price_usd) : 0.0
        let plBase   = item.value_in_base - costBase

        let accent: Color = isStock ? Color(red: 0.09, green: 0.70, blue: 0.45) : .orange
        let plColor: Color = pl >= 0 ? Color(red: 0.09, green: 0.70, blue: 0.45)
                                     : Color(red: 0.97, green: 0.25, blue: 0.36)

        return HStack(spacing: 14) {
            ZStack {
                if isStock {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accent.opacity(0.10))
                        .frame(width: 44, height: 44)
                    AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(item.symbol)?format=jpg")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        default:
                            Text(String(item.symbol.prefix(3)))
                                .font(.caption.bold()).foregroundColor(accent)
                        }
                    }
                } else {
                    Circle()
                        .fill(accent.opacity(0.10))
                        .frame(width: 44, height: 44)
                    if let url = cryptoImages[item.symbol.uppercased()].flatMap(URL.init) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFit()
                                    .frame(width: 32, height: 32).clipShape(Circle())
                            default:
                                Text(String(item.symbol.prefix(3)))
                                    .font(.caption.bold()).foregroundColor(accent)
                            }
                        }
                    } else {
                        Text(String(item.symbol.prefix(3)))
                            .font(.caption.bold()).foregroundColor(accent)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.symbol).font(.subheadline.bold())
                Text(item.asset_name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                if item.avg_cost > 0 {
                    Text("avg \(fmtPrice(item.avg_cost)) · now \(fmtPrice(item.price_usd))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(fmtValue(item.value_in_base)).font(.subheadline.bold())
                if item.avg_cost > 0 {
                    Text((plBase >= 0 ? "+" : "") + fmtValue(plBase))
                        .font(.caption.bold())
                        .foregroundColor(plColor)
                    Text(pctStr(pl))
                        .font(.caption2.bold())
                        .foregroundColor(plColor)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // ── Data loading ───────────────────────────────────────────────────────────
    private func load() async {
        isLoading = true; errorMessage = nil; defer { isLoading = false }
        do {
            async let accFetch = APIService.shared.fetchAccounts()
            async let valFetch = APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            accounts  = try await accFetch
            valuation = try await valFetch
            await loadCryptoImages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCryptoImages() async {
        let symbols = Array(Set(cryptoItems.map { $0.symbol.uppercased() }))
        await withTaskGroup(of: (String, String?).self) { group in
            for symbol in symbols {
                group.addTask {
                    guard let results = try? await APIService.shared.searchCrypto(query: symbol),
                          let match   = results.first(where: { $0.symbol.uppercased() == symbol })
                                        ?? results.first
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
}
