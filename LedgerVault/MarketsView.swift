import Combine
import SwiftUI
import UserNotifications

// MARK: - Logo image loader (primary → fallback → avatar)

struct LogoImageView<Placeholder: View>: View {
    let urls: [URL]
    let placeholder: Placeholder

    @State private var urlIndex = 0

    var body: some View {
        Group {
            if urlIndex >= urls.count {
                placeholder
            } else {
                AsyncImage(url: urls[urlIndex]) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    case .failure:
                        placeholder.onAppear { urlIndex += 1 }
                    default:
                        placeholder
                    }
                }
                .id(urlIndex) // force view refresh when index changes
            }
        }
    }
}

// MARK: - Logo (real image + avatar fallback)

struct SymbolLogo: View {
    let symbol: String

    // Strip exchange suffix to get the base ticker
    private var cleanSymbol: String {
        // Remove known exchange suffixes
        let suffixes = ["-USD", ".L", ".AS", ".PA", ".DE", ".AE", ".MI", ".SW",
                        ".HK", ".T", ".TO", ".AX", ".MX", ".SA", ".NE", ".VI",
                        ".ST", ".CO", ".OL", ".HE", ".BR", ".LS", ".MC", ".IR",
                        ".WA", ".PR", ".BU", ".AT", ".IS", ".SR", ".KW", ".QA",
                        ".CA", ".XD", ".F", ".BE", ".MU", ".DU", ".HA", ".TI"]
        var s = symbol
        for suffix in suffixes {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)); break }
        }
        return s
    }

    // Logo sources tried in order
    private var logoURLs: [URL] {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let cleanEncoded = cleanSymbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanSymbol
        return [
            // 1. Parqet with full symbol (covers many international stocks like MC.PA, MBG.DE)
            URL(string: "https://assets.parqet.com/logos/symbol/\(encoded)?format=jpg"),
            // 2. Parqet with clean symbol (US tickers like AAPL, TSLA)
            URL(string: "https://assets.parqet.com/logos/symbol/\(cleanEncoded)?format=jpg"),
            // 3. FMP with clean symbol
            URL(string: "https://financialmodelingprep.com/image-stock/\(cleanEncoded).png"),
            // 4. Logo.dev using ticker as domain hint (works for many large companies)
            URL(string: "https://img.logo.dev/ticker/\(cleanEncoded)?token=pk_public&size=64"),
        ].compactMap { $0 }
    }

    private var avatarColor: Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .cyan, .red]
        return palette[abs(symbol.hashValue) % palette.count]
    }

    private var initials: String {
        String(cleanSymbol.prefix(2)).uppercased()
    }

    var body: some View {
        LogoImageView(urls: logoURLs, placeholder: avatarFallback)
            .frame(width: 40, height: 40)
    }

    private var avatarFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(avatarColor.opacity(0.18))
            Text(initials)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(avatarColor)
        }
    }
}

// MARK: - Sparkline

struct SparklineShape: Shape {
    let prices: [Double]
    func path(in rect: CGRect) -> Path {
        guard prices.count >= 2 else { return Path() }
        let mn = prices.min()!, mx = prices.max()!
        let range = mx == mn ? 1.0 : mx - mn
        var path = Path()
        for (i, p) in prices.enumerated() {
            let x = rect.width * CGFloat(i) / CGFloat(prices.count - 1)
            let y = rect.height * (1 - CGFloat((p - mn) / range))
            i == 0 ? path.move(to: .init(x: x, y: y)) : path.addLine(to: .init(x: x, y: y))
        }
        return path
    }
}

struct SparklineView: View {
    let symbol: String
    var changeIsPositive: Bool = true   // driven by quote.change_pct — not sparkline direction

    @State private var prices: [Double] = []
    @State private var loaded = false

    private var lineColor: Color { changeIsPositive ? Color(red: 0.2, green: 0.85, blue: 0.4) : Color(red: 1, green: 0.3, blue: 0.3) }

    var body: some View {
        ZStack {
            if prices.count >= 2 {
                SparklineShape(prices: prices)
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: lineColor.opacity(0.4), radius: 3)
            } else if loaded {
                Text("No chart")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            } else {
                Capsule().fill(Color.secondary.opacity(0.1))
            }
        }
        .frame(width: 68, height: 30)
        .task(id: symbol) {
            guard !loaded else { return }
            if let r = try? await APIService.shared.fetchSparkline(symbol: symbol) { prices = r.prices }
            loaded = true
        }
    }
}

// MARK: - Exchange helpers

private func exchangeInfo(_ raw: String?) -> (flag: String, name: String) {
    guard let raw = raw?.uppercased(), !raw.isEmpty else { return ("", "") }
    let flags: [(keys: [String], flag: String, name: String)] = [
        (["NMS","NGM","NCM","NASDAQGS","NASDAQGM","NASDAQCM","NASDAQ",
          "NASDAQ GLOBAL SELECT MARKET","NASDAQ GLOBAL MARKET","NASDAQ CAPITAL MARKET"], "🇺🇸", "NASDAQ"),
        (["NYQ","NYM","NYSE","NEW YORK STOCK EXCHANGE","NYSE ARCA","NYSE AMERICAN"],     "🇺🇸", "NYSE"),
        (["ASE","PCX","BATS","BTS","CBOE"],                                              "🇺🇸", "NYSE AMEX"),
        (["CBT","CME","NYB","NYF"],                                                      "🇺🇸", "CBOT/CME"),
        (["LSE","IOB"],                                                    "🇬🇧", "London"),
        (["EPA","PAR"],                                                    "🇫🇷", "Paris"),
        (["ETR","GER","XETRA"],                                            "🇩🇪", "Frankfurt"),
        (["AMS","EAM"],                                                    "🇳🇱", "Amsterdam"),
        (["MCE","BME"],                                                    "🇪🇸", "Madrid"),
        (["BIT","MIL"],                                                    "🇮🇹", "Milan"),
        (["SWX","EBS"],                                                    "🇨🇭", "Swiss"),
        (["STO","OMX"],                                                    "🇸🇪", "Stockholm"),
        (["HEL"],                                                          "🇫🇮", "Helsinki"),
        (["TOR","TSX"],                                                    "🇨🇦", "Toronto"),
        (["ASX"],                                                          "🇦🇺", "Sydney"),
        (["NZE"],                                                          "🇳🇿", "NZX"),
        (["HKG"],                                                          "🇭🇰", "Hong Kong"),
        (["TYO","JPX","OSA"],                                             "🇯🇵", "Tokyo"),
        (["SHH","SHZ"],                                                    "🇨🇳", "Shanghai"),
        (["KSC"],                                                          "🇰🇷", "Seoul"),
        (["BSE","NSE","BOM"],                                             "🇮🇳", "Mumbai"),
        (["SES","SGX"],                                                    "🇸🇬", "Singapore"),
        (["DFM"],                                                          "🇦🇪", "Dubai"),
        (["TAE"],                                                          "🇮🇱", "Tel Aviv"),
        (["SAU"],                                                          "🇸🇦", "Riyadh"),
        (["LSEETF","SBF"],                                                "🇬🇧", "LSE ETF"),
        (["IBIS2","IBIS"],                                                 "🇩🇪", "Xetra"),
    ]
    for row in flags {
        if row.keys.contains(raw) { return (row.flag, row.name) }
    }
    // Substring fallback for full exchange names (e.g. "NEW YORK STOCK EXCHANGE" contains "NYSE")
    for row in flags {
        if row.keys.contains(where: { raw.contains($0) }) { return (row.flag, row.name) }
    }
    return ("🌐", raw)
}

private func marketStateBadge(_ state: String?) -> (label: String, color: Color) {
    switch state?.uppercased() {
    case "REGULAR": return ("● OPEN",     .green)
    case "PRE":     return ("● PRE-MKT",  Color(red: 1, green: 0.8, blue: 0))
    case "POST":    return ("● POST-MKT", .orange)
    default:        return ("● CLOSED",   Color.secondary)
    }
}

// MARK: - Market Row

struct MarketRowView: View {
    let quote: APIService.MarketQuote
    let isEditMode: Bool
    let onRemove: () -> Void

    // Price flash state
    @State private var flashColor: Color? = nil
    @State private var prevPrice: Double  = 0

    private var up: Bool           { quote.change_pct >= 0 }
    private var changeColor: Color { up ? Color(red: 0.2, green: 0.85, blue: 0.4) : Color(red: 1, green: 0.3, blue: 0.3) }
    private var excInfo:           (flag: String, name: String) { exchangeInfo(quote.exchange) }
    private var mktBadge:          (label: String, color: Color) { marketStateBadge(quote.market_state) }
    private var isHeld: Bool       { (quote.position ?? 0) != 0 }
    private var canRemove: Bool    { (quote.in_watchlist ?? false) && !isHeld }

    // Unrealised P&L
    private var unrealisedPnL: Double? {
        guard let pos = quote.position, let avg = quote.avg_price, abs(pos) > 1e-8, avg > 0
        else { return nil }
        return (quote.last - avg) * pos
    }
    private var unrealisedPct: Double? {
        guard let pnl = unrealisedPnL, let avg = quote.avg_price, avg > 0,
              let pos = quote.position, abs(pos) > 1e-8
        else { return nil }
        return pnl / (avg * abs(pos)) * 100
    }

    var body: some View {
        HStack(spacing: 8) {
            // Edit-mode delete button
            if isEditMode && canRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

        VStack(spacing: 0) {

            // ── Main row ──────────────────────────────────────────────────
            HStack(spacing: 10) {
                SymbolLogo(symbol: quote.symbol)

                // Symbol + company + exchange
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(quote.symbol)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(mktBadge.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(mktBadge.color)
                    }
                    Text(quote.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !excInfo.flag.isEmpty {
                        HStack(spacing: 3) {
                            Text(excInfo.flag).font(.system(size: 10))
                            Text(excInfo.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                // Sparkline — colour matches change direction
                SparklineView(symbol: quote.symbol, changeIsPositive: quote.change_pct >= 0)

                // Price + change (right-aligned, fixed width)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(fmtPrice(quote.last, ccy: quote.currency))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    let sign = quote.change >= 0 ? "+" : ""
                    Text("\(sign)\(fmtPrice(quote.change, ccy: quote.currency))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(changeColor)
                    Text(fmtPct(quote.change_pct))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(changeColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(changeColor.opacity(0.12))
                        .cornerRadius(5)
                }
                .frame(width: 82, alignment: .trailing)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(flashColor?.opacity(0.25) ?? Color.clear)
                        .animation(.easeOut(duration: 0.5), value: flashColor)
                )
                .onChange(of: quote.last) { oldVal, newVal in
                    guard prevPrice != 0 else { prevPrice = newVal; return }
                    flashColor = newVal > oldVal
                        ? Color(red: 0.2, green: 0.85, blue: 0.4)
                        : Color(red: 1, green: 0.3, blue: 0.3)
                    prevPrice = newVal
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeOut(duration: 0.15)) { flashColor = nil }
                    }
                }
                .onAppear { prevPrice = quote.last }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // ── Position strip (held only) ─────────────────────────────────
            if isHeld {
                Rectangle().fill(Color(UIColor.separator)).frame(height: 1)
                    .padding(.horizontal, 12)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("POSITION").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).tracking(0.5)
                        Text(fmtQty(quote.position ?? 0))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("AVG PRICE").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).tracking(0.5)
                        Text(quote.avg_price.map { fmtPrice($0, ccy: quote.currency) } ?? "—")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let pnl = unrealisedPnL, let pct = unrealisedPct {
                        let c: Color = pnl >= 0 ? Color(red: 0.2, green: 0.85, blue: 0.4) : Color(red: 1, green: 0.3, blue: 0.3)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("UNREALISED").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).tracking(0.5)
                            Text("\(pnl >= 0 ? "+" : "")\(fmtPrice(pnl, ccy: quote.currency))")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(c)
                            Text("\(pct >= 0 ? "+" : "")\(String(format: "%.2f", pct))%")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(c.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .overlay(
            isHeld ? RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.25), lineWidth: 1) : nil
        )
        .contextMenu {
            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Watchlist", systemImage: "trash")
                }
            }
        }
        } // closes outer HStack
        .animation(.easeInOut(duration: 0.2), value: isEditMode)
    }

    // MARK: Formatters
    private func fmtPrice(_ v: Double, ccy: String?) -> String {
        let s = ccy == "GBP" ? "£" : ccy == "EUR" ? "€" : "$"
        let abs = Swift.abs(v)
        let sign = v < 0 ? "-" : ""
        if abs >= 1000 { return "\(sign)\(s)\(String(format: "%.2f", abs))" }
        if abs >= 1    { return "\(sign)\(s)\(String(format: "%.2f", abs))" }
        return "\(sign)\(s)\(String(format: "%.4f", abs))"
    }
    private func fmtPct(_ v: Double) -> String { "\(v >= 0 ? "+" : "")\(String(format: "%.2f", v))%" }
    private func fmtQty(_ v: Double) -> String {
        v == v.rounded() && Swift.abs(v) < 1_000_000 ? String(format: "%.0f", v) : String(format: "%.4f", v)
    }
}

// MARK: - Add Symbol Sheet

struct AddWatchlistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query        = ""
    @State private var results:     [APIService.StockSearchResult] = []
    @State private var isSearching  = false
    @State private var isAdding     = false
    @State private var searchTask:  Task<Void, Never>?
    let onAdd: (String) async -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    // Search field
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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

                    if results.isEmpty && query.count >= 1 && !isSearching {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No results for \"\(query)\"").foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                    } else {
                        List(results) { r in
                            Button {
                                isAdding = true
                                Task { await onAdd(r.symbol); isAdding = false; dismiss() }
                            } label: {
                                HStack(spacing: 12) {
                                    SymbolLogo(symbol: r.symbol)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(r.symbol)
                                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        Text(r.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let exch = r.exchange {
                                        let info = exchangeInfo(exch)
                                        Text("\(info.flag) \(info.name)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(Color.secondary.opacity(0.1))
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
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .overlay {
                if isAdding {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView("Adding…").padding(24)
                            .background(.regularMaterial).cornerRadius(12)
                    }
                }
            }
        }
    }
}

// MARK: - Section Header

struct MarketSectionHeader: View {
    let title: String; let count: Int
    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).tracking(1)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(UIColor.tertiarySystemFill)).cornerRadius(5)
            Spacer()
        }
        .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 6)
    }
}

// MARK: - Sort

enum MarketSortField { case symbol, last, change, changePct }

// MARK: - Open URL (Chrome → Safari fallback)
private func openInBrowser(_ urlString: String) {
    guard let url = URL(string: urlString), let scheme = url.scheme else { return }
    let chromeScheme = scheme == "https" ? "googlechromes" : "googlechrome"
    let chromeString = urlString.replacingOccurrences(of: "\(scheme)://", with: "\(chromeScheme)://")
    if let chromeURL = URL(string: chromeString), UIApplication.shared.canOpenURL(chromeURL) {
        UIApplication.shared.open(chromeURL)
    } else {
        UIApplication.shared.open(url)
    }
}

// MARK: - Currency flag helper
private func currencyFlag(_ code: String) -> String {
    let flags: [String: String] = [
        "EUR": "🇪🇺", "USD": "🇺🇸", "GBP": "🇬🇧", "JPY": "🇯🇵",
        "CHF": "🇨🇭", "AUD": "🇦🇺", "CAD": "🇨🇦", "AED": "🇦🇪",
        "SGD": "🇸🇬", "NZD": "🇳🇿", "HKD": "🇭🇰", "SEK": "🇸🇪",
        "NOK": "🇳🇴", "DKK": "🇩🇰",
    ]
    return flags[code] ?? "🌐"
}

// MARK: - Forex Row
struct ForexRowView: View {
    let pair: APIService.ForexPair

    private var changeColor: Color {
        pair.change >= 0 ? Color(red: 0.2, green: 0.85, blue: 0.4) : Color(red: 1, green: 0.3, blue: 0.3)
    }

    private var flags: (String, String) {
        let parts = (pair.display_name ?? pair.symbol).split(separator: "/").map(String.init)
        return (currencyFlag(parts.first ?? ""), currencyFlag(parts.last ?? ""))
    }

    var body: some View {
        HStack(spacing: 12) {
            let (baseFlag, quoteFlag) = flags
            HStack(spacing: 2) {
                Text(baseFlag).font(.system(size: 22))
                Text(quoteFlag).font(.system(size: 22)).offset(x: -4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(pair.display_name ?? pair.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                Text("FOREX").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.4f", pair.last))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                let sign = pair.change >= 0 ? "+" : ""
                Text("\(sign)\(String(format: "%.4f", pair.change))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(changeColor)
                Text("\(pair.change >= 0 ? "+" : "")\(String(format: "%.2f", pair.change_pct))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(changeColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(changeColor.opacity(0.12))
                    .cornerRadius(5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - News Article Row
struct NewsArticleRow: View {
    let article: APIService.NewsArticle

    private var timeAgo: String {
        let diff = Date().timeIntervalSince(Date(timeIntervalSince1970: Double(article.published_at)))
        if diff < 3600  { return "\(max(1, Int(diff / 60)))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }

    var body: some View {
        Button {
            openInBrowser(article.link)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let thumb = article.thumbnail, let url = URL(string: thumb) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                Color(UIColor.tertiarySystemFill)
                                    .overlay(Image(systemName: "newspaper").foregroundStyle(.secondary))
                            }
                        }
                    } else {
                        Color.white.opacity(0.07)
                            .overlay(Image(systemName: "newspaper").foregroundStyle(.white.opacity(0.3)))
                    }
                }
                .frame(width: 84, height: 64)
                .clipped()
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 5) {
                    Text(article.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(article.publisher)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
                        Text(timeAgo)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let syms = article.symbols, !syms.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(syms.prefix(3), id: \.self) { s in
                                Text(s)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }
}

// MARK: - News Tab
struct MarketNewsView: View {
    let watchlistSymbols: [String]
    @State private var articles: [APIService.NewsArticle] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading && articles.isEmpty {
                Spacer(); ProgressView().tint(.white); Spacer()
            } else if let err = error {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
                .padding()
                Spacer()
            } else if articles.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "newspaper").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No news yet").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text("Add symbols to your watchlist to see relevant news.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32).padding(.top, 60)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(articles) { article in
                            NewsArticleRow(article: article)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true; error = nil
        // Use watchlist symbols; if empty use top indices
        let syms = watchlistSymbols.isEmpty ? ["SPY", "QQQ", "AAPL", "TSLA"] : watchlistSymbols
        do {
            let resp = try await APIService.shared.fetchMarketNews(symbols: syms)
            articles = resp.articles
            scheduleNotifications(for: resp.articles)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func scheduleNotifications(for articles: [APIService.NewsArticle]) {
        let lastSeen = UserDefaults.standard.double(forKey: "news_last_seen_ts")
        let fresh = articles.filter { Double($0.published_at) > lastSeen && Double($0.published_at) > Date().addingTimeInterval(-3600).timeIntervalSince1970 }
        guard !fresh.isEmpty else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            for article in fresh.prefix(3) {
                let content = UNMutableNotificationContent()
                content.title = article.publisher
                content.body = article.title
                content.sound = .default
                content.userInfo = ["url": article.link]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let req = UNNotificationRequest(identifier: article.link, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(req)
            }
            UserDefaults.standard.set(articles.first.map { Double($0.published_at) } ?? 0, forKey: "news_last_seen_ts")
        }
    }
}

// MARK: - Main View
struct MarketsView: View {
    @AppStorage("theme") private var theme = "dark"
    @AppStorage("customForexSymbols") private var customForexJSON = "[]"
    @AppStorage("hiddenForexSymbols") private var hiddenForexJSON = "[]"
    @State private var quotes:      [APIService.MarketQuote] = []
    @State private var forexPairs:  [APIService.ForexPair]   = []
    @State private var customForexPairs: [APIService.ForexPair] = []
    @State private var isLoading    = false
    @State private var error:       String?
    @State private var showAdd      = false
    @State private var showAddForex = false
    @State private var isEditMode      = false
    @State private var isForexEditMode = false
    @State private var sortField    = MarketSortField.symbol
    @State private var sortAsc      = true
    @State private var selectedTab  = 0   // 0=Markets, 1=News
    @State private var lastUpdated: Date? = nil

    private var customSymbols: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(customForexJSON.utf8))) ?? []
    }

    private var hiddenSymbols: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(hiddenForexJSON.utf8))) ?? [])
    }

    private var visibleForexPairs: [APIService.ForexPair] {
        let hidden = hiddenSymbols
        return forexPairs.filter { !hidden.contains($0.symbol) }
    }

    private func hideForexSymbol(_ sym: String) {
        var hidden = Array(hiddenSymbols)
        hidden.append(sym)
        hiddenForexJSON = (try? String(data: JSONEncoder().encode(hidden), encoding: .utf8)) ?? "[]"
    }

    private func addCustomForexSymbol(_ sym: String) {
        var syms = customSymbols
        let upper = sym.uppercased()
        guard !syms.contains(upper) else { return }
        syms.append(upper)
        customForexJSON = (try? String(data: JSONEncoder().encode(syms), encoding: .utf8)) ?? "[]"
    }

    private func removeCustomForexSymbol(_ sym: String) {
        var syms = customSymbols
        syms.removeAll { $0 == sym.uppercased() }
        customForexJSON = (try? String(data: JSONEncoder().encode(syms), encoding: .utf8)) ?? "[]"
        customForexPairs.removeAll { $0.symbol == sym.uppercased() }
    }

    private func loadCustomForexPairs() async {
        let syms = customSymbols
        guard !syms.isEmpty else { customForexPairs = []; return }
        var results: [APIService.ForexPair] = []
        await withTaskGroup(of: APIService.ForexPair?.self) { group in
            for sym in syms {
                group.addTask {
                    guard let q = try? await APIService.shared.fetchStockQuote(symbol: "\(sym)=X") else { return nil }
                    let base = String(sym.prefix(3))
                    let quote = String(sym.suffix(3))
                    let change = q.price * (q.change_pct / 100.0)
                    return APIService.ForexPair(
                        symbol: sym,
                        name: "\(base)/\(quote)",
                        last: q.price,
                        change: change,
                        change_pct: q.change_pct,
                        currency: q.currency,
                        market_state: q.market_state,
                        display_name: "\(base)/\(quote)"
                    )
                }
            }
            for await r in group { if let r { results.append(r) } }
        }
        customForexPairs = results
    }

    // Auto-refresh every 5 s (backend cache prevents hammering Yahoo Finance)
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var sorted: [APIService.MarketQuote] {
        quotes.sorted {
            let r: Bool
            switch sortField {
            case .symbol:    r = $0.symbol < $1.symbol
            case .last:      r = $0.last < $1.last
            case .change:    r = $0.change < $1.change
            case .changePct: r = $0.change_pct < $1.change_pct
            }
            return sortAsc ? r : !r
        }
    }

    private var held:      [APIService.MarketQuote] { sorted.filter { ($0.position ?? 0) != 0 } }
    private var watchOnly: [APIService.MarketQuote] { sorted.filter { ($0.position ?? 0) == 0 && $0.in_watchlist == true } }
    private var watchlistSymbols: [String] { quotes.filter { $0.in_watchlist == true }.map(\.symbol) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    // Tab picker
                    Picker("", selection: $selectedTab) {
                        Text("Markets").tag(0)
                        Text("News").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    if selectedTab == 0 {
                        marketsContent
                    } else {
                        MarketNewsView(watchlistSymbols: watchlistSymbols)
                    }
                }
            }
            .navigationTitle("Markets")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(theme == "dark" ? .dark : nil, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showAdd = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.green)
                        }
                        .accessibilityLabel("Add to Watchlist")
                        Button { Task { await loadData() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(isLoading ? Color.secondary.opacity(0.4) : Color.secondary)
                        }
                        .disabled(isLoading)
                        .accessibilityLabel("Refresh")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddToWatchlistSheet { sym in
                    Task { await addToWatchlist(sym) }
                }
            }
            .task { await loadData() }
            .onReceive(timer) { _ in
                Task { await silentRefresh() }
            }
            .sheet(isPresented: $showAddForex) {
                AddForexPairSheet { symbol in
                    addCustomForexSymbol(symbol)
                    Task { await loadCustomForexPairs() }
                }
            }
        }
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
    }

    // MARK: Markets tab content
    @ViewBuilder
    private var marketsContent: some View {
        if isLoading && quotes.isEmpty && forexPairs.isEmpty && customForexPairs.isEmpty {
            Spacer(); ProgressView().tint(.white); Spacer()
        } else if let err = error {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await loadData() } }.buttonStyle(.borderedProminent)
            }.padding()
            Spacer()
        } else {
            VStack(spacing: 0) {
                sortBar
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if !held.isEmpty {
                            MarketSectionHeader(title: "My Holdings", count: held.count)
                            ForEach(held) { q in
                                MarketRowView(quote: q, isEditMode: false) { }
                            }
                        }
                        if !watchOnly.isEmpty {
                            HStack {
                                MarketSectionHeader(title: "Watchlist", count: watchOnly.count)
                                Spacer()
                                Button(isEditMode ? "Done" : "Edit") {
                                    isEditMode.toggle()
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.trailing, 4)
                            }
                            ForEach(watchOnly) { q in
                                MarketRowView(quote: q, isEditMode: isEditMode) {
                                    Task { await removeFromWatchlist(q.symbol) }
                                }
                            }
                        }
                        let visible = visibleForexPairs
                        let totalForexCount = visible.count + customForexPairs.count
                        HStack {
                            Text("FOREX")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).tracking(1)
                            if totalForexCount > 0 {
                                Text("\(totalForexCount)")
                                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(UIColor.tertiarySystemFill)).cornerRadius(5)
                            }
                            Spacer()
                            if totalForexCount > 0 {
                                Button(isForexEditMode ? "Done" : "Edit") {
                                    isForexEditMode.toggle()
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            }
                            Button { showAddForex = true } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16)).foregroundStyle(.green)
                            }
                            .padding(.leading, 12)
                        }
                        .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 6)
                        ForEach(visible) { pair in
                            HStack(spacing: 0) {
                                Button {
                                    hapticMedium()
                                    hideForexSymbol(pair.symbol)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 22)).foregroundStyle(.red)
                                }
                                .opacity(isForexEditMode ? 1 : 0)
                                .frame(width: isForexEditMode ? 30 : 0)
                                .clipped()
                                .allowsHitTesting(isForexEditMode)
                                .padding(.trailing, isForexEditMode ? 8 : 0)
                                .animation(.easeInOut(duration: 0.2), value: isForexEditMode)
                                ForexRowView(pair: pair)
                            }
                        }
                        ForEach(customForexPairs) { pair in
                            HStack(spacing: 0) {
                                Button {
                                    hapticMedium()
                                    removeCustomForexSymbol(pair.symbol)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 22)).foregroundStyle(.red)
                                }
                                .opacity(isForexEditMode ? 1 : 0)
                                .frame(width: isForexEditMode ? 30 : 0)
                                .clipped()
                                .allowsHitTesting(isForexEditMode)
                                .padding(.trailing, isForexEditMode ? 8 : 0)
                                .animation(.easeInOut(duration: 0.2), value: isForexEditMode)
                                ForexRowView(pair: pair)
                            }
                        }
                        if sorted.isEmpty && visible.isEmpty && customForexPairs.isEmpty { emptyState }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .refreshable { await loadData() }
            }
        }
    }

    // MARK: Sort bar
    private var sortBar: some View {
        HStack(spacing: 0) {
            sortBtn("INSTRUMENT", .symbol)
            Spacer()
            // Live indicator
            if let ts = lastUpdated {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text(relativeTime(ts))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 8)
            }
            sortBtn("LAST", .last).frame(width: 62)
            sortBtn("CHG", .change).frame(width: 54)
            sortBtn("CHG%", .changePct).frame(width: 62)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color(UIColor.systemBackground).opacity(0.8))
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5  { return "LIVE" }
        if s < 60 { return "\(s)s ago" }
        return "\(s / 60)m ago"
    }

    private func sortBtn(_ label: String, _ field: MarketSortField) -> some View {
        Button {
            if sortField == field { sortAsc.toggle() }
            else { sortField = field; sortAsc = field == .symbol }
        } label: {
            HStack(spacing: 2) {
                Text(label).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(sortField == field ? Color.primary : Color.secondary)
                Image(systemName: sortField == field
                      ? (sortAsc ? "chevron.up" : "chevron.down")
                      : "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: sortField == field ? .bold : .regular))
                    .foregroundStyle(sortField == field ? Color.primary : Color.secondary.opacity(0.4))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 52)).foregroundStyle(.secondary)
            Text("No instruments yet").font(.title3.weight(.semibold)).foregroundStyle(.primary)
            Text("Connect a broker or exchange to see your holdings,\nor search above to add symbols to your watchlist.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 60).padding(.horizontal, 32)
    }

    // MARK: Data
    private func loadData() async {
        isLoading = true; error = nil
        async let quotesTask = APIService.shared.fetchMarketData()
        async let forexTask  = APIService.shared.fetchForexRates()
        do {
            let (qResp, fResp) = try await (quotesTask, forexTask)
            quotes     = qResp.quotes
            forexPairs = fResp.pairs
            lastUpdated = Date()
        } catch is CancellationError {
            // Swallow — happens when a new refresh races with an in-flight load
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Same for underlying URL cancellations
        } catch {
            self.error = error.localizedDescription
        }
        await loadCustomForexPairs()
        isLoading = false
    }

    /// Silent background refresh — no loading spinner, preserves existing data
    private func silentRefresh() async {
        guard !isLoading else { return }
        async let quotesTask = APIService.shared.fetchMarketData()
        async let forexTask  = APIService.shared.fetchForexRates()
        if let (qResp, fResp) = try? await (quotesTask, forexTask) {
            quotes     = qResp.quotes
            forexPairs = fResp.pairs
            lastUpdated = Date()
        }
        await loadCustomForexPairs()
    }

    private func addToWatchlist(_ sym: String) async {
        _ = try? await APIService.shared.addToWatchlist(symbol: sym)
        await loadData()
    }

    private func removeFromWatchlist(_ sym: String) async {
        // Optimistically remove from local list for instant UI feedback
        quotes.removeAll { $0.symbol == sym && ($0.in_watchlist ?? false) && ($0.position ?? 0) == 0 }
        try? await APIService.shared.removeFromWatchlist(symbol: sym)
        await loadData()
        if watchOnly.isEmpty { withAnimation { isEditMode = false } }
    }
}

// MARK: - Add Forex Pair Sheet
private struct AddForexPairSheet: View {
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var error: String?
    @State private var isLoading = false
    @FocusState private var focused: Bool

    // Common suggestions
    private let suggestions = ["GBPJPY", "AUDUSD", "USDCHF", "NZDUSD", "USDCAD", "EURGBP", "EURJPY", "GBPUSD", "AUDNZD"]

    private var sanitized: String { input.uppercased().filter { $0.isLetter }.prefix(6).description }
    private var isValid: Bool { sanitized.count == 6 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. GBPJPY, AUDUSD", text: $input)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onChange(of: input) { _, v in
                            input = v.uppercased().filter { $0.isLetter }
                            if input.count > 6 { input = String(input.prefix(6)) }
                            error = nil
                        }
                } header: {
                    Text("Currency Pair")
                } footer: {
                    Text("Enter a 6-letter forex code: first 3 = base currency, last 3 = quote currency.")
                }

                if let err = error {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                Section("Suggestions") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { s in
                                Button(s) { input = s }
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .cornerRadius(8)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Add Forex Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Add") { Task { await validate() } }
                            .disabled(!isValid)
                            .bold()
                    }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func validate() async {
        guard isValid else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await APIService.shared.fetchStockQuote(symbol: "\(sanitized)=X")
            onAdd(sanitized)
            dismiss()
        } catch {
            let base = String(sanitized.prefix(3))
            let quote = String(sanitized.suffix(3))
            self.error = "Pair '\(base)/\(quote)' not found. Check the code and try again."
        }
    }
}

// MARK: - Add to Watchlist Sheet
private struct AddToWatchlistSheet: View {
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [APIService.StockSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var addedSymbols: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView()
                        Text("Searching…").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if results.isEmpty && searchText.count >= 2 {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No results for \"\(searchText)\"")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if results.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "magnifyingglass.circle.fill")
                            .font(.system(size: 52)).foregroundStyle(.secondary.opacity(0.4))
                        Text("Search for a stock or crypto")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Type at least 2 characters to search")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    List(results) { result in
                        let alreadyAdded = addedSymbols.contains(result.symbol)
                        Button {
                            guard !alreadyAdded else { return }
                            onAdd(result.symbol)
                            addedSymbols.insert(result.symbol)
                        } label: {
                            HStack(spacing: 12) {
                                SymbolLogo(symbol: result.symbol).frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.symbol)
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Text(result.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if result.type != "crypto",
                                       let exch = result.exchange, !exch.isEmpty {
                                        let info = exchangeInfo(exch)
                                        Text("\(info.flag) \(info.name)")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    } else if result.type == "crypto" {
                                        Text("🪙 Crypto")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if alreadyAdded {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3).foregroundStyle(.green)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3).foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(alreadyAdded)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search stocks & crypto")
            .navigationTitle("Add to Watchlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: searchText) { _, val in
                let q = val.trimmingCharacters(in: .whitespaces)
                searchTask?.cancel()
                if q.count < 2 { results = []; isSearching = false; return }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    isSearching = true
                    async let stockTask = APIService.shared.searchStocks(query: q)
                    async let cryptoTask = APIService.shared.searchCrypto(query: q)
                    let stocks = (try? await stockTask) ?? []
                    let cryptos = (try? await cryptoTask) ?? []
                    let stockSymbols = Set(stocks.map { $0.symbol.uppercased() })
                    let cryptoAsStocks = cryptos
                        .filter { !stockSymbols.contains($0.symbol.uppercased()) } // deduplicate
                        .map { c in
                            APIService.StockSearchResult(
                                symbol: c.symbol, name: c.name, exchange: nil,
                                exchange_code: nil, type: "crypto",
                                asset_class: c.asset_class, quote_currency: c.quote_currency,
                                price_usd: c.price_usd, change_pct: nil, market_state: nil
                            )
                        }
                    results = stocks + cryptoAsStocks
                    isSearching = false
                }
            }
        }
    }
}
