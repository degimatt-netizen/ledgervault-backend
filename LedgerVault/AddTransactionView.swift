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
    private enum FocusField { case amount, description, note }
    @FocusState private var focusedField: FocusField?
    @State private var showCategoryPicker = false
    @State private var showFromPicker = false
    @State private var showToPicker = false
    @State private var customExpenseCategories: [CategoryItem] = CategoryItem.load(key: "customExpenseCats")
    @State private var customIncomeCategories:  [CategoryItem] = CategoryItem.load(key: "customIncomeCats")

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
        let custom = type == "Income"
            ? customIncomeCategories.map { ($0.name, $0.icon) }
            : customExpenseCategories.map { ($0.name, $0.icon) }
        return (type == "Income" ? incomeCategories : expenseCategories) + custom
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
        let currency: String
        switch type {
        case "Income":   currency = toAccount?.base_currency   ?? "EUR"
        default:         currency = fromAccount?.base_currency ?? "EUR"
        }
        return ccySymbol(currency)
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
                ZStack {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(currencySymbol)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(amountString.isEmpty ? "0" : amountString)
                            .font(.system(size: 58, weight: .bold))
                            .minimumScaleFactor(0.4)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    // Hidden text field captures keyboard input
                    TextField("", text: $amountString)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount)
                        .opacity(0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: amountString) { _, newValue in
                            // Allow only valid decimal: one dot, digits only
                            var filtered = newValue.filter { $0.isNumber || $0 == "." }
                            let dots = filtered.filter { $0 == "." }.count
                            if dots > 1 {
                                var seenDot = false
                                filtered = String(filtered.filter { ch in
                                    if ch == "." { if seenDot { return false }; seenDot = true }
                                    return true
                                })
                            }
                            if filtered != newValue { amountString = filtered }
                            amount = Double(filtered)
                        }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .onTapGesture { focusedField = .amount }

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
                ScrollViewReader { proxy in
                    ScrollView {
                        // Dismiss keyboard on tap of blank area
                        Color.clear.frame(height: 0)
                            .contentShape(Rectangle())
                            .onTapGesture { focusedField = nil }
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
                                    .focused($focusedField, equals: .description)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .note }
                            }
                            .id("description")

                            rowDivider()

                            // Account rows
                            if type == "Income" {
                                Button { showToPicker = true } label: {
                                    row(icon: "wallet.pass.fill", iconBg: Color.blue.opacity(0.2), iconColor: .blue) {
                                        HStack(spacing: 4) {
                                            Text("To:").foregroundColor(.secondary)
                                            Text("\(toAccount?.name ?? "Select account")")
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
                                            Text("\(fromAccount?.name ?? "Select account")")
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
                                            Text("\(fromAccount?.name ?? "Select")")
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
                                            Text("\(toAccount?.name ?? "Select")")
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
                                TextField("Note (optional)", text: $note)
                                    .foregroundColor(.primary)
                                    .focused($focusedField, equals: .note)
                                    .submitLabel(.done)
                                    .onSubmit { focusedField = nil }
                            }
                            .id("note")

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

                            Color.clear.frame(height: 40)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedField) { _, field in
                        guard let field, field != .amount else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(field == .description ? "description" : "note", anchor: .center)
                        }
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
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .task { await loadAccounts() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focusedField = .amount } }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .font(.body.bold())
            }
        }
        .onChange(of: type) { _, _ in
            if let first = currentCategories.first { category = first.0 }
        }
        .sheet(isPresented: $showCategoryPicker) {
            CategoryPickerView(
                baseCategories: type == "Income" ? incomeCategories : expenseCategories,
                selected: $category,
                customExpenseCategories: $customExpenseCategories,
                customIncomeCategories: $customIncomeCategories,
                type: type
            ) { showCategoryPicker = false }
            .presentationDetents([.large])
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
                legs = [.init(account_id: toAccountId, asset_id: nil, quantity: amount, unit_price: 1.0, fee_flag: false)]
            case "Expense":
                legs = [.init(account_id: fromAccountId, asset_id: nil, quantity: -amount, unit_price: 1.0, fee_flag: false)]
            case "Transfer":
                legs = [
                    .init(account_id: fromAccountId, asset_id: nil, quantity: -amount, unit_price: 1.0, fee_flag: false),
                    .init(account_id: toAccountId,   asset_id: nil, quantity:  amount, unit_price: 1.0, fee_flag: false)
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

// ── CategoryPickerView ────────────────────────────────────────────────────────
struct CategoryItem: Codable, Equatable {
    let name: String
    let icon: String

    static func load(key: String) -> [CategoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CategoryItem].self, from: data)) ?? []
    }

    static func save(_ items: [CategoryItem], key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }
}

struct CategoryPickerView: View {
    let baseCategories: [(String, String)]
    @Binding var selected: String
    @Binding var customExpenseCategories: [CategoryItem]
    @Binding var customIncomeCategories: [CategoryItem]
    let type: String
    let onDone: () -> Void

    @State private var showAddCategory = false
    @State private var newCategoryName = ""
    @State private var newCategoryIcon = "tag.fill"

    let availableIcons = [
        "tag.fill", "star.fill", "heart.fill", "house.fill", "car.fill",
        "airplane", "fork.knife", "cart.fill", "bag.fill", "gift.fill",
        "bolt.fill", "tv.fill", "gamecontroller.fill", "music.note",
        "book.fill", "figure.run", "pawprint.fill", "leaf.fill",
        "hammer.fill", "wrench.fill", "creditcard.fill", "banknote.fill",
        "chart.line.uptrend.xyaxis", "laptopcomputer", "phone.fill"
    ]

    private var allCategories: [(String, String)] {
        let custom = type == "Income"
            ? customIncomeCategories.map { ($0.name, $0.icon) }
            : customExpenseCategories.map { ($0.name, $0.icon) }
        return baseCategories + custom
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(allCategories, id: \.0) { cat in
                        Button {
                            selected = cat.0
                            onDone()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: cat.1)
                                    .frame(width: 32, height: 32)
                                    .background(Color.gray.opacity(0.15))
                                    .clipShape(Circle())
                                    .foregroundColor(.primary)
                                Text(cat.0).foregroundColor(.primary)
                                Spacer()
                                if selected == cat.0 {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                        .swipeActions {
                                let isCustom = (type == "Income" ? customIncomeCategories : customExpenseCategories).contains(where: { $0.name == cat.0 })
                            if isCustom {
                                Button(role: .destructive) {
                                    if type == "Income" {
                                        customIncomeCategories.removeAll { $0.name == cat.0 }
                                        CategoryItem.save(customIncomeCategories, key: "customIncomeCats")
                                    } else {
                                        customExpenseCategories.removeAll { $0.name == cat.0 }
                                        CategoryItem.save(customExpenseCategories, key: "customExpenseCats")
                                    }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showAddCategory = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus.circle.fill")
                                .frame(width: 32, height: 32)
                                .foregroundColor(.blue)
                            Text("Add Custom Category").foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                }
            }
            .sheet(isPresented: $showAddCategory) {
                NavigationStack {
                    Form {
                        Section("Category Name") {
                            TextField("e.g. Gym, Subscriptions…", text: $newCategoryName)
                        }
                        Section("Icon") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                                ForEach(availableIcons, id: \.self) { icon in
                                    Button {
                                        newCategoryIcon = icon
                                    } label: {
                                        Image(systemName: icon)
                                            .font(.title3)
                                            .frame(width: 44, height: 44)
                                            .background(newCategoryIcon == icon ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
                                            .foregroundColor(newCategoryIcon == icon ? .blue : .primary)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .navigationTitle("New Category")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAddCategory = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                guard !newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                                let newCat = CategoryItem(name: newCategoryName.trimmingCharacters(in: .whitespaces), icon: newCategoryIcon)
                                if type == "Income" {
                                    customIncomeCategories.append(newCat)
                                    CategoryItem.save(customIncomeCategories, key: "customIncomeCats")
                                } else {
                                    customExpenseCategories.append(newCat)
                                    CategoryItem.save(customExpenseCategories, key: "customExpenseCats")
                                }
                                newCategoryName = ""
                                newCategoryIcon = "tag.fill"
                                showAddCategory = false
                            }
                            .disabled(newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}
