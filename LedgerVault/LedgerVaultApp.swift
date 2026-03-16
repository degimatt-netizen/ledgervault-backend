import SwiftUI
import UserNotifications

@main
struct LedgerVaultApp: App {
    @AppStorage("theme")      private var theme      = "system"
    @AppStorage("isSignedIn") private var isSignedIn = false

    var body: some Scene {
        WindowGroup {
            Group {
                if isSignedIn {
                    ContentView()
                        .environment(AppSettings.shared)
                        .preferredColorScheme(
                            theme == "light" ? .light :
                            theme == "dark"  ? .dark  : nil
                        )
                } else {
                    SignInView()
                        .preferredColorScheme(.dark)
                }
            }
            .task { await startPriceAlertChecker() }
            .onAppear { AlertsManager.shared.checkNotificationStatus() }
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
