import SwiftUI

struct AddTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var type = "Income"
    @State private var amount: Double?
    @State private var description = ""
    @State private var category = ""
    @State private var fromAccountId = ""
    @State private var toAccountId = ""
    @State private var accounts: [APIService.Account] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    let types = ["Income", "Expense", "Transfer"]

    var categories: [String] {
        switch type {
        case "Income": return ["Salary", "Freelance", "Investment Return", "Other Income"]
        case "Expense": return ["Food", "Rent", "Transport", "Bills", "Entertainment", "Other Expense"]
        default: return []
        }
    }

    private var bankAndStableAccounts: [APIService.Account] {
        accounts.filter { ["bank", "cash"].contains($0.account_type) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { Text($0) }
                    }
                    TextField("Amount", value: $amount, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                    TextField("Description", text: $description)
                    if !categories.isEmpty {
                        Picker("Category", selection: $category) {
                            ForEach(categories, id: \.self) { Text($0) }
                        }
                    }
                }

                if type == "Income" {
                    Section("Destination") {
                        Picker("To Account", selection: $toAccountId) {
                            ForEach(bankAndStableAccounts) { acc in
                                Text("\(acc.name) (\(acc.base_currency))").tag(acc.id)
                            }
                        }
                    }
                } else if type == "Expense" {
                    Section("Source") {
                        Picker("From Account", selection: $fromAccountId) {
                            ForEach(bankAndStableAccounts) { acc in
                                Text("\(acc.name) (\(acc.base_currency))").tag(acc.id)
                            }
                        }
                    }
                } else if type == "Transfer" {
                    Section("From / To") {
                        Picker("From Account", selection: $fromAccountId) { ForEach(bankAndStableAccounts) { acc in Text("\(acc.name) (\(acc.base_currency))").tag(acc.id) } }
                        Picker("To Account", selection: $toAccountId) { ForEach(bankAndStableAccounts) { acc in Text("\(acc.name) (\(acc.base_currency))").tag(acc.id) } }
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundColor(.red)
                }
            }
            .navigationTitle("New Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .task { await loadAccounts() }
            .onChange(of: type) { _, _ in
                if category.isEmpty, let first = categories.first { category = first }
            }
        }
    }

    private var canSave: Bool {
        guard let amount, amount > 0, !description.isEmpty else { return false }
        switch type {
        case "Income": return !toAccountId.isEmpty
        case "Expense": return !fromAccountId.isEmpty
        case "Transfer": return !fromAccountId.isEmpty && !toAccountId.isEmpty && fromAccountId != toAccountId
        default: return false
        }
    }

    private func loadAccounts() async {
        do {
            accounts = try await APIService.shared.fetchAccounts()
            if let first = bankAndStableAccounts.first {
                fromAccountId = first.id
                toAccountId = first.id
            }
            if category.isEmpty, let firstCategory = categories.first {
                category = firstCategory
            }
        } catch {}
    }

    private func save() async {
        guard !isSaving, canSave, let amount else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let legs: [APIService.TransactionLegCreate]
            switch type {
            case "Income":
                legs = [.init(account_id: toAccountId, asset_id: "", quantity: amount, unit_price: amount, fee_flag: false)]
            case "Expense":
                legs = [.init(account_id: fromAccountId, asset_id: "", quantity: -amount, unit_price: amount, fee_flag: false)]
            case "Transfer":
                legs = [
                    .init(account_id: fromAccountId, asset_id: "", quantity: -amount, unit_price: amount, fee_flag: false),
                    .init(account_id: toAccountId, asset_id: "", quantity: amount, unit_price: amount, fee_flag: false)
                ]
            default: legs = []
            }

            _ = try await APIService.shared.createTransactionEvent(
                eventType: type.lowercased(),
                category: category.isEmpty ? nil : category,
                description: description,
                date: Date().formatted(.iso8601.dateSeparator(.dash).year().month().day()),
                note: nil,
                legs: legs
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
