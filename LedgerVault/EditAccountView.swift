import SwiftUI

struct EditAccountView: View {
    let account: APIService.Account
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var accountType: String
    @State private var baseCurrency: String
    @State private var errorMessage: String?

    private let accountTypes = ["bank", "exchange", "broker", "crypto_wallet", "cash"]
    private let currencies = ["EUR", "USD", "GBP", "CHF", "CAD", "AUD", "JPY", "PLN", "SEK", "NOK", "CZK"]

    init(account: APIService.Account, onSaved: @escaping () -> Void) {
        self.account = account
        self.onSaved = onSaved
        _name = State(initialValue: account.name)
        _accountType = State(initialValue: account.account_type)
        _baseCurrency = State(initialValue: account.base_currency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Details") {
                    TextField("Name", text: $name)

                    Picker("Type", selection: $accountType) {
                        ForEach(accountTypes, id: \.self) { type in
                            Text(type.replacingOccurrences(of: "_", with: " ").capitalized).tag(type)
                        }
                    }

                    Picker("Base Currency", selection: $baseCurrency) {
                        ForEach(currencies, id: \.self) { currency in
                            Text(currency).tag(currency)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
            .navigationTitle("Edit Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                }
            }
        }
    }

    private func save() async {
        do {
            _ = try await APIService.shared.updateAccount(
                id: account.id,
                name: name,
                accountType: accountType,
                baseCurrency: baseCurrency
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
