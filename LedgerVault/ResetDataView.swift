import SwiftUI
import UserNotifications

struct ResetDataView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("isSignedIn") private var isSignedIn = false

    @State private var isResetting       = false
    @State private var isDeletingAccount = false
    @State private var errorMessage: String?

    @State private var showClearConfirm  = false
    @State private var showFullConfirm   = false
    @State private var showDeleteConfirm = false
    @State private var showSuccess       = false
    @State private var successMessage    = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // ── Header ────────────────────────────────────────────────
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.1))
                                .frame(width: 64, height: 64)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        Text("Manage Data")
                            .font(.title3.bold())
                        Text("These actions are permanent and cannot be undone.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 12)

                    // ── Actions ───────────────────────────────────────────────
                    VStack(spacing: 0) {
                        actionRow(
                            icon:     "clock.arrow.circlepath",
                            color:    .orange,
                            title:    "Clear Transactions",
                            subtitle: "Removes transaction history only. Accounts, wallets, brokers and holdings are kept.",
                            isLoading: isResetting,
                            action:   { showClearConfirm = true }
                        )

                        Divider().padding(.leading, 60)

                        actionRow(
                            icon:     "arrow.counterclockwise",
                            color:    .red,
                            title:    "Full Reset",
                            subtitle: "Deletes everything — accounts, assets, transactions and holdings.",
                            isLoading: false,
                            action:   { showFullConfirm = true }
                        )
                    }
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                    .padding(.horizontal, 20)

                    // ── Danger zone ───────────────────────────────────────────
                    VStack(spacing: 0) {
                        actionRow(
                            icon:     "person.crop.circle.badge.minus",
                            color:    .red,
                            title:    "Delete Account",
                            subtitle: "Permanently deletes your account and all data from our servers.",
                            isLoading: isDeletingAccount,
                            action:   { showDeleteConfirm = true }
                        )
                    }
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                    .padding(.horizontal, 20)
                    .overlay(
                        VStack {
                            HStack {
                                Text("DANGER ZONE")
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(.red.opacity(0.7))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.red.opacity(0.08))
                                    .cornerRadius(6)
                                    .padding(.leading, 28)
                                Spacer()
                            }
                            .padding(.top, -12)
                            Spacer()
                        }
                    )

                    // ── Error ─────────────────────────────────────────────────
                    if let err = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 32)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Reset Data")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }

            // ── Alerts ────────────────────────────────────────────────────────
            .alert("Clear Transactions?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    Task { await performReset(full: false) }
                }
            } message: {
                Text("All transaction history will be deleted. Your accounts, wallets, brokers and current holdings will remain.")
            }
            .alert("Full Reset?", isPresented: $showFullConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reset Everything", role: .destructive) {
                    Task { await performReset(full: true) }
                }
            } message: {
                Text("This will delete all accounts, assets, transactions and holdings. Your app will start completely fresh.")
            }
            .alert("Delete Account?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Forever", role: .destructive) {
                    Task { await performDeleteAccount() }
                }
            } message: {
                Text("Your account and all data will be permanently deleted from our servers. This cannot be undone.")
            }
            .alert("Done", isPresented: $showSuccess) {
                Button("OK") { dismiss() }
            } message: {
                Text(successMessage)
            }
        }
    }

    // ── Row builder ────────────────────────────────────────────────────────────
    @ViewBuilder
    private func actionRow(
        icon: String, color: Color,
        title: String, subtitle: String,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.1))
                        .frame(width: 40, height: 40)
                    if isLoading {
                        ProgressView().tint(color)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(color)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(color == .orange ? .primary : .red)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Color(.systemGray3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isResetting || isDeletingAccount)
    }

    // ── Actions ────────────────────────────────────────────────────────────────
    private func performReset(full: Bool) async {
        isResetting  = true
        errorMessage = nil
        defer { isResetting = false }
        do {
            if full {
                try await APIService.shared.fullReset()
                // Clear local-only data that the backend can't reach
                UserDefaults.standard.removeObject(forKey: "price_alerts_v1")
                UserDefaults.standard.removeObject(forKey: "customExpenseCats")
                UserDefaults.standard.removeObject(forKey: "customIncomeCats")
                UserDefaults.standard.removeObject(forKey: "customForexSymbols")
                UserDefaults.standard.removeObject(forKey: "hiddenForexSymbols")
                // Clear in-memory alerts state and remove all pending notifications
                await MainActor.run {
                    AlertsManager.shared.alerts = []
                }
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                successMessage = "Everything has been reset. Your app is starting fresh."
            } else {
                try await APIService.shared.clearTransactions()
                successMessage = "Transaction history cleared. Your accounts and holdings are intact."
            }
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performDeleteAccount() async {
        isDeletingAccount = true
        do {
            try await APIService.shared.deleteAccount()
            await MainActor.run {
                KeychainHelper.delete(account: "auth_token")
                if let domain = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: domain)
                }
                isSignedIn = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                isDeletingAccount = false
                errorMessage = "Failed to delete account. Please try again."
            }
        }
    }
}
