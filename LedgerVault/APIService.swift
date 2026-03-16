import Foundation

final class APIService {
    static let shared = APIService()
    private init() {}

    private let baseURL = URL(string: "https://ledgervault-backend-production.up.railway.app")!

    // MARK: - Accounts

    struct Account: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let account_type: String
        let base_currency: String
    }

    struct AccountList: Codable {
        let items: [Account]
    }

    struct CreateAccountRequest: Codable {
        let name: String
        let account_type: String
        let base_currency: String
    }

    struct UpdateAccountRequest: Codable {
        let name: String
        let account_type: String
        let base_currency: String
    }

    // MARK: - Assets

    struct Asset: Codable, Identifiable {
        let id: String
        let symbol: String
        let name: String
        let asset_class: String
        let quote_currency: String
    }

    struct AssetList: Codable {
        let items: [Asset]
    }

    // MARK: - Holdings

    struct Holding: Codable, Identifiable {
        let id: String
        let account_id: String
        let asset_id: String
        let quantity: Double
        let avg_cost: Double
    }

    struct HoldingList: Codable {
        let items: [Holding]
    }

    // MARK: - Transaction Events

    struct TransactionEvent: Codable, Identifiable {
        let id: String
        let event_type: String
        let category: String?
        let description: String?
        let date: String
        let note: String?
        let source: String
        let external_id: String?
        let amount: Double?     // computed by backend: net inflow amount
        let outflow: Double?    // absolute outflow amount
    }

    struct TransactionEventList: Codable {
        let items: [TransactionEvent]
    }

    // Simple struct — only used to carry data, JSON is built manually below
    struct TransactionLegCreate {
        let account_id: String
        let asset_id: String?   // nil = cash leg (sends JSON null), real UUID = asset leg
        let quantity: Double
        let unit_price: Double?
        let fee_flag: Bool
    }

    // MARK: - Valuation

    struct ValuationPortfolioItem: Codable, Identifiable {
        let holding_id: String
        let account_id: String
        let account_name: String
        let asset_id: String
        let symbol: String
        let asset_name: String
        let asset_class: String
        let quantity: Double
        let avg_cost: Double
        let price_usd: Double
        let price_live: Bool?   // false = fallback to avg_cost (after-hours)
        let value_in_base: Double
        let base_currency: String

        var id: String { holding_id }

        // Logo URL for display
        var logoURL: URL? {
            let cls = asset_class.lowercased()
            let sym = symbol.uppercased()
            if cls == "stock" || cls == "etf" {
                return URL(string: "https://financialmodelingprep.com/image-stock/\(sym).png")
            } else if cls == "crypto" {
                // CoinCap CDN — free, no API key, covers all major coins
                return URL(string: "https://assets.coincap.io/assets/icons/\(sym.lowercased())@2x.png")
            }
            return nil
        }

        // P&L % using live price vs avg_cost (both in USD)
        var plPercent: Double {
            guard avg_cost > 0, price_usd > 0 else { return 0 }
            return ((price_usd - avg_cost) / avg_cost) * 100
        }

        var isLivePrice: Bool { price_live ?? true }
    }

    struct ValuationRecentActivity: Codable, Identifiable {
        let id: String
        let event_type: String
        let category: String?
        let description: String?
        let date: String
        let note: String?
        let amount: Double?
        let account_name: String?
        let from_account: String?   // source account name
        let to_account: String?     // destination account name
        let traded_symbol: String?  // e.g. "BTC", "TSLA" for trades
    }

    struct ValuationResponse: Codable {
        let base_currency: String
        let total: Double
        let cash: Double
        let crypto: Double
        let stocks: Double
        let portfolio: [ValuationPortfolioItem]
        let recent_activity: [ValuationRecentActivity]
    }

    // MARK: - Rates

    struct RatesResponse: Codable {
        let base_reference: String
        let prices: [String: Double]
        let fx_to_usd: [String: Double]
    }

    // MARK: - Accounts API

    func fetchAccounts() async throws -> [Account] {
        let url = baseURL.appendingPathComponent("accounts")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AccountList.self, from: data).items
    }

    func createAccount(name: String, accountType: String, baseCurrency: String) async throws -> Account {
        let url = baseURL.appendingPathComponent("accounts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CreateAccountRequest(name: name, account_type: accountType, base_currency: baseCurrency)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    func updateAccount(id: String, name: String, accountType: String, baseCurrency: String) async throws -> Account {
        let url = baseURL.appendingPathComponent("accounts/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            UpdateAccountRequest(name: name, account_type: accountType, base_currency: baseCurrency)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    func deleteAccount(id: String) async throws {
        let url = baseURL.appendingPathComponent("accounts/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Assets API

    func fetchAssets() async throws -> [Asset] {
        let url = baseURL.appendingPathComponent("assets")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AssetList.self, from: data).items
    }

    // MARK: - Holdings API

    func fetchHoldings() async throws -> [Holding] {
        let url = baseURL.appendingPathComponent("holdings")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(HoldingList.self, from: data).items
    }

    // MARK: - Activity API

    func fetchAccountTransactions(accountId: String, baseCurrency: String = "USD") async throws -> [TransactionEvent] {
        var components = URLComponents(url: baseURL.appendingPathComponent("accounts/\(accountId)/transactions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "base_currency", value: baseCurrency)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        struct Wrapper: Codable { let items: [TransactionEvent] }
        return try JSONDecoder().decode(Wrapper.self, from: data).items
    }

    func fetchTransactionEvents(baseCurrency: String = "USD") async throws -> [TransactionEvent] {
        var components = URLComponents(url: baseURL.appendingPathComponent("transaction-events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "base_currency", value: baseCurrency)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TransactionEventList.self, from: data).items
    }

    func createTransactionEvent(
        eventType: String,
        category: String?,
        description: String?,
        date: String,
        note: String?,
        legs: [TransactionLegCreate]
    ) async throws -> TransactionEvent {
        let url = baseURL.appendingPathComponent("transaction-events")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // ✅ Build JSON manually using NSMutableDictionary so we have FULL control.
        // Swift Codable drops nil fields. JSONSerialization with NSNull() writes explicit null.
        var bodyDict: [String: Any] = [
            "event_type": eventType,
            "source": "manual",
            "date": date
        ]
        bodyDict["category"]    = category    ?? NSNull()
        bodyDict["description"] = description ?? NSNull()
        bodyDict["note"]        = note        ?? NSNull()
        bodyDict["external_id"] = NSNull()

        // Build legs array — asset_id is ALWAYS present, either a string UUID or NSNull()
        var legsArray: [[String: Any]] = []
        for leg in legs {
            var legDict: [String: Any] = [
                "account_id": leg.account_id,
                "asset_id":   leg.asset_id ?? NSNull(),   // ← explicit null for cash legs
                "quantity":   leg.quantity,
                "fee_flag":   leg.fee_flag
            ]
            if let price = leg.unit_price {
                legDict["unit_price"] = price
            }
            legsArray.append(legDict)
        }
        bodyDict["legs"] = legsArray

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        // Debug — confirm asset_id: null is present in the JSON
        if let bodyStr = String(data: request.httpBody!, encoding: .utf8) {
            print("🚀 POST body: \(bodyStr)")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TransactionEvent.self, from: data)
    }

    func deleteTransactionEvent(id: String) async throws {
        let url = baseURL.appendingPathComponent("transaction-events/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Dashboard / Portfolio API

    func fetchValuation(baseCurrency: String) async throws -> ValuationResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("valuation"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "base_currency", value: baseCurrency)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ValuationResponse.self, from: data)
    }


    func searchAssets(query: String) async throws -> [Asset] {
        var components = URLComponents(url: baseURL.appendingPathComponent("assets/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AssetList.self, from: data).items
    }


    // Fetch live price for a single symbol — bypasses rates cache
    func fetchSymbolPrice(symbol: String) async throws -> (priceUSD: Double, fxToUSD: [String: Double]) {
        let url = baseURL.appendingPathComponent("price/\(symbol.uppercased())")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let price = json["price_usd"] as? Double,
              let fx    = json["fx_to_usd"] as? [String: Double]
        else { throw URLError(.cannotParseResponse) }
        return (price, fx)
    }

    func fetchRates() async throws -> RatesResponse {
        let url = baseURL.appendingPathComponent("rates")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(RatesResponse.self, from: data)
    }

    // MARK: - Error Handling

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = json["detail"] as? String {
                throw NSError(domain: "APIError", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: detail])
            }
            let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw NSError(domain: "APIError", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
