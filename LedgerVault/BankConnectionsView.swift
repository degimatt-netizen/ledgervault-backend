import SwiftUI
import AuthenticationServices

// ── Presentation context provider for ASWebAuthenticationSession ──────────────
class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

// ── BankProviderPickerView ────────────────────────────────────────────────────
struct BankProviderPickerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    VStack(spacing: 6) {
                        Text("Open Banking")
                            .font(.largeTitle.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Choose how you want to connect your bank accounts.")
                            .font(.subheadline).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // ── TrueLayer (Production) ───────────────────────────
                    NavigationLink {
                        BankConnectionsView(sandbox: false)
                    } label: {
                        providerCard(
                            icon: "building.columns.fill",
                            iconColors: [.blue, .purple],
                            title: "TrueLayer",
                            badge: "Live",
                            badgeColor: .green,
                            description: "Connect your real bank accounts via TrueLayer Open Banking. Supports Revolut, Wise, Monzo, HSBC and 100+ banks across Europe.",
                            details: [
                                ("lock.shield.fill",         "Read-only · No payment access"),
                                ("building.2.fill",          "Revolut, Wise, Monzo, HSBC, Starling + 100 more"),
                                ("arrow.triangle.2.circlepath", "Auto-sync transactions"),
                            ],
                            buttonLabel: "Connect Live Bank",
                            buttonColor: .blue
                        )
                    }
                    .buttonStyle(.plain)

                    // ── Sandbox (Test) ────────────────────────────────────
                    NavigationLink {
                        BankConnectionsView(sandbox: true)
                    } label: {
                        providerCard(
                            icon: "testtube.2",
                            iconColors: [.orange, .yellow],
                            title: "Sandbox",
                            badge: "Test",
                            badgeColor: .orange,
                            description: "Use simulated test bank data without touching real accounts. Perfect for trying out the integration before going live.",
                            details: [
                                ("exclamationmark.triangle.fill", "No real bank credentials needed"),
                                ("arrow.triangle.2.circlepath",   "Simulated transactions & accounts"),
                                ("checkmark.shield.fill",          "Safe to test — no real data"),
                            ],
                            buttonLabel: "Connect Sandbox Bank",
                            buttonColor: .orange
                        )
                    }
                    .buttonStyle(.plain)

                    Text("Both modes use the same TrueLayer infrastructure. Switch to Live when you're ready for real data.")
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
            }
        }
    }

    private func providerCard(
        icon: String, iconColors: [Color],
        title: String, badge: String, badgeColor: Color,
        description: String,
        details: [(String, String)],
        buttonLabel: String, buttonColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: iconColors.map { $0.opacity(0.20) },
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundStyle(LinearGradient(
                            colors: iconColors,
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        Text(badge)
                            .font(.caption2.bold())
                            .foregroundColor(badgeColor)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(badgeColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text(description)
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 16)

            Divider().padding(.horizontal, 16).padding(.top, 14)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(details, id: \.0) { icon, text in
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.caption2).foregroundColor(.secondary)
                            .frame(width: 16)
                        Text(text).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12)

            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Text(buttonLabel).font(.subheadline.bold())
                    Image(systemName: "chevron.right").font(.caption.bold())
                }
                .foregroundColor(buttonColor)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(18)
        .padding(.horizontal, 16)
    }
}

// ── BankConnectionsView ───────────────────────────────────────────────────────
struct BankConnectionsView: View {
    let sandbox: Bool

    init(sandbox: Bool = false) {
        self.sandbox = sandbox
    }

    @Environment(\.dismiss) private var dismiss
    @State private var connections: [APIService.BankConnectionResponse] = []
    @State private var accounts: [APIService.Account] = []
    @State private var isLoading = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var syncingID: String?
    @State private var linkingConn: APIService.BankConnectionResponse?
    @State private var successMessage: String?

    private let presenter = WebAuthPresenter()

    private var modeTitle: String { sandbox ? "Sandbox Banking" : "Open Banking" }
    private var modeAccent: Color  { sandbox ? .orange : .blue }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && connections.isEmpty {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if connections.isEmpty {
                    emptyState
                } else {
                    List {
                        if let msg = successMessage {
                            Section {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text(msg).font(.subheadline).foregroundColor(.green)
                                }
                            }
                        }
                        Section {
                            ForEach(connections) { conn in
                                connectionRow(conn)
                            }
                        }
                        Section {
                            connectButton
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(modeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading)  { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        if sandbox {
                            Text("SANDBOX")
                                .font(.caption2.bold())
                                .foregroundColor(.orange)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        if isConnecting {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Button { Task { await connect() } } label: {
                                Image(systemName: "plus.circle.fill").font(.title2)
                                    .foregroundColor(modeAccent)
                            }
                        }
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $linkingConn) { conn in
                LinkAccountSheet(conn: conn, accounts: accounts) { accountID in
                    Task { await linkAccount(connID: conn.id, accountID: accountID) }
                }
            }
        }
        .task { await load() }
    }

    // ── Empty state ───────────────────────────────────────────────────────────
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)

                // Hero icon
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.18), Color.indigo.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 110, height: 110)
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(LinearGradient(
                            colors: [.blue, .indigo],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }

                VStack(spacing: 8) {
                    Text("Connect via TrueLayer")
                        .font(.title2.bold())
                    Text("Access 100+ banks across the UK and Europe via Open Banking.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Feature list
                VStack(spacing: 0) {
                    ForEach(tlFeatureRows, id: \.title) { row in
                        HStack(spacing: 14) {
                            Image(systemName: row.icon)
                                .foregroundColor(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.subheadline.weight(.medium))
                                Text(row.subtitle).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        if row.title != tlFeatureRows.last?.title {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)

                // Connect button
                Button {
                    Task { await connect() }
                } label: {
                    Group {
                        if isConnecting {
                            ProgressView().tint(.white)
                        } else {
                            Text("Connect a Bank")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [.blue, .indigo],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(14)
                }
                .padding(.horizontal, 16)
                .disabled(isConnecting)

                // Fine print
                Label("Read-only access · No payment permissions", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer(minLength: 40)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private let tlFeatureRows: [(icon: String, title: String, subtitle: String)] = [
        (icon: "building.columns.fill",
         title: "100+ Banks",
         subtitle: "Revolut, Monzo, Wise, HSBC, Barclays, Starling and many more"),
        (icon: "flag.fill",
         title: "UK & EU Coverage",
         subtitle: "Full Open Banking support across the UK and Europe"),
        (icon: "arrow.triangle.2.circlepath",
         title: "Auto Transaction Sync",
         subtitle: "Import 90 days of history and sync new transactions"),
        (icon: "checkmark.shield.fill",
         title: "Bank-level Security",
         subtitle: "Read-only access — TrueLayer cannot move funds"),
    ]

    @ViewBuilder
    private func accountTypeRow(_ title: String, icon: String, color: Color) -> some View {
        Button { Task { await connect() } } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.system(size: 19))
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                if isConnecting {
                    ProgressView().scaleEffect(0.75)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.primary)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
    }

    private static let faqItems: [BankFAQItem] = [
        BankFAQItem(
            question: "I can't find my bank on the list.",
            answer: "We support 100+ banks via TrueLayer. If yours isn't listed yet, you can add transactions manually in the meantime. We're always adding new providers."),
        BankFAQItem(
            question: "How long does it take for transactions to sync?",
            answer: "Most banks sync within a few seconds. Occasionally it can take up to a minute depending on your bank's response time."),
        BankFAQItem(
            question: "Will my data be shared with other companies?",
            answer: "No. Your banking credentials are handled by TrueLayer, a regulated open banking provider. LedgerVault only receives read-only transaction data — we never see your passwords."),
        BankFAQItem(
            question: "How much transaction history is imported?",
            answer: "We import up to 90 days of transaction history on the first sync. Subsequent syncs pick up from where the last one left off."),
        BankFAQItem(
            question: "Can money be transferred from my bank account?",
            answer: "No. The connection is read-only. LedgerVault cannot initiate any payments or transfers."),
        BankFAQItem(
            question: "I've added transactions manually — will I get duplicates?",
            answer: "We use the bank's transaction ID to detect duplicates, so existing manual entries won't be doubled up as long as the descriptions match."),
        BankFAQItem(
            question: "Can I remove my imported data?",
            answer: "Yes. You can delete any connection from the Open Banking screen, and remove individual imported transactions from the Transactions tab."),
    ]

    // ── Connect button (inside list) ──────────────────────────────────────────
    private var connectButton: some View {
        Button {
            Task { await connect() }
        } label: {
            HStack {
                if isConnecting {
                    ProgressView().scaleEffect(0.85)
                } else {
                    Image(systemName: "plus.circle.fill").foregroundColor(.blue)
                }
                Text(isConnecting ? "Connecting…" : "Connect Another Bank")
                    .foregroundColor(.blue)
            }
        }
        .disabled(isConnecting)
    }

    // ── Connection row ────────────────────────────────────────────────────────
    @ViewBuilder
    private func connectionRow(_ conn: APIService.BankConnectionResponse) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                // Bank icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(bankColor(conn.provider_id).opacity(0.13))
                        .frame(width: 50, height: 50)
                    Image(systemName: bankIcon(conn.provider_id))
                        .foregroundColor(bankColor(conn.provider_id))
                        .font(.system(size: 22))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(conn.provider_name).font(.headline)
                    Text(conn.account_display_name)
                        .font(.subheadline).foregroundColor(.secondary)
                    if let currency = conn.currency {
                        Text(currency + " · " + (conn.account_type?.capitalized ?? "Account"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    // Status badge
                    Text(conn.status.capitalized)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(statusColor(conn.status).opacity(0.12))
                        .foregroundColor(statusColor(conn.status))
                        .clipShape(Capsule())

                    // Last synced
                    if let synced = conn.last_synced {
                        Text(relativeTime(synced))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)

            // Linked account + action buttons
            HStack(spacing: 8) {
                if let acctID = conn.ledger_account_id,
                   let acct = accounts.first(where: { $0.id == acctID }) {
                    Label(acct.name, systemImage: "link")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Button {
                        linkingConn = conn
                    } label: {
                        Label("Link Account", systemImage: "link.badge.plus")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Sync button
                if conn.ledger_account_id != nil {
                    Button {
                        Task { await sync(conn) }
                    } label: {
                        if syncingID == conn.id {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2.bold())
                                .foregroundColor(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(syncingID != nil)
                }
            }
            .padding(.bottom, 6)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await delete(conn) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // ── Actions ───────────────────────────────────────────────────────────────
    private func connect() async {
        isConnecting = true
        successMessage = nil
        defer { isConnecting = false }

        do {
            // 1. Get auth URL from backend (with sandbox flag)
            let authURL = try await APIService.shared.getBankAuthURL(sandbox: sandbox)
            guard let url = URL(string: authURL) else {
                errorMessage = "Invalid auth URL"; return
            }

            // 2. Open TrueLayer OAuth in ASWebAuthenticationSession
            let callbackURL = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: "ledgervault"
                ) { callbackURL, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL = callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                session.presentationContextProvider = presenter
                session.prefersEphemeralWebBrowserSession = true
                session.start()
                _ = session
            }

            // 3. Extract code from redirect URL
            guard
                let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            else {
                errorMessage = "Auth callback missing code"; return
            }

            // 4. Exchange code with backend
            let newConns = try await APIService.shared.completeBankAuth(code: code, sandbox: sandbox)
            connections = try await APIService.shared.fetchBankConnections()
            successMessage = "Connected \(newConns.count) account\(newConns.count == 1 ? "" : "s")"

        } catch let err as NSError where err.domain == ASWebAuthenticationSessionErrorDomain
                                     && err.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            // User cancelled — silent
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sync(_ conn: APIService.BankConnectionResponse) async {
        syncingID = conn.id
        successMessage = nil
        defer { syncingID = nil }
        do {
            let result = try await APIService.shared.syncBankConnection(id: conn.id)
            successMessage = "Imported \(result.imported), skipped \(result.skipped)"
            connections = try await APIService.shared.fetchBankConnections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ conn: APIService.BankConnectionResponse) async {
        do {
            try await APIService.shared.deleteBankConnection(id: conn.id)
            connections.removeAll { $0.id == conn.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private func linkAccount(connID: String, accountID: String) async {
        do {
            _ = try await APIService.shared.linkBankToAccount(connID: connID, accountID: accountID)
            connections = try await APIService.shared.fetchBankConnections()
        } catch { errorMessage = error.localizedDescription }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        async let conns = APIService.shared.fetchBankConnections()
        async let accts = APIService.shared.fetchAccounts()
        do {
            connections = try await conns
            accounts    = try await accts
        } catch { errorMessage = error.localizedDescription }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    private func bankIcon(_ providerID: String) -> String {
        let p = providerID.lowercased()
        if p.contains("revolut")  { return "arrow.triangle.2.circlepath.circle.fill" }
        if p.contains("monzo")    { return "creditcard.fill" }
        if p.contains("starling") { return "star.fill" }
        if p.contains("wise")     { return "globe" }
        if p.contains("hsbc")     { return "building.columns.fill" }
        return "building.2.fill"
    }

    private func bankColor(_ providerID: String) -> Color {
        let p = providerID.lowercased()
        if p.contains("revolut")  { return .indigo }
        if p.contains("monzo")    { return .pink }
        if p.contains("starling") { return Color(red: 0.2, green: 0.7, blue: 0.5) }
        if p.contains("wise")     { return .green }
        if p.contains("hsbc")     { return .red }
        return .blue
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "active": return .green
        case "error":  return .red
        default:       return .orange
        }
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ??
              ISO8601DateFormatter().date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return "synced " + rel.localizedString(for: date, relativeTo: Date())
    }
}

// ── FAQ helpers ───────────────────────────────────────────────────────────────
struct BankFAQItem {
    let question: String
    let answer: String
}

struct BankFAQRow: View {
    let item: BankFAQItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(item.question)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.top, 2)
                }
                .padding(16)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(item.answer)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// ── Link Account Sheet ────────────────────────────────────────────────────────
struct LinkAccountSheet: View {
    let conn: APIService.BankConnectionResponse
    let accounts: [APIService.Account]
    let onLink: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String = ""

    private var bankAccounts: [APIService.Account] {
        accounts.filter { $0.account_type == "bank" || $0.account_type == "cash" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose which LedgerVault account should receive transactions imported from **\(conn.provider_name) – \(conn.account_display_name)**.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }
                Section("Your Accounts") {
                    if bankAccounts.isEmpty {
                        Text("No bank accounts yet. Add one first.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(bankAccounts) { acct in
                            Button {
                                selectedID = acct.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(acct.name).font(.subheadline.bold())
                                        Text(acct.base_currency).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedID == acct.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Link Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading)  { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Link") {
                        guard !selectedID.isEmpty else { return }
                        onLink(selectedID)
                        dismiss()
                    }
                    .bold()
                    .disabled(selectedID.isEmpty)
                }
            }
        }
    }
}
