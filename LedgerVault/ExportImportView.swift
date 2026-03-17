import SwiftUI
import UniformTypeIdentifiers

struct ExportImportView: View {
    @Environment(\.dismiss) private var dismiss

    // Export
    @State private var exportStartDate = Calendar.current.date(
        byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var exportEndDate   = Date()
    @State private var isExporting     = false
    @State private var exportURL: URL?
    @State private var showShareSheet  = false
    @State private var exportError: String?

    // Import
    @State private var showFilePicker  = false
    @State private var isImporting     = false
    @State private var importResult: String?
    @State private var importError: String?
    @State private var showImportAlert = false

    var body: some View {
        NavigationStack {
            Form {
                // ── EXPORT ────────────────────────────────────────────────────
                Section {
                    DatePicker("From", selection: $exportStartDate, displayedComponents: .date)
                    DatePicker("To",   selection: $exportEndDate,   displayedComponents: .date)

                    Button {
                        Task { await runExport() }
                    } label: {
                        HStack {
                            Spacer()
                            if isExporting {
                                ProgressView().tint(.teal)
                            } else {
                                Label("Export CSV", systemImage: "square.and.arrow.up")
                                    .foregroundColor(.teal)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isExporting)

                    if let err = exportError {
                        Label(err, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundColor(.red)
                    }
                } header: {
                    Label("Export Transactions", systemImage: "square.and.arrow.up.on.square")
                } footer: {
                    Text("Exports all transactions in the selected date range as a CSV file.")
                }

                // ── IMPORT ────────────────────────────────────────────────────
                Section {
                    Button {
                        showFilePicker = true
                    } label: {
                        HStack {
                            Spacer()
                            if isImporting {
                                ProgressView().tint(.blue)
                            } else {
                                Label("Import CSV", systemImage: "square.and.arrow.down")
                                    .foregroundColor(.blue)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isImporting)

                    if let err = importError {
                        Label(err, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundColor(.red)
                    }
                } header: {
                    Label("Import Transactions", systemImage: "square.and.arrow.down.on.square")
                } footer: {
                    Text("CSV must have columns: date, event_type, description, account_id, asset_id, quantity, unit_price, fee_flag\n\ndate format: YYYY-MM-DD")
                }

                // ── FORMAT REFERENCE ──────────────────────────────────────────
                Section("CSV Format Reference") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Required columns:")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary)
                        Group {
                            formatRow("date",         "YYYY-MM-DD (e.g. 2026-03-01)")
                            formatRow("event_type",   "income / expense / transfer / trade")
                            formatRow("account_id",   "Account ID from your accounts list")
                            formatRow("quantity",     "Positive = inflow, negative = outflow")
                        }
                        .padding(.leading, 8)
                        Text("Optional columns:")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary)
                            .padding(.top, 4)
                        Group {
                            formatRow("description", "Free text label")
                            formatRow("asset_id",    "Asset ID (blank = fiat)")
                            formatRow("unit_price",  "Price per unit in quote currency")
                            formatRow("fee_flag",    "true / false")
                            formatRow("note",        "Private note")
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Export / Import")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.commaSeparatedText, .text],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleImport(result: result) }
            }
            .alert("Import Complete", isPresented: $showImportAlert) {
                Button("OK") { }
            } message: {
                Text(importResult ?? "Import finished.")
            }
        }
    }

    @ViewBuilder
    private func formatRow(_ col: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(col)
                .font(.caption.monospaced())
                .foregroundColor(.primary)
                .frame(width: 90, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Export

    private func runExport() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }

        do {
            let events   = try await APIService.shared.fetchTransactionEvents()
            let legs     = try await APIService.shared.fetchTransactionLegs()
            let accounts = try await APIService.shared.fetchAccounts()
            let assets   = try await APIService.shared.fetchAssets()

            let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            let assetMap   = Dictionary(uniqueKeysWithValues: assets.map   { ($0.id, $0) })

            let startStr = formatDate(exportStartDate)
            let endStr   = formatDate(exportEndDate)

            let filtered = events.filter { $0.date >= startStr && $0.date <= endStr }

            var lines = ["event_id,date,event_type,category,description,note,source,account_id,account_name,asset_id,asset_symbol,quantity,unit_price,fee_flag"]

            for event in filtered {
                let eventLegs = legs.filter { $0.event_id == event.id }
                for leg in eventLegs {
                    let account = accountMap[leg.account_id]
                    let asset   = leg.asset_id.flatMap { assetMap[$0] }
                    let row = [
                        csvEscape(event.id),
                        csvEscape(event.date),
                        csvEscape(event.event_type),
                        csvEscape(event.category ?? ""),
                        csvEscape(event.description ?? ""),
                        csvEscape(event.note ?? ""),
                        csvEscape(event.source),
                        csvEscape(leg.account_id),
                        csvEscape(account?.name ?? ""),
                        csvEscape(leg.asset_id ?? ""),
                        csvEscape(asset?.symbol ?? ""),
                        "\(leg.quantity)",
                        leg.unit_price.map { "\($0)" } ?? "",
                        csvEscape(leg.fee_flag),
                    ].joined(separator: ",")
                    lines.append(row)
                }
            }

            let csv = lines.joined(separator: "\n")
            let filename = "ledgervault-\(startStr)-to-\(endStr).csv"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try csv.write(to: url, atomically: true, encoding: .utf8)

            await MainActor.run {
                exportURL = url
                showShareSheet = true
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: - Import

    private func handleImport(result: Result<[URL], Error>) async {
        isImporting = true
        importError = nil
        defer { isImporting = false }

        do {
            let urls = try result.get()
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                importError = "Cannot access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let content = try String(contentsOf: url, encoding: .utf8)
            let accounts = try await APIService.shared.fetchAccounts()
            let assets   = try await APIService.shared.fetchAssets()
            let assetMap   = Dictionary(uniqueKeysWithValues: assets.map   { ($0.symbol.uppercased(), $0.id) })

            let (imported, skipped, errors) = try await parseAndImportCSV(
                csv: content,
                accountIDs: Set(accounts.map { $0.id }),
                assetMap: assetMap
            )

            var msg = "✅ Imported \(imported) transaction(s)."
            if skipped > 0 { msg += "\nSkipped \(skipped) row(s)." }
            if !errors.isEmpty { msg += "\nErrors: " + errors.prefix(3).joined(separator: "; ") }

            await MainActor.run {
                importResult  = msg
                showImportAlert = true
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func parseAndImportCSV(
        csv: String,
        accountIDs: Set<String>,
        assetMap: [String: String]
    ) async throws -> (Int, Int, [String]) {
        let lines = csv.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else { return (0, 0, ["Empty or header-only file"]) }

        let headers = lines[0].components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func col(_ name: String, _ row: [String]) -> String {
            guard let i = headers.firstIndex(of: name), i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        // Group rows by event (group consecutive same-event rows or by event_id if present)
        struct RawLeg {
            let accountID: String
            let assetID:   String?
            let quantity:  Double
            let unitPrice: Double?
            let feeFlag:   Bool
        }
        struct RawEvent {
            let date:      String
            let eventType: String
            let category:  String?
            let description: String?
            let note:      String?
            let legs:      [RawLeg]
        }

        var eventGroups: [String: (String, String, String?, String?, String?, [RawLeg])] = [:]
        var eventOrder: [String] = []
        var skipped = 0
        var errors:  [String] = []

        for line in lines.dropFirst() {
            let row = splitCSVLine(line)
            let eventID  = col("event_id", row)
            let date     = col("date", row)
            let evType   = col("event_type", row)
            let accountID = col("account_id", row)
            let assetSym  = col("asset_symbol", row).uppercased()
            let assetID   = col("asset_id", row).isEmpty ? assetMap[assetSym] : col("asset_id", row)
            let qty       = Double(col("quantity", row)) ?? 0
            let price     = Double(col("unit_price", row))
            let feeFlag   = col("fee_flag", row).lowercased() == "true"
            let category  = col("category", row).isEmpty ? nil : col("category", row)
            let desc      = col("description", row).isEmpty ? nil : col("description", row)
            let note      = col("note", row).isEmpty ? nil : col("note", row)

            guard !date.isEmpty, !evType.isEmpty, !accountID.isEmpty, accountIDs.contains(accountID) else {
                skipped += 1
                continue
            }

            let key = eventID.isEmpty ? "\(date)|\(evType)|\(desc ?? "")|\(Int.random(in: 0...999999))" : eventID

            let leg = RawLeg(accountID: accountID, assetID: assetID, quantity: qty,
                             unitPrice: price, feeFlag: feeFlag)

            if eventGroups[key] == nil {
                eventGroups[key] = (date, evType, category, desc, note, [leg])
                eventOrder.append(key)
            } else {
                eventGroups[key]!.5.append(leg)
            }
        }

        var imported = 0
        for key in eventOrder {
            guard let (date, evType, cat, desc, note, legs) = eventGroups[key] else { continue }
            let legCreates: [APIService.TransactionLegCreate] = legs.map {
                APIService.TransactionLegCreate(
                    account_id: $0.accountID,
                    asset_id: $0.assetID,
                    quantity: $0.quantity,
                    unit_price: $0.unitPrice,
                    fee_flag: $0.feeFlag
                )
            }
            do {
                _ = try await APIService.shared.createTransactionEvent(
                    eventType: evType,
                    category: cat,
                    description: desc,
                    date: date,
                    note: note,
                    legs: legCreates
                )
                imported += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        return (imported, skipped, errors)
    }

    private func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
