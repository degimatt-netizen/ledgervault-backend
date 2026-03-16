import SwiftUI
import Observation

@Observable
class AppSettings {
    static let shared = AppSettings()
    
    var baseCurrency: String {
        didSet {
            UserDefaults.standard.set(baseCurrency, forKey: "baseCurrency")
        }
    }
    
    var theme: String {
        didSet {
            UserDefaults.standard.set(theme, forKey: "theme")
        }
    }
    
    init() {
        self.baseCurrency = UserDefaults.standard.string(forKey: "baseCurrency") ?? "EUR"
        self.theme = UserDefaults.standard.string(forKey: "theme") ?? "system"
    }
}
