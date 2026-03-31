import SwiftUI
import Charts

struct HomeView: View {
    @EnvironmentObject var pm: ProfileManager
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("baseCurrency") private var baseCurrency = "USD"

    @State private var valuation: APIService.ValuationResponse?
    @State private var accounts: [APIService.Account] = []
    @State private var assets: [APIService.Asset] = []
    @State private var legs: [APIService.TransactionLeg] = []
    @State private var cryptoImages: [String: String] = [:]
    @State private var fxRates: [String: Double] = [:]
    @State private var portfolioHistory: APIService.PortfolioHistoryResponse?
    @State private var historyDays = 30
    @State private var isLoading = false
    @State private var lastUpdated: Date?
    @State private var errorMessage: String?
    @State private var showAddTransaction = false
    @State private var showProfile = false

    @AppStorage("profile_name")       private var profileName       = ""
    @AppStorage("profile_nickname")   private var profileNickname   = ""
    @AppStorage("profile_country_id") private var profileCountryId  = "MT"

    private let refreshInterval: TimeInterval = 30

    private var stocks: Double     { valuation?.stocks ?? 0 }
    private var crypto: Double     { valuation?.crypto  ?? 0 }

    private func toBase(_ amount: Double, currency: String) -> Double {
        let usdPerCurrency = fxRates[currency.uppercased()] ?? 1.0
        let usdPerBase     = fxRates[baseCurrency.uppercased()] ?? 1.0
        guard usdPerBase > 0 else { return amount }
        return (amount * usdPerCurrency) / usdPerBase
    }

    private func fiatBalance(accountTypes: [String]) -> Double {
        let relevantAccounts = accounts.filter {
            accountTypes.contains($0.account_type) && !($0.exclude_from_total ?? false)
        }
        return relevantAccounts.reduce(0.0) { total, account in
            let nativeBalance = legs
                .filter { $0.account_id == account.id }
                .reduce(0.0) { $0 + $1.quantity }
            return total + toBase(nativeBalance, currency: account.base_currency)
        }
    }

    private var cash: Double        { fiatBalance(accountTypes: ["bank"]) }
    private var stablecoins: Double { fiatBalance(accountTypes: ["cash", "stablecoin_wallet"]) }
    private var total: Double       { cash + stablecoins + stocks + crypto }

    private let fiatSymbols: Set<String> = [
        "USD","EUR","GBP","CHF","CAD","AUD","JPY","PLN","SEK","NOK",
        "CZK","HKD","SGD","NZD","DKK","HUF","RON","TRY","INR","BRL"
    ]

    private var investmentPositions: [APIService.ValuationPortfolioItem] {
        (valuation?.portfolio ?? [])
            .filter { !fiatSymbols.contains($0.symbol.uppercased()) }
            .sorted { $0.value_in_base > $1.value_in_base }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    portfolioCard
                    recentActivitySection
                    updatedFooter
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showProfile = true } label: {
                        HStack(spacing: 10) {
                            profileAvatar
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Hello, \(firstName)! 👋")
                                    .font(.subheadline.weight(.semibold))
                                Text("LedgerVault")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .principal) {
                    ProfileSwitcherView()
                        .environmentObject(pm)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddTransaction = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            .sheet(isPresented: $showProfile) { ProfileView() }
            .refreshable { await load() }
            .task { await load() }
            .task { await startAutoRefresh() }
            .onChange(of: baseCurrency) { _, _ in Task { await load() } }
            .onChange(of: pm.selectedProfileId) { _, _ in Task { await load() } }
            .sheet(isPresented: $showAddTransaction) {
                AddTransactionView { Task { await load() } }
            }
            .overlay {
                if isLoading && valuation == nil {
                    ProgressView("Loading…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    // MARK: - Profile

    private var firstName: String {
        profileName.split(separator: " ").first.map(String.init) ?? "there"
    }

    private var avatarImage: UIImage? {
        guard let data = UserDefaults.standard.data(forKey: "profile_avatar") else { return nil }
        return UIImage(data: data)
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let img = avatarImage {
            Image(uiImage: img)
                .resizable().scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
        } else {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                Text(firstName.prefix(1).uppercased())
                    .font(.subheadline.bold()).foregroundColor(.white)
            }
        }
    }

    // MARK: - Net Worth Hero

    @ViewBuilder
    private var netWorthHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("Total Portfolio")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("LIVE")
                        .font(.caption2.bold())
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
            }

            // Amount — shimmer placeholder while loading
            Group {
                if isLoading && valuation == nil {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 220, height: 48)
                        .shimmer()
                } else {
                    Text(fmt(total))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            .padding(.top, 8)

            Text(baseCurrency)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 2)

            // Allocation bar
            if total > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    GeometryReader { geo in
                        HStack(spacing: 3) {
                            ForEach(allocationSegments, id: \.2) { value, color, _ in
                                if value > 0 {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(color)
                                        .frame(width: max(4, geo.size.width * (value / max(total, 1))))
                                }
                            }
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 14) {
                        ForEach(allocationSegments, id: \.2) { value, color, label in
                            HStack(spacing: 5) {
                                Circle().fill(color).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(label)
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.65))
                                    Text("\(total > 0 ? Int((value / total) * 100) : 0)%")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white.opacity(0.9))
                                }
                            }
                        }
                    }
                }
                .padding(.top, 20)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Group {
                if colorScheme == .dark {
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.08, green: 0.10, blue: 0.22),
                                Color(red: 0.14, green: 0.08, blue: 0.28)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        RadialGradient(
                            colors: [Color(red: 0.30, green: 0.55, blue: 0.95).opacity(0.15), Color.clear],
                            center: .topLeading, startRadius: 0, endRadius: 220
                        )
                    }
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.25, blue: 0.82),
                            Color(red: 0.44, green: 0.18, blue: 0.78)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
        )
        .cornerRadius(26)
        .shadow(
            color: colorScheme == .dark
                ? Color(red: 0.10, green: 0.06, blue: 0.22).opacity(0.7)
                : .blue.opacity(0.25),
            radius: 16, x: 0, y: 6
        )
    }

    private var allocationSegments: [(Double, Color, String)] {
        [(cash, .blue, "Cash"),
         (stablecoins, .teal, "Stable"),
         (stocks, Color(red: 0.18, green: 0.80, blue: 0.44), "Stocks"),
         (crypto, .orange, "Crypto")]
    }

    // MARK: - Revolut-style Portfolio Card

    @ViewBuilder
    private var portfolioCard: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 6) {
                Text("Total Portfolio")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Color(red: 0.2, green: 0.9, blue: 0.5)).frame(width: 6, height: 6)
                    Text("LIVE").font(.caption2.bold()).foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }

            // Amount
            Group {
                if isLoading && valuation == nil {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 200, height: 46)
                        .shimmer()
                } else {
                    Text(fmt(total))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .padding(.top, 10)

            Text(baseCurrency)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 2)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 20)

            // Category rows
            VStack(spacing: 0) {
                NavigationLink(destination: BanksView()) {
                    portfolioRow("Cash", sub: "Bank accounts",
                                 icon: "banknote.fill", color: Color(red: 0.22, green: 0.46, blue: 0.97),
                                 amount: cash)
                }.buttonStyle(.plain)
                portfolioDivider()
                NavigationLink(destination: StablecoinsView()) {
                    portfolioRow("Stablecoins", sub: "USDT · USDC",
                                 icon: "link.circle.fill", color: .teal,
                                 amount: stablecoins)
                }.buttonStyle(.plain)
                portfolioDivider()
                NavigationLink(destination: StocksView()) {
                    portfolioRow("Stocks", sub: "Equities & ETFs",
                                 icon: "chart.bar.fill", color: Color(red: 0.09, green: 0.70, blue: 0.45),
                                 amount: stocks)
                }.buttonStyle(.plain)
                portfolioDivider()
                NavigationLink(destination: CryptoStocksView()) {
                    portfolioRow("Crypto", sub: "BTC · ETH · SOL",
                                 icon: "bitcoinsign.circle.fill", color: .orange,
                                 amount: crypto)
                }.buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.09, green: 0.11, blue: 0.19))
        .cornerRadius(26)
        .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 8)
    }

    @ViewBuilder
    private func portfolioRow(_ title: String, sub: String, icon: String, color: Color, amount: Double) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(color).frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Text(fmt(amount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 11)
    }

    private func portfolioDivider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 58)
    }

    // MARK: - Performance Chart

    @ViewBuilder
    private func performanceChart(_ history: APIService.PortfolioHistoryResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("Performance")
                    .font(.headline)
                Spacer()
                // Period picker
                HStack(spacing: 4) {
                    ForEach([7, 30, 90], id: \.self) { d in
                        Button {
                            historyDays = d
                            Task {
                                portfolioHistory = try? await APIService.shared.fetchPortfolioHistory(
                                    days: d, baseCurrency: baseCurrency
                                )
                            }
                        } label: {
                            Text(d == 7 ? "1W" : d == 30 ? "1M" : "3M")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(historyDays == d ? Color.primary : Color(.systemGray5))
                                .foregroundColor(historyDays == d ? Color(.systemBackground) : .primary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // Compute change from first to last history point
            let points = history.points.filter { $0.total > 0 }
            let first   = points.first?.total ?? 0
            let current = points.last?.total ?? first
            let change = current - first
            let changePct = first > 0 ? (change / first) * 100 : 0
            let isUp = change >= 0

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fmt(current))
                        .font(.subheadline.bold())
                    Text("from \(fmt(first))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text("\(change >= 0 ? "+" : "")\(fmt(abs(change))) (\(isUp ? "+" : "")\(changePct.formatted(.number.precision(.fractionLength(2))))%)")
                        .font(.caption.bold())
                }
                .foregroundColor(isUp ? .green : .red)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background((isUp ? Color.green : Color.red).opacity(0.1))
                .clipShape(Capsule())
            }

            // Line chart
            if !points.isEmpty {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.element.id) { idx, point in
                        LineMark(
                            x: .value("Date", idx),
                            y: .value("Value", point.total)
                        )
                        .foregroundStyle(isUp ? Color.green : Color.red)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Date", idx),
                            y: .value("Value", point.total)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [(isUp ? Color.green : Color.red).opacity(0.18),
                                         (isUp ? Color.green : Color.red).opacity(0.01)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 80)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(20)
    }

    // MARK: - Account Grid

    @ViewBuilder
    private var accountGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                NavigationLink(destination: BanksView()) {
                    accountTile(title: "Cash", subtitle: "Bank accounts",
                                icon: "banknote.fill", amount: cash, accent: .blue)
                }.buttonStyle(.plain)

                NavigationLink(destination: StablecoinsView()) {
                    accountTile(title: "Stablecoins", subtitle: "USDT · USDC",
                                icon: "link.circle.fill", amount: stablecoins, accent: .teal)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                NavigationLink(destination: StocksView()) {
                    accountTile(title: "Stocks", subtitle: "Equities & ETFs",
                                icon: "chart.bar.fill", amount: stocks,
                                accent: Color(red: 0.18, green: 0.80, blue: 0.44))
                }.buttonStyle(.plain)

                NavigationLink(destination: CryptoStocksView()) {
                    accountTile(title: "Crypto", subtitle: "BTC · ETH · SOL",
                                icon: "bitcoinsign.circle.fill", amount: crypto, accent: .orange)
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func accountTile(title: String, subtitle: String, icon: String,
                             amount: Double, accent: Color) -> some View {
        let pct = total > 0 && amount > 0 ? Int((amount / total) * 100) : 0

        VStack(alignment: .leading, spacing: 0) {

            // ── Top row: icon + allocation badge ──
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accent.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Spacer()
                if pct > 0 {
                    Text("\(pct)%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(accent.opacity(0.10))
                        .clipShape(Capsule())
                }
            }

            Spacer()

            // ── Amount ──
            Text(fmt(amount))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.top, 16)

            // ── Labels ──
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.top, 4)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color(red: 0.83, green: 0.67, blue: 0.22).opacity(0.6), lineWidth: 1.5)
        )
    }

    // MARK: - Top Holdings

    @ViewBuilder
    private var topHoldingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Top Holdings") { EmptyView() }

            VStack(spacing: 0) {
                ForEach(Array(investmentPositions.prefix(5).enumerated()), id: \.element.id) { idx, item in
                    holdingRow(item)
                    if idx < min(5, investmentPositions.count) - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(20)
        }
    }

    @ViewBuilder
    private func holdingRow(_ item: APIService.ValuationPortfolioItem) -> some View {
        let pl = item.avg_cost > 0 ? ((item.price_usd - item.avg_cost) / item.avg_cost) * 100 : 0.0
        let isStock = ["stock", "etf"].contains(item.asset_class.lowercased())
        let isCrypto = item.asset_class.lowercased() == "crypto"
        let accentColor: Color = isStock ? .green : isCrypto ? .orange : .blue

        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: isStock ? 10 : 22)
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                if isStock {
                    AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(item.symbol)?format=jpg")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        default:
                            Text(String(item.symbol.prefix(3)))
                                .font(.caption.bold()).foregroundColor(accentColor)
                        }
                    }
                } else if isCrypto, let imgURL = cryptoImages[item.symbol.uppercased()],
                          let url = URL(string: imgURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(width: 32, height: 32).clipShape(Circle())
                        default:
                            Text(String(item.symbol.prefix(3)))
                                .font(.caption.bold()).foregroundColor(accentColor)
                        }
                    }
                } else {
                    Text(String(item.symbol.prefix(3)))
                        .font(.caption.bold()).foregroundColor(accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.symbol).font(.subheadline.weight(.semibold))
                Text(item.asset_name).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(fmt(item.value_in_base)).font(.subheadline.weight(.semibold))
                Text((pl >= 0 ? "+" : "") + String(format: "%.2f%%", pl))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(pl >= 0 ? .green : .red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recent Activity") {
                NavigationLink(destination: TransactionsFullView()) {
                    Text("See all")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.blue)
                }
            }

            let activity = (valuation?.recent_activity ?? [])
                .sorted {
                    if $0.date != $1.date { return $0.date > $1.date }
                    // Same date — use created_at for newest-first ordering
                    return ($0.created_at ?? $0.date) > ($1.created_at ?? $1.date)
                }

            if activity.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 36)).foregroundColor(.secondary.opacity(0.35))
                    Text("No activity yet").font(.subheadline).foregroundColor(.secondary)
                    Text("Tap + to add your first transaction")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activity.prefix(5).enumerated()), id: \.element.id) { idx, item in
                        activityRow(item)
                        if idx < min(5, activity.count) - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(20)
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            trailing()
        }
    }

    @ViewBuilder
    private func activityRow(_ item: APIService.ValuationRecentActivity) -> some View {
        let amt       = activityAmount(item)
        let symbol    = activitySymbol(item)
        let accName   = activityAccount(item)
        let isIncome  = item.event_type.lowercased() == "income"
        let isExpense = item.event_type.lowercased() == "expense"
        let isTrade   = item.event_type.lowercased() == "trade"
        let amtColor: Color = isIncome ? .green : isExpense ? .red : .primary
        let asset     = isTrade ? activityAsset(item) : nil
        let isStock   = ["stock", "etf"].contains(asset?.asset_class.lowercased() ?? "")
        let isCrypto  = asset?.asset_class.lowercased() == "crypto"

        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(eventColor(item.event_type).opacity(0.15))
                    .frame(width: 42, height: 42)
                if let asset, isStock {
                    AsyncImage(url: URL(string: "https://assets.parqet.com/logos/symbol/\(asset.symbol)?format=jpg")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 32, height: 32).clipShape(Circle())
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
                                    .frame(width: 32, height: 32).clipShape(Circle())
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
                    let icon = (isIncome || isExpense) && item.category != nil
                        ? categoryIcon(item.category)
                        : eventIcon(item.event_type)
                    Image(systemName: icon)
                        .foregroundColor(eventColor(item.event_type))
                        .font(.system(size: 16))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.description ?? item.event_type.capitalized)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)

                if isTrade, let price = activityUnitPrice(item), let qty = activityAssetQty(item) {
                    Text("\(qty.formatted(.number.precision(.fractionLength(0...6)))) \(asset?.symbol ?? "units") @ $\(price.formatted(.number.precision(.fractionLength(2))))")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 5) {
                        Text(item.event_type.capitalized)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(eventColor(item.event_type).opacity(0.12))
                            .foregroundColor(eventColor(item.event_type))
                            .clipShape(Capsule())
                        if let cat = item.category {
                            Text(cat).font(.caption2).foregroundColor(.secondary)
                        }
                        if let name = accName {
                            Text("· \(name)").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer()
            if amt > 0 {
                Text("\(isExpense || isTrade ? "-" : isIncome ? "+" : "")\(symbol)\(amt.formatted(.number.precision(.fractionLength(2))))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(amtColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    @ViewBuilder
    private var updatedFooter: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Updated \(lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "now")")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .labelStyle(.iconOnly)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let profileId = pm.selectedProfileId
        do {
            async let v   = APIService.shared.fetchValuation(baseCurrency: baseCurrency, profileId: profileId)
            async let a   = APIService.shared.fetchAccounts()
            async let as_ = APIService.shared.fetchAssets()
            async let l   = APIService.shared.fetchTransactionLegs()
            async let r   = APIService.shared.fetchRates()
            valuation   = try await v
            accounts    = try await a
            assets      = try await as_
            legs        = try await l
            fxRates     = try await r.fx_to_usd
            lastUpdated = Date()
            errorMessage = nil
            let cryptoSymbols = assets
                .filter { $0.asset_class.lowercased() == "crypto" }
                .map { $0.symbol.uppercased() }
            await loadCryptoImages(for: cryptoSymbols)
        } catch {
            errorMessage = error.localizedDescription
        }
        // Load portfolio history in background (non-blocking — can be slow)
        Task {
            portfolioHistory = try? await APIService.shared.fetchPortfolioHistory(
                days: historyDays, baseCurrency: baseCurrency, profileId: profileId
            )
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

    private func activityAssetLeg(_ item: APIService.ValuationRecentActivity) -> APIService.TransactionLeg? {
        legs.filter { $0.event_id == item.id && $0.fee_flag != "true" }
            .first(where: { $0.quantity > 0 })
    }

    private func activityAsset(_ item: APIService.ValuationRecentActivity) -> APIService.Asset? {
        guard let assetId = activityAssetLeg(item)?.asset_id else { return nil }
        return assets.first(where: { $0.id == assetId })
    }

    private func activityUnitPrice(_ item: APIService.ValuationRecentActivity) -> Double? {
        activityAssetLeg(item)?.unit_price
    }

    private func activityAssetQty(_ item: APIService.ValuationRecentActivity) -> Double? {
        activityAssetLeg(item).map { abs($0.quantity) }
    }

    private func primaryActivityLeg(_ item: APIService.ValuationRecentActivity) -> APIService.TransactionLeg? {
        let txLegs = legs.filter { $0.event_id == item.id && $0.fee_flag != "true" }
        if item.event_type.lowercased() == "trade" {
            return txLegs.first(where: { $0.quantity < 0 }) ?? txLegs.first
        }
        return txLegs.first(where: { $0.quantity > 0 }) ?? txLegs.first
    }

    private func activityAmount(_ item: APIService.ValuationRecentActivity) -> Double {
        abs(primaryActivityLeg(item)?.quantity ?? 0)
    }

    private func activityAccount(_ item: APIService.ValuationRecentActivity) -> String? {
        guard let leg = primaryActivityLeg(item) else { return nil }
        return accounts.first(where: { $0.id == leg.account_id })?.name
    }

    private func activitySymbol(_ item: APIService.ValuationRecentActivity) -> String {
        guard let leg = primaryActivityLeg(item),
              let currency = accounts.first(where: { $0.id == leg.account_id })?.base_currency
        else { return "€" }
        return ccySymbol(currency)
    }

    private func startAutoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
            await load()
        }
    }

    // MARK: - Helpers

    private func fmt(_ v: Double) -> String {
        fmtCurrency(v, currency: baseCurrency)
    }

    private func eventIcon(_ t: String) -> String {
        switch t.lowercased() {
        case "income":     return "arrow.down.circle.fill"
        case "expense":    return "arrow.up.circle.fill"
        case "transfer":   return "arrow.left.arrow.right.circle.fill"
        case "conversion": return "arrow.triangle.2.circlepath.circle.fill"
        case "trade":      return "chart.line.uptrend.xyaxis.circle.fill"
        default:           return "circle.fill"
        }
    }

    private func eventColor(_ t: String) -> Color {
        switch t.lowercased() {
        case "income":     return .green
        case "expense":    return .red
        case "trade":      return .orange
        case "conversion": return .purple
        default:           return .blue
        }
    }
}

// MARK: - Full Transactions View

struct TransactionsFullView: View {
    var body: some View {
        TransactionsView()
            .navigationBarBackButtonHidden(false)
    }
}
