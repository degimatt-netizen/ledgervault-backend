import SwiftUI
import UserNotifications

// MARK: - Logo (real image + avatar fallback)

struct SymbolLogo: View {
    let symbol: String

    private var logoURL: URL? {
        let clean = symbol.replacingOccurrences(of: "-USD", with: "")
                          .replacingOccurrences(of: ".L", with: "")
                          .replacingOccurrences(of: ".AS", with: "")
                          .replacingOccurrences(of: ".PA", with: "")
                          .replacingOccurrences(of: ".DE", with: "")
        return URL(string: "https://financialmodelingprep.com/image-stock/\(clean).png")
    }

    private var avatarColor: Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .cyan, .red]
        return palette[abs(symbol.hashValue) % palette.count]
    }

    private var initials: String {
        let clean = symbol.replacingOccurrences(of: "-USD", with: "")
                          .replacingOccurrences(of: ".L", with: "").replacingOccurrences(of: ".AS", with: "")
        return String(clean.prefix(2)).uppercased()
    }

    var body: some View {
        Group {
            if let url = logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    default:
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
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
    @State private var prices: [Double] = []
    @State private var loaded = false

    private var positive: Bool { (prices.last ?? 0) >= (prices.first ?? 1) }

    var body: some View {
        ZStack {
            if prices.count >= 2 {
                SparklineShape(prices: prices)
                    .stroke(positive ? Color.green : Color.red,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: (positive ? Color.green : Color.red).opacity(0.5), radius: 3)
            } else {
                Capsule().fill(Color.white.opacity(0.06))
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
        (["NMS","NGM","NCM","NasdaqGS","NasdaqGM","NasdaqCM","NASDAQ"], "🇺🇸", "NASDAQ"),
        (["NYQ","NYM","NYSE"],                                            "🇺🇸", "NYSE"),
        (["ASE","PCX","BATS","BTS"],                                      "🇺🇸", "NYSE AMEX"),
        (["CBT","CME","NYB","NYF"],                                        "🇺🇸", "CBOT/CME"),
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
    return ("🌐", raw)
}

private func marketStateBadge(_ state: String?) -> (label: String, color: Color) {
    switch state?.uppercased() {
    case "REGULAR": return ("● OPEN",     .green)
    case "PRE":     return ("● PRE-MKT",  Color(red: 1, green: 0.8, blue: 0))
    case "POST":    return ("● POST-MKT", .orange)
    default:        return ("● CLOSED",   Color.white.opacity(0.3))
    }
}

// MARK: - Market Row

struct MarketRowView: View {
    let quote: APIService.MarketQuote
    let onRemove: () -> Void

    private var up: Bool           { quote.change_pct >= 0 }
    private var changeColor: Color { up ? Color(red: 0.2, green: 0.85, blue: 0.4) : Color(red: 1, green: 0.3, blue: 0.3) }
    private var excInfo:           (flag: String, name: String) { exchangeInfo(quote.exchange) }
    private var mktBadge:          (label: String, color: Color) { marketStateBadge(quote.market_state) }
    private var isHeld: Bool       { (quote.position ?? 0) != 0 }
    private var canRemove: Bool    { quote.in_watchlist == true && !isHeld }

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
        VStack(spacing: 0) {

            // ── Main row ──────────────────────────────────────────────────
            HStack(spacing: 10) {
                SymbolLogo(symbol: quote.symbol)

                // Symbol + company + exchange
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(quote.symbol)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(mktBadge.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(mktBadge.color)
                    }
                    Text(quote.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                    if !excInfo.flag.isEmpty {
                        HStack(spacing: 3) {
                            Text(excInfo.flag).font(.system(size: 10))
                            Text(excInfo.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }

                Spacer()

                // Sparkline
                SparklineView(symbol: quote.symbol)

                // Price + change (right-aligned, fixed width)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(fmtPrice(quote.last, ccy: quote.currency))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // ── Position strip (held only) ─────────────────────────────────
            if isHeld {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                    .padding(.horizontal, 12)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("POSITION").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.3)).tracking(0.5)
                        Text(fmtQty(quote.position ?? 0))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("AVG PRICE").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.3)).tracking(0.5)
                        Text(quote.avg_price.map { fmtPrice($0, ccy: quote.currency) } ?? "—")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let pnl = unrealisedPnL, let pct = unrealisedPct {
                        let c: Color = pnl >= 0 ? Color(red: 0.2, green: 0.85, blue: 0.4) : Color(red: 1, green: 0.3, blue: 0.3)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("UNREALISED").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.3)).tracking(0.5)
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
        .background(Color.white.opacity(isHeld ? 0.055 : 0.04))
        .cornerRadius(12)
        .overlay(
            isHeld ? RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.12), lineWidth: 1) : nil
        )
        .contextMenu {
            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Watchlist", systemImage: "trash")
                }
            }
        }
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
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.4)).tracking(1)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.25))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.07)).cornerRadius(5)
            Spacer()
        }
        .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 6)
    }
}

// MARK: - Sort

enum MarketSortField { case symbol, last, changePct }

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
                    .foregroundStyle(.white)
                Text("FOREX").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.4f", pair.last))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
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
        .background(Color.white.opacity(0.04))
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
                                Color.white.opacity(0.07)
                                    .overlay(Image(systemName: "newspaper").foregroundStyle(.white.opacity(0.3)))
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
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(article.publisher)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("·").foregroundStyle(.white.opacity(0.2))
                        Text(timeAgo)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    if let syms = article.symbols, !syms.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(syms.prefix(3), id: \.self) { s in
                                Text(s)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.white.opacity(0.07))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.04))
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
                    Image(systemName: "newspaper").font(.system(size: 48)).foregroundStyle(.white.opacity(0.15))
                    Text("No news yet").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    Text("Add symbols to your watchlist to see relevant news.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.3)).multilineTextAlignment(.center)
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
    @State private var quotes:      [APIService.MarketQuote] = []
    @State private var forexPairs:  [APIService.ForexPair]   = []
    @State private var isLoading    = false
    @State private var error:       String?
    @State private var showAdd      = false
    @State private var sortField    = MarketSortField.symbol
    @State private var sortAsc      = true
    @State private var searchText   = ""
    @State private var selectedTab  = 0   // 0=Markets, 1=News

    private var sorted: [APIService.MarketQuote] {
        let base = searchText.isEmpty ? quotes : quotes.filter {
            $0.symbol.localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return base.sorted {
            let r: Bool
            switch sortField {
            case .symbol:    r = $0.symbol < $1.symbol
            case .last:      r = $0.last < $1.last
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
                Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea()
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
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search symbol or name"
            )
            .navigationTitle("Markets")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.green)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await loadData() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(isLoading ? .white.opacity(0.3) : .white.opacity(0.7))
                    }.disabled(isLoading)
                }
            }
            .sheet(isPresented: $showAdd) {
                AddWatchlistSheet { sym in await addToWatchlist(sym) }
            }
            .task { await loadData() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Markets tab content
    @ViewBuilder
    private var marketsContent: some View {
        if isLoading && quotes.isEmpty && forexPairs.isEmpty {
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
                                MarketRowView(quote: q) { Task { await removeFromWatchlist(q.symbol) } }
                            }
                        }
                        if !watchOnly.isEmpty {
                            MarketSectionHeader(title: "Watchlist", count: watchOnly.count)
                            ForEach(watchOnly) { q in
                                MarketRowView(quote: q) { Task { await removeFromWatchlist(q.symbol) } }
                            }
                        }
                        if !forexPairs.isEmpty {
                            MarketSectionHeader(title: "Forex", count: forexPairs.count)
                            ForEach(forexPairs) { pair in
                                ForexRowView(pair: pair)
                            }
                        }
                        if sorted.isEmpty && forexPairs.isEmpty { emptyState }
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
            sortBtn("INSTRUMENT", .symbol, leading: true)
            Spacer()
            sortBtn("LAST", .last, leading: false)
            sortBtn("CHG %", .changePct, leading: false).frame(width: 88)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color.white.opacity(0.04))
    }

    private func sortBtn(_ label: String, _ field: MarketSortField, leading: Bool) -> some View {
        Button {
            sortField == field ? (sortAsc.toggle()) : { sortField = field; sortAsc = true }()
        } label: {
            HStack(spacing: 2) {
                Text(label).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(sortField == field ? .white : .white.opacity(0.3))
                if sortField == field {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 52)).foregroundStyle(.white.opacity(0.15))
            Text("No instruments yet").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            Text("Connect a broker or exchange to see your holdings,\nor tap + to add symbols to your watchlist.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.3)).multilineTextAlignment(.center)
            Button { showAdd = true } label: {
                Label("Add Symbol", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Color.green.opacity(0.18)).foregroundStyle(.green).cornerRadius(22)
            }
        }
        .padding(.top, 60).padding(.horizontal, 32)
    }

    // MARK: Data
    private func loadData() async {
        isLoading = true; error = nil
        async let quotesTask  = APIService.shared.fetchMarketData()
        async let forexTask   = APIService.shared.fetchForexRates()
        do {
            let (qResp, fResp) = try await (quotesTask, forexTask)
            quotes     = qResp.quotes
            forexPairs = fResp.pairs
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func addToWatchlist(_ sym: String) async {
        _ = try? await APIService.shared.addToWatchlist(symbol: sym)
        await loadData()
    }

    private func removeFromWatchlist(_ sym: String) async {
        try? await APIService.shared.removeFromWatchlist(symbol: sym)
        await loadData()
    }
}
