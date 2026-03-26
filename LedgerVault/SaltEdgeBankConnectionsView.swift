import SwiftUI
import AuthenticationServices

// MARK: - SaltEdgeBankConnectionsView

struct SaltEdgeBankConnectionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var connections: [APIService.BankConnectionResponse] = []
    @State private var isLoading   = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var authSession: ASWebAuthenticationSession?

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
            .navigationTitle("Salt Edge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await connect() }
                    } label: {
                        if isConnecting {
                            ProgressView().tint(.white)
                        } else {
                            Label("Add Bank", systemImage: "plus")
                        }
                    }
                    .disabled(isConnecting)
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
            .task { await load() }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)

                // Hero
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.green.opacity(0.18), Color.teal.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 110, height: 110)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 46))
                        .foregroundStyle(LinearGradient(
                            colors: [.green, .teal],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }

                VStack(spacing: 8) {
                    Text("Connect via Salt Edge")
                        .font(.title2.bold())
                    Text("Access 5,000+ banks across Europe and beyond using Salt Edge Open Banking.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Feature rows
                VStack(spacing: 0) {
                    ForEach(featureRows, id: \.title) { row in
                        HStack(spacing: 14) {
                            Image(systemName: row.icon)
                                .foregroundColor(.green)
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
                        LinearGradient(colors: [.green, .teal],
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

    private let featureRows: [(icon: String, title: String, subtitle: String)] = [
        (icon: "building.columns.fill",
         title: "5,000+ Banks",
         subtitle: "Revolut, N26, ING, Monzo, Bunq, Starling and thousands more"),
        (icon: "eurosign.circle.fill",
         title: "EU & Beyond",
         subtitle: "Full PSD2/Open Banking coverage across Europe"),
        (icon: "arrow.triangle.2.circlepath",
         title: "Auto Transaction Sync",
         subtitle: "Import 90 days of history and sync new transactions"),
        (icon: "checkmark.shield.fill",
         title: "Bank-level Security",
         subtitle: "Read-only access — Salt Edge cannot move funds"),
    ]

    // MARK: - Connection List

    private var connectionList: some View {
        List {
            Section {
                ForEach(connections) { conn in
                    connectionRow(conn)
                }
            } header: {
                Text("\(connections.count) connected account\(connections.count == 1 ? "" : "s")")
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    Label("Add Another Bank", systemImage: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                .disabled(isConnecting)
            }
        }
    }

    @ViewBuilder
    private func connectionRow(_ conn: APIService.BankConnectionResponse) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: "building.columns.fill")
                    .foregroundColor(.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(conn.account_display_name).font(.subheadline.weight(.semibold))
                Text(conn.provider_name).font(.caption).foregroundColor(.secondary)
                if let synced = conn.last_synced {
                    Text("Synced \(synced.prefix(10))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                statusBadge(conn.status)
                if conn.ledger_account_id == nil {
                    Text("Not linked")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let isActive = status == "active"
        Text(isActive ? "Active" : status.capitalized)
            .font(.caption2.bold())
            .foregroundColor(isActive ? .green : .orange)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((isActive ? Color.green : Color.orange).opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true; defer { isLoading = false }
        do { connections = try await APIService.shared.fetchSaltEdgeConnections() }
        catch { /* silent on empty */ }
    }

    private func connect() async {
        isConnecting = true; defer { isConnecting = false }
        do {
            let authURL = try await APIService.shared.getSaltEdgeAuthURL()
            guard let url = URL(string: authURL) else { return }
            await openAuthSession(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func openAuthSession(url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "ledgervault"
            ) { callbackURL, error in
                defer { continuation.resume() }
                guard error == nil, let callback = callbackURL else { return }
                // Backend handles the connection storage and redirects to ledgervault://saltedge/callback
                let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
                let success = components?.queryItems?.first(where: { $0.name == "success" })?.value == "true"
                if success {
                    Task { await self.load() }
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = UIApplication.shared.windows.first?.rootViewController as? ASWebAuthenticationPresentationContextProviding
            self.authSession = session
            session.start()
        }
    }
}
