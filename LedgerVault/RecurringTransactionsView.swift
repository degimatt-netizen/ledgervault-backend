import SwiftUI

// MARK: - Main View

struct RecurringTransactionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var items:    [APIService.RecurringTransactionResponse] = []
    @State private var accounts: [APIService.Account] = []
    @State private var assets:   [APIService.Asset] = []
    @State private var isLoading = false
    @State private var error:    String?

    @State private var showAddSheet     = false
    @State private var executingID:     String?
    @State private var deleteID:        String?
    @State private var showDeleteAlert  = false
    @State private var executeResult:   String?
    @State private var showExecuteAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && items.isEmpty {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label("No Recurring Transactions", systemImage: "repeat")
                    } description: {
                        Text("Create templates for expenses, income, or transfers that happen on a regular schedule.")
                    } actions: {
                        Button("Add Template") { showAddSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(items) { item in
                            recurringRow(item)
                        }
                        .onDelete { offsets in
                            if let i = offsets.first {
                                deleteID       = items[i].id
                                showDeleteAlert = true
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Recurring")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add recurring transaction")
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showAddSheet) {
                AddRecurringTransactionView(accounts: accounts, assets: assets) {
                    Task { await load() }
                }
            }
            .alert("Delete Template?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let id = deleteID { Task { await deleteItem(id: id) } }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The template will be removed. Past transactions are unaffected.")
            }
            .alert("Executed", isPresented: $showExecuteAlert) {
                Button("OK") { }
            } message: { Text(executeResult ?? "Transaction created.") }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    @ViewBuilder
    private func recurringRow(_ item: APIService.RecurringTransactionResponse) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(eventColor(item.event_type).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: eventIcon(item.event_type))
                    .foregroundColor(eventColor(item.event_type))
                    .font(.system(size: 16, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    if !item.enabled {
                        Text("Paused")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(item.event_type.capitalized + " · " + item.frequency.capitalized)
                    .font(.caption).foregroundColor(.secondary)
                Text("Next: " + prettyDate(item.next_run_date))
                    .font(.caption2)
                    .foregroundColor(isDue(item.next_run_date) ? .orange : .secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(formatQty(item.from_quantity))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(eventColor(item.event_type))

                Button {
                    Task { await executeItem(id: item.id) }
                } label: {
                    if executingID == item.id {
                        ProgressView().frame(width: 24, height: 24)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Run")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(executingID != nil)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func eventIcon(_ type: String) -> String {
        switch type {
        case "income":   return "arrow.down.circle.fill"
        case "expense":  return "arrow.up.circle.fill"
        case "transfer": return "arrow.left.arrow.right.circle.fill"
        case "trade":    return "chart.line.uptrend.xyaxis.circle.fill"
        default:         return "repeat.circle.fill"
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "income":   return .green
        case "expense":  return .red
        case "transfer": return .blue
        case "trade":    return .orange
        default:         return .gray
        }
    }

    private func prettyDate(_ d: String) -> String {
        let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd"
        guard let date = p.date(from: d) else { return d }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: date)
    }

    private func isDue(_ d: String) -> Bool {
        let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd"
        guard let date = p.date(from: d) else { return false }
        return date <= Date()
    }

    private func formatQty(_ q: Double) -> String {
        q.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(q))" : String(format: "%.4g", q)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let r    = APIService.shared.fetchRecurringTransactions()
            async let accs = APIService.shared.fetchAccounts()
            async let ass  = APIService.shared.fetchAssets()
            (items, accounts, assets) = try await (r, accs, ass)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func executeItem(id: String) async {
        executingID = id
        defer { executingID = nil }
        do {
            let result = try await APIService.shared.executeRecurringTransaction(id: id)
            executeResult    = "Transaction created. Next run: \(prettyDate(result.next_run_date))"
            showExecuteAlert = true
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteItem(id: String) async {
        do {
            try await APIService.shared.deleteRecurringTransaction(id: id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Add Template Sheet

struct AddRecurringTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    let accounts: [APIService.Account]
    let assets:   [APIService.Asset]
    let onSaved:  () -> Void

    let eventTypes  = ["expense", "income", "transfer", "trade"]
    let frequencies = ["daily", "weekly", "monthly", "quarterly"]

    @State private var name           = ""
    @State private var eventType      = "expense"
    @State private var category       = ""
    @State private var descriptionText = ""
    @State private var note           = ""
    @State private var fromAccountID  = ""
    @State private var fromAssetID    = ""
    @State private var fromQtyText    = ""
    @State private var toAccountID    = ""
    @State private var frequency      = "monthly"
    @State private var startDate      = Date()
    @State private var isSaving       = false
    @State private var error:         String?

    private var spendableAssets: [APIService.Asset] {
        assets.filter { $0.asset_class == "fiat" || $0.asset_class == "crypto" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    TextField("Name (e.g. Monthly Rent)", text: $name)
                    Picker("Type", selection: $eventType) {
                        ForEach(eventTypes, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    TextField("Category (optional)", text: $category)
                    TextField("Description (optional)", text: $descriptionText)
                }

                Section("Amount") {
                    Picker("Account", selection: $fromAccountID) {
                        Text("Select account…").tag("")
                        ForEach(accounts) { a in
                            Text("\(a.name) (\(a.base_currency))").tag(a.id)
                        }
                    }
                    Picker("Asset", selection: $fromAssetID) {
                        Text("Account Currency").tag("")
                        ForEach(spendableAssets) { a in
                            Text("\(a.symbol) — \(a.name)").tag(a.id)
                        }
                    }
                    HStack {
                        Text("Quantity")
                        Spacer()
                        TextField("0.00", text: $fromQtyText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                }

                if eventType == "transfer" {
                    Section("Destination") {
                        Picker("To Account", selection: $toAccountID) {
                            Text("None").tag("")
                            ForEach(accounts.filter { $0.id != fromAccountID }) { a in
                                Text("\(a.name) (\(a.base_currency))").tag(a.id)
                            }
                        }
                    }
                }

                Section("Schedule") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(frequencies, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    DatePicker("First Run", selection: $startDate, displayedComponents: .date)
                }

                Section("Note") {
                    TextField("Private note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let e = error {
                    Section {
                        Label(e, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundColor(.red)
                    }
                }

                Section {
                    Button { Task { await save() } } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Create Template")
                                    .fontWeight(.semibold)
                                    .foregroundColor(isValid ? .white : .secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(isValid ? Color.accentColor : Color.gray.opacity(0.2))
                    .disabled(!isValid || isSaving)
                }
            }
            .navigationTitle("Add Recurring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            .onAppear { fromAccountID = accounts.first?.id ?? "" }
        }
    }

    private var isValid: Bool {
        !name.isEmpty &&
        !fromAccountID.isEmpty &&
        (Double(fromQtyText) ?? 0) > 0
    }

    private func save() async {
        isSaving = true; error = nil
        defer { isSaving = false }
        let qty      = Double(fromQtyText) ?? 0
        let f        = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let dateStr  = f.string(from: startDate)
        do {
            _ = try await APIService.shared.createRecurringTransaction(
                name:          name,
                eventType:     eventType,
                category:      category.isEmpty ? nil : category,
                description:   descriptionText.isEmpty ? nil : descriptionText,
                note:          note.isEmpty ? nil : note,
                fromAccountID: fromAccountID,
                fromAssetID:   fromAssetID.isEmpty ? nil : fromAssetID,
                fromQuantity:  qty,
                toAccountID:   toAccountID.isEmpty ? nil : toAccountID,
                frequency:     frequency,
                startDate:     dateStr,
                nextRunDate:   dateStr
            )
            onSaved(); dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
