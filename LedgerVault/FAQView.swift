import SwiftUI

struct FAQView: View {
    @Environment(\.dismiss) private var dismiss

    struct FAQItem: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
    }

    let items: [FAQItem] = [
        FAQItem(
            question: "What is LedgerVault?",
            answer: "LedgerVault is a personal finance tracker for crypto, stocks, cash, and bank accounts in one place. It shows live market prices and calculates your net worth in your chosen base currency."
        ),
        FAQItem(
            question: "How is my portfolio value calculated?",
            answer: "Your total is calculated using live market prices: CoinGecko for crypto, Yahoo Finance for stocks, and open.er-api.com for FX rates. All values are converted to your chosen base currency in real time."
        ),
        FAQItem(
            question: "What transaction types are supported?",
            answer: "Income, Expense, Transfer (between accounts), Conversion (currency exchange), and Trade (buy/sell assets). Each transaction uses a double-entry ledger so balances always stay accurate."
        ),
        FAQItem(
            question: "How do I connect an exchange?",
            answer: "Go to More → Exchange Connections, tap +, choose your exchange, and enter your API key and secret. We recommend creating read-only API keys on your exchange for security. Supported: Binance, Kraken, Coinbase, Bybit, KuCoin, OKX."
        ),
        FAQItem(
            question: "Are my API keys stored securely?",
            answer: "API keys are stored in the backend database. Always use read-only API keys — LedgerVault never needs trading or withdrawal permissions. You can delete a connection at any time from Exchange Connections."
        ),
        FAQItem(
            question: "What does Sync do on Exchange Connections?",
            answer: "Sync fetches your recent trade history from the exchange using your API credentials and imports any new trades as transactions. Duplicate trades are automatically detected using unique trade IDs."
        ),
        FAQItem(
            question: "How do recurring transactions work?",
            answer: "Recurring transactions are templates that auto-create transactions on a schedule (daily, weekly, monthly, quarterly). Go to More → Recurring to create templates. When a transaction is due, tap Execute to apply it."
        ),
        FAQItem(
            question: "Can I export my data?",
            answer: "Yes — go to More → Export / Import to download a CSV of all your transactions, or import a CSV to bulk-add transactions. The CSV includes date, type, account, asset, quantity, and price for every leg."
        ),
        FAQItem(
            question: "How do I reset my data?",
            answer: "Go to More → Reset Data. You can clear all transactions and holdings (keeping accounts and assets), or do a full reset that removes everything. Type RESET to confirm — this cannot be undone."
        ),
        FAQItem(
            question: "How does the app lock work?",
            answer: "Go to More → Security to enable the app lock. When enabled, you'll need Face ID, Touch ID, or your device passcode to open the app after it goes to the background."
        ),
        FAQItem(
            question: "Why is my crypto price showing $0?",
            answer: "Prices come from CoinGecko's free tier (top 250 coins by market cap). If a coin isn't in the top 250, the price may not auto-fetch. Try searching for it and adding it manually via a buy transaction."
        ),
        FAQItem(
            question: "What base currencies are supported?",
            answer: "EUR, USD, GBP, CHF, CAD, AUD, JPY, PLN, SEK, NOK, CZK. Change your base currency in More → Settings."
        ),
    ]

    @State private var expanded: Set<UUID> = []
    @State private var search = ""

    private var filtered: [FAQItem] {
        if search.isEmpty { return items }
        return items.filter {
            $0.question.localizedCaseInsensitiveContains(search) ||
            $0.answer.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { item in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expanded.contains(item.id) },
                        set: { open in
                            if open { expanded.insert(item.id) }
                            else    { expanded.remove(item.id) }
                        }
                    )
                ) {
                    Text(item.answer)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text(item.question)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search FAQ")
            .navigationTitle("FAQ")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
