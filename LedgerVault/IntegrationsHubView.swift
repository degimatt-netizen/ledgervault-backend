import SwiftUI

// MARK: - Institution Model (private)

private enum ICategory: String {
    case bank     = "Banks & Neobanks"
    case exchange = "Crypto Exchanges"
    case broker   = "Stock Brokers"
    case wallet   = "Crypto Wallets"

    var icon: String {
        switch self {
        case .bank:     "building.columns.fill"
        case .exchange: "bitcoinsign.circle.fill"
        case .broker:   "chart.bar.fill"
        case .wallet:   "link.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .bank:     .blue
        case .exchange: .orange
        case .broker:   .green
        case .wallet:   .purple
        }
    }
}

private enum IProvider: String {
    case trueLayer     = "TrueLayer"
    case saltEdge      = "Salt Edge"
    case apiKey        = "API Key"
    case snapTrade     = "SnapTrade"
    case flanks        = "Flanks"
    case alpaca        = "Alpaca"
    case vezgo         = "Vezgo"
    case walletConnect = "WalletConnect"
    case rpc           = "RPC"

    var isLive: Bool {
        switch self {
        case .trueLayer, .saltEdge, .apiKey, .rpc: return true
        default: return false
        }
    }
    var badgeColor: Color {
        switch self {
        case .trueLayer: return .blue
        case .saltEdge:  return .green
        case .apiKey:    return .orange
        default:         return .secondary
        }
    }
}

private struct Institution: Identifiable {
    let id:       String
    let name:     String
    let icon:     String
    let color:    Color
    let category: ICategory
    let provider: IProvider
    let popular:  Bool
}

// MARK: - Institution Catalog

private let catalog: [Institution] = [

    // ════════════════════════════════════════════════════════════
    // BANKS — TrueLayer  (UK / IE / EU)
    // ════════════════════════════════════════════════════════════
    .init(id:"revolut",      name:"Revolut",           icon:"r.circle.fill",              color:Color(red:0.42,green:0.20,blue:0.86), category:.bank, provider:.trueLayer,  popular:true),
    .init(id:"monzo",        name:"Monzo",              icon:"m.circle.fill",              color:Color(red:1.0, green:0.40,blue:0.22), category:.bank, provider:.trueLayer,  popular:true),
    .init(id:"wise",         name:"Wise",               icon:"w.circle.fill",              color:Color(red:0.16,green:0.72,blue:0.43), category:.bank, provider:.trueLayer,  popular:true),
    .init(id:"starling",     name:"Starling",           icon:"star.fill",                  color:Color(red:0.13,green:0.65,blue:0.94), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"hsbc",         name:"HSBC",               icon:"building.columns.fill",      color:Color(red:0.84,green:0.0, blue:0.10), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"barclays",     name:"Barclays",           icon:"b.circle.fill",              color:Color(red:0.0, green:0.22,blue:0.58), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"lloyds",       name:"Lloyds",             icon:"l.circle.fill",              color:Color(red:0.0, green:0.42,blue:0.20), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"natwest",      name:"NatWest",            icon:"building.2.fill",            color:Color(red:0.49,green:0.02,blue:0.19), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"santander",    name:"Santander",          icon:"s.circle.fill",              color:Color(red:0.87,green:0.0, blue:0.0),  category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"halifax",      name:"Halifax",            icon:"h.circle.fill",              color:Color(red:0.0, green:0.24,blue:0.58), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"nationwide",   name:"Nationwide",         icon:"n.circle.fill",              color:Color(red:0.0, green:0.34,blue:0.62), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"chase_uk",     name:"Chase UK",           icon:"c.circle.fill",              color:Color(red:0.0, green:0.15,blue:0.38), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"first_direct", name:"First Direct",       icon:"1.circle.fill",              color:Color(red:0.10,green:0.10,blue:0.10), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"tsb",          name:"TSB",                icon:"t.circle.fill",              color:Color(red:0.0, green:0.46,blue:0.70), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"virgin_money", name:"Virgin Money",       icon:"v.circle.fill",              color:Color(red:0.78,green:0.0, blue:0.0),  category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"monese",       name:"Monese",             icon:"m.circle.fill",              color:Color(red:0.0, green:0.56,blue:0.84), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"tide",         name:"Tide",               icon:"waveform.circle.fill",       color:Color(red:0.23,green:0.84,blue:0.71), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"aib",          name:"AIB",                icon:"a.circle.fill",              color:Color(red:0.0, green:0.40,blue:0.20), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"boi",          name:"Bank of Ireland",    icon:"building.columns.fill",      color:Color(red:0.0, green:0.48,blue:0.30), category:.bank, provider:.trueLayer,  popular:false),
    .init(id:"curve",        name:"Curve",              icon:"creditcard.fill",            color:Color(red:0.07,green:0.07,blue:0.25), category:.bank, provider:.trueLayer,  popular:false),

    // ════════════════════════════════════════════════════════════
    // BANKS — Salt Edge  (EU wide)
    // ════════════════════════════════════════════════════════════
    .init(id:"n26",          name:"N26",                icon:"n.circle.fill",              color:Color(red:0.15,green:0.85,blue:0.65), category:.bank, provider:.saltEdge,   popular:true),
    .init(id:"bunq",         name:"Bunq",               icon:"bolt.circle.fill",           color:Color(red:0.0, green:0.80,blue:0.63), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"ing",          name:"ING",                icon:"i.circle.fill",              color:Color(red:1.0, green:0.42,blue:0.0),  category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"bnp",          name:"BNP Paribas",        icon:"building.columns.fill",      color:Color(red:0.0, green:0.30,blue:0.60), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"sg",           name:"Société Générale",   icon:"s.circle.fill",              color:Color(red:0.80,green:0.0, blue:0.10), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"deutsche",     name:"Deutsche Bank",      icon:"d.circle.fill",              color:Color(red:0.0, green:0.0, blue:0.60), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"abnamro",      name:"ABN AMRO",           icon:"a.circle.fill",              color:Color(red:0.0, green:0.48,blue:0.78), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"rabobank",     name:"Rabobank",           icon:"r.circle.fill",              color:Color(red:0.86,green:0.33,blue:0.0),  category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"unicredit",    name:"UniCredit",          icon:"u.circle.fill",              color:Color(red:0.84,green:0.0, blue:0.0),  category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"bbva",         name:"BBVA",               icon:"b.circle.fill",              color:Color(red:0.0, green:0.44,blue:0.76), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"caixabank",    name:"CaixaBank",          icon:"c.circle.fill",              color:Color(red:0.0, green:0.38,blue:0.62), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"credit_agri",  name:"Crédit Agricole",    icon:"leaf.fill",                  color:Color(red:0.0, green:0.52,blue:0.16), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"nordea",       name:"Nordea",             icon:"n.circle.fill",              color:Color(red:0.0, green:0.36,blue:0.60), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"commerzbank",  name:"Commerzbank",        icon:"c.circle.fill",              color:Color(red:0.94,green:0.71,blue:0.0),  category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"kbc",          name:"KBC",                icon:"k.circle.fill",              color:Color(red:0.0, green:0.42,blue:0.20), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"belfius",      name:"Belfius",            icon:"b.circle.fill",              color:Color(red:0.72,green:0.0, blue:0.16), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"seb",          name:"SEB",                icon:"s.circle.fill",              color:Color(red:0.0, green:0.44,blue:0.18), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"swedbank",     name:"Swedbank",           icon:"s.circle.fill",              color:Color(red:0.84,green:0.10,blue:0.14), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"handelsbanken",name:"Handelsbanken",      icon:"h.circle.fill",              color:Color(red:0.0, green:0.36,blue:0.62), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"intesa",       name:"Intesa Sanpaolo",    icon:"i.circle.fill",              color:Color(red:0.0, green:0.36,blue:0.62), category:.bank, provider:.saltEdge,   popular:false),
    .init(id:"postbank",     name:"Postbank",           icon:"envelope.fill",              color:Color(red:0.94,green:0.71,blue:0.0),  category:.bank, provider:.saltEdge,   popular:false),

    // ════════════════════════════════════════════════════════════
    // CRYPTO EXCHANGES — API Key  (connected now)
    // ════════════════════════════════════════════════════════════
    .init(id:"binance",      name:"Binance",            icon:"bitcoinsign.circle.fill",    color:Color(red:0.94,green:0.71,blue:0.0),  category:.exchange, provider:.apiKey, popular:true),
    .init(id:"coinbase",     name:"Coinbase",           icon:"c.circle.fill",              color:Color(red:0.0, green:0.42,blue:0.95), category:.exchange, provider:.apiKey, popular:true),
    .init(id:"kraken",       name:"Kraken",             icon:"k.circle.fill",              color:Color(red:0.40,green:0.22,blue:0.80), category:.exchange, provider:.apiKey, popular:true),
    .init(id:"bybit",        name:"Bybit",              icon:"b.circle.fill",              color:Color(red:1.0, green:0.48,blue:0.0),  category:.exchange, provider:.apiKey, popular:false),
    .init(id:"kucoin",       name:"KuCoin",             icon:"k.circle.fill",              color:Color(red:0.07,green:0.76,blue:0.52), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"okx",          name:"OKX",                icon:"o.circle.fill",              color:Color(red:0.15,green:0.15,blue:0.15), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"bitfinex",     name:"Bitfinex",           icon:"f.circle.fill",              color:Color(red:0.0, green:0.68,blue:0.36), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"gemini",       name:"Gemini",             icon:"g.circle.fill",              color:Color(red:0.0, green:0.45,blue:0.75), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"gateio",       name:"Gate.io",            icon:"circle.grid.2x2.fill",       color:Color(red:1.0, green:0.42,blue:0.0),  category:.exchange, provider:.apiKey, popular:false),
    .init(id:"mexc",         name:"MEXC",               icon:"m.circle.fill",              color:Color(red:0.0, green:0.55,blue:0.76), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"bitstamp",     name:"Bitstamp",           icon:"bitcoinsign.circle.fill",    color:Color(red:0.15,green:0.40,blue:0.75), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"htx",          name:"HTX",                icon:"h.circle.fill",              color:Color(red:0.15,green:0.25,blue:0.58), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"bitmart",      name:"BitMart",            icon:"b.circle.fill",              color:Color(red:0.42,green:0.10,blue:0.72), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"deribit",      name:"Deribit",            icon:"d.circle.fill",              color:Color(red:0.0, green:0.36,blue:0.84), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"phemex",       name:"Phemex",             icon:"p.circle.fill",              color:Color(red:0.0, green:0.46,blue:0.84), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"coinex",       name:"CoinEx",             icon:"c.circle.fill",              color:Color(red:0.0, green:0.62,blue:0.36), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"lbank",        name:"LBank",              icon:"l.circle.fill",              color:Color(red:0.0, green:0.42,blue:0.84), category:.exchange, provider:.apiKey, popular:false),

    // ════════════════════════════════════════════════════════════
    // CRYPTO EXCHANGES — Vezgo  (coming soon)
    // ════════════════════════════════════════════════════════════
    .init(id:"bitpanda",     name:"Bitpanda",           icon:"p.circle.fill",              color:Color(red:1.0, green:0.46,blue:0.0),  category:.exchange, provider:.vezgo,  popular:false),
    .init(id:"nexo",         name:"Nexo",               icon:"n.circle.fill",              color:Color(red:0.12,green:0.32,blue:0.62), category:.exchange, provider:.vezgo,  popular:false),
    .init(id:"cryptocom",    name:"Crypto.com",         icon:"c.circle.fill",              color:Color(red:0.0, green:0.20,blue:0.55), category:.exchange, provider:.apiKey, popular:false),
    .init(id:"binance_us",   name:"Binance US",         icon:"bitcoinsign.circle.fill",    color:Color(red:0.94,green:0.71,blue:0.0),  category:.exchange, provider:.vezgo,  popular:false),
    .init(id:"bittrex",      name:"Bittrex",            icon:"b.circle.fill",              color:Color(red:0.0, green:0.58,blue:0.84), category:.exchange, provider:.vezgo,  popular:false),
    .init(id:"coinberry",    name:"Coinberry",          icon:"c.circle.fill",              color:Color(red:0.18,green:0.62,blue:0.86), category:.exchange, provider:.vezgo,  popular:false),

    // ════════════════════════════════════════════════════════════
    // STOCK BROKERS — SnapTrade  (coming soon)
    // ════════════════════════════════════════════════════════════
    .init(id:"t212",         name:"Trading 212",        icon:"t.circle.fill",              color:Color(red:0.0, green:0.42,blue:0.95), category:.broker, provider:.snapTrade, popular:true),
    .init(id:"ibkr",         name:"IBKR",               icon:"i.circle.fill",              color:Color(red:0.80,green:0.0, blue:0.0),  category:.broker, provider:.snapTrade, popular:true),
    .init(id:"etoro",        name:"eToro",              icon:"e.circle.fill",              color:Color(red:0.0, green:0.62,blue:0.36), category:.broker, provider:.snapTrade, popular:false),
    .init(id:"robinhood",    name:"Robinhood",          icon:"r.circle.fill",              color:Color(red:0.0, green:0.75,blue:0.40), category:.broker, provider:.snapTrade, popular:false),
    .init(id:"degiro",       name:"Degiro",             icon:"d.circle.fill",              color:Color(red:0.84,green:0.10,blue:0.10), category:.broker, provider:.snapTrade, popular:false),
    .init(id:"schwab",       name:"Schwab",             icon:"chart.bar.fill",             color:Color(red:0.0, green:0.42,blue:0.25), category:.broker, provider:.snapTrade, popular:false),
    .init(id:"fidelity",     name:"Fidelity",           icon:"f.circle.fill",              color:Color(red:0.0, green:0.30,blue:0.62), category:.broker, provider:.snapTrade, popular:false),
    .init(id:"webull",       name:"Webull",             icon:"w.circle.fill",              color:Color(red:0.84,green:0.0, blue:0.0),  category:.broker, provider:.snapTrade, popular:false),
    .init(id:"moomoo",       name:"Moomoo",             icon:"m.circle.fill",              color:Color(red:1.0, green:0.48,blue:0.0),  category:.broker, provider:.snapTrade, popular:false),
    .init(id:"vanguard",     name:"Vanguard",           icon:"v.circle.fill",              color:Color(red:0.58,green:0.0, blue:0.0),  category:.broker, provider:.snapTrade, popular:false),
    .init(id:"public",       name:"Public.com",         icon:"p.circle.fill",              color:Color(red:0.20,green:0.20,blue:0.84), category:.broker, provider:.snapTrade, popular:false),

    // ════════════════════════════════════════════════════════════
    // STOCK BROKERS — Flanks  (coming soon)
    // ════════════════════════════════════════════════════════════
    .init(id:"xtb",          name:"XTB",                icon:"x.circle.fill",              color:Color(red:0.87,green:0.17,blue:0.13), category:.broker, provider:.flanks,    popular:false),
    .init(id:"freetrade",    name:"Freetrade",          icon:"f.circle.fill",              color:Color(red:0.54,green:0.17,blue:0.88), category:.broker, provider:.flanks,    popular:false),
    .init(id:"trade_rep",    name:"Trade Republic",     icon:"t.circle.fill",              color:Color(red:0.0, green:0.0, blue:0.0),  category:.broker, provider:.flanks,    popular:false),
    .init(id:"scalable",     name:"Scalable Capital",   icon:"chart.line.uptrend.xyaxis",  color:Color(red:0.36,green:0.10,blue:0.76), category:.broker, provider:.flanks,    popular:false),
    .init(id:"bux",          name:"Bux",                icon:"b.circle.fill",              color:Color(red:0.42,green:0.10,blue:0.76), category:.broker, provider:.flanks,    popular:false),
    .init(id:"saxo",         name:"Saxo",               icon:"s.circle.fill",              color:Color(red:0.0, green:0.28,blue:0.55), category:.broker, provider:.flanks,    popular:false),

    // ════════════════════════════════════════════════════════════
    // STOCK BROKERS — Alpaca  (coming soon)
    // ════════════════════════════════════════════════════════════
    .init(id:"alpaca",       name:"Alpaca",             icon:"hare.fill",                  color:Color(red:0.95,green:0.80,blue:0.0),  category:.broker, provider:.alpaca,    popular:false),

    // ════════════════════════════════════════════════════════════
    // CRYPTO WALLETS — WalletConnect  (coming soon)
    // ════════════════════════════════════════════════════════════
    .init(id:"metamask",     name:"MetaMask",           icon:"bolt.circle.fill",           color:Color(red:1.0, green:0.46,blue:0.0),  category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"trust",        name:"Trust Wallet",       icon:"shield.fill",                color:Color(red:0.0, green:0.45,blue:0.90), category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"ledger_wc",    name:"Ledger",             icon:"key.fill",                   color:Color(red:0.27,green:0.27,blue:0.27), category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"rainbow",      name:"Rainbow",            icon:"rainbow",                    color:Color(red:0.60,green:0.30,blue:0.90), category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"exodus",       name:"Exodus",             icon:"e.circle.fill",              color:Color(red:0.54,green:0.17,blue:0.88), category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"phantom",      name:"Phantom",            icon:"p.circle.fill",              color:Color(red:0.42,green:0.10,blue:0.90), category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"okx_wallet",   name:"OKX Wallet",         icon:"o.circle.fill",              color:Color(red:0.10,green:0.10,blue:0.10), category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"cb_wallet",    name:"Coinbase Wallet",    icon:"c.circle.fill",              color:Color(red:0.0, green:0.36,blue:0.84), category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"zerion",       name:"Zerion",             icon:"z.circle.fill",              color:Color(red:0.0, green:0.48,blue:0.96), category:.wallet, provider:.walletConnect, popular:false),
    .init(id:"tronlink",     name:"TronLink",           icon:"t.circle.fill",              color:Color(red:0.84,green:0.10,blue:0.10), category:.wallet, provider:.walletConnect, popular:false),

    // ════════════════════════════════════════════════════════════
    // CRYPTO WALLETS — RPC / Address Scan  (coming soon)
    // ════════════════════════════════════════════════════════════
    .init(id:"eth_rpc",      name:"ETH Address",        icon:"link.circle.fill",           color:Color(red:0.38,green:0.20,blue:0.76), category:.wallet, provider:.rpc,       popular:false),
    .init(id:"btc_rpc",      name:"BTC Address",        icon:"bitcoinsign.circle.fill",    color:Color(red:0.94,green:0.55,blue:0.0),  category:.wallet, provider:.rpc,       popular:false),
    .init(id:"sol_rpc",      name:"Solana Address",     icon:"s.circle.fill",              color:Color(red:0.60,green:0.20,blue:0.90), category:.wallet, provider:.rpc,       popular:false),
    .init(id:"bnb_rpc",      name:"BNB Address",        icon:"b.circle.fill",              color:Color(red:0.94,green:0.71,blue:0.0),  category:.wallet, provider:.rpc,       popular:false),
    .init(id:"matic_rpc",    name:"Polygon Address",    icon:"p.circle.fill",              color:Color(red:0.54,green:0.17,blue:0.88), category:.wallet, provider:.rpc,       popular:false),
    .init(id:"tron_rpc",     name:"Tron Address",       icon:"t.circle.fill",              color:Color(red:0.84,green:0.0, blue:0.0),  category:.wallet, provider:.rpc,       popular:false),
    .init(id:"arb_rpc",      name:"Arbitrum Address",   icon:"a.circle.fill",              color:Color(red:0.10,green:0.50,blue:0.90), category:.wallet, provider:.rpc,       popular:false),
    .init(id:"avax_rpc",     name:"Avalanche Address",  icon:"a.circle.fill",              color:Color(red:0.84,green:0.10,blue:0.10), category:.wallet, provider:.rpc,       popular:false),
]

// MARK: - IntegrationsHubView

struct IntegrationsHubView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var exchangeConnections: [APIService.ExchangeConnectionResponse] = []
    @State private var bankConnections:     [APIService.BankConnectionResponse]     = []
    @State private var searchText   = ""
    @State private var showTrueLayer  = false
    @State private var showSaltEdge   = false
    @State private var showExchanges  = false
    @State private var comingSoonName: String? = nil

    private var searchResults: [Institution] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return catalog.filter {
            $0.name.lowercased().contains(q) ||
            $0.category.rawValue.lowercased().contains(q) ||
            $0.provider.rawValue.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if searchText.isEmpty {
                        idleContent
                    } else {
                        liveSearchContent
                    }
                }
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search banks, exchanges, brokers…"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading)  { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Text("Connect Institution")
                        .font(.headline)
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showTrueLayer,  onDismiss: { Task { await load() } }) { BankProviderPickerView() }
            .sheet(isPresented: $showSaltEdge,   onDismiss: { Task { await load() } }) { SaltEdgeBankConnectionsView() }
            .sheet(isPresented: $showExchanges,  onDismiss: { Task { await load() } }) { ExchangeConnectionsView() }
            .alert("Coming Soon", isPresented: .constant(comingSoonName != nil), actions: {
                Button("Got It") { comingSoonName = nil }
            }, message: {
                if let n = comingSoonName {
                    Text("\(n) is in development. We'll notify you when it's ready.")
                }
            })
        }
    }

    // MARK: Idle content (search bar empty)

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 24) {

            // ── Popular grid ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Most Popular")
                    .padding(.horizontal, 20)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    ForEach(catalog.filter { $0.popular }) { inst in
                        InstitutionTile(inst: inst) { tap(inst) }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 20)

            // ── Category rows ───────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Browse by Category")
                    .padding(.horizontal, 20)

                VStack(spacing: 0) {
                    NavigationLink {
                        BankIntegrationsView(
                            bankConnections: bankConnections,
                            onUpdate: { Task { await load() } }
                        )
                    } label: {
                        categoryRow(
                            icon: "building.columns.fill", iconColor: .blue,
                            title: "Banks & Neobanks",
                            subtitle: "TrueLayer · Tink · Plaid · Salt Edge",
                            badge: bankConnections.count > 0 ? "\(bankConnections.count)" : nil,
                            badgeColor: .green
                        )
                    }

                    Divider().padding(.leading, 68)

                    NavigationLink {
                        CryptoExchangeIntegrationsView(
                            connections: exchangeConnections,
                            onUpdate: { Task { await load() } }
                        )
                    } label: {
                        categoryRow(
                            icon: "bitcoinsign.circle.fill", iconColor: .orange,
                            title: "Crypto Exchanges",
                            subtitle: "API Key · Vezgo · CCXT",
                            badge: exchangeConnections.count > 0 ? "\(exchangeConnections.count)" : nil,
                            badgeColor: .orange
                        )
                    }

                    Divider().padding(.leading, 68)

                    NavigationLink { StockIntegrationsView() } label: {
                        categoryRow(
                            icon: "chart.bar.fill", iconColor: .green,
                            title: "Stock Brokers",
                            subtitle: "SnapTrade · Flanks · Alpaca",
                            badge: nil, badgeColor: .green
                        )
                    }

                    Divider().padding(.leading, 68)

                    NavigationLink { CryptoWalletIntegrationsView() } label: {
                        categoryRow(
                            icon: "link.circle.fill", iconColor: .purple,
                            title: "Crypto Wallets",
                            subtitle: "WalletConnect · Alchemy · Infura",
                            badge: nil, badgeColor: .purple
                        )
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)
            }

            Text("More integrations coming soon. Use Settings → Feedback to request a provider.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Live search results

    private var liveSearchContent: some View {
        Group {
            if searchResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No results for \"\(searchText)\"")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(ICategory.allCases, id: \.rawValue) { cat in
                        let rows = searchResults.filter { $0.category == cat }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { inst in
                                    InstitutionSearchRow(inst: inst) { tap(inst) }
                                    if inst.id != rows.last?.id {
                                        Divider().padding(.leading, 70)
                                    }
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    Image(systemName: cat.icon)
                                        .font(.caption.bold())
                                        .foregroundColor(cat.color)
                                    Text(cat.rawValue)
                                        .font(.caption.bold())
                                        .foregroundColor(cat.color)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color(.systemGroupedBackground))
                            }
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
    }

    // MARK: Tap handler

    private func tap(_ inst: Institution) {
        switch inst.provider {
        case .trueLayer:    showTrueLayer = true
        case .saltEdge:     showSaltEdge  = true
        case .apiKey:       showExchanges = true
        default:            comingSoonName = inst.name
        }
    }

    // MARK: Shared sub-views

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
    }

    @ViewBuilder
    private func categoryRow(
        icon: String, iconColor: Color,
        title: String, subtitle: String,
        badge: String?, badgeColor: Color
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.13))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 20))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    if let badge {
                        Text(badge)
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(badgeColor)
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func load() async {
        do {
            async let ex   = APIService.shared.fetchExchangeConnections()
            async let bank = APIService.shared.fetchBankConnections()
            (exchangeConnections, bankConnections) = try await (ex, bank)
        } catch { }
    }
}

// MARK: - Institution Tile (popular grid)

private struct InstitutionTile: View {
    let inst:   Institution
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(inst.color.opacity(0.13))
                        .frame(width: 54, height: 54)
                    Image(systemName: inst.icon)
                        .font(.system(size: 22))
                        .foregroundColor(inst.color)
                }
                Text(inst.name)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                // Provider badge
                Text("via \(inst.provider.rawValue)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(inst.provider.isLive ? inst.provider.badgeColor : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(14)
            .overlay(alignment: .topTrailing) {
                if !inst.provider.isLive {
                    Text("Soon")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.secondary)
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Institution Search Row

private struct InstitutionSearchRow: View {
    let inst:   Institution
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(inst.color.opacity(0.13))
                        .frame(width: 42, height: 42)
                    Image(systemName: inst.icon)
                        .font(.system(size: 18))
                        .foregroundColor(inst.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(inst.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    HStack(spacing: 4) {
                        Image(systemName: inst.category.icon)
                            .font(.caption2)
                            .foregroundColor(inst.category.color)
                        Text(inst.category.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("via \(inst.provider.rawValue)")
                        .font(.caption2.bold())
                        .foregroundColor(inst.provider.isLive ? inst.provider.badgeColor : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            (inst.provider.isLive ? inst.provider.badgeColor : Color.secondary).opacity(0.12)
                        )
                        .clipShape(Capsule())
                    if !inst.provider.isLive {
                        Text("Coming Soon")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Live")
                            .font(.system(size: 9))
                            .foregroundColor(.green)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared: Integration Provider Card

struct IntegrationProviderCard: View {
    let icon:           String
    let iconColors:     [Color]
    let name:           String
    let isLive:         Bool
    let description:    String
    let brands:         [String]   // kept for compatibility, no longer displayed
    let connectedCount: Int
    let action:         () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: iconColors.map { $0.opacity(0.15) },
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(LinearGradient(
                        colors: iconColors,
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }

            // Text
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.headline)
                    Text(isLive ? "Live" : "Soon")
                        .font(.caption2.bold())
                        .foregroundColor(isLive ? .green : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((isLive ? Color.green : Color.secondary).opacity(0.12))
                        .clipShape(Capsule())
                    if connectedCount > 0 {
                        Text("\(connectedCount) connected")
                            .font(.caption2.bold())
                            .foregroundColor(iconColors[0])
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(iconColors[0].opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            // Action
            if isLive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .opacity(isLive ? 1.0 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if isLive { action() } }
    }
}

// MARK: - Shared: Section Header

private struct IntegrationSectionHeader: View {
    let icon:       String
    let iconColors: [Color]
    let title:      String
    let subtitle:   String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: iconColors.map { $0.opacity(0.18) },
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(LinearGradient(
                        colors: iconColors,
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Text(title).font(.title2.bold())
            Text(subtitle)
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28).padding(.bottom, 4)
    }
}

// MARK: - Bank Integrations View

struct BankIntegrationsView: View {
    let bankConnections: [APIService.BankConnectionResponse]
    let onUpdate: () -> Void

    @State private var showTrueLayer = false
    @State private var showSaltEdge  = false
    @State private var showPlaid     = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                IntegrationSectionHeader(
                    icon: "building.columns.fill",
                    iconColors: [.blue, .purple],
                    title: "Banks & Neobanks",
                    subtitle: "Connect bank accounts to auto-import transactions via Open Banking."
                )

                IntegrationProviderCard(
                    icon: "building.columns.fill",
                    iconColors: [.blue, .indigo],
                    name: "TrueLayer",
                    isLive: true,
                    description: "UK & EU Open Banking — 100+ banks including Revolut, Wise, Monzo and HSBC.",
                    brands: [],
                    connectedCount: bankConnections.filter { $0.provider != "saltedge" && $0.provider != "plaid" }.count
                ) { showTrueLayer = true }

                IntegrationProviderCard(
                    icon: "shield.lefthalf.filled",
                    iconColors: [.green, .teal],
                    name: "Salt Edge",
                    isLive: true,
                    description: "5,000+ banks across Europe via PSD2 Open Banking.",
                    brands: [],
                    connectedCount: bankConnections.filter { $0.provider == "saltedge" }.count
                ) { showSaltEdge = true }

                IntegrationProviderCard(
                    icon: "creditcard.circle.fill",
                    iconColors: [Color(red: 0.0, green: 0.42, blue: 0.65), .teal],
                    name: "Plaid",
                    isLive: true,
                    description: "12,000+ banks globally — strong US and growing EU coverage.",
                    brands: [],
                    connectedCount: bankConnections.filter { $0.provider == "plaid" }.count
                ) { showPlaid = true }

                IntegrationProviderCard(
                    icon: "wave.3.right.circle.fill",
                    iconColors: [.blue, .cyan],
                    name: "Tink",
                    isLive: false,
                    description: "Visa-owned. 6,000+ connections across Europe.",
                    brands: [],
                    connectedCount: 0
                ) { }
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Banks & Neobanks")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showTrueLayer, onDismiss: onUpdate) { BankConnectionsView(sandbox: false) }
        .sheet(isPresented: $showSaltEdge,  onDismiss: onUpdate) { SaltEdgeBankConnectionsView() }
        .sheet(isPresented: $showPlaid,     onDismiss: onUpdate) { PlaidBankConnectionsView() }
    }
}

// MARK: - Crypto Exchange Integrations View

struct CryptoExchangeIntegrationsView: View {
    let connections: [APIService.ExchangeConnectionResponse]
    let onUpdate: () -> Void

    @State private var showExchanges = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                IntegrationSectionHeader(
                    icon: "bitcoinsign.circle.fill",
                    iconColors: [.orange, .yellow],
                    title: "Crypto Exchanges",
                    subtitle: "Connect exchanges to auto-import trade history and balances."
                )

                IntegrationProviderCard(
                    icon: "key.fill",
                    iconColors: [.orange, .yellow],
                    name: "API Key Connect",
                    isLive: true,
                    description: "Connect 12 exchanges using a read-only API key. Full trade history imported automatically.",
                    brands: ["Binance", "Coinbase", "Kraken", "Bybit", "KuCoin", "OKX", "Gate.io", "Bitfinex", "Gemini", "HTX", "MEXC", "Crypto.com"],
                    connectedCount: connections.count
                ) { showExchanges = true }

                IntegrationProviderCard(
                    icon: "circle.grid.3x3.fill",
                    iconColors: [.purple, .indigo],
                    name: "Vezgo",
                    isLive: false,
                    description: "One API for 40+ CEX, 30+ blockchain networks and 500+ wallets. Balances, trades and full history.",
                    brands: ["Kraken", "ByBit", "Crypto.com", "Bitpanda", "Nexo", "BitPay", "500+ wallets"],
                    connectedCount: 0
                ) { }

                IntegrationProviderCard(
                    icon: "terminal.fill",
                    iconColors: [Color(.systemGray), Color(.systemGray2)],
                    name: "CCXT",
                    isLive: false,
                    description: "Open-source library supporting 100+ exchanges. Maximum flexibility with no aggregator fees.",
                    brands: ["100+ exchanges", "Binance", "Kraken", "ByBit", "Crypto.com", "Bitfinex"],
                    connectedCount: 0
                ) { }
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Crypto Exchanges")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showExchanges, onDismiss: onUpdate) { ExchangeConnectionsView() }
    }
}

// MARK: - Stock Integrations View

struct StockIntegrationsView: View {

    @State private var showSnapTrade   = false
    @State private var showExchanges   = false  // reuse for Alpaca (already in ExchangeConnectionsView)

    @State private var snapConnected   = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                IntegrationSectionHeader(
                    icon: "chart.bar.fill",
                    iconColors: [.green, .mint],
                    title: "Stock Brokers",
                    subtitle: "Import holdings and trade history directly from your broker."
                )

                IntegrationProviderCard(
                    icon: "chart.line.uptrend.xyaxis.circle.fill",
                    iconColors: [.green, .teal],
                    name: "SnapTrade",
                    isLive: true,
                    description: "Unified brokerage API. Covers Trading 212, IBKR, eToro, Robinhood, Schwab, Fidelity, Webull and 50+ brokers via OAuth.",
                    brands: ["Trading 212", "IBKR", "eToro", "Robinhood", "Schwab", "Fidelity", "Webull"],
                    connectedCount: snapConnected
                ) { showSnapTrade = true }

                IntegrationProviderCard(
                    icon: "a.circle.fill",
                    iconColors: [.yellow, .orange],
                    name: "Alpaca",
                    isLive: true,
                    description: "Commission-free stock & crypto API. Connect with your own Alpaca API key for live or paper trading.",
                    brands: ["US Stocks", "ETFs", "Crypto", "Fractional shares", "Paper Trading"],
                    connectedCount: 0
                ) { showExchanges = true }

                IntegrationProviderCard(
                    icon: "chart.pie.fill",
                    iconColors: [Color(red: 0.2, green: 0.5, blue: 0.9), .purple],
                    name: "Flanks",
                    isLive: false,
                    description: "Open Wealth platform covering 300+ European banks and brokers — Trade Republic, XTB, Freetrade, Scalable Capital and Saxo.",
                    brands: ["Trade Republic", "XTB", "Freetrade", "Scalable", "Saxo", "EU-wide"],
                    connectedCount: 0
                ) { }

                IntegrationProviderCard(
                    icon: "arrow.up.doc.fill",
                    iconColors: [.blue, .cyan],
                    name: "CSV Import",
                    isLive: false,
                    description: "Import trade history from a broker-exported CSV. Works with almost any broker worldwide.",
                    brands: ["Any broker", "Degiro", "Freetrade", "Fidelity", "Saxo", "Hargreaves"],
                    connectedCount: 0
                ) { }
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Stock Brokers")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showSnapTrade, onDismiss: { Task { await loadSnapCount() } }) {
            SnapTradeConnectionsView()
        }
        .sheet(isPresented: $showExchanges) {
            ExchangeConnectionsView()
        }
        .task { await loadSnapCount() }
    }

    private func loadSnapCount() async {
        let userID = UserDefaults.standard.string(forKey: "userID") ?? "default_user"
        if let conns = try? await APIService.shared.fetchSnaptradeConnections(userID: userID) {
            snapConnected = conns.count
        }
    }
}

// MARK: - Crypto Wallet Integrations View

struct CryptoWalletIntegrationsView: View {
    @State private var showRPCScan = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                IntegrationSectionHeader(
                    icon: "link.circle.fill",
                    iconColors: [.purple, .indigo],
                    title: "Crypto Wallets",
                    subtitle: "Connect self-custody wallets to track on-chain balances and transactions."
                )

                IntegrationProviderCard(
                    icon: "qrcode",
                    iconColors: [Color(red: 0.24, green: 0.39, blue: 0.91), .blue],
                    name: "WalletConnect",
                    isLive: false,
                    description: "Industry-standard protocol for 300+ self-custody wallets. Scan a QR — no keys ever shared.",
                    brands: ["MetaMask", "Trust Wallet", "TronLink", "Rainbow", "Ledger", "300+ wallets"],
                    connectedCount: 0
                ) { }

                IntegrationProviderCard(
                    icon: "cube.fill",
                    iconColors: [.purple, Color(red: 0.54, green: 0.17, blue: 0.89)],
                    name: "RPC / Address Scan",
                    isLive: true,
                    description: "Paste any wallet address to fetch live on-chain balance. ETH, BTC, SOL, BNB, Polygon, Arbitrum, Avalanche & Tron — no API key needed.",
                    brands: ["ETH", "BTC", "SOL", "BNB", "Polygon", "Arbitrum", "Avalanche", "Tron"],
                    connectedCount: 0
                ) {
                    showRPCScan = true
                }
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Crypto Wallets")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showRPCScan) {
            WalletAddressScanView()
        }
    }
}

// MARK: - ICategory CaseIterable

extension ICategory: CaseIterable {}
