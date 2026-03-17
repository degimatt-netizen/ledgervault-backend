import SwiftUI
import LocalAuthentication

struct SecurityView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("requiresAuth")  private var requiresAuth  = false
    @AppStorage("useBiometrics") private var useBiometrics = false

    @State private var biometryType: LABiometryType = .none
    @State private var authError: String?
    @State private var showingError = false

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
                    .onChange(of: requiresAuth) { newValue in
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
                    LabeledContent("Biometry") {
                        Text(biometryType == .none ? "Not Available" : biometryName + " Available")
                            .foregroundColor(.secondary)
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
            .alert("Authentication Failed", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(authError ?? "Could not verify identity. App lock was not enabled.")
            }
        }
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
