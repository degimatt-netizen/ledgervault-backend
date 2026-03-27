import SwiftUI
import UserNotifications
import LocalAuthentication
import Combine

@main
struct LedgerVaultApp: App {
    @AppStorage("theme")                  private var theme              = "dark"
    @AppStorage("isSignedIn")             private var isSignedIn         = false
    @AppStorage("requiresAuth")           private var requiresAuth       = false
    @AppStorage("onboardingComplete")     private var onboardingComplete = false
    @AppStorage("onboardingCompletedFor") private var onboardingFor      = ""
    @AppStorage("profile_email")          private var profileEmail       = ""
    @AppStorage("inactivityTimeout")      private var inactivityTimeout  = 30   // seconds; 0 = never

    @Environment(\.scenePhase) private var scenePhase

    @State private var isLocked    = false
    @State private var authTrigger = 0
    @StateObject private var inactivityMonitor = InactivityMonitor()

    var body: some Scene {
        WindowGroup {
            Group {
                if isSignedIn {
                    let needsOnboarding = !onboardingComplete || onboardingFor != profileEmail
                    if needsOnboarding {
                        OnboardingView()
                            .preferredColorScheme(.dark)
                    } else {
                        ZStack {
                            ContentView()
                                .environment(AppSettings.shared)
                                .preferredColorScheme(
                                    theme == "light" ? .light :
                                    theme == "dark"  ? .dark  : nil
                                )
                                .blur(radius: isLocked ? 20 : 0)
                                .animation(.easeInOut(duration: 0.2), value: isLocked)

                            // Transparent overlay — detects any touch and resets the inactivity
                            // timer without consuming or interfering with the touch itself.
                            if !isLocked {
                                TouchActivityDetector {
                                    inactivityMonitor.recordInteraction()
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .ignoresSafeArea()
                            }

                            if isLocked {
                                LockScreenView(isLocked: $isLocked, authTrigger: authTrigger)
                                    .transition(.opacity)
                                    .zIndex(999)
                            }
                        }
                    }
                } else {
                    SignInView()
                        .preferredColorScheme(.dark)
                }
            }
            .task { await startPriceAlertChecker() }
            .onAppear {
                AlertsManager.shared.checkNotificationStatus()
                inactivityMonitor.onLock = {
                    withAnimation(.easeOut(duration: 0.25)) { isLocked = true }
                }
                if isSignedIn { isLocked = true }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    if isSignedIn {
                        isLocked = true
                        inactivityMonitor.stop()
                    }
                case .active:
                    if isLocked {
                        authTrigger += 1
                    } else if isSignedIn {
                        inactivityMonitor.start(timeout: inactivityTimeout)
                    }
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            // Start / stop inactivity timer whenever lock state changes
            .onChange(of: isLocked) { _, locked in
                if locked {
                    inactivityMonitor.stop()
                } else if isSignedIn {
                    inactivityMonitor.start(timeout: inactivityTimeout)
                }
            }
            // Restart with new timeout if the user changes the setting
            .onChange(of: inactivityTimeout) { _, timeout in
                if isSignedIn && !isLocked {
                    inactivityMonitor.start(timeout: timeout)
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
    let authTrigger: Int
    @AppStorage("useBiometrics") private var useBiometrics = false
    @State private var authError: String?
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.systemBackground).opacity(0.85))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                LVWordmark(shieldSize: 52, textColor: .primary)

                Text("Locked")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let error = authError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                Button { authenticate() } label: {
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
        // First appearance — trigger after short settle delay
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { authenticate() }
        }
        // Each time the app returns to foreground while locked, re-trigger Face ID
        .onChange(of: authTrigger) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { authenticate() }
        }
    }

    private func biometryIcon() -> String {
        let ctx = LAContext(); var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            return "lock.open.fill"
        }
        return ctx.biometryType == .faceID ? "faceid" : "touchid"
    }

    private func authenticate() {
        guard !isAuthenticating else { return }   // prevent double-fire
        isAuthenticating = true

        let ctx = LAContext()
        let preferred: LAPolicy = useBiometrics
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        var nsErr: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(preferred, error: &nsErr)
            ? preferred
            : .deviceOwnerAuthentication

        guard ctx.canEvaluatePolicy(policy, error: &nsErr) else {
            authError = "Authentication not available."
            isAuthenticating = false
            return
        }

        ctx.evaluatePolicy(policy, localizedReason: "Unlock LedgerVault") { success, error in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    hapticSuccess()
                    withAnimation(.easeOut(duration: 0.25)) { isLocked = false }
                    authError = nil
                } else {
                    authError = error?.localizedDescription ?? "Authentication failed."
                }
            }
        }
    }
}

// MARK: - Inactivity Monitor

/// Tracks the last user touch and fires `onLock` when the configured timeout elapses.
final class InactivityMonitor: ObservableObject {
    // Explicit publisher required when the class is used with @MainActor isolation elsewhere
    nonisolated let objectWillChange = ObservableObjectPublisher()

    var onLock: (() -> Void)?
    private var lastInteraction: Date = Date()
    private var timer: Timer?

    func start(timeout: Int) {
        stop()
        guard timeout > 0 else { return }
        lastInteraction = Date()   // reset so we don't immediately lock
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard Date().timeIntervalSince(self.lastInteraction) >= Double(timeout) else { return }
                self.onLock?()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func recordInteraction() {
        lastInteraction = Date()
    }
}

// MARK: - Touch Activity Detector

/// A full-screen transparent UIKit view that reports touches to `onTouch` without
/// consuming them — all touches pass through normally to views beneath.
struct TouchActivityDetector: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        view.onTouch = onTouch
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ uiView: PassthroughView, context: Context) {
        uiView.onTouch = onTouch
    }

    final class PassthroughView: UIView {
        var onTouch: (() -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Only fire for genuine touch events, not layout probing (nil event)
            if let event, event.type == .touches {
                onTouch?()
            }
            return nil   // Always pass through — never capture the touch
        }
    }
}
