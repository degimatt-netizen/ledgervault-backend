import SwiftUI

// ── AssetLogo ─────────────────────────────────────────────────────────────────
// Loads a stock/crypto logo from URL with fallback to initials.
// Stocks:  https://financialmodelingprep.com/image-stock/TSLA.png  (free, no key needed)
// Crypto:  https://assets.coincap.io/assets/icons/{symbol}@2x.png  (free, no key needed)
struct AssetLogo: View {
    let url:    URL?
    let symbol: String
    let color:  Color
    var cornerRadius: CGFloat = 10

    @State private var loaded = false

    var body: some View {
        ZStack {
            // Background always visible
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(color.opacity(0.12))

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                            .padding(4)
                    case .failure, .empty:
                        initialsView
                    @unknown default:
                        initialsView
                    }
                }
            } else {
                initialsView
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var initialsView: some View {
        Text(String(symbol.prefix(2)).uppercased())
            .font(.caption.weight(.bold))
            .foregroundColor(color)
    }
}

// ── Crypto-specific logo using CoinCap CDN ────────────────────────────────────
// CoinCap has free logos for all major coins without API key
extension URL {
    static func cryptoLogo(_ symbol: String) -> URL? {
        // CoinCap CDN — works for BTC, ETH, SOL, XRP, BNB, DOGE, ADA, etc.
        URL(string: "https://assets.coincap.io/assets/icons/\(symbol.lowercased())@2x.png")
    }

    static func stockLogo(_ symbol: String) -> URL? {
        // Parqet has broader coverage including European stocks
        URL(string: "https://assets.parqet.com/logos/symbol/\(symbol.uppercased())?format=jpg")
    }

    static func stockLogoFMP(_ symbol: String) -> URL? {
        URL(string: "https://financialmodelingprep.com/image-stock/\(symbol.uppercased()).png")
    }
}

#Preview {
    HStack(spacing: 12) {
        AssetLogo(url: URL.stockLogo("AAPL"),  symbol: "AAPL", color: .green)  .frame(width: 44, height: 44)
        AssetLogo(url: URL.stockLogo("TSLA"),  symbol: "TSLA", color: .green)  .frame(width: 44, height: 44)
        AssetLogo(url: URL.cryptoLogo("BTC"),  symbol: "BTC",  color: .orange) .frame(width: 44, height: 44)
        AssetLogo(url: URL.cryptoLogo("ETH"),  symbol: "ETH",  color: .orange) .frame(width: 44, height: 44)
        AssetLogo(url: URL.cryptoLogo("XRP"),  symbol: "XRP",  color: .orange) .frame(width: 44, height: 44)
        AssetLogo(url: nil,                     symbol: "?",    color: .gray)   .frame(width: 44, height: 44)
    }
    .padding()
    .background(Color.black)
}
