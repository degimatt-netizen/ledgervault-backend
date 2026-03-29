import SwiftUI
import PhotosUI

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
    @State private var legs: [APIService.TransactionLeg] = []
    @State private var receivedAmount: Double?
    @State private var receivedAmountString = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    private enum FocusField { case amount, description, note, receivedAmount }
    @FocusState private var focusedField: FocusField?
    @State private var showCategoryPicker = false
    @State private var showFromPicker = false
    @State private var showToPicker = false
    @State private var customExpenseCategories: [CategoryItem] = CategoryItem.load(key: "customExpenseCats")
    @State private var customIncomeCategories:  [CategoryItem] = CategoryItem.load(key: "customIncomeCats")
    // Receipt
    @State private var receiptPhoto: PhotosPickerItem?
    @State private var receiptImage: UIImage?

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
        let items = type == "Income" ? customIncomeCategories : customExpenseCategories
        return items.isEmpty
            ? (type == "Income" ? incomeCategories : expenseCategories)
            : items.map { ($0.name, $0.icon) }
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

    /// True when the Transfer is between two accounts with different currencies.
    private var isCrossCurrencyTransfer: Bool {
        guard type == "Transfer" else { return false }
        guard let from = fromAccount, let to = toAccount else { return false }
        return from.base_currency.uppercased() != to.base_currency.uppercased()
    }

    private var toCurrencySymbol: String {
        ccySymbol(toAccount?.base_currency ?? "EUR")
    }

    private var typeColor: Color {
        switch type {
        case "Income":  return Color(red: 0.09, green: 0.70, blue: 0.45)
        case "Expense": return Color(red: 0.97, green: 0.25, blue: 0.36)
        default:        return Color(red: 0.22, green: 0.46, blue: 0.97)
        }
    }

    /// Fiat balance for a given account (sum of all leg quantities).
    private func accountBalance(_ accountId: String) -> Double {
        legs.filter { $0.account_id == accountId }.reduce(0) { $0 + $1.quantity }
    }

    /// True if the source account would go negative after this transaction.
    private var wouldOverdraw: Bool {
        guard let amount, amount > 0 else { return false }
        switch type {
        case "Expense", "Transfer":
            guard !fromAccountId.isEmpty else { return false }
            let balance = accountBalance(fromAccountId)
            return amount > balance
        default: return false
        }
    }

    private var canSave: Bool {
        guard let amount, amount > 0 else { return false }
        if wouldOverdraw { return false }
        switch type {
        case "Income": return !toAccountId.isEmpty
        case "Expense": return !fromAccountId.isEmpty
        case "Transfer":
            let basic = !fromAccountId.isEmpty && !toAccountId.isEmpty && fromAccountId != toAccountId
            if isCrossCurrencyTransfer { return basic && (receivedAmount ?? 0) > 0 }
            return basic
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {

                // ── Header ──────────────────────────────────────────────
                HStack {
                    Button { dismiss() } label: {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                                .frame(width: 36, height: 36)
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    Text("New transaction")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)

                // ── Amount display ──────────────────────────────────────
                ZStack {
                    VStack(spacing: 0) {
                        HStack(alignment: .lastTextBaseline, spacing: 4) {
                            Text(currencySymbol)
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(.white.opacity(0.55))
                            Text(amountString.isEmpty ? "0" : amountString)
                                .font(.system(size: 62, weight: .bold, design: .rounded))
                                .foregroundStyle(amountString.isEmpty ? .white.opacity(0.2) : .white)
                                .minimumScaleFactor(0.4)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    TextField("", text: $amountString)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount)
                        .opacity(0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: amountString) { _, newValue in
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
                .frame(height: 90)
                .padding(.horizontal, 32)
                .onTapGesture { focusedField = .amount }

                // ── Type selector ────────────────────────────────────────
                HStack(spacing: 4) {
                    ForEach(types, id: \.self) { t in
                        let isSelected = type == t
                        Button {
                            hapticLight()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                type = t
                                if let first = currentCategories.first { category = first.0 }
                            }
                        } label: {
                            Text(t.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(isSelected ? .white : .white.opacity(0.3))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(isSelected ? Color.white.opacity(0.14) : Color.clear)
                                .clipShape(Capsule())
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider().background(Color.white.opacity(0.08))

                // ── Rows ─────────────────────────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        // Dismiss keyboard on tap of blank area
                        Color.clear.frame(height: 0)
                            .contentShape(Rectangle())
                            .onTapGesture { focusedField = nil }
                        VStack(spacing: 0) {

                            // Category (hidden for Transfer)
                            if type != "Transfer" {
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
                            }

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
                                if let acc = fromAccount {
                                    balanceHint(for: acc)
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
                                if let acc = fromAccount {
                                    balanceHint(for: acc)
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

                                // Cross-currency received amount
                                if isCrossCurrencyTransfer {
                                    rowDivider()
                                    row(icon: "arrow.triangle.2.circlepath", iconBg: Color.purple.opacity(0.2), iconColor: .purple) {
                                        HStack(spacing: 6) {
                                            Text("Received:").foregroundColor(.secondary)
                                            Text(toCurrencySymbol)
                                                .foregroundColor(.secondary).bold()
                                            TextField("0", text: $receivedAmountString)
                                                .keyboardType(.decimalPad)
                                                .focused($focusedField, equals: .receivedAmount)
                                                .foregroundColor(.primary)
                                                .font(.body.bold())
                                                .onChange(of: receivedAmountString) { _, newValue in
                                                    var filtered = newValue.filter { $0.isNumber || $0 == "." }
                                                    let dots = filtered.filter { $0 == "." }.count
                                                    if dots > 1 {
                                                        var seenDot = false
                                                        filtered = String(filtered.filter { ch in
                                                            if ch == "." { if seenDot { return false }; seenDot = true }
                                                            return true
                                                        })
                                                    }
                                                    if filtered != newValue { receivedAmountString = filtered }
                                                    receivedAmount = Double(filtered)
                                                }
                                            Spacer()
                                        }
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
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

                            rowDivider()

                            // Receipt
                            row(icon: "camera.fill", iconBg: Color.orange.opacity(0.2), iconColor: .orange) {
                                HStack {
                                    if let receiptImage {
                                        Image(uiImage: receiptImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text("Receipt attached")
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Button {
                                            self.receiptImage = nil
                                            self.receiptPhoto = nil
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        PhotosPicker(selection: $receiptPhoto, matching: .images) {
                                            HStack(spacing: 6) {
                                                Text("Attach receipt").foregroundColor(.secondary)
                                                Spacer()
                                                Image(systemName: "plus")
                                                    .font(.caption.bold())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                            .onChange(of: receiptPhoto) { _, item in
                                Task {
                                    if let data = try? await item?.loadTransferable(type: Data.self),
                                       let img = UIImage(data: data) {
                                        receiptImage = img
                                    }
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
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().tint(.black).scaleEffect(0.85) }
                        Text(isSaving ? "SAVING…" : "SAVE")
                            .font(.system(size: 15, weight: .bold))
                            .tracking(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(canSave ? .white : Color.white.opacity(0.15))
                    .foregroundStyle(canSave ? .black : Color.white.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .animation(.easeInOut(duration: 0.15), value: canSave)
                }
                .disabled(!canSave || isSaving)
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.15).ignoresSafeArea())
        .preferredColorScheme(.dark)
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
        iconBg: Color = .clear,
        iconColor: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
    }

    @ViewBuilder
    private func rowDivider() -> some View {
        Divider().padding(.leading, 58)
    }

    @ViewBuilder
    private func balanceHint(for account: APIService.Account) -> some View {
        let bal = accountBalance(account.id)
        HStack(spacing: 6) {
            if wouldOverdraw {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.red)
                Text("Insufficient funds")
                    .font(.caption2.bold()).foregroundStyle(.red)
                Text("·").foregroundStyle(.secondary)
            }
            Text("Balance: \(ccySymbol(account.base_currency))\(smartNum(bal))")
                .font(.caption2).foregroundStyle(wouldOverdraw ? .red : .secondary)
        }
        .padding(.horizontal, 58)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        // Seed built-in categories into custom lists on first run
        if customExpenseCategories.isEmpty {
            let seeded = expenseCategories.map { CategoryItem(name: $0.0, icon: $0.1) }
            customExpenseCategories = seeded
            CategoryItem.save(seeded, key: "customExpenseCats")
        }
        if customIncomeCategories.isEmpty {
            let seeded = incomeCategories.map { CategoryItem(name: $0.0, icon: $0.1) }
            customIncomeCategories = seeded
            CategoryItem.save(seeded, key: "customIncomeCats")
        }
        do {
            async let a = APIService.shared.fetchAccounts()
            async let l = APIService.shared.fetchTransactionLegs()
            accounts = try await a
            legs = try await l
            if let first = allAccounts.first {
                fromAccountId = first.id
                toAccountId = first.id
            }
            if let first = currentCategories.first { category = first.0 }
        } catch {
            errorMessage = "Failed to load accounts. Please try again."
        }
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
                if isCrossCurrencyTransfer, let received = receivedAmount, received > 0 {
                    legs = [
                        .init(account_id: fromAccountId, asset_id: nil, quantity: -amount, unit_price: 1.0, fee_flag: false),
                        .init(account_id: toAccountId,   asset_id: nil, quantity:  received, unit_price: 1.0, fee_flag: false)
                    ]
                } else {
                    legs = [
                        .init(account_id: fromAccountId, asset_id: nil, quantity: -amount, unit_price: 1.0, fee_flag: false),
                        .init(account_id: toAccountId,   asset_id: nil, quantity:  amount, unit_price: 1.0, fee_flag: false)
                    ]
                }
            default: legs = []
            }
            let effectiveType = (type == "Transfer" && isCrossCurrencyTransfer) ? "conversion" : type.lowercased()
            let event = try await APIService.shared.createTransactionEvent(
                eventType: effectiveType,
                category: category.isEmpty ? nil : category,
                description: description.isEmpty ? category : description,
                date: date.formatted(.iso8601.dateSeparator(.dash).year().month().day()),
                note: note.isEmpty ? nil : note,
                legs: legs
            )
            // Save receipt image locally if attached
            if let receiptImage {
                ReceiptStore.save(receiptImage, for: event.id)
            }
            hapticSuccess()
            onSaved()
            dismiss()
        } catch {
            hapticError()
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
struct CategoryItem: Codable, Equatable, Identifiable {
    var id: String { name }
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

// ── Shared icon list ─────────────────────────────────────────────────────────
let categoryIcons = [
    // Finance
    "creditcard.fill", "banknote.fill", "dollarsign.circle.fill",
    "chart.line.uptrend.xyaxis", "chart.bar.fill", "arrow.up.arrow.down.circle.fill",
    // Food & Drink
    "fork.knife", "cup.and.saucer.fill", "wineglass.fill",
    "birthday.cake.fill", "cart.fill", "bag.fill",
    // Home & Life
    "house.fill", "sofa.fill", "bed.double.fill",
    "lightbulb.fill", "bolt.fill", "drop.fill",
    // Transport
    "car.fill", "airplane", "tram.fill",
    "bicycle", "fuelpump.fill", "ferry.fill",
    // Shopping & Leisure
    "gift.fill", "tag.fill", "star.fill",
    "heart.fill", "sparkles", "party.popper.fill",
    // Tech & Work
    "laptopcomputer", "phone.fill", "ipad",
    "desktopcomputer", "wifi", "printer.fill",
    // Health
    "cross.fill", "stethoscope", "pills.fill",
    "cross.case.fill", "figure.walk", "dumbbell.fill",
    // Entertainment
    "tv.fill", "gamecontroller.fill", "music.note",
    "headphones", "photo.fill", "camera.fill",
    // Education & Work
    "book.fill", "graduationcap.fill", "pencil.and.scribble",
    "briefcase.fill", "building.2.fill", "person.3.fill",
    // Nature & Travel
    "leaf.fill", "pawprint.fill", "figure.run",
    "mountain.2.fill", "sun.max.fill", "cloud.sun.fill",
    // Utilities & Misc
    "hammer.fill", "wrench.fill", "scissors",
    "paintbrush.fill", "trash.fill", "archivebox.fill",
    "lock.fill", "key.fill", "envelope.fill"
]

// ── Category Add / Edit Form ─────────────────────────────────────────────────
struct CategoryFormSheet: View {
    let title: String
    let buttonLabel: String
    @Binding var name: String
    @Binding var icon: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Category Name") {
                    TextField("e.g. Gym, Subscriptions…", text: $name)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(categoryIcons, id: \.self) { ic in
                            Button { icon = ic } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(icon == ic ? Color.blue.opacity(0.18) : Color(.tertiarySystemFill))
                                        .frame(width: 44, height: 44)
                                    if icon == ic {
                                        RoundedRectangle(cornerRadius: 9)
                                            .stroke(Color.blue.opacity(0.5), lineWidth: 1.5)
                                            .frame(width: 44, height: 44)
                                    }
                                    Image(systemName: ic)
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(icon == ic ? .blue : .primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(buttonLabel) { onSave() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// ── Category Picker (used inside AddTransactionView) ─────────────────────────
struct CategoryPickerView: View {
    let baseCategories: [(String, String)]
    @Binding var selected: String
    @Binding var customExpenseCategories: [CategoryItem]
    @Binding var customIncomeCategories: [CategoryItem]
    let type: String
    let onDone: () -> Void

    @State private var showAddCategory = false
    @State private var editingCategory: CategoryItem?
    @State private var formName = ""
    @State private var formIcon = "tag.fill"

    private var customList: [CategoryItem] {
        type == "Income" ? customIncomeCategories : customExpenseCategories
    }

    var body: some View {
        NavigationStack {
            List {
                // Prominent "Create your own" at the top
                Section {
                    Button {
                        formName = ""; formIcon = "tag.fill"
                        showAddCategory = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Create Custom Category").foregroundColor(.blue).font(.subheadline.bold())
                                Text("Add your own with a custom icon").foregroundColor(.secondary).font(.caption)
                            }
                        }
                    }
                }

                // All categories (custom + seeded defaults)
                if !customList.isEmpty {
                    Section(header: Text("My Categories")) {
                        ForEach(customList, id: \.name) { cat in
                            categoryButton(name: cat.name, icon: cat.icon, isCustom: true)
                        }
                    }
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone() } }
            }
            .sheet(isPresented: $showAddCategory) {
                CategoryFormSheet(title: "New Category", buttonLabel: "Add",
                                  name: $formName, icon: $formIcon,
                                  onSave: { addCategory() }, onCancel: { showAddCategory = false })
            }
            .sheet(item: $editingCategory) { cat in
                CategoryFormSheet(title: "Edit Category", buttonLabel: "Save",
                                  name: $formName, icon: $formIcon,
                                  onSave: { saveEdit(original: cat) }, onCancel: { editingCategory = nil })
            }
        }
    }

    private func addCategory() {
        guard !formName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let newCat = CategoryItem(name: formName.trimmingCharacters(in: .whitespaces), icon: formIcon)
        if type == "Income" {
            customIncomeCategories.append(newCat)
            CategoryItem.save(customIncomeCategories, key: "customIncomeCats")
        } else {
            customExpenseCategories.append(newCat)
            CategoryItem.save(customExpenseCategories, key: "customExpenseCats")
        }
        hapticSuccess()
        formName = ""; formIcon = "tag.fill"
        showAddCategory = false
    }

    private func saveEdit(original: CategoryItem) {
        guard !formName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let updated = CategoryItem(name: formName.trimmingCharacters(in: .whitespaces), icon: formIcon)
        if type == "Income" {
            if let idx = customIncomeCategories.firstIndex(of: original) {
                customIncomeCategories[idx] = updated
                CategoryItem.save(customIncomeCategories, key: "customIncomeCats")
            }
        } else {
            if let idx = customExpenseCategories.firstIndex(of: original) {
                customExpenseCategories[idx] = updated
                CategoryItem.save(customExpenseCategories, key: "customExpenseCats")
            }
        }
        if selected == original.name { selected = updated.name }
        hapticSuccess()
        editingCategory = nil
    }

    @ViewBuilder
    private func categoryButton(name: String, icon: String, isCustom: Bool) -> some View {
        Button {
            selected = name
            onDone()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(selected == name ? Color.blue.opacity(0.12) : Color(.tertiarySystemFill))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(selected == name ? .blue : .primary)
                }
                Text(name).foregroundColor(.primary)
                Spacer()
                if selected == name {
                    Image(systemName: "checkmark").foregroundColor(.blue).font(.caption.bold())
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if isCustom {
                Button(role: .destructive) {
                    if type == "Income" {
                        customIncomeCategories.removeAll { $0.name == name }
                        CategoryItem.save(customIncomeCategories, key: "customIncomeCats")
                    } else {
                        customExpenseCategories.removeAll { $0.name == name }
                        CategoryItem.save(customExpenseCategories, key: "customExpenseCats")
                    }
                    hapticWarning()
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .leading) {
            if isCustom {
                Button {
                    formName = name; formIcon = icon
                    editingCategory = CategoryItem(name: name, icon: icon)
                } label: { Label("Edit", systemImage: "pencil") }
                    .tint(.blue)
            }
        }
    }
}

// ── Standalone Category Manager (for More menu) ──────────────────────────────
struct CategoryManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expenseCategories: [CategoryItem] = CategoryItem.load(key: "customExpenseCats")
    @State private var incomeCategories:  [CategoryItem] = CategoryItem.load(key: "customIncomeCats")
    @State private var selectedTab = 0  // 0 = Expense, 1 = Income
    @State private var showAdd = false
    @State private var editingCategory: CategoryItem?
    @State private var formName = ""
    @State private var formIcon = "tag.fill"

    private var currentCustom: [CategoryItem] { selectedTab == 0 ? expenseCategories : incomeCategories }

    private let seedExpense: [CategoryItem] = [
        .init(name: "Food & Drink", icon: "fork.knife"), .init(name: "Rent", icon: "house.fill"),
        .init(name: "Transport", icon: "car.fill"),       .init(name: "Bills", icon: "bolt.fill"),
        .init(name: "Entertainment", icon: "tv.fill"),    .init(name: "Shopping", icon: "bag.fill"),
        .init(name: "Health", icon: "heart.fill"),        .init(name: "Travel", icon: "airplane"),
        .init(name: "Miscellaneous", icon: "square.grid.2x2.fill")
    ]
    private let seedIncome: [CategoryItem] = [
        .init(name: "Salary", icon: "banknote.fill"),
        .init(name: "Freelance", icon: "laptopcomputer"),
        .init(name: "Investment Return", icon: "chart.line.uptrend.xyaxis"),
        .init(name: "Gift", icon: "gift.fill"),
        .init(name: "Other Income", icon: "plus.circle.fill")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Expense").tag(0)
                    Text("Income").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)

                List {
                    Section(header: Text("My Categories")) {
                        ForEach(currentCustom, id: \.name) { cat in
                            HStack(spacing: 14) {
                                Image(systemName: cat.icon)
                                    .frame(width: 32, height: 32)
                                    .background(Color.gray.opacity(0.15))
                                    .clipShape(Circle())
                                Text(cat.name)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleteCategory(cat) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    formName = cat.name; formIcon = cat.icon
                                    editingCategory = cat
                                } label: { Label("Edit", systemImage: "pencil") }
                                    .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if expenseCategories.isEmpty {
                    expenseCategories = seedExpense
                    CategoryItem.save(seedExpense, key: "customExpenseCats")
                }
                if incomeCategories.isEmpty {
                    incomeCategories = seedIncome
                    CategoryItem.save(seedIncome, key: "customIncomeCats")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        formName = ""; formIcon = "tag.fill"
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add category")
                }
            }
            .sheet(isPresented: $showAdd) {
                CategoryFormSheet(title: "New Category", buttonLabel: "Add",
                                  name: $formName, icon: $formIcon,
                                  onSave: { addCategory(); showAdd = false },
                                  onCancel: { showAdd = false })
            }
            .sheet(item: $editingCategory) { cat in
                CategoryFormSheet(title: "Edit Category", buttonLabel: "Save",
                                  name: $formName, icon: $formIcon,
                                  onSave: { saveEdit(original: cat) },
                                  onCancel: { editingCategory = nil })
            }
        }
    }

    private func addCategory() {
        guard !formName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let cat = CategoryItem(name: formName.trimmingCharacters(in: .whitespaces), icon: formIcon)
        if selectedTab == 0 {
            expenseCategories.append(cat)
            CategoryItem.save(expenseCategories, key: "customExpenseCats")
        } else {
            incomeCategories.append(cat)
            CategoryItem.save(incomeCategories, key: "customIncomeCats")
        }
        hapticSuccess()
    }

    private func saveEdit(original: CategoryItem) {
        guard !formName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let updated = CategoryItem(name: formName.trimmingCharacters(in: .whitespaces), icon: formIcon)
        if selectedTab == 0 {
            if let idx = expenseCategories.firstIndex(of: original) {
                expenseCategories[idx] = updated
                CategoryItem.save(expenseCategories, key: "customExpenseCats")
            }
        } else {
            if let idx = incomeCategories.firstIndex(of: original) {
                incomeCategories[idx] = updated
                CategoryItem.save(incomeCategories, key: "customIncomeCats")
            }
        }
        hapticSuccess()
        editingCategory = nil
    }

    private func deleteCategory(_ cat: CategoryItem) {
        if selectedTab == 0 {
            expenseCategories.removeAll { $0 == cat }
            CategoryItem.save(expenseCategories, key: "customExpenseCats")
        } else {
            incomeCategories.removeAll { $0 == cat }
            CategoryItem.save(incomeCategories, key: "customIncomeCats")
        }
        hapticWarning()
    }
}
