import SwiftUI

struct HomeView: View {
    @AppStorage("baseCurrency") private var baseCurrency = "EUR"

    @State private var valuation: APIService.ValuationResponse?
    @State private var accounts: [APIService.Account] = []
    @State private var isLoading = false
    @State private var lastUpdated: Date?
    @State private var errorMessage: String?
    @State private var showAddTransaction = false
    @State private var showProfile = false

    // Profile data for header
    @AppStorage("profile_name")     private var profileName     = ""
    @AppStorage("profile_nickname") private var profileNickname = ""
    @AppStorage("profile_country_id") private var profileCountryId = "MT"

    private let refreshInterval: TimeInterval = 30

    private var total:  Double { valuation?.total  ?? 0 }
    private var stocks: Double { valuation?.stocks ?? 0 }

    // ✅ Cash = only bank accounts (not stablecoin wallets)
    private var cash: Double {
        let bankIds = Set(accounts.filter { $0.account_type == "bank" }.map { $0.id })
        return (valuation?.portfolio ?? [])
            .filter { bankIds.contains($0.account_id) }
            .reduce(0) { $0 + $1.value_in_base }
    }

    // ✅ Stablecoins = cash-type wallets that are NOT bank accounts
    private var stablecoins: Double {
        let stableIds = Set(accounts.filter {
            $0.account_type == "cash" || $0.account_type == "stablecoin_wallet"
        }.map { $0.id })
        return (valuation?.portfolio ?? [])
            .filter { stableIds.contains($0.account_id) }
            .reduce(0) { $0 + $1.value_in_base }
    }

    // ✅ Crypto = crypto_wallet accounts only
    private var crypto: Double {
        let cryptoIds = Set(accounts.filter { $0.account_type == "crypto_wallet" }.map { $0.id })
        return (valuation?.portfolio ?? [])
            .filter { cryptoIds.contains($0.account_id) }
            .reduce(0) { $0 + $1.value_in_base }
    }

    private let fiatSymbols: Set<String> = [
        "USD","EUR","GBP","CHF","CAD","AUD","JPY","PLN","SEK","NOK",
        "CZK","HKD","SGD","NZD","DKK","HUF","RON","TRY","INR","BRL"
    ]

    private var investmentPositions: [APIService.ValuationPortfolioItem] {
        (valuation?.portfolio ?? [])
            .filter { !fiatSymbols.contains($0.symbol.uppercased()) }
            .sorted { $0.value_in_base > $1.value_in_base }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // ── Net Worth Card ────────────────────────────────────
                    netWorthCard

                    // ── Allocation Bar ────────────────────────────────────
                    if total > 0 { allocationBar }

                    // ── Account Cards (tappable) ──────────────────────────
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MY ACCOUNTS")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .tracking(1)
                            .padding(.horizontal, 4)

                        // Top row: Cash + Stablecoins
                        HStack(spacing: 12) {
                            NavigationLink(destination: BanksView()) {
                                accountCard(
                                    title: "Cash",
                                    subtitle: "Bank Accounts",
                                    icon: "banknote.fill",
                                    amount: cash,
                                    color: .blue
                                )
                            }
                            .buttonStyle(.plain)

                            NavigationLink(destination: StablecoinsView()) {
                                accountCard(
                                    title: "Stablecoins",
                                    subtitle: "USDT · USDC",
                                    icon: "link.circle.fill",
                                    amount: stablecoins,
                                    color: .indigo
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        // Bottom row: Stocks + Crypto
                        HStack(spacing: 12) {
                            NavigationLink(destination: StocksView()) {
                                accountCard(
                                    title: "Stocks",
                                    subtitle: "Equities & ETFs",
                                    icon: "chart.bar.fill",
                                    amount: stocks,
                                    color: .green
                                )
                            }
                            .buttonStyle(.plain)

                            NavigationLink(destination: CryptoStocksView()) {
                                accountCard(
                                    title: "Crypto",
                                    subtitle: "BTC · ETH · SOL",
                                    icon: "bitcoinsign.circle.fill",
                                    amount: crypto,
                                    color: .orange
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // ── Recent Activity ───────────────────────────────────
                    recentActivitySection

                    // ── Footer ────────────────────────────────────────────
                    HStack {
                        Text("Live • Updated \(lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "now")")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Refresh") { Task { await load() } }
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 4)
                }
                .padding()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showProfile = true } label: {
                        HStack(spacing: 10) {
                            profileAvatarSmall
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddTransaction = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showProfile) { ProfileView() }
            .refreshable { await load() }
            .task { await load() }
            .task { await startAutoRefresh() }
            .onChange(of: baseCurrency) { _, _ in Task { await load() } }
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

    // MARK: - Net Worth Card

    private var firstName: String {
        profileName.split(separator: " ").first.map(String.init) ?? "there"
    }

    @ViewBuilder
    private var profileAvatarSmall: some View {
        if let data = UserDefaults.standard.data(forKey: "profile_avatar"),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable().scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
        } else if !profileName.isEmpty {
            let initials = profileName.split(separator: " ").prefix(2)
                .compactMap { $0.first }.map(String.init).joined().uppercased()
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 34, height: 34)
                .overlay(
                    Text(initials)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.blue)
                )
        } else {
            // Show LV logo when no profile set
            LVMonogram(size: 34)
        }
    }

    private var netWorthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOTAL NET WORTH")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .tracking(0.8)

            Text(fmt(total))
                .font(.system(size: 42, weight: .bold, design: .rounded))

            HStack {
                Text("Base: \(baseCurrency)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    Text("Live").font(.caption.weight(.semibold)).foregroundColor(.green)
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(22)
    }

    // MARK: - Allocation Bar

    private var allocationBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                bar(cash,        geo.size.width, .blue)
                bar(stablecoins, geo.size.width, .indigo)
                bar(stocks,      geo.size.width, .green)
                bar(crypto,      geo.size.width, .orange)
            }
        }
        .frame(height: 8)
        .cornerRadius(4)
    }

    @ViewBuilder
    private func bar(_ value: Double, _ width: CGFloat, _ color: Color) -> some View {
        let pct = total > 0 ? CGFloat(value / total) : 0
        if pct > 0 {
            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: pct * width)
        }
    }

    // MARK: - Account Card (improved UX — clearly tappable)

    @ViewBuilder
    private func accountCard(title: String, subtitle: String, icon: String, amount: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.top, 4)
            }
            .padding(.bottom, 12)

            // Title + subtitle
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 10)

            // Amount
            Text(fmt(amount))
                .font(.title3.weight(.bold))
                .foregroundColor(.primary)

            // Percentage bar
            let pct = total > 0 ? amount / total : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, CGFloat(pct) * geo.size.width), height: 4)
                }
            }
            .frame(height: 4)
            .padding(.top, 8)

            Text(String(format: "%.1f%% of total", pct * 100))
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Activity").font(.headline)
                Spacer()
                NavigationLink(destination: TransactionsFullView()) {
                    Text("See all")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.blue)
                }
            }
            .padding(.bottom, 14)

            let activity  = valuation?.recent_activity ?? []
            let positions = investmentPositions.prefix(2)

            if activity.isEmpty && positions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 40)).foregroundColor(.secondary.opacity(0.3))
                    Text("No activity yet").font(.subheadline).foregroundColor(.secondary)
                    Text("Tap + to add your first transaction")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                // Investment positions
                ForEach(Array(positions.enumerated()), id: \.element.id) { idx, item in
                    positionRow(item)
                    if idx < positions.count - 1 { Divider() }
                }

                // Transaction events
                if !activity.isEmpty {
                    if !positions.isEmpty { Divider().padding(.vertical, 4) }
                    ForEach(Array(activity.prefix(4).enumerated()), id: \.element.id) { idx, item in
                        activityRow(item)
                        if idx < min(4, activity.count) - 1 { Divider() }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(22)
    }

    @ViewBuilder
    private func positionRow(_ item: APIService.ValuationPortfolioItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(assetColor(item.asset_class).opacity(0.15)).frame(width: 42, height: 42)
                Image(systemName: assetIcon(item.asset_class)).foregroundColor(assetColor(item.asset_class))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.symbol).font(.subheadline.weight(.semibold))
                Text(item.asset_name).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(fmt(item.value_in_base)).font(.subheadline.weight(.semibold))
                let pl = item.avg_cost > 0 ? ((item.price_usd - item.avg_cost) / item.avg_cost) * 100 : 0
                Text((pl >= 0 ? "+" : "") + String(format: "%.2f%%", pl))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(pl >= 0 ? .green : .red)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func activityRow(_ item: APIService.ValuationRecentActivity) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(eventColor(item.event_type).opacity(0.15)).frame(width: 42, height: 42)
                Image(systemName: eventIcon(item.event_type)).foregroundColor(eventColor(item.event_type))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description ?? item.event_type.capitalized)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.event_type.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(eventColor(item.event_type).opacity(0.12))
                        .foregroundColor(eventColor(item.event_type))
                        .cornerRadius(6)
                    if let cat = item.category {
                        Text(cat).font(.caption).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    if let acct = item.account_name {
                        Image(systemName: "building.columns").font(.caption2).foregroundColor(.secondary)
                        Text(acct).font(.caption2).foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary).font(.caption2)
                    }
                    Text(item.date).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            // ✅ Amount shown in base currency (FX converted by backend)
            if let amount = item.amount, amount > 0 {
                let isExpense = item.event_type.lowercased() == "expense"
                Text((isExpense ? "-" : "+") + fmt(amount))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(isExpense ? .red : .green)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let v = APIService.shared.fetchValuation(baseCurrency: baseCurrency)
            async let a = APIService.shared.fetchAccounts()
            valuation = try await v
            accounts  = try await a
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startAutoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
            await load()
        }
    }

    private func fmt(_ v: Double) -> String {
        let s: String
        switch baseCurrency {
        case "EUR": s = "€"; case "USD": s = "$"; case "GBP": s = "£"
        case "CHF": s = "CHF "; case "JPY": s = "¥"; case "CAD": s = "C$"
        case "AUD": s = "A$"; default: s = baseCurrency + " "
        }
        return s + v.formatted(.number.precision(.fractionLength(2)))
    }

    private func assetIcon(_ cls: String) -> String {
        switch cls.lowercased() {
        case "stock", "etf": return "chart.bar.fill"
        case "crypto":       return "bitcoinsign.circle.fill"
        default:             return "dollarsign.circle.fill"
        }
    }
    private func assetColor(_ cls: String) -> Color {
        switch cls.lowercased() {
        case "stock", "etf": return .green
        case "crypto":       return .orange
        default:             return .blue
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

// Full transactions view pushed from "See all"
struct TransactionsFullView: View {
    var body: some View {
        TransactionsView()
            .navigationBarBackButtonHidden(false)
    }
}
