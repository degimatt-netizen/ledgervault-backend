import SwiftUI
import AuthenticationServices

// MARK: - SnapTrade Connections View

struct SnapTradeConnectionsView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var connections: [APIService.SnaptradeConnectionResponse] = []
    @State private var isConnecting  = false
    @State private var syncingID: String? = nil
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    @State private var isLoading = true

    // Presentation context for ASWebAuthenticationSession
    private let presenter = WebAuthPresenter()

    // User ID — matches the pattern used for TrueLayer / SaltEdge
    private var userID: String {
        UserDefaults.standard.string(forKey: "userID") ?? "default_user"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // ── Header card ─────────────────────────────────────────
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.green, Color.teal],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 64, height: 64)
                            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                        }

                        Text("SnapTrade")
                            .font(.title2.bold())

                        Text("Connect Trading 212, IBKR, eToro, Robinhood, Schwab, Fidelity, Webull and 50+ brokers via OAuth — no credentials ever shared.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // ── Status / error banners ───────────────────────────────
                    if let msg = errorMessage {
                        Text(msg)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.red.opacity(0.85))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .onTapGesture { errorMessage = nil }
                    }

                    if let msg = successMessage {
                        Text(msg)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.green.opacity(0.85))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .onTapGesture { successMessage = nil }
                    }

                    // ── Connect button ───────────────────────────────────────
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            if isConnecting {
                                ProgressView().tint(.white).padding(.trailing, 4)
                            }
                            Image(systemName: "plus.circle.fill")
                            Text(isConnecting ? "Opening broker…" : "Connect a Broker")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .background(
                            LinearGradient(
                                colors: [Color.green, Color.teal],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(14)
                    }
                    .disabled(isConnecting)
                    .padding(.horizontal)

                    // ── Connected accounts list ──────────────────────────────
                    if isLoading {
                        ProgressView()
                            .padding()
                    } else if connections.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("No brokers connected yet")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 12)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(connections) { conn in
                                connectionRow(conn)
                                if conn.id != connections.last?.id {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 40)
                .padding(.top, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SnapTrade Brokers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await loadConnections() }
        }
    }

    // MARK: Row

    @ViewBuilder
    private func connectionRow(_ conn: APIService.SnaptradeConnectionResponse) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(conn.brokerage_name ?? "Broker")
                    .font(.subheadline.weight(.semibold))
                if let synced = conn.last_synced {
                    Text("Synced \(synced.prefix(10))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Never synced")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if syncingID == conn.id {
                ProgressView().scaleEffect(0.8)
            } else {
                Button {
                    Task { await syncConnection(conn) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await deleteConnection(conn) }
            } label: { Label("Remove", systemImage: "trash") }
        }
    }

    // MARK: Actions

    private func loadConnections() async {
        isLoading = true
        defer { isLoading = false }
        do {
            connections = try await APIService.shared.fetchSnaptradeConnections(userID: userID)
        } catch {
            // If backend says SnapTrade not configured, show friendly message
            if (error as NSError).code == 503 {
                errorMessage = "SnapTrade not configured yet — add SNAPTRADE_CLIENT_ID and SNAPTRADE_CONSUMER_KEY to your server env vars."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func connect() async {
        isConnecting = true
        successMessage = nil
        errorMessage = nil
        defer { isConnecting = false }

        do {
            // 1. Register user (idempotent) + get OAuth URL
            let result = try await APIService.shared.snaptradeRegisterAndAuthURL(userID: userID)
            guard let url = URL(string: result.auth_url) else {
                errorMessage = "Invalid auth URL"; return
            }

            // 2. Open broker OAuth in ASWebAuthenticationSession
            let callbackURL = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: "ledgervault"
                ) { callbackURL, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let url = callbackURL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                session.presentationContextProvider = presenter
                session.prefersEphemeralWebBrowserSession = false
                session.start()
                _ = session
            }

            // 3. SnapTrade redirect comes back — reload connections
            _ = callbackURL
            await loadConnections()
            successMessage = "Broker connected! Your holdings will sync shortly."

        } catch let err as NSError
            where err.domain == ASWebAuthenticationSessionErrorDomain
               && err.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            // User cancelled — silent
        } catch {
            if (error as NSError).code == 503 {
                errorMessage = "SnapTrade keys not configured on server yet."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func syncConnection(_ conn: APIService.SnaptradeConnectionResponse) async {
        syncingID = conn.id
        defer { syncingID = nil }
        do {
            let result = try await APIService.shared.syncSnaptradeConnection(id: conn.id)
            successMessage = "Imported \(result.imported), skipped \(result.skipped)"
            connections = try await APIService.shared.fetchSnaptradeConnections(userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteConnection(_ conn: APIService.SnaptradeConnectionResponse) async {
        do {
            try await APIService.shared.deleteSnaptradeConnection(id: conn.id)
            connections = try await APIService.shared.fetchSnaptradeConnections(userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
