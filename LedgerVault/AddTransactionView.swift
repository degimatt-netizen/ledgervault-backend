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
        case "CHF": return "CHF "
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

                // ── Header ──────────────────────────────────────────────
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3.bold())
                            .foregroundColor(.primary)
                            .frame(width: 40, height: 40)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(Circle())
                    }
                    Spacer()
                    Text("New transaction").font(.headline)
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                // ── Big amount ───────────────────────────────────────────
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

                // ── Type pills ───────────────────────────────────────────
                HStack(spacing: 8) {
                    ForEach(types, id: \.self) { t in
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                type = t
                                if let first = currentCategories.first { category = first.0 }
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

                // ── Rows ─────────────────────────────────────────────────
                ScrollView {
                    VStack(spacing: 0) {

                        // Category
                        Button { showCategoryPicker = true } label: {
                            row(icon: categoryIcon, iconBg: Color.gray.opacity(0.25), iconColor: .primary) {
                                HStack(spacing: 4) {
                                    Text("Category:").foregroundColor(.secondary)
                                    Text(category).foregroundColor(.primary).bold()
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        rowDivider()

                        // Description
                        row(icon: "text.alignleft", iconBg: Color.gray.opacity(0.25), iconColor: .primary) {
                            TextField("Description (optional)", text: $description)
                                .foregroundColor(.primary)
                        }

                        rowDivider()

                        // Account rows
                        if type == "Income" {
                            Button { showToPicker = true } label: {
                                row(icon: "wallet.pass.fill", iconBg: Color.blue.opacity(0.2), iconColor: .blue) {
                                    HStack(spacing: 4) {
                                        Text("To:").foregroundColor(.secondary)
                                        Text("💰 \(toAccount?.name ?? "Select account")")
                                            .foregroundColor(.primary).bold()
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        } else if type == "Expense" {
                            Button { showFromPicker = true } label: {
                                row(icon: "wallet.pass.fill", iconBg: Color.blue.opacity(0.2), iconColor: .blue) {
                                    HStack(spacing: 4) {
                                        Text("From:").foregroundColor(.secondary)
                                        Text("💰 \(fromAccount?.name ?? "Select account")")
                                            .foregroundColor(.primary).bold()
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        } else {
                            Button { showFromPicker = true } label: {
                                row(icon: "wallet.pass.fill", iconBg: Color.blue.opacity(0.2), iconColor: .blue) {
                                    HStack(spacing: 4) {
                                        Text("From:").foregroundColor(.secondary)
                                        Text("💰 \(fromAccount?.name ?? "Select")")
                                            .foregroundColor(.primary).bold()
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            rowDivider()
                            Button { showToPicker = true } label: {
                                row(icon: "wallet.pass.fill", iconBg: Color.green.opacity(0.2), iconColor: .green) {
                                    HStack(spacing: 4) {
                                        Text("To:").foregroundColor(.secondary)
                                        Text("💰 \(toAccount?.name ?? "Select")")
                                            .foregroundColor(.primary).bold()
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        rowDivider()

                        // Note
                        row(icon: "note.text", iconBg: Color.gray.opacity(0.25), iconColor: .primary) {
                            TextField("Note", text: $note)
                                .foregroundColor(.primary)
                        }

                        rowDivider()

                        // Date
                        row(icon: "calendar", iconBg: Color.gray.opacity(0.25), iconColor: .primary) {
                            HStack {
                                DatePicker("", selection: $date, displayedComponents: .date)
                                    .labelsHidden()
                                Spacer()
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                        }

                        Color.clear.frame(height: 100)
                    }
                }

                // ── Save button ──────────────────────────────────────────
                Button { Task { await save() } } label: {
                    Text(isSaving ? "Saving…" : "SAVE")
                        .font(.headline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(canSave ? Color.white : Color.white.opacity(0.3))
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
            if let first = currentCategories.first { category = first.0 }
        }
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
                            Text(cat.0).foregroundColor(.primary)
                            Spacer()
                            if category == cat.0 {
                                Image(systemName: "checkmark").foregroundColor(.blue)
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
        .sheet(isPresented: $showFromPicker) {
            accountPickerSheet(title: "From Account", selectedId: $fromAccountId) {
                showFromPicker = false
            }
        }
        .sheet(isPresented: $showToPicker) {
            accountPickerSheet(title: "To Account", selectedId: $toAccountId) {
                showToPicker = false
            }
        }
    }

    // ── Reusable row builder ─────────────────────────────────────────────────
    @ViewBuilder
    private func row<Content: View>(
        icon: String,
        iconBg: Color,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 32, height: 32)
                .background(iconBg)
                .clipShape(Circle())
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemGroupedBackground))
    }

    @ViewBuilder
    private func rowDivider() -> some View {
        Divider().padding(.leading, 66)
    }

    // ── Account picker sheet ─────────────────────────────────────────────────
    @ViewBuilder
    private func accountPickerSheet(
        title: String,
        selectedId: Binding<String>,
        onDone: @escaping () -> Void
    ) -> some View {
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

    // ── Data ─────────────────────────────────────────────────────────────────
    private func loadAccounts() async {
        do {
            accounts = try await APIService.shared.fetchAccounts()
            if let first = allAccounts.first {
                fromAccountId = first.id
                toAccountId = first.id
            }
            if let first = currentCategories.first { category = first.0 }
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

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
