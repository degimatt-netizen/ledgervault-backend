import Foundation

final class APIService {
    static let shared = APIService()
    private init() {}

    private let baseURL = URL(string: "https://ledgervault-backend-production.up.railway.app")!

    // MARK: - Accounts

    struct Account: Codable, Identifiable {
        let id: String
        let name: String
        let account_type: String
        let base_currency: String
    }

    struct AccountList: Codable { let items: [Account] }
    struct CreateAccountRequest: Codable { let name: String; let account_type: String; let base_currency: String }
    struct UpdateAccountRequest: Codable { let name: String; let account_type: String; let base_currency: String }

    // MARK: - Assets

    struct Asset: Codable, Identifiable {
        let id: String
        let symbol: String
        let name: String
        let asset_class: String
        let quote_currency: String
    }

    struct AssetList: Codable { let items: [Asset] }

    // MARK: - Search Results

    struct CryptoSearchResult: Codable, Identifiable {
        let symbol: String
        let name: String
        let coingecko_id: String?
        let thumb: String?
        let market_cap_rank: Int?
        let price_usd: Double?
        let asset_class: String
        let quote_currency: String
        var id: String { symbol }
    }

    struct StockSearchResult: Codable, Identifiable {
        let symbol: String
        let name: String
        let exchange: String?
        let exchange_code: String?
        let type: String?
        let asset_class: String
        let quote_currency: String
        let price_usd: Double?
        let change_pct: Double?
        let market_state: String?
        var id: String { symbol }
    }

    struct CryptoSearchResponse: Codable { let results: [CryptoSearchResult] }
    struct StockSearchResponse: Codable  { let results: [StockSearchResult] }

    // MARK: - Stock Quote

    struct StockQuote: Codable {
        let symbol: String
        let price: Double
        let change_pct: Double
        let exchange: String?
        let name: String?
        let currency: String?
        let market_state: String?
    }

    // MARK: - Holdings

    struct Holding: Codable, Identifiable {
        let id: String
        let account_id: String
        let asset_id: String
        let quantity: Double
        let avg_cost: Double
    }

    struct HoldingList: Codable { let items: [Holding] }

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
    }

    struct TransactionEventList: Codable { let items: [TransactionEvent] }

    struct TransactionLeg: Codable, Identifiable {
        let id: String
        let event_id: String
        let account_id: String
        let asset_id: String?
        let quantity: Double
        let unit_price: Double?
        let fee_flag: String   // "true" or "false"
    }

    struct TransactionLegList: Codable { let items: [TransactionLeg] }

    struct TransactionLegCreate: Codable {
        let account_id: String
        let asset_id: String?   // nil → backend auto-creates fiat asset
        let quantity: Double
        let unit_price: Double?
        let fee_flag: Bool
    }

    struct TransactionEventCreateRequest: Codable {
        let event_type: String
        let category: String?
        let description: String?
        let date: String
        let note: String?
        let source: String
        let external_id: String?
        let legs: [TransactionLegCreate]
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
        let value_in_base: Double
        let base_currency: String
        var id: String { holding_id }
    }

    struct ValuationRecentActivity: Codable, Identifiable {
        let id: String
        let event_type: String
        let category: String?
        let description: String?
        let date: String
        let note: String?
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

    // MARK: - Exchange Connections

    struct ExchangeConnectionResponse: Codable, Identifiable {
        let id:             String
        let exchange:       String
        let name:           String
        let api_key_masked: String
        let account_id:     String?
        let last_synced:    String?
        let status:         String
        let status_message: String?
    }

    struct ExchangeConnectionListResponse: Codable { let items: [ExchangeConnectionResponse] }

    struct ExchangeConnectionCreateRequest: Codable {
        let exchange:    String
        let name:        String
        let api_key:     String
        let api_secret:  String
        let passphrase:  String?
        let account_id:  String?
    }

    struct SyncResultResponse: Codable {
        let imported: Int
        let skipped:  Int
        let errors:   [String]
        let status:   String
    }

    // MARK: - Recurring Transactions

    struct RecurringTransactionResponse: Codable, Identifiable {
        let id:             String
        let name:           String
        let event_type:     String
        let category:       String?
        let description:    String?
        let note:           String?
        let from_account_id: String
        let from_asset_id:  String?
        let from_quantity:  Double
        let to_account_id:  String?
        let to_asset_id:    String?
        let to_quantity:    Double?
        let unit_price:     Double?
        let frequency:      String
        let start_date:     String
        let last_run_date:  String?
        let next_run_date:  String
        let enabled:        Bool
    }

    struct RecurringTransactionListResponse: Codable { let items: [RecurringTransactionResponse] }

    struct RecurringTransactionCreateRequest: Codable {
        let name:           String
        let event_type:     String
        let category:       String?
        let description:    String?
        let note:           String?
        let from_account_id: String
        let from_asset_id:  String?
        let from_quantity:  Double
        let to_account_id:  String?
        let to_asset_id:    String?
        let to_quantity:    Double?
        let unit_price:     Double?
        let frequency:      String
        let start_date:     String
        let next_run_date:  String
        let enabled:        Bool
    }

    struct ExecuteRecurringResponse: Codable {
        let status:        String
        let event_id:      String
        let next_run_date: String
    }

    // MARK: - Accounts API

    func fetchAccounts() async throws -> [Account] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("accounts"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AccountList.self, from: data).items
    }

    func createAccount(name: String, accountType: String, baseCurrency: String) async throws -> Account {
        var request = URLRequest(url: baseURL.appendingPathComponent("accounts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateAccountRequest(name: name, account_type: accountType, base_currency: baseCurrency))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    func updateAccount(id: String, name: String, accountType: String, baseCurrency: String) async throws -> Account {
        var request = URLRequest(url: baseURL.appendingPathComponent("accounts/\(id)"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(UpdateAccountRequest(name: name, account_type: accountType, base_currency: baseCurrency))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    func deleteAccount(id: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("accounts/\(id)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Assets API

    func fetchAssets() async throws -> [Asset] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("assets"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AssetList.self, from: data).items
    }

    func createAsset(symbol: String, name: String, assetClass: String, quoteCurrency: String) async throws -> Asset {
        var request = URLRequest(url: baseURL.appendingPathComponent("assets"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["symbol": symbol, "name": name, "asset_class": assetClass, "quote_currency": quoteCurrency]
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Asset.self, from: data)
    }

    // MARK: - Search API

    func searchCrypto(query: String) async throws -> [CryptoSearchResult] {
        var components = URLComponents(url: baseURL.appendingPathComponent("search/crypto"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(CryptoSearchResponse.self, from: data).results
    }

    func searchStocks(query: String) async throws -> [StockSearchResult] {
        var components = URLComponents(url: baseURL.appendingPathComponent("search/stocks"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(StockSearchResponse.self, from: data).results
    }

    func fetchStockQuote(symbol: String) async throws -> StockQuote {
        let url = baseURL.appendingPathComponent("quote/stock/\(symbol)")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(StockQuote.self, from: data)
    }

    // MARK: - Holdings API

    func fetchHoldings() async throws -> [Holding] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("holdings"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(HoldingList.self, from: data).items
    }

    // MARK: - Transactions API

    func fetchTransactionLegs() async throws -> [TransactionLeg] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("transaction-legs"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TransactionLegList.self, from: data).items
    }

    func fetchTransactionEvents() async throws -> [TransactionEvent] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("transaction-events"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TransactionEventList.self, from: data).items
    }

    func createTransactionEvent(eventType: String, category: String?, description: String?,
                                date: String, note: String?,
                                legs: [TransactionLegCreate]) async throws -> TransactionEvent {
        var request = URLRequest(url: baseURL.appendingPathComponent("transaction-events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TransactionEventCreateRequest(
            event_type: eventType, category: category, description: description,
            date: date, note: note, source: "manual", external_id: nil, legs: legs))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TransactionEvent.self, from: data)
    }

    func deleteTransactionEvent(id: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("transaction-events/\(id)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Valuation & Rates

    func fetchValuation(baseCurrency: String) async throws -> ValuationResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("valuation"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "base_currency", value: baseCurrency)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ValuationResponse.self, from: data)
    }

    func fetchRates() async throws -> RatesResponse {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("rates"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(RatesResponse.self, from: data)
    }

    // MARK: - Reset API

    func clearTransactions() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("reset/transactions"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func fullReset() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("reset"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Exchange Connections API

    func fetchExchangeConnections() async throws -> [ExchangeConnectionResponse] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("exchange-connections"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ExchangeConnectionListResponse.self, from: data).items
    }

    func createExchangeConnection(exchange: String, name: String, apiKey: String,
                                  apiSecret: String, passphrase: String?,
                                  accountID: String?) async throws -> ExchangeConnectionResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("exchange-connections"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeConnectionCreateRequest(
            exchange: exchange, name: name, api_key: apiKey,
            api_secret: apiSecret, passphrase: passphrase, account_id: accountID))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ExchangeConnectionResponse.self, from: data)
    }

    func deleteExchangeConnection(id: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("exchange-connections/\(id)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func syncExchangeConnection(id: String) async throws -> SyncResultResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("exchange-connections/\(id)/sync"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SyncResultResponse.self, from: data)
    }

    // MARK: - Recurring Transactions API

    func fetchRecurringTransactions() async throws -> [RecurringTransactionResponse] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("recurring-transactions"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(RecurringTransactionListResponse.self, from: data).items
    }

    func createRecurringTransaction(name: String, eventType: String, category: String?,
                                    description: String?, note: String?,
                                    fromAccountID: String, fromAssetID: String?,
                                    fromQuantity: Double, toAccountID: String?,
                                    frequency: String, startDate: String,
                                    nextRunDate: String) async throws -> RecurringTransactionResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("recurring-transactions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RecurringTransactionCreateRequest(
            name: name, event_type: eventType, category: category,
            description: description, note: note,
            from_account_id: fromAccountID, from_asset_id: fromAssetID,
            from_quantity: fromQuantity,
            to_account_id: toAccountID, to_asset_id: nil, to_quantity: nil,
            unit_price: nil,
            frequency: frequency, start_date: startDate, next_run_date: nextRunDate,
            enabled: true))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(RecurringTransactionResponse.self, from: data)
    }

    func executeRecurringTransaction(id: String) async throws -> ExecuteRecurringResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("recurring-transactions/\(id)/execute"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ExecuteRecurringResponse.self, from: data)
    }

    func deleteRecurringTransaction(id: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("recurring-transactions/\(id)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Bank Connections (TrueLayer Open Banking)

    struct BankConnectionResponse: Codable, Identifiable {
        let id:                   String
        let provider_id:          String
        let provider_name:        String
        let account_display_name: String
        let account_type:         String?
        let currency:             String?
        let truelayer_account_id: String
        let ledger_account_id:    String?
        let last_synced:          String?
        let status:               String
        let status_message:       String?
    }

    struct BankConnectionListResponse: Codable { let items: [BankConnectionResponse] }

    struct BankAuthUrlResponse: Codable { let auth_url: String; let state: String }

    struct BankCallbackResponse: Codable { let items: [BankConnectionResponse] }

    func getBankAuthURL() async throws -> String {
        let (data, response) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("bank-connections/auth-url"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BankAuthUrlResponse.self, from: data).auth_url
    }

    func completeBankAuth(code: String) async throws -> [BankConnectionResponse] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("bank-connections/callback"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BankCallbackResponse.self, from: data).items
    }

    func fetchBankConnections() async throws -> [BankConnectionResponse] {
        let (data, response) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("bank-connections"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BankConnectionListResponse.self, from: data).items
    }

    func deleteBankConnection(id: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("bank-connections/\(id)"))
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func linkBankToAccount(connID: String, accountID: String) async throws -> BankConnectionResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("bank-connections/\(connID)/link"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "account_id", value: accountID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BankConnectionResponse.self, from: data)
    }

    func syncBankConnection(id: String) async throws -> SyncResultResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("bank-connections/\(id)/sync"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SyncResultResponse.self, from: data)
    }

    // MARK: - Error Handling

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = json["detail"] as? String {
                throw NSError(domain: "APIError", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: detail])
            }
            let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw NSError(domain: "APIError", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
