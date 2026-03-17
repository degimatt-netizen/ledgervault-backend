import SwiftUI

struct ResetDataView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedOption = 0
    @State private var confirmText    = ""
    @State private var isResetting    = false
    @State private var errorMessage: String?
    @State private var showSuccess    = false

    struct ResetOption {
        let title:       String
        let subtitle:    String
        let icon:        String
        let color:       Color
    }

    let options: [ResetOption] = [
        ResetOption(
            title:    "Clear Transactions",
            subtitle: "Delete all transactions and holdings. Accounts and assets are kept.",
            icon:     "clock.arrow.circlepath",
            color:    .orange
        ),
        ResetOption(
            title:    "Full Reset",
            subtitle: "Delete everything — accounts, assets, transactions, and holdings. Starts fresh.",
            icon:     "exclamationmark.triangle.fill",
            color:    .red
        ),
    ]

    var body: some View {
        NavigationStack {
            Form {
                // ── Option Picker ─────────────────────────────────────────────
                Section("Reset Type") {
                    ForEach(0..<options.count, id: \.self) { i in
                        Button {
                            selectedOption = i
                            confirmText = ""
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: options[i].icon)
                                    .foregroundColor(options[i].color)
                                    .frame(width: 26)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(options[i].title)
                                        .foregroundColor(.primary)
                                        .font(.subheadline.weight(.semibold))
                                    Text(options[i].subtitle)
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer()

                                if selectedOption == i {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // ── Confirmation ──────────────────────────────────────────────
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Type RESET to confirm")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("RESET", text: $confirmText)
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                            .font(.body.monospaced())
                            .foregroundColor(confirmText == "RESET" ? .red : .primary)
                    }
                } header: {
                    Text("Confirmation")
                } footer: {
                    Text("⚠️ This action cannot be undone.")
                        .foregroundColor(.red)
                }

                // ── Error ─────────────────────────────────────────────────────
                if let msg = errorMessage {
                    Section {
                        Label(msg, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                // ── Action ────────────────────────────────────────────────────
                Section {
                    Button(role: .destructive) {
                        Task { await performReset() }
                    } label: {
                        HStack {
                            Spacer()
                            if isResetting {
                                ProgressView().tint(.red)
                            } else {
                                Label(
                                    options[selectedOption].title,
                                    systemImage: options[selectedOption].icon
                                )
                                .foregroundColor(confirmText == "RESET" ? .red : .secondary)
                            }
                            Spacer()
                        }
                    }
                    .disabled(confirmText != "RESET" || isResetting)
                }
            }
            .navigationTitle("Reset Data")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Reset Complete", isPresented: $showSuccess) {
                Button("Done") { dismiss() }
            } message: {
                Text("Your data has been reset successfully.")
            }
        }
    }

    private func performReset() async {
        isResetting  = true
        errorMessage = nil
        defer { isResetting = false }

        do {
            if selectedOption == 0 {
                try await APIService.shared.clearTransactions()
            } else {
                try await APIService.shared.fullReset()
            }
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
