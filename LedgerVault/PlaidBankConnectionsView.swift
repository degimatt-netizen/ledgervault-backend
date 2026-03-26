import SwiftUI
import AuthenticationServices

// MARK: - PlaidBankConnectionsView

struct PlaidBankConnectionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var connections:  [APIService.BankConnectionResponse] = []
    @State private var isLoading     = false
    @State private var isConnecting  = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private let presenter = WebAuthPresenter()
    private let accentA   = Color(red: 0.0, green: 0.42, blue: 0.65)
    private let accentB   = Color.teal

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && connections.isEmpty {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if connections.isEmpty {
                    emptyState
                } else {
                    connectionList
                }
            }
            .navigationTitle("Plaid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Button { Task { await connect() } } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(isConnecting)
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task { await load() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)

                // Hero icon
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [accentA.opacity(0.18), accentB.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 110, height: 110)
                    Image(systemName: "creditcard.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(LinearGradient(
                            colors: [accentA, accentB],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }

                VStack(spacing: 8) {
                    Text("Connect via Plaid")
                        .font(.title2.bold())
                    Text("Link your bank accounts from 12,000+ institutions across the US, UK and Europe.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Feature list
                VStack(spacing: 0) {
                    ForEach(featureRows, id: \.title) { row in
                        HStack(spacing: 14) {
                            Image(systemName: row.icon)
                                .foregroundColor(accentA)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.subheadline.weight(.medium))
                                Text(row.subtitle).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        if row.title != featureRows.last?.title {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)

                // Connect button
                Button { Task { await connect() } } label: {
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
                        LinearGradient(colors: [accentA, accentB],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(14)
                }
                .padding(.horizontal, 16)
                .disabled(isConnecting)

                Label("Read-only access · No payment permissions", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer(minLength: 40)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private let featureRows: [(icon: String, title: String, subtitle: String)] = [
        (icon: "building.columns.fill",
         title: "12,000+ Institutions",
         subtitle: "Chase, Bank of America, Revolut, Monzo, HSBC and thousands more"),
        (icon: "globe.americas.fill",
         title: "US, UK & Europe",
         subtitle: "Broad coverage across North America and growing EU support"),
        (icon: "arrow.triangle.2.circlepath",
         title: "Auto Transaction Sync",
         subtitle: "Import up to 2 years of history and sync new transactions"),
        (icon: "checkmark.shield.fill",
         title: "Bank-grade Security",
         subtitle: "Read-only access — Plaid cannot move funds"),
    ]

    // MARK: - Connection List

    private var connectionList: some View {
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
            } header: {
                Text("\(connections.count) connected account\(connections.count == 1 ? "" : "s")")
            }

            Section {
                Button { Task { await connect() } } label: {
                    Label(isConnecting ? "Connecting…" : "Add Another Bank",
                          systemImage: "plus.circle.fill")
                        .foregroundColor(accentA)
                }
                .disabled(isConnecting)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func connectionRow(_ conn: APIService.BankConnectionResponse) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(accentA.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "building.columns.fill")
                    .foregroundColor(accentA)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(conn.provider_name).font(.subheadline.weight(.semibold))
                Text(conn.account_display_name).font(.caption).foregroundColor(.secondary)
                if let synced = conn.last_synced {
                    Text("Synced \(synced.prefix(10))").font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await sync(connID: conn.id) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(accentA)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        if let list = try? await APIService.shared.fetchPlaidConnections() {
            connections = list
        }
        isLoading = false
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        do {
            let urlInfo = try await APIService.shared.plaidAuthURL()
            guard let url = URL(string: urlInfo.auth_url) else {
                throw NSError(domain: "Plaid", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid auth URL"])
            }

            let publicToken: String = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: "ledgervault"
                ) { callbackURL, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let cbURL = callbackURL,
                          let components = URLComponents(url: cbURL, resolvingAgainstBaseURL: false),
                          let token = components.queryItems?.first(where: { $0.name == "public_token" })?.value
                    else {
                        continuation.resume(throwing: NSError(domain: "Plaid", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Could not get public token from callback"]))
                        return
                    }
                    continuation.resume(returning: token)
                }
                session.presentationContextProvider = presenter
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }

            let result = try await APIService.shared.plaidExchangeToken(publicToken: publicToken)
            successMessage = "Connected \(result.institution) — \(result.connected) account\(result.connected == 1 ? "" : "s")"
            await load()
        } catch {
            let msg = error.localizedDescription
            if !msg.lowercased().contains("cancel") {
                errorMessage = msg
            }
        }
        isConnecting = false
    }

    private func sync(connID: String) async {
        do {
            _ = try await APIService.shared.syncPlaidConnection(id: connID)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
