import SwiftUI

struct EditTransactionView: View {
    let tx: APIService.TransactionEvent
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var eventType: String
    @State private var description: String
    @State private var category: String
    @State private var note: String
    @State private var date: Date
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showCategoryPicker = false

    @State private var customExpenseCategories: [CategoryItem] = CategoryItem.load(key: "customExpenseCats")
    @State private var customIncomeCategories:  [CategoryItem] = CategoryItem.load(key: "customIncomeCats")

    private let types = ["Income", "Expense", "Transfer", "Conversion", "Trade"]

    private let expenseCategories = [
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
    private let incomeCategories = [
        ("Salary", "banknote.fill"),
        ("Freelance", "laptopcomputer"),
        ("Investment Return", "chart.line.uptrend.xyaxis"),
        ("Gift", "gift.fill"),
        ("Other Income", "plus.circle.fill")
    ]

    private var currentCategories: [(String, String)] {
        let custom = eventType.lowercased() == "income"
            ? customIncomeCategories.map { ($0.name, $0.icon) }
            : customExpenseCategories.map { ($0.name, $0.icon) }
        return custom.isEmpty
            ? (eventType.lowercased() == "income" ? incomeCategories : expenseCategories)
            : custom
    }

    init(tx: APIService.TransactionEvent, onSaved: @escaping () -> Void) {
        self.tx = tx
        self.onSaved = onSaved
        _eventType = State(initialValue: tx.event_type.capitalized)
        _description = State(initialValue: tx.description ?? "")
        _category = State(initialValue: tx.category ?? "Miscellaneous")
        _note = State(initialValue: tx.note ?? "")

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        _date = State(initialValue: parser.date(from: tx.date) ?? Date())
    }

    private var typeColor: Color {
        switch eventType.lowercased() {
        case "income":  return .green
        case "expense": return .red
        case "trade":   return .orange
        default:        return .blue
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Type ─────────────────────────────────────────────
                Section("Transaction Type") {
                    HStack(spacing: 6) {
                        ForEach(types, id: \.self) { t in
                            Button {
                                withAnimation(.spring(duration: 0.2)) { eventType = t }
                            } label: {
                                Text(t)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(eventType == t ? typeColor : Color(.systemGray6))
                                    .foregroundColor(eventType == t ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // ── Details ──────────────────────────────────────────
                Section("Details") {
                    TextField("Description", text: $description)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                // ── Category ─────────────────────────────────────────
                if eventType.lowercased() != "transfer" {
                    Section("Category") {
                        Button {
                            showCategoryPicker = true
                        } label: {
                            HStack {
                                let icon = currentCategories.first(where: { $0.0 == category })?.1 ?? "square.grid.2x2.fill"
                                Image(systemName: icon)
                                    .foregroundColor(typeColor)
                                    .frame(width: 24)
                                Text(category)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // ── Note ─────────────────────────────────────────────
                Section("Note") {
                    TextField("Optional note", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }

                // ── Error ────────────────────────────────────────────
                if let err = errorMessage {
                    Section {
                        Text(err).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showCategoryPicker) {
                NavigationStack {
                    List {
                        ForEach(currentCategories, id: \.0) { cat in
                            Button {
                                category = cat.0
                                showCategoryPicker = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: cat.1)
                                        .foregroundColor(typeColor)
                                        .frame(width: 24)
                                    Text(cat.0).foregroundColor(.primary)
                                    Spacer()
                                    if category == cat.0 {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(typeColor)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Category")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showCategoryPicker = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        do {
            _ = try await APIService.shared.updateTransactionEvent(
                id: tx.id,
                eventType: eventType.lowercased(),
                category: category,
                description: description.isEmpty ? nil : description,
                date: fmt.string(from: date),
                note: note.isEmpty ? nil : note
            )
            hapticSuccess()
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            hapticError()
        }
    }
}
