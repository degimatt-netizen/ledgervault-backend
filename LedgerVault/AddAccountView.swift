import SwiftUI

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    let defaultType: String

    @State private var name              = ""
    @State private var baseCurrency: String
    @State private var excludeFromTotal  = false
    @State private var isSaving          = false
    @State private var errorMessage: String?

    let currencies = ["EUR", "USD", "GBP", "CHF", "CAD", "AUD", "JPY", "PLN", "SEK", "NOK", "CZK"]

    init(onSaved: @escaping () -> Void, defaultType: String) {
        self.onSaved = onSaved
        self.defaultType = defaultType
        // Brokers, crypto wallets and stablecoin wallets default to USD
        switch defaultType {
        case "broker", "crypto_wallet", "cash":
            _baseCurrency = State(initialValue: "USD")
        default:
            _baseCurrency = State(initialValue: "EUR")
        }
    }

    // ── Type metadata ─────────────────────────────────────────────────────────
    private var typeConfig: AccountTypeConfig {
        switch defaultType {
        case "bank":          return .bank
        case "broker":        return .broker
        case "crypto_wallet": return .crypto
        case "cash":          return .stablecoin
        default:              return .bank
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // ── Icon header ───────────────────────────────────────────
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(typeConfig.color.opacity(0.12))
                                .frame(width: 72, height: 72)
                            Image(systemName: typeConfig.icon)
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundColor(typeConfig.color)
                        }
                        Text("New \(typeConfig.label)")
                            .font(.title3.bold())
                        Text(typeConfig.subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 8)


                    // ── Name field ────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Account Name")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        HStack(spacing: 12) {
                            Image(systemName: typeConfig.icon)
                                .foregroundColor(typeConfig.color)
                                .frame(width: 20)
                            TextField(typeConfig.placeholder, text: $name)
                                .font(.body)
                                .autocorrectionDisabled()
                            if !name.isEmpty {
                                Button { name = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Color(.systemGray3))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color(.systemBackground))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(.systemGray5), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    }

                    // ── Currency picker ───────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Currency")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(currencies, id: \.self) { cur in
                                    Button {
                                        baseCurrency = cur
                                    } label: {
                                        Text(cur)
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 9)
                                            .background(
                                                baseCurrency == cur
                                                    ? typeConfig.color
                                                    : Color(.systemGray6)
                                            )
                                            .foregroundColor(
                                                baseCurrency == cur ? .white : .primary
                                            )
                                            .cornerRadius(20)
                                    }
                                    .animation(.easeInOut(duration: 0.15), value: baseCurrency)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }

                    // ── Exclude from total toggle ────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.orange.opacity(0.12))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "eye.slash.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Exclude from Net Worth")
                                    .font(.subheadline.weight(.semibold))
                                Text("This account won't count towards your total wealth")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $excludeFromTotal)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color(.systemBackground))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(.systemGray5), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 20)

                    // ── Error ─────────────────────────────────────────────────
                    if let err = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 20)
                    }

                    // ── Save button ───────────────────────────────────────────
                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.85)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                            Text(isSaving ? "Adding…" : "Add \(typeConfig.label)")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving
                                ? typeConfig.color.opacity(0.4)
                                : typeConfig.color
                        )
                        .cornerRadius(16)
                        .padding(.horizontal, 20)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .animation(.easeInOut(duration: 0.15), value: name.isEmpty)

                    Spacer(minLength: 20)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            _ = try await APIService.shared.createAccount(
                name: name.trimmingCharacters(in: .whitespaces),
                accountType: defaultType,
                baseCurrency: baseCurrency,
                excludeFromTotal: excludeFromTotal
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// ── Type config ────────────────────────────────────────────────────────────────
private struct AccountTypeConfig {
    let label:       String
    let subtitle:    String
    let icon:        String
    let color:       Color
    let placeholder: String
    let suggestions: [String]

    static let bank = AccountTypeConfig(
        label:       "Bank Account",
        subtitle:    "Track balances and transactions from your bank",
        icon:        "building.columns.fill",
        color:       .blue,
        placeholder: "e.g. Revolut, Monzo, HSBC",
        suggestions: ["Revolut", "Monzo", "N26", "Wise", "Starling", "HSBC",
                      "Barclays", "Lloyds", "NatWest", "Chase"]
    )

    static let broker = AccountTypeConfig(
        label:       "Broker",
        subtitle:    "Track your stock and ETF investments",
        icon:        "chart.bar.fill",
        color:       .green,
        placeholder: "e.g. eToro, Trading 212, Degiro",
        suggestions: ["eToro", "Trading 212", "Degiro", "Robinhood",
                      "Interactive Brokers", "Freetrade", "Saxo", "Lightyear"]
    )

    static let crypto = AccountTypeConfig(
        label:       "Crypto Wallet",
        subtitle:    "Track holdings across exchanges and wallets",
        icon:        "bitcoinsign.circle.fill",
        color:       .orange,
        placeholder: "e.g. Binance, Coinbase, Kraken",
        suggestions: ["Binance", "Coinbase", "Kraken", "Bybit", "OKX",
                      "Gemini", "Bitfinex", "Ledger", "MetaMask"]
    )

    static let stablecoin = AccountTypeConfig(
        label:       "Stablecoin Wallet",
        subtitle:    "Track USDC, USDT and other stable assets",
        icon:        "dollarsign.circle.fill",
        color:       .teal,
        placeholder: "e.g. USDC Wallet, Tether Reserve",
        suggestions: ["USDC Wallet", "USDT Wallet", "DAI Wallet",
                      "Binance USDC", "Coinbase USDC", "Kraken USDT"]
    )
}
