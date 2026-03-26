import SwiftUI
import LocalAuthentication

struct SecurityView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("requiresAuth")       private var requiresAuth       = false
    @AppStorage("useBiometrics")      private var useBiometrics      = false
    @AppStorage("inactivityTimeout")  private var inactivityTimeout  = 30

    @State private var biometryType: LABiometryType = .none
    @State private var authError: String?
    @State private var showingError = false

    // TOTP state
    @State private var totpEnabled   = false
    @State private var isLoadingTotp = true
    @State private var showTotpSetup = false
    @State private var showTotpDisable = false

    private var autoLockLabel: String {
        switch inactivityTimeout {
        case 0:   return "Never"
        case 30:  return "30 seconds"
        case 45:  return "45 seconds"
        case 60:  return "1 minute"
        case 120: return "2 minutes"
        case 300: return "5 minutes"
        case 600: return "10 minutes"
        default:  return "\(inactivityTimeout)s"
        }
    }

    private var biometryName: String {
        switch biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "Biometrics"
        }
    }

    private var biometryIcon: String {
        switch biometryType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        default:       return "lock.fill"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── App Lock ──────────────────────────────────────────────────
                Section {
                    Toggle(isOn: $requiresAuth) {
                        Label("Require Authentication", systemImage: "lock.fill")
                    }
                    .onChange(of: requiresAuth) { _, newValue in
                        if newValue { authenticate(enabling: true) }
                    }
                } header: {
                    Text("App Lock")
                } footer: {
                    Text("When enabled, you must authenticate each time the app returns from the background.")
                }

                // ── Biometrics ─────────────────────────────────────────────────
                if requiresAuth && biometryType != .none {
                    Section {
                        Toggle(isOn: $useBiometrics) {
                            Label(biometryName, systemImage: biometryIcon)
                        }
                    } header: {
                        Text("Authentication Method")
                    } footer: {
                        Text("Use \(biometryName) instead of your device passcode to unlock the app.")
                    }
                }

                // ── Auto-Lock ─────────────────────────────────────────────────
                Section {
                    Picker("Auto-Lock", selection: $inactivityTimeout) {
                        Text("Never").tag(0)
                        Text("30 seconds").tag(30)
                        Text("45 seconds").tag(45)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                    }
                } header: {
                    Text("Auto-Lock")
                } footer: {
                    Text("Locks the app automatically after the selected period of inactivity.")
                }

                // ── Two-Factor Authentication ──────────────────────────────────
                Section {
                    if isLoadingTotp {
                        HStack {
                            Label("Two-Factor Authentication", systemImage: "lock.badge.clock.fill")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Button {
                            if totpEnabled { showTotpDisable = true } else { showTotpSetup = true }
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Two-Factor Authentication")
                                            .foregroundColor(.primary)
                                        Text(totpEnabled ? "Enabled" : "Not Enabled")
                                            .font(.caption)
                                            .foregroundColor(totpEnabled ? .green : .secondary)
                                    }
                                } icon: {
                                    Image(systemName: "lock.badge.clock.fill")
                                        .foregroundColor(totpEnabled ? .green : .blue)
                                }
                                Spacer()
                                Text(totpEnabled ? "Disable" : "Set Up")
                                    .font(.subheadline)
                                    .foregroundColor(totpEnabled ? .red : .blue)
                            }
                        }
                    }
                } header: {
                    Text("Two-Factor Authentication")
                } footer: {
                    Text(totpEnabled
                         ? "Your account is protected with a time-based one-time password (TOTP). You'll need your authenticator app each time you sign in."
                         : "Add an extra layer of security by requiring a code from an authenticator app (Google Authenticator, Authy, etc.) when signing in.")
                }

                // ── Info ──────────────────────────────────────────────────────
                Section("Status") {
                    LabeledContent("App Lock") {
                        Text(requiresAuth ? "Enabled" : "Disabled")
                            .foregroundColor(requiresAuth ? .green : .secondary)
                    }
                    LabeledContent("Method") {
                        Text(
                            !requiresAuth ? "None" :
                            (useBiometrics && biometryType != .none
                                ? biometryName
                                : "Device Passcode")
                        )
                        .foregroundColor(.secondary)
                    }
                    LabeledContent("Auto-Lock") {
                        Text(autoLockLabel)
                            .foregroundColor(.secondary)
                    }
                    LabeledContent("Biometry") {
                        Text(biometryType == .none ? "Not Available" : biometryName + " Available")
                            .foregroundColor(.secondary)
                    }
                    LabeledContent("2FA") {
                        Text(totpEnabled ? "Enabled" : "Disabled")
                            .foregroundColor(totpEnabled ? .green : .secondary)
                    }
                }
            }
            .navigationTitle("Security")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { checkBiometry() }
            .task { await loadTotpStatus() }
            .alert("Authentication Failed", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(authError ?? "Could not verify identity. App lock was not enabled.")
            }
            .sheet(isPresented: $showTotpSetup) {
                TOTPSetupView {
                    totpEnabled = true
                }
            }
            .sheet(isPresented: $showTotpDisable) {
                TOTPDisableView {
                    totpEnabled = false
                }
            }
        }
    }

    private func loadTotpStatus() async {
        isLoadingTotp = true
        if let status = try? await APIService.shared.totpStatus() {
            totpEnabled = status.enabled
        }
        isLoadingTotp = false
    }

    private func checkBiometry() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometryType = context.biometryType
        }
    }

    private func authenticate(enabling: Bool) {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            if enabling {
                requiresAuth = false
                authError = error?.localizedDescription ?? "Authentication not available on this device."
                showingError = true
            }
            return
        }
        context.evaluatePolicy(policy, localizedReason: "Authenticate to enable app lock") { success, err in
            DispatchQueue.main.async {
                if !success && enabling {
                    requiresAuth = false
                    authError = err?.localizedDescription ?? "Authentication failed."
                    showingError = true
                }
            }
        }
    }
}
