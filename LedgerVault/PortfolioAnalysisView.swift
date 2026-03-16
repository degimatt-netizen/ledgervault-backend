import SwiftUI
import Charts

struct PortfolioAnalysisView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("baseCurrency") private var baseCurrency = "EUR"

    @State private var valuation: APIService.ValuationResponse?
    @State private var accounts: [APIService.Account] = []
    @State private var isLoading = false
    @State private var lastUpdated: Date?
    @State private var selectedTab = "Performance"
    @State private var errorMessage: String?

    private let tabs    = ["Performance", "Risk", "Allocation"]
    private let refresh: TimeInterval = 30

    // ── Derived metrics ───────────────────────────────────────────────────────
    private var portfolio: [APIService.ValuationPortfolioItem] {
        (valuation?.portfolio ?? []).filter {
            !fiatSymbols.contains($0.symbol.uppercased())
        }
    }

    private let fiatSymbols: Set<String> = [
        "USD","EUR","GBP","CHF","CAD","AUD","JPY","PLN","SEK","NOK","CZK"
    ]

    private var totalValue:    Double { valuation?.total   ?? 0 }
    private var totalInvested: Double { portfolio.reduce(0) { $0 + ($1.avg_cost * $1.quantity) } }
    private var totalGain:     Double { totalValue - totalInvested }
    private var totalROI:      Double { totalInvested > 0 ? (totalGain / totalInvested) * 100 : 0 }

    private var cryptoValue: Double {
        let ids = Set(accounts.filter { $0.account_type == "crypto_wallet" }.map { $0.id })
        return portfolio.filter { ids.contains($0.account_id) }.reduce(0) { $0 + $1.value_in_base }
    }
    private var stockValue: Double { valuation?.stocks ?? 0 }
    private var cryptoPct:  Double { totalValue > 0 ? cryptoValue / totalValue * 100 : 0 }
    private var stockPct:   Double { totalValue > 0 ? stockValue  / totalValue * 100 : 0 }

    // Risk score: 0-100 based on crypto concentration
    private var riskScore: Int {
        let cryptoWeight = totalValue > 0 ? cryptoValue / totalValue : 0
        let stockWeight  = totalValue > 0 ? stockValue  / totalValue : 0
        let concentration = portfolio.isEmpty ? 0.0 :
            portfolio.map { $0.value_in_base / max(totalValue, 1) }.max() ?? 0
        return min(100, Int(cryptoWeight * 60 + stockWeight * 30 + concentration * 30))
    }

    private var riskLabel: String {
        switch riskScore {
        case 0..<25:  return "Low Risk"
        case 25..<50: return "Moderate Risk"
        case 50..<75: return "High Risk"
        default:      return "Extreme Risk"
        }
    }

    private var riskColor: Color {
        switch riskScore {
        case 0..<25:  return .green
        case 25..<50: return .yellow
        case 50..<75: return .orange
        default:      return .red
        }
    }

    // Sharpe approximation: ROI / estimated volatility
    private var sharpeRatio: Double {
        let vol = cryptoPct > 50 ? 35.0 : cryptoPct > 25 ? 20.0 : 10.0
        return vol > 0 ? (totalROI - 4.0) / vol : 0
    }

    // Beta vs market (crypto heavy = high beta)
    private var beta: Double {
        return 0.5 + (cryptoPct / 100) * 1.5 + (stockPct / 100) * 0.8
    }

    // Alpha = ROI - (beta * market_return) where market_return ≈ 10%
    private var alpha: Double {
        return totalROI - (beta * 10.0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Tab picker ────────────────────────────────────────────
                Picker("Tab", selection: $selectedTab) {
                    ForEach(tabs, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if isLoading && valuation == nil {
                    Spacer()
                    ProgressView("Loading analysis…")
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Footer timestamp
                            HStack {
                                Text("Live prices • Updated \(lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "now")")
                                    .font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Button("Refresh") { Task { await load() } }
                                    .font(.caption.weight(.bold))
                            }
                            .padding(.horizontal, 4)

                            if selectedTab == "Performance" {
                                performanceTab
                            } else if selectedTab == "Risk" {
                                riskTab
                            } else {
                                allocationTab
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Portfolio Analysis")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await load() }
            .task { await startLiveRefresh() }
            .refreshable { await load() }
        }
    }

    // ── PERFORMANCE TAB ───────────────────────────────────────────────────────
    private var performanceTab: some View {
        VStack(spacing: 16) {
            // 4 metric cards
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metricCard("TOTAL ROI",    String(format: "%.2f%%", totalROI),
                           totalROI >= 0 ? "+" + String(format: "%.2f%%", totalROI) : String(format: "%.2f%%", totalROI),
                           totalROI >= 0 ? .green : .red,
                           "Total return on invested capital",
                           fmt(totalGain) + " gain")

                metricCard("SHARPE RATIO", String(format: "%.2f", sharpeRatio),
                           String(format: "%.2f", sharpeRatio),
                           sharpeRatio >= 1 ? .green : sharpeRatio >= 0 ? .orange : .red,
                           sharpeRatio >= 1 ? "Good risk-adjusted return" : "Below risk-free rate",
                           nil)

                metricCard("ALPHA",       String(format: "%.2f%%", alpha),
                           String(format: "%.2f%%", alpha),
                           alpha >= 0 ? .green : .red,
                           "vs 10% market benchmark",
                           nil)

                metricCard("BETA",        String(format: "%.2f", beta),
                           String(format: "%.2f", beta),
                           beta > 1.5 ? .red : beta > 1 ? .orange : .green,
                           beta > 1.5 ? "High volatility" : beta > 1 ? "Above market" : "Below market",
                           nil)
            }

            // Total Invested / Current Value
            HStack(spacing: 12) {
                summaryTile("TOTAL INVESTED", fmt(totalInvested), "Cost basis", .secondary)
                summaryTile("CURRENT VALUE",  fmt(totalValue),    "Market value", .primary)
            }

            // Individual Asset Returns bar chart
            if !portfolio.isEmpty {
                assetReturnsChart
            }

            // Radar
            radarChart
        }
    }

    @ViewBuilder
    private func metricCard(_ label: String, _ display: String, _ value: String, _ color: Color, _ subtitle: String, _ extra: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption2.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)
            Text(value).font(.title2.weight(.bold)).foregroundColor(color)
            Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            if let extra { Text(extra).font(.caption2).foregroundColor(color).lineLimit(1) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 6)
    }

    @ViewBuilder
    private func summaryTile(_ label: String, _ value: String, _ sub: String, _ col: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)
            Text(value).font(.title3.weight(.bold))
            Text(sub).font(.caption2).foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 6)
    }

    private var assetReturnsChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INDIVIDUAL ASSET RETURNS")
                .font(.caption.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)

            Chart(portfolio.prefix(6), id: \.id) { item in
                let pl = item.avg_cost > 0
                    ? ((item.price_usd - item.avg_cost) / item.avg_cost) * 100 : 0
                BarMark(
                    x: .value("Return", pl),
                    y: .value("Asset", item.symbol)
                )
                .foregroundStyle(pl >= 0 ? Color.green : Color.red)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f%%", d)) } }
                    AxisGridLine()
                }
            }
            .frame(height: max(80, CGFloat(min(portfolio.count, 6)) * 36))
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(18)
    }

    private var radarChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PORTFOLIO HEALTH RADAR")
                .font(.caption.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)

            // Simple polygon radar using Canvas
            let labels = ["ROI", "Alpha", "Sharpe", "Beta", "Diversif."]
            let scores: [Double] = [
                min(max(totalROI / 20 + 0.5, 0), 1),
                min(max(alpha   / 20 + 0.5, 0), 1),
                min(max(sharpeRatio / 3 + 0.5, 0), 1),
                min(max(1 - (beta - 1) / 2, 0), 1),
                min(max(Double(portfolio.count) / 10, 0), 1),
            ]

            ZStack {
                RadarShape(scores: Array(repeating: 1.0, count: 5))
                    .stroke(Color(.systemGray4), lineWidth: 1)
                RadarShape(scores: Array(repeating: 0.5, count: 5))
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
                RadarShape(scores: scores)
                    .fill(Color.blue.opacity(0.25))
                RadarShape(scores: scores)
                    .stroke(Color.blue, lineWidth: 2)

                // Labels
                ForEach(0..<5, id: \.self) { i in
                    let angle = Double(i) * (2 * .pi / 5) - .pi / 2
                    let x = cos(angle) * 110 + 130
                    let y = sin(angle) * 110 + 130
                    Text(labels[i])
                        .font(.caption2).foregroundColor(.secondary)
                        .position(x: x, y: y)
                }
            }
            .frame(width: 260, height: 260)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(18)
    }

    // ── RISK TAB ──────────────────────────────────────────────────────────────
    private var riskTab: some View {
        VStack(spacing: 16) {
            // Risk score card
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OVERALL RISK SCORE").font(.caption2.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(riskScore)").font(.system(size: 52, weight: .bold)).foregroundColor(riskColor)
                        Text("/100").font(.title3).foregroundColor(.secondary)
                    }
                    Text(riskLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(riskColor.opacity(0.15))
                        .foregroundColor(riskColor)
                        .cornerRadius(8)
                    Text(riskScore > 50 ? "High volatility exposure. Consider diversifying." : "Portfolio risk is within reasonable bounds.")
                        .font(.caption).foregroundColor(.secondary).padding(.top, 4)
                }
                Spacer()
                // Mini gauge
                ZStack {
                    Circle().trim(from: 0, to: 0.75)
                        .stroke(Color(.systemGray5), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(135))
                    Circle().trim(from: 0, to: 0.75 * Double(riskScore) / 100)
                        .stroke(riskColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(135))
                }
                .frame(width: 80, height: 80)
            }
            .padding(16)
            .background(Color(.systemBackground))
            .cornerRadius(18)
            .shadow(color: .black.opacity(0.05), radius: 6)

            // Risk breakdown bars
            VStack(alignment: .leading, spacing: 12) {
                Text("RISK FACTORS").font(.caption.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)
                riskBar("Crypto Exposure",      cryptoPct,  .red)
                riskBar("Stock Exposure",        stockPct,   .orange)
                riskBar("Concentration Risk",    portfolio.isEmpty ? 0 : (portfolio.first?.value_in_base ?? 0) / max(totalValue, 1) * 100, .yellow)
                riskBar("Stable Assets",         max(0, 100 - cryptoPct - stockPct), .green)
            }
            .padding(16)
            .background(Color(.systemGray6))
            .cornerRadius(18)

            // Asset exposure donut
            if !portfolio.isEmpty {
                assetExposureDonut
            }

            // Position concentration
            positionConcentration
        }
    }

    @ViewBuilder
    private func riskBar(_ label: String, _ pct: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(String(format: "%.1f%%", pct)).font(.subheadline.weight(.semibold)).foregroundColor(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(color)
                        .frame(width: max(0, CGFloat(pct / 100) * geo.size.width), height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private var assetExposureDonut: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RISK EXPOSURE BY ASSET CLASS")
                .font(.caption.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)

            let data: [(String, Double, Color)] = [
                ("Stocks", stockPct, .orange),
                ("Crypto", cryptoPct, .red),
            ].filter { $0.1 > 0 }

            HStack(spacing: 20) {
                Chart(data, id: \.0) { item in
                    SectorMark(angle: .value("Value", item.1), innerRadius: .ratio(0.55))
                        .foregroundStyle(item.2)
                }
                .frame(width: 130, height: 130)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(data, id: \.0) { item in
                        HStack(spacing: 8) {
                            Circle().fill(item.2).frame(width: 8, height: 8)
                            Text(item.0).font(.subheadline)
                            Spacer()
                            Text(String(format: "%.1f%%", item.1)).font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(18)
    }

    private var positionConcentration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("POSITION CONCENTRATION RISK")
                .font(.caption.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)

            ForEach(portfolio.prefix(6)) { item in
                let pct = totalValue > 0 ? item.value_in_base / totalValue * 100 : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.symbol).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.1f%%", pct)).font(.caption.weight(.semibold))
                            .foregroundColor(pct > 40 ? .red : pct > 20 ? .orange : .secondary)
                        Text("· \(fmt(item.value_in_base))").font(.caption).foregroundColor(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray5)).frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(pct > 40 ? Color.red : pct > 20 ? Color.orange : Color.blue)
                                .frame(width: max(0, CGFloat(pct / 100) * geo.size.width), height: 6)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(18)
    }

    // ── ALLOCATION TAB ────────────────────────────────────────────────────────
    private var allocationTab: some View {
        VStack(spacing: 16) {
            // 3 donuts side by side
            HStack(spacing: 12) {
                donutCard("BY SECTOR",    sectorData)
                donutCard("BY GEOGRAPHY", geoData)
                donutCard("BY MARKET CAP",capData)
            }

            // Treemap / allocation map
            if !portfolio.isEmpty {
                allocationMap
            }

            // Table breakdown
            allocationTable
        }
    }

    // Sector: classify by asset_class
    private var sectorData: [(String, Double, Color)] {
        var d: [(String, Double, Color)] = []
        let crypto = portfolio.filter { $0.asset_class.lowercased() == "crypto" }.reduce(0) { $0 + $1.value_in_base }
        let stocks = portfolio.filter { $0.asset_class.lowercased() == "stock" || $0.asset_class.lowercased() == "etf" }.reduce(0) { $0 + $1.value_in_base }
        let stable = (valuation?.total ?? 0) - crypto - stocks
        if crypto > 0 { d.append(("Crypto", crypto / max(totalValue,1) * 100, .orange)) }
        if stocks > 0 { d.append(("Stocks", stocks / max(totalValue,1) * 100, .green)) }
        if stable > 0 { d.append(("Cash/Stable", stable / max(totalValue,1) * 100, .blue)) }
        return d
    }

    private var geoData: [(String, Double, Color)] {
        // Stocks = US, Crypto = Global
        let usVal     = portfolio.filter { $0.asset_class.lowercased() == "stock" }.reduce(0) { $0 + $1.value_in_base }
        let globalVal = totalValue - usVal
        var d: [(String, Double, Color)] = []
        if usVal     > 0 { d.append(("US",     usVal     / max(totalValue,1) * 100, .blue)) }
        if globalVal > 0 { d.append(("Global", globalVal / max(totalValue,1) * 100, Color(hex: "B8860B"))) }
        return d
    }

    private var capData: [(String, Double, Color)] {
        // All holdings are large cap for now
        return [("Large Cap", 100.0, Color(hex: "B8860B"))]
    }

    @ViewBuilder
    private func donutCard(_ title: String, _ data: [(String, Double, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption2.weight(.semibold)).foregroundColor(.secondary)

            if data.isEmpty {
                Circle().fill(Color(.systemGray5)).frame(width: 70, height: 70)
            } else {
                Chart(data, id: \.0) { item in
                    SectorMark(angle: .value("Pct", item.1), innerRadius: .ratio(0.55))
                        .foregroundStyle(item.2)
                }
                .frame(width: 70, height: 70)
            }

            ForEach(data, id: \.0) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.2).frame(width: 6, height: 6)
                    Text(item.0).font(.caption2).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", item.1)).font(.caption2.weight(.semibold))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .cornerRadius(14)
    }

    private var allocationMap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TOP HOLDINGS ALLOCATION MAP")
                .font(.caption.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(portfolio.prefix(5)) { item in
                        let pct = totalValue > 0 ? item.value_in_base / totalValue : 0
                        let color: Color = item.asset_class.lowercased() == "crypto" ? .orange : .green
                        ZStack {
                            Rectangle().fill(color.opacity(0.3))
                            VStack(spacing: 2) {
                                Text(item.symbol).font(.caption.weight(.bold)).foregroundColor(.primary)
                                Text(String(format: "%.1f%%", pct * 100)).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .frame(width: max(20, CGFloat(pct) * geo.size.width))
                    }
                }
                .cornerRadius(8)
            }
            .frame(height: 80)
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(18)
    }

    private var allocationTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ALL HOLDINGS").font(.caption.weight(.semibold)).foregroundColor(.secondary).tracking(0.5)

            ForEach(portfolio) { item in
                HStack {
                    Circle().fill(item.asset_class.lowercased() == "crypto" ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(item.symbol).font(.subheadline.weight(.semibold))
                    Text(item.asset_name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(fmt(item.value_in_base)).font(.subheadline.weight(.semibold))
                        let pct = totalValue > 0 ? item.value_in_base / totalValue * 100 : 0
                        Text(String(format: "%.1f%%", pct)).font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if item.id != portfolio.last?.id { Divider() }
            }
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(18)
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let v = APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            async let a = APIService.shared.fetchAccounts()
            valuation = try await v
            accounts  = try await a
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startLiveRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(refresh * 1_000_000_000))
            await load()
        }
    }

    private func fmt(_ v: Double) -> String {
        let s: String
        switch baseCurrency {
        case "EUR": s = "€"; case "USD": s = "$"; case "GBP": s = "£"
        default: s = baseCurrency + " "
        }
        return s + v.formatted(.number.precision(.fractionLength(2)))
    }
}

// ── Radar chart shape ─────────────────────────────────────────────────────────
struct RadarShape: Shape {
    let scores: [Double]
    func path(in rect: CGRect) -> Path {
        guard !scores.isEmpty else { return Path() }
        let cx = rect.midX, cy = rect.midY
        let r  = min(rect.width, rect.height) / 2 * 0.8
        let n  = scores.count
        var path = Path()
        for (i, score) in scores.enumerated() {
            let angle = Double(i) * (2 * .pi / Double(n)) - .pi / 2
            let x = cx + CGFloat(cos(angle) * r * score)
            let y = cy + CGFloat(sin(angle) * r * score)
            i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }
}
