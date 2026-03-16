import SwiftUI

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    let defaultType: String

    @State private var name = ""
    @State private var baseCurrency = "EUR"
    @State private var isSaving = false
    @State private var errorMessage: String?

    let currencies = ["EUR", "USD", "GBP", "CHF", "CAD", "AUD", "JPY", "PLN", "SEK", "NOK", "CZK"]

    private var displayType: String {
        switch defaultType {
        case "bank": return "Bank"
        case "broker": return "Broker"
        case "crypto_wallet": return "Crypto Wallet"
        case "cash": return "Stablecoin Wallet"
        default: return "Account"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Details") {
                    TextField("Name (e.g. Revolut, Binance, Kraken, eToro)", text: $name)

                    HStack {
                        Text("Account Type")
                        Spacer()
                        Text(displayType)
                            .foregroundColor(.blue)
                            .font(.body.bold())
                    }

                    Picker("Currency", selection: $baseCurrency) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Add New \(displayType)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.isEmpty)
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
                name: name,
                accountType: defaultType,
                baseCurrency: baseCurrency
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
