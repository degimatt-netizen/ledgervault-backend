import Foundation

final class APIService {
    static let shared = APIService()
    private init() {}

    private let baseURL = URL(string: "https://ledgervault-backend-production.up.railway.app")!

    static var authToken: String? { KeychainHelper.read(account: "auth_token") }

    private func makeRequest(url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = Self.authToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    // MARK: - Auth Models

    struct AuthResponse: Codable {
        let status: String
        let access_token: String?
        let user_id: String?
        let email: String?
        let name: String?
        let message: String?
        let is_new_user: Bool?
        let totp_required: Bool?
    }

    struct TotpSetupResponse: Codable { let secret: String; let uri: String }
    struct TotpStatusResponse: Codable { let enabled: Bool }

    struct RegisterRequest: Codable   { let name: String; let email: String; let password: String }
    struct LoginRequest: Codable      { let email: String; let password: String; let totp_code: String? }
    struct VerifyEmailRequest: Codable { let email: String; let code: String }
    struct ResendCodeRequest: Codable  { let email: String }
    struct ForgotPasswordRequest: Codable { let email: String }
    struct ResetPasswordRequest: Codable  { let email: String; let code: String; let new_password: String }
    struct SocialAuthRequest: Codable {
        let provider: String; let email: String; let name: String
        let apple_user_id: String; let google_sub: String
    }

    // MARK: - Auth API

    func register(name: String, email: String, password: String) async throws -> AuthResponse {
        let body = try JSONEncoder().encode(RegisterRequest(name: name, email: email, password: password))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/register"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func verifyEmail(email: String, code: String) async throws -> AuthResponse {
        let body = try JSONEncoder().encode(VerifyEmailRequest(email: email, code: code))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/verify-email"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func resendCode(email: String) async throws -> AuthResponse {
        let body = try JSONEncoder().encode(ResendCodeRequest(email: email))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/resend-code"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func login(email: String, password: String, totpCode: String? = nil) async throws -> AuthResponse {
        let body = try JSONEncoder().encode(LoginRequest(email: email, password: password, totp_code: totpCode))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/login"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func forgotPassword(email: String) async throws -> AuthResponse {
        let body = try JSONEncoder().encode(ForgotPasswordRequest(email: email))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/forgot-password"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthResponse {
        let body = try JSONEncoder().encode(ResetPasswordRequest(email: email, code: code, new_password: newPassword))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/reset-password"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func socialAuth(provider: String, email: String, name: String,
                    appleUserID: String = "", googleSub: String = "") async throws -> AuthResponse {
        let body = try JSONEncoder().encode(SocialAuthRequest(
            provider: provider, email: email, name: name,
            apple_user_id: appleUserID, google_sub: googleSub))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/social"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func logout() async throws {
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/logout"), method: "POST")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    func deleteAccount() async throws {
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/account"), method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    // MARK: - TOTP / Two-Factor Auth

    func totpStatus() async throws -> TotpStatusResponse {
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/totp/status"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TotpStatusResponse.self, from: data)
    }

    func totpSetup() async throws -> TotpSetupResponse {
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/totp/setup"), method: "POST")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TotpSetupResponse.self, from: data)
    }

    func totpEnable(code: String) async throws {
        struct Req: Encodable { let code: String }
        let body = try JSONEncoder().encode(Req(code: code))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/totp/enable"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    func totpDisable(code: String) async throws {
        struct Req: Encodable { let code: String }
        let body = try JSONEncoder().encode(Req(code: code))
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/totp/disable"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    func updateProfile(phone: String? = nil, name: String? = nil) async throws {
        var body: [String: String] = [:]
        if let phone { body["phone"] = phone }
        if let name  { body["name"]  = name  }
        let bodyData = try JSONEncoder().encode(body)
        let req = makeRequest(url: baseURL.appendingPathComponent("auth/profile"), method: "PATCH", body: bodyData)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

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

    // MARK: - Portfolio History

    struct PortfolioHistoryPoint: Codable, Identifiable {
        let date: String
        let total: Double
        var id: String { date }
    }

    struct PortfolioHistoryResponse: Codable {
        let base_currency: String
        let days: Int
        let points: [PortfolioHistoryPoint]
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
        let req = makeRequest(url: baseURL.appendingPathComponent("accounts"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AccountList.self, from: data).items
    }

    func createAccount(name: String, accountType: String, baseCurrency: String) async throws -> Account {
        let body = try JSONEncoder().encode(CreateAccountRequest(name: name, account_type: accountType, base_currency: baseCurrency))
        let req = makeRequest(url: baseURL.appendingPathComponent("accounts"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    func updateAccount(id: String, name: String, accountType: String, baseCurrency: String) async throws -> Account {
        let body = try JSONEncoder().encode(UpdateAccountRequest(name: name, account_type: accountType, base_currency: baseCurrency))
        let req = makeRequest(url: baseURL.appendingPathComponent("accounts/\(id)"), method: "PUT", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    func deleteAccount(id: String) async throws {
        let req = makeRequest(url: baseURL.appendingPathComponent("accounts/\(id)"), method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: req)
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
        let req = makeRequest(url: baseURL.appendingPathComponent("holdings"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(HoldingList.self, from: data).items
    }

    // MARK: - Transactions API

    func fetchTransactionLegs() async throws -> [TransactionLeg] {
        let req = makeRequest(url: baseURL.appendingPathComponent("transaction-legs"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TransactionLegList.self, from: data).items
    }

    func fetchTransactionEvents() async throws -> [TransactionEvent] {
        let req = makeRequest(url: baseURL.appendingPathComponent("transaction-events"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TransactionEventList.self, from: data).items
    }

    func createTransactionEvent(eventType: String, category: String?, description: String?,
                                date: String, note: String?,
                                legs: [TransactionLegCreate]) async throws -> TransactionEvent {
        let body = try JSONEncoder().encode(TransactionEventCreateRequest(
            event_type: eventType, category: category, description: description,
            date: date, note: note, source: "manual", external_id: nil, legs: legs))
        let req = makeRequest(url: baseURL.appendingPathComponent("transaction-events"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TransactionEvent.self, from: data)
    }

    func deleteTransactionEvent(id: String) async throws {
        let req = makeRequest(url: baseURL.appendingPathComponent("transaction-events/\(id)"), method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    // MARK: - Valuation & Rates

    func fetchValuation(baseCurrency: String) async throws -> ValuationResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("valuation"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "base_currency", value: baseCurrency)]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ValuationResponse.self, from: data)
    }

    func fetchPortfolioHistory(days: Int = 30, baseCurrency: String) async throws -> PortfolioHistoryResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("portfolio/history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "days", value: "\(days)"),
            URLQueryItem(name: "base_currency", value: baseCurrency)
        ]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(PortfolioHistoryResponse.self, from: data)
    }

    func fetchRates() async throws -> RatesResponse {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("rates"))
        try validate(response: response, data: data)
        return try JSONDecoder().decode(RatesResponse.self, from: data)
    }

    // MARK: - Reset API

    func clearTransactions() async throws {
        let req = makeRequest(url: baseURL.appendingPathComponent("user/transactions"), method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    func fullReset() async throws {
        let req = makeRequest(url: baseURL.appendingPathComponent("user/data"), method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: req)
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

    // MARK: - Crypto Wallets

    struct WalletTokenBalance: Codable {
        let symbol: String
        let name: String
        let balance: Double
        let price_usd: Double
        let value_usd: Double
        let is_native: Bool
        let contract: String?
    }

    struct CryptoWallet: Codable, Identifiable {
        let id: String
        let chain: String
        let address: String
        let label: String?
        let last_synced: String?
        let created_at: String?
    }

    struct WalletListResponse: Codable { let wallets: [CryptoWallet] }

    struct WalletSyncResponse: Codable {
        let wallet_id: String
        let chain: String
        let address: String
        let holdings: [WalletTokenBalance]
        let total_usd: Double
        let synced_at: String
    }

    struct AllWalletBalancesResponse: Codable {
        struct WalletResult: Codable {
            let wallet_id: String
            let chain: String
            let address: String
            let label: String?
            let holdings: [WalletTokenBalance]
            let total_usd: Double
        }
        let wallets: [WalletResult]
        let total_usd: Double
    }

    func fetchWallets() async throws -> [CryptoWallet] {
        let data = try await get("/wallets")
        return try JSONDecoder().decode(WalletListResponse.self, from: data).wallets
    }

    func addWallet(chain: String, address: String, label: String?) async throws -> CryptoWallet {
        var body: [String: Any] = ["chain": chain, "address": address]
        if let l = label, !l.isEmpty { body["label"] = l }
        let data = try await post("/wallets", body: body)
        return try JSONDecoder().decode(CryptoWallet.self, from: data)
    }

    func deleteWallet(id: String) async throws {
        _ = try await delete("/wallets/\(id)")
    }

    func syncWallet(id: String) async throws -> WalletSyncResponse {
        let data = try await post("/wallets/\(id)/sync", body: [:])
        return try JSONDecoder().decode(WalletSyncResponse.self, from: data)
    }

    func fetchAllWalletBalances() async throws -> AllWalletBalancesResponse {
        let data = try await get("/wallets/balances")
        return try JSONDecoder().decode(AllWalletBalancesResponse.self, from: data)
    }

    // MARK: - SnapTrade API

    struct SnaptradeConnectionResponse: Codable, Identifiable {
        let id: String
        let brokerage_name: String?
        let status: String
        let status_message: String?
        let last_synced: String?
        let account_id: String?
    }
    struct SnaptradeConnectionListResponse: Codable { let items: [SnaptradeConnectionResponse] }
    struct SnaptradeAuthURLResponse: Codable { let auth_url: String; let registered: Bool }

    func snaptradeRegisterAndAuthURL(userID: String) async throws -> SnaptradeAuthURLResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("snaptrade/auth-url"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SnaptradeAuthURLResponse.self, from: data)
    }

    func fetchSnaptradeConnections(userID: String) async throws -> [SnaptradeConnectionResponse] {
        var components = URLComponents(url: baseURL.appendingPathComponent("snaptrade/connections"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SnaptradeConnectionListResponse.self, from: data).items
    }

    func syncSnaptradeConnection(id: String) async throws -> SyncResultResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("snaptrade/\(id)/sync"))
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SyncResultResponse.self, from: data)
    }

    func deleteSnaptradeConnection(id: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("snaptrade/\(id)"))
        req.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    // MARK: - Vezgo API

    struct VezgoConnectionResponse: Codable, Identifiable {
        let id: String
        let account_name: String?
        let status: String
        let status_message: String?
        let last_synced: String?
        let account_id: String?
    }
    struct VezgoConnectionListResponse: Codable { let items: [VezgoConnectionResponse] }
    struct VezgoAuthURLResponse: Codable { let auth_url: String }

    func vezgoAuthURL(userID: String) async throws -> VezgoAuthURLResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("vezgo/auth-url"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(VezgoAuthURLResponse.self, from: data)
    }

    func fetchVezgoConnections(userID: String) async throws -> [VezgoConnectionResponse] {
        var components = URLComponents(url: baseURL.appendingPathComponent("vezgo/connections"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(VezgoConnectionListResponse.self, from: data).items
    }

    func syncVezgoConnection(id: String) async throws -> SyncResultResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("vezgo/\(id)/sync"))
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SyncResultResponse.self, from: data)
    }

    func deleteVezgoConnection(id: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("vezgo/\(id)"))
        req.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    // MARK: - Flanks API

    struct FlanksConnectionResponse: Codable, Identifiable {
        let id: String
        let broker_name: String?
        let broker_id: String
        let status: String
        let status_message: String?
        let last_synced: String?
        let account_id: String?
    }
    struct FlanksConnectionListResponse: Codable { let items: [FlanksConnectionResponse] }
    struct FlanksBrokerResponse: Codable, Identifiable { let id: String; let name: String; let country: String? }
    struct FlanksBrokerListResponse: Codable { let brokers: [FlanksBrokerResponse] }

    func fetchFlanksBrokers() async throws -> [FlanksBrokerResponse] {
        let req = makeRequest(url: baseURL.appendingPathComponent("flanks/brokers"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(FlanksBrokerListResponse.self, from: data).brokers
    }

    func fetchFlanksConnections(userID: String) async throws -> [FlanksConnectionResponse] {
        var components = URLComponents(url: baseURL.appendingPathComponent("flanks/connections"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(FlanksConnectionListResponse.self, from: data).items
    }

    func syncFlanksConnection(id: String) async throws -> SyncResultResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("flanks/\(id)/sync"))
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SyncResultResponse.self, from: data)
    }

    func deleteFlanksConnection(id: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("flanks/\(id)"))
        req.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
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
        let id:                      String
        let provider:                String?   // "truelayer" | "saltedge"
        let provider_id:             String
        let provider_name:           String
        let account_display_name:    String
        let account_type:            String?
        let currency:                String?
        let truelayer_account_id:    String?
        let saltedge_connection_id:  String?
        let ledger_account_id:       String?
        let last_synced:             String?
        let status:                  String
        let status_message:          String?
    }

    struct BankConnectionListResponse: Codable { let items: [BankConnectionResponse] }
    struct BankConnectionList: Codable { let data: [BankConnectionResponse] }

    struct BankAuthUrlResponse: Codable { let auth_url: String; let state: String }

    struct BankCallbackResponse: Codable { let items: [BankConnectionResponse] }

    func getBankAuthURL(sandbox: Bool = false) async throws -> String {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("bank-connections/auth-url"),
            resolvingAgainstBaseURL: false)!
        if sandbox { components.queryItems = [URLQueryItem(name: "sandbox", value: "true")] }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BankAuthUrlResponse.self, from: data).auth_url
    }

    func completeBankAuth(code: String, sandbox: Bool = false) async throws -> [BankConnectionResponse] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("bank-connections/callback"),
            resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "code", value: code)]
        if sandbox { items.append(URLQueryItem(name: "sandbox", value: "true")) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BankCallbackResponse.self, from: data).items
    }

    // MARK: - Salt Edge

    func getSaltEdgeAuthURL() async throws -> String {
        let url = baseURL.appendingPathComponent("bank-connections-saltedge/auth-url")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BankAuthUrlResponse.self, from: data).auth_url
    }

    func fetchSaltEdgeConnections() async throws -> [BankConnectionResponse] {
        let url = baseURL.appendingPathComponent("bank-connections-saltedge")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BankConnectionListResponse.self, from: data).items
    }

    func syncSaltEdgeConnection(id: String) async throws -> SyncResultResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("bank-connections-saltedge/\(id)/sync"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SyncResultResponse.self, from: data)
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

    // MARK: - Plaid

    struct PlaidAuthURLResponse: Codable {
        let auth_url:   String
        let link_token: String
    }

    struct PlaidExchangeResponse: Codable {
        let status:      String
        let connected:   Int
        let institution: String
    }

    func plaidAuthURL(userID: String = "default_user") async throws -> PlaidAuthURLResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("bank-connections-plaid/auth-url"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(PlaidAuthURLResponse.self, from: data)
    }

    func plaidExchangeToken(publicToken: String, userID: String = "default_user") async throws -> PlaidExchangeResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("bank-connections-plaid/exchange"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "public_token", value: publicToken),
            URLQueryItem(name: "user_id",      value: userID),
        ]
        let req = makeRequest(url: components.url!, method: "POST")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(PlaidExchangeResponse.self, from: data)
    }

    func fetchPlaidConnections() async throws -> [BankConnectionResponse] {
        let req = makeRequest(url: baseURL.appendingPathComponent("bank-connections-plaid"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        let wrapper = try JSONDecoder().decode(BankConnectionList.self, from: data)
        return wrapper.data
    }

    func syncPlaidConnection(id: String) async throws -> SyncResultResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("bank-connections-plaid/\(id)/sync"))
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SyncResultResponse.self, from: data)
    }

    // MARK: - Wallet Scan

    struct WalletScanResult: Codable, Identifiable {
        var id: String { "\(chain):\(address)" }
        let address:   String
        let chain:     String
        let balance:   Double
        let symbol:    String
        let usd_value: Double?
    }

    func scanWalletAddress(address: String, chain: String) async throws -> WalletScanResult {
        var components = URLComponents(url: baseURL.appendingPathComponent("wallet-scan"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "chain",   value: chain),
        ]
        let req = makeRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(WalletScanResult.self, from: data)
    }

    // MARK: - Markets

    struct MarketQuote: Codable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let name: String
        let last: Double
        let bid: Double?
        let ask: Double?
        let change: Double
        let change_pct: Double
        let volume: Int?
        let currency: String?
        let market_state: String?
        let exchange: String?
        let position: Double?
        let avg_price: Double?
        let in_watchlist: Bool?
    }

    struct MarketDataResponse: Codable {
        let quotes: [MarketQuote]
        let watchlist: [String]
    }

    struct SparklineResponse: Codable {
        let symbol: String
        let prices: [Double]
    }

    struct WatchlistResponse: Codable {
        let symbols: [String]
    }

    struct WatchlistStatusResponse: Codable {
        let status: String
        let symbol: String
    }

    func fetchMarketData() async throws -> MarketDataResponse {
        let req = makeRequest(url: baseURL.appendingPathComponent("market/data"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(MarketDataResponse.self, from: data)
    }

    func fetchSparkline(symbol: String) async throws -> SparklineResponse {
        let req = makeRequest(url: baseURL.appendingPathComponent("market/sparkline/\(symbol)"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SparklineResponse.self, from: data)
    }

    func addToWatchlist(symbol: String) async throws -> WatchlistStatusResponse {
        let body = try JSONEncoder().encode(["symbol": symbol])
        let req = makeRequest(url: baseURL.appendingPathComponent("market/watchlist"), method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(WatchlistStatusResponse.self, from: data)
    }

    func removeFromWatchlist(symbol: String) async throws {
        let req = makeRequest(url: baseURL.appendingPathComponent("market/watchlist/\(symbol)"), method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
    }

    // MARK: - Forex

    struct ForexPair: Codable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let name: String
        let last: Double
        let change: Double
        let change_pct: Double
        let currency: String?
        let market_state: String?
        let display_name: String?
    }

    struct ForexResponse: Codable {
        let pairs: [ForexPair]
    }

    // MARK: - News

    struct NewsArticle: Codable, Identifiable {
        var id: String { link }
        let title: String
        let link: String
        let publisher: String
        let published_at: Int
        let thumbnail: String?
        let symbols: [String]?
    }

    struct NewsResponse: Codable {
        let articles: [NewsArticle]
    }

    func fetchForexRates() async throws -> ForexResponse {
        let req = makeRequest(url: baseURL.appendingPathComponent("market/forex"))
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ForexResponse.self, from: data)
    }

    func fetchMarketNews(symbols: [String]) async throws -> NewsResponse {
        var comps = URLComponents(url: baseURL.appendingPathComponent("market/news"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))]
        let req = makeRequest(url: comps.url!)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(NewsResponse.self, from: data)
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
