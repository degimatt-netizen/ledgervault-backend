import SwiftUI

// ── InvestmentDashboardView ───────────────────────────────────────────────────
struct InvestmentDashboardView: View {

    @AppStorage("baseCurrency") private var baseCurrency = "USD"

    @State private var valuation:    APIService.ValuationResponse?
    @State private var accounts:     [APIService.Account] = []
    @State private var cryptoImages: [String: String]     = [:]
    @State private var isLoading     = true
    @State private var errorMessage: String?

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
                        VStack(spacing: 20) {
                            totalCard
                            allocationCards
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
            .navigationTitle("Dashboard")
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

                        // Currency menu
                        Menu {
                            ForEach(Self.currencies, id: \.self) { currency in
                                Button {
                                    baseCurrency = currency
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
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: baseCurrency) { _, _ in Task { await load() } }
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

    // ── Total portfolio card ───────────────────────────────────────────────────
    private var totalCard: some View {
        VStack(spacing: 8) {
            Text("Total Portfolio")
                .font(.caption).foregroundColor(.secondary)
            Text(fmtValue(totalValue))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7).lineLimit(1)
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: totalPL >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.bold())
                        .foregroundColor(totalPL >= 0 ? .green : .red)
                    Text((totalPL >= 0 ? "+" : "") + fmtValue(totalPL))
                        .font(.subheadline.bold())
                        .foregroundColor(totalPL >= 0 ? .green : .red)
                }
                Text(pctStr(totalPLPct))
                    .font(.subheadline.bold())
                    .foregroundColor(totalPLPct >= 0 ? .green : .red)
            }
            Text("Invested \(fmtValue(totalCost))")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.top, 8)
    }

    // ── Allocation cards (horizontal scroll) ──────────────────────────────────
    private var allocationCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                miniCard(
                    icon: "chart.bar.fill", iconColor: .green,
                    title: "Stocks", value: fmtValue(totalStocks),
                    sub: totalValue > 0
                        ? "\((totalStocks / totalValue * 100).formatted(.number.precision(.fractionLength(1))))% of total"
                        : "—"
                )
                miniCard(
                    icon: "bitcoinsign.circle.fill", iconColor: .orange,
                    title: "Crypto", value: fmtValue(totalCrypto),
                    sub: totalValue > 0
                        ? "\((totalCrypto / totalValue * 100).formatted(.number.precision(.fractionLength(1))))% of total"
                        : "—"
                )
                // P&L card
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: totalPL >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                            .font(.caption.bold())
                            .foregroundColor(totalPL >= 0 ? .green : .red)
                        Text("P&L").font(.caption).foregroundColor(.secondary)
                    }
                    Text((totalPL >= 0 ? "+" : "") + fmtValue(totalPL))
                        .font(.headline.bold())
                        .foregroundColor(totalPL >= 0 ? .green : .red)
                    Text(pctStr(totalPLPct))
                        .font(.caption.bold())
                        .foregroundColor(totalPLPct >= 0 ? .green : .red)
                    Text("vs \(fmtValue(totalCost)) cost")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .frame(width: 150)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(14)

                // Top holding card
                if let top = allItems.max(by: { $0.value_in_base < $1.value_in_base }) {
                    let topPL = top.avg_cost > 0
                        ? ((top.price_usd - top.avg_cost) / top.avg_cost) * 100 : 0.0
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill")
                                .font(.caption.bold()).foregroundColor(.yellow)
                            Text("Top Holding").font(.caption).foregroundColor(.secondary)
                        }
                        Text(top.symbol).font(.headline.bold())
                        Text(fmtValue(top.value_in_base)).font(.subheadline.bold())
                        Text(pctStr(topPL))
                            .font(.caption.bold())
                            .foregroundColor(topPL >= 0 ? .green : .red)
                    }
                    .frame(width: 150)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func miniCard(icon: String, iconColor: Color, title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.bold()).foregroundColor(iconColor)
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            Text(value).font(.headline.bold())
            Text(sub).font(.caption).foregroundColor(.secondary)
        }
        .frame(width: 150)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    // ── Holdings section ───────────────────────────────────────────────────────
    private func holdingsSection(
        title: String,
        items: [APIService.ValuationPortfolioItem],
        isStock: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isStock ? "chart.bar.fill" : "bitcoinsign.circle.fill")
                    .foregroundColor(isStock ? .green : .orange)
                    .font(.subheadline)
                Text(title).font(.headline)
                Spacer()
                Text("\(items.count) holding\(items.count == 1 ? "" : "s")")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(items) { item in
                    holdingRow(item, isStock: isStock)
                    if item.id != items.last?.id {
                        Divider().padding(.leading, 60)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
    }

    @ViewBuilder
    private func holdingRow(_ item: APIService.ValuationPortfolioItem, isStock: Bool) -> some View {
        let pl       = item.avg_cost > 0 ? ((item.price_usd - item.avg_cost) / item.avg_cost) * 100 : 0.0
        let costBase = item.price_usd > 0 ? item.value_in_base * (item.avg_cost / item.price_usd) : 0.0
        let plBase   = item.value_in_base - costBase

        HStack(spacing: 14) {
            ZStack {
                if isStock {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 44, height: 44)
                    AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(item.symbol)?format=jpg")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        default:
                            Text(String(item.symbol.prefix(3)))
                                .font(.caption.bold()).foregroundColor(.green)
                        }
                    }
                } else {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 44, height: 44)
                    if let url = cryptoImages[item.symbol.uppercased()].flatMap(URL.init) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFit()
                                    .frame(width: 32, height: 32).clipShape(Circle())
                            default:
                                Text(String(item.symbol.prefix(3)))
                                    .font(.caption.bold()).foregroundColor(.orange)
                            }
                        }
                    } else {
                        Text(String(item.symbol.prefix(3)))
                            .font(.caption.bold()).foregroundColor(.orange)
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
                        .foregroundColor(pl >= 0 ? .green : .red)
                    Text(pctStr(pl))
                        .font(.caption2.bold())
                        .foregroundColor(pl >= 0 ? .green : .red)
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
