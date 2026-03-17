import SwiftUI
import AuthenticationServices

// ── Presentation context provider for ASWebAuthenticationSession ──────────────
private class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

// ── BankConnectionsView ───────────────────────────────────────────────────────
struct BankConnectionsView: View {
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
            .navigationTitle("Open Banking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading)  { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if isConnecting {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button { Task { await connect() } } label: {
                            Image(systemName: "plus.circle.fill").font(.title2)
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
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 90, height: 90)
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 38))
                    .foregroundColor(.blue)
            }
            Text("Connect Your Bank").font(.title2.bold())
            Text("Securely connect via Open Banking to auto-import transactions.\nSupports Revolut, Wise, Monzo, Starling, HSBC and 100+ banks.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Supported bank logos row
            HStack(spacing: 12) {
                ForEach(["Revolut", "Wise", "Monzo", "Starling"], id: \.self) { name in
                    Text(name)
                        .font(.caption2.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
            }

            if isConnecting {
                ProgressView("Connecting…").padding(.top, 8)
            } else {
                Button {
                    Task { await connect() }
                } label: {
                    Label("Connect Bank Account", systemImage: "link")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }
            Spacer()
        }
    }

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
            // 1. Get auth URL from backend
            let authURL = try await APIService.shared.getBankAuthURL()
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
                // Hold reference so session lives until callback
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
            let newConns = try await APIService.shared.completeBankAuth(code: code)
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
