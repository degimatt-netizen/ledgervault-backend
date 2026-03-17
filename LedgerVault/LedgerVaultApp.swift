import SwiftUI
import UserNotifications
import LocalAuthentication

@main
struct LedgerVaultApp: App {
    @AppStorage("theme")        private var theme        = "system"
    @AppStorage("isSignedIn")   private var isSignedIn   = false
    @AppStorage("requiresAuth") private var requiresAuth = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var isLocked     = false
    @State private var wentInactive = false

    var body: some Scene {
        WindowGroup {
            Group {
                if isSignedIn {
                    ZStack {
                        ContentView()
                            .environment(AppSettings.shared)
                            .preferredColorScheme(
                                theme == "light" ? .light :
                                theme == "dark"  ? .dark  : nil
                            )

                        if isLocked {
                            LockScreenView(isLocked: $isLocked)
                                .transition(.opacity)
                                .zIndex(999)
                        }
                    }
                } else {
                    SignInView()
                        .preferredColorScheme(.dark)
                }
            }
            .task { await startPriceAlertChecker() }
            .onAppear { AlertsManager.shared.checkNotificationStatus() }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background:
                    if requiresAuth && isSignedIn {
                        isLocked = true
                    }
                case .active:
                    break
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func startPriceAlertChecker() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard isSignedIn else { continue }
            let hasActive = AlertsManager.shared.alerts.contains { $0.isActive && !$0.triggered }
            guard hasActive else { continue }
            if let rates = try? await APIService.shared.fetchRates() {
                AlertsManager.shared.checkPrices(rates.prices)
            }
        }
    }
}

// MARK: - Lock Screen

struct LockScreenView: View {
    @Binding var isLocked: Bool
    @AppStorage("useBiometrics") private var useBiometrics = false
    @State private var authError: String?

    var body: some View {
        ZStack {
            // Background blur
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                LVMonogram(size: 80)

                VStack(spacing: 6) {
                    Text("LedgerVault")
                        .font(.title.bold())
                    Text("Locked")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if let error = authError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // Unlock button
                Button {
                    authenticate()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: biometryIcon())
                        Text("Unlock")
                    }
                    .font(.headline)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .onAppear { authenticate() }
    }

    private func biometryIcon() -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "lock.open.fill"
        }
        return context.biometryType == .faceID ? "faceid" : "touchid"
    }

    private func authenticate() {
        let context = LAContext()
        let policy: LAPolicy = useBiometrics ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        var nsError: NSError?

        // Fall back to device passcode if biometrics not available
        let effectivePolicy: LAPolicy
        if context.canEvaluatePolicy(policy, error: &nsError) {
            effectivePolicy = policy
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsError) {
            effectivePolicy = .deviceOwnerAuthentication
        } else {
            authError = "Authentication not available."
            return
        }

        context.evaluatePolicy(effectivePolicy, localizedReason: "Unlock LedgerVault") { success, error in
            DispatchQueue.main.async {
                if success {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isLocked = false
                    }
                    authError = nil
                } else {
                    authError = error?.localizedDescription ?? "Authentication failed."
                }
            }
        }
    }
}
