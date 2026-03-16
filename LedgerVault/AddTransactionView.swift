import SwiftUI

struct AddTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var type = "Expense"
    @State private var amount: Double?
    @State private var amountString = ""
    @State private var description = ""
    @State private var category = "Miscellaneous"
    @State private var note = ""
    @State private var date = Date()
    @State private var excludeFromBudget = false
    @State private var fromAccountId = ""
    @State private var toAccountId = ""
    @State private var accounts: [APIService.Account] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showCategoryPicker = false
    @State private var showFromPicker = false
    @State private var showToPicker = false

    let types = ["Expense", "Income", "Transfer"]

    let expenseCategories = [
        ("Food & Drink", "fork.knife"),
        ("Rent", "house.fill"),
        ("Transport", "car.fill"),
        ("Bills", "bolt.fill"),
        ("Entertainment", "tv.fill"),
        ("Shopping", "bag.fill"),
        ("Health", "heart.fill"),
        ("Travel", "airplane"),
        ("Miscellaneous", "square.grid.2x2.fill")
    ]

    let incomeCategories = [
        ("Salary", "banknote.fill"),
        ("Freelance", "laptopcomputer"),
        ("Investment Return", "chart.line.uptrend.xyaxis"),
        ("Gift", "gift.fill"),
        ("Other Income", "plus.circle.fill")
    ]

    var currentCategories: [(String, String)] {
        type == "Income" ? incomeCategories : expenseCategories
    }

    var categoryIcon: String {
        currentCategories.first(where: { $0.0 == category })?.1 ?? "square.grid.2x2.fill"
    }

    private var allAccounts: [APIService.Account] {
        accounts.filter { ["bank", "cash", "stablecoin_wallet"].contains($0.account_type) }
    }

    private var fromAccount: APIService.Account? {
        accounts.first(where: { $0.id == fromAccountId })
    }

    private var toAccount: APIService.Account? {
        accounts.first(where: { $0.id == toAccountId })
    }

    private var currencySymbol: String {
        let currency = fromAccount?.base_currency ?? toAccount?.base_currency ?? "EUR"
        switch currency {
        case "USD": return "$"
        case "GBP": return "£"
        case "CHF": return "CHF"
        default: return "€"
        }
    }

    private var canSave: Bool {
        guard let amount, amount > 0 else { return false }
        switch type {
        case "Income": return !toAccountId.isEmpty
        case "Expense": return !fromAccountId.isEmpty
        case "Transfer": return !fromAccountId.isEmpty && !toAccountId.isEmpty && fromAccountId != toAccountId
        default: return false
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.bold())
                            .foregroundColor(.primary)
                            .frame(width: 40, height: 40)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(Circle())
                    }
                    Spacer()
                    Text("New transaction")
                        .font(.headline)
                    Spacer()
                    // Balance the X button
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                // Big amount
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(currencySymbol)
                        .font(.system(size: 42, weight: .bold))
                    Text(amountString.isEmpty ? "0" : amountString)
                        .font(.system(size: 64, weight: .bold))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .onTapGesture { showAmountEntry() }

                // Type selector pills
                HStack(spacing: 8) {
                    ForEach(types, id: \.self) { t in
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                type = t
                                if let first = currentCategories.first {
                                    category = first.0
                                }
                            }
                        } label: {
                            Text(t.uppercased())
                                .font(.caption.bold())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(type == t ? Color.primary : Color.clear)
                                .foregroundColor(type == t ? Color(UIColor.systemGroupedBackground) : .secondary)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.bottom, 20)

                Divider()

                // Rows
                ScrollView {
                    VStack(spacing: 0) {

                        // Category
                        Button {
                            showCategoryPicker = true
                        } label: {
                            rowContent {
                                Image(systemName: categoryIcon)
                                    .frame(width: 32, height: 32)
                                    .background(Color.gray.opacity(0.2))
                                    .clipShape(Circle())
                                    .foregroundColor(.primary)
                                Text("Category: ")
                                    .foregroundColor(.secondary)
                                + Text(category)
                                    .foregroundColor(.primary)
                                    .bold()
                            }
                        }

                        Divider().padding(.leading, 60)

                        // Description
                        rowContent {
                            Image(systemName: "text.alignleft")
                                .frame(width: 32, height: 32)
                                .background(Color.gray.opacity(0.2))
                                .clipShape(Circle())
                                .foregroundColor(.primary)
                            TextField("Description (optional)", text: $description)
                                .foregroundColor(.primary)
                        }

                        Divider().padding(.leading, 60)

                        // From / To account
                        if type == "Income" {
                            Button { showToPicker = true } label: {
                                rowContent {
                                    Image(systemName: "wallet.pass.fill")
                                        .frame(width: 32, height: 32)
                                        .background(Color.blue.opacity(0.2))
                                        .clipShape(Circle())
                                        .foregroundColor(.blue)
                                    (Text("To: ").foregroundColor(.secondary) +
                                     Text("💰 \(toAccount?.name ?? "Select account")").foregroundColor(.primary).bold())
                                }
                            }
                        } else if type == "Expense" {
                            Button { showFromPicker = true } label: {
                                rowContent {
                                    Image(systemName: "wallet.pass.fill")
                                        .frame(width: 32, height: 32)
                                        .background(Color.blue.opacity(0.2))
                                        .clipShape(Circle())
                                        .foregroundColor(.blue)
                                    HStack {
                                        (Text("From: ").foregroundColor(.secondary) +
                                         Text("💰 \(fromAccount?.name ?? "Select account")").foregroundColor(.primary).bold())
                                        Spacer()
                                        Image(systemName: "arrow.left.arrow.right")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                            }
                        } else {
                            Button { showFromPicker = true } label: {
                                rowContent {
                                    Image(systemName: "wallet.pass.fill")
                                        .frame(width: 32, height: 32)
                                        .background(Color.blue.opacity(0.2))
                                        .clipShape(Circle())
                                        .foregroundColor(.blue)
                                    (Text("From: ").foregroundColor(.secondary) +
                                     Text("💰 \(fromAccount?.name ?? "Select")").foregroundColor(.primary).bold())
                                }
                            }
                            Divider().padding(.leading, 60)
                            Button { showToPicker = true } label: {
                                rowContent {
                                    Image(systemName: "wallet.pass.fill")
                                        .frame(width: 32, height: 32)
                                        .background(Color.green.opacity(0.2))
                                        .clipShape(Circle())
                                        .foregroundColor(.green)
                                    (Text("To: ").foregroundColor(.secondary) +
                                     Text("💰 \(toAccount?.name ?? "Select")").foregroundColor(.primary).bold())
                                }
                            }
                        }

                        Divider().padding(.leading, 60)

                        // Note
                        rowContent {
                            Image(systemName: "note.text")
                                .frame(width: 32, height: 32)
                                .background(Color.gray.opacity(0.2))
                                .clipShape(Circle())
                                .foregroundColor(.primary)
                            TextField("Note", text: $note)
                                .foregroundColor(.primary)
                        }

                        Divider().padding(.leading, 60)

                        // Date
                        rowContent {
                            Image(systemName: "calendar")
                                .frame(width: 32, height: 32)
                                .background(Color.gray.opacity(0.2))
                                .clipShape(Circle())
                                .foregroundColor(.primary)
                            HStack {
                                DatePicker("", selection: $date, displayedComponents: .date)
                                    .labelsHidden()
                                Spacer()
                            }
                        }

                        Divider().padding(.leading, 60)

                        // Exclude from budget
                        rowContent {
                            Image(systemName: "circle.lefthalf.filled")
                                .frame(width: 32, height: 32)
                                .background(Color.gray.opacity(0.2))
                                .clipShape(Circle())
                                .foregroundColor(.primary)
                            HStack {
                                Text("Exclude from budget")
                                    .foregroundColor(.primary)
                                Spacer()
                                Toggle("", isOn: $excludeFromBudget)
                                    .labelsHidden()
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                                .padding()
                        }

                        Color.clear.frame(height: 100)
                    }
                }

                // Save button
                Button {
                    Task { await save() }
                } label: {
                    Text(isSaving ? "Saving…" : "SAVE")
                        .font(.headline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(canSave ? Color.white : Color.white.opacity(0.4))
                        .foregroundColor(canSave ? .black : .gray)
                        .clipShape(Capsule())
                }
                .disabled(!canSave || isSaving)
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .background(Color(UIColor.systemGroupedBackground))
            }
        }
        .task { await loadAccounts() }
        .onChange(of: type) { _, _ in
            if let first = currentCategories.first {
                category = first.0
            }
        }
        // Category picker sheet
        .sheet(isPresented: $showCategoryPicker) {
            NavigationStack {
                List(currentCategories, id: \.0) { cat in
                    Button {
                        category = cat.0
                        showCategoryPicker = false
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: cat.1)
                                .frame(width: 32, height: 32)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(Circle())
                                .foregroundColor(.primary)
                            Text(cat.0)
                                .foregroundColor(.primary)
                            Spacer()
                            if category == cat.0 {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                .navigationTitle("Category")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showCategoryPicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        // From account picker
        .sheet(isPresented: $showFromPicker) {
            accountPickerSheet(title: "From Account", selectedId: $fromAccountId) {
                showFromPicker = false
            }
        }
        // To account picker
        .sheet(isPresented: $showToPicker) {
            accountPickerSheet(title: "To Account", selectedId: $toAccountId) {
                showToPicker = false
            }
        }
    }

    @ViewBuilder
    private func rowContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(UIColor.systemGroupedBackground))
    }

    @ViewBuilder
    private func accountPickerSheet(title: String, selectedId: Binding<String>, onDone: @escaping () -> Void) -> some View {
        NavigationStack {
            List(allAccounts) { acc in
                Button {
                    selectedId.wrappedValue = acc.id
                    onDone()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acc.name).foregroundColor(.primary).font(.headline)
                            Text(acc.base_currency).foregroundColor(.secondary).font(.caption)
                        }
                        Spacer()
                        if selectedId.wrappedValue == acc.id {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func showAmountEntry() {
        // Amount is entered via keyboard — just focus handled by tapping the amount area
    }

    private func loadAccounts() async {
        do {
            accounts = try await APIService.shared.fetchAccounts()
            if let first = allAccounts.first {
                fromAccountId = first.id
                toAccountId = first.id
            }
            if let first = currentCategories.first {
                category = first.0
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
                description: description.isEmpty ? category : description,
                date: date.formatted(.iso8601.dateSeparator(.dash).year().month().day()),
                note: note.isEmpty ? nil : note,
                legs: legs
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Numpad overlay for amount entry
extension AddTransactionView {
    var amountEntryOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 0) {
                // Display
                HStack {
                    Text(currencySymbol + (amountString.isEmpty ? "0" : amountString))
                        .font(.system(size: 36, weight: .bold))
                        .padding()
                    Spacer()
                    Button {
                        if !amountString.isEmpty {
                            amountString.removeLast()
                            amount = Double(amountString)
                        }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title2)
                            .padding()
                    }
                }

                // Numpad grid
                let keys = ["1","2","3","4","5","6","7","8","9",".","0","⌫"]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 0) {
                    ForEach(keys, id: \.self) { key in
                        Button {
                            handleKey(key)
                        } label: {
                            Text(key)
                                .font(.title.bold())
                                .frame(maxWidth: .infinity)
                                .frame(height: 70)
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(20, corners: [.topLeft, .topRight])
        }
        .ignoresSafeArea()
    }

    private func handleKey(_ key: String) {
        switch key {
        case "⌫":
            if !amountString.isEmpty { amountString.removeLast() }
        case ".":
            if !amountString.contains(".") { amountString += "." }
        default:
            if amountString.count < 10 { amountString += key }
        }
        amount = Double(amountString)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
