import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("baseCurrency") private var baseCurrency = "EUR"
    @AppStorage("theme")      private var theme      = "system"
    @AppStorage("isSignedIn") private var isSignedIn = false

    let currencies = ["EUR","USD","GBP","CHF","CAD","AUD","JPY","PLN","SEK","NOK","CZK"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Base Currency", selection: $baseCurrency) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Appearance", selection: $theme) {
                        Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                        Label("Light",  systemImage: "sun.max.fill").tag("light")
                        Label("Dark",   systemImage: "moon.fill").tag("dark")
                    }
                }

                Section("Per-Tab Currency") {
                    PerTabCurrencyView()
                }

                Section {
                Button(role: .destructive) {
                    isSignedIn = false
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundColor(.red)
                }
            }

            Section("About") {
                    LabeledContent("App", value: "LedgerVault")
                    LabeledContent("Version", value: "1.0 MVP")
                    LabeledContent("Backend", value: "Railway · FastAPI")
                    Text("Base currency affects dashboard & valuation. Per-tab currencies affect display only.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// ── Per-Tab Currency Picker ───────────────────────────────────────────────────
struct PerTabCurrencyView: View {
    @AppStorage("currency_banks")       private var banksCurrency       = "EUR"
    @AppStorage("currency_stablecoins") private var stablecoinsCurrency = "USD"
    @AppStorage("currency_stocks")      private var stocksCurrency      = "USD"
    @AppStorage("currency_crypto")      private var cryptoCurrency      = "USD"

    let currencies = ["EUR","USD","GBP","CHF","CAD","AUD","JPY"]

    var body: some View {
        Group {
            tabCurrencyRow("Banks",       "building.columns.fill", .blue,   $banksCurrency)
            tabCurrencyRow("Stablecoins", "link.circle.fill",      .indigo, $stablecoinsCurrency)
            tabCurrencyRow("Stocks",      "chart.bar.fill",        .green,  $stocksCurrency)
            tabCurrencyRow("Crypto",      "bitcoinsign.circle.fill",.orange, $cryptoCurrency)
        }
    }

    @ViewBuilder
    private func tabCurrencyRow(_ label: String, _ icon: String, _ color: Color, _ binding: Binding<String>) -> some View {
        HStack {
            Label(label, systemImage: icon).foregroundColor(color)
            Spacer()
            Picker("", selection: binding) {
                ForEach(currencies, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }
}
