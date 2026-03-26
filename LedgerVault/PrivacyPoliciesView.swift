import SwiftUI

// MARK: - PrivacyPoliciesView

struct PrivacyPoliciesView: View {
    @Environment(\.dismiss) private var dismiss

    private let policies: [PolicyDocument] = PolicyDocument.all

    var body: some View {
        NavigationStack {
            List(policies) { policy in
                NavigationLink(destination: PolicyDetailView(policy: policy)) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(policy.color.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: policy.icon)
                                .foregroundColor(policy.color)
                                .font(.system(size: 18, weight: .semibold))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.title)
                                .font(.subheadline.weight(.semibold))
                            Text(policy.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Privacy & Legal")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// MARK: - PolicyDetailView

struct PolicyDetailView: View {
    let policy: PolicyDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero header
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(policy.color.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: policy.icon)
                            .foregroundColor(policy.color)
                            .font(.system(size: 24, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(policy.title)
                            .font(.headline)
                        Text("Version 1.0 · \(policy.effectiveDate)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal)
                .padding(.top)

                // Sections
                ForEach(policy.sections) { section in
                    PolicySectionView(section: section)
                }

                // Footer
                Text("LedgerVault · \(policy.title) · v1.0")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(policy.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - PolicySectionView

private struct PolicySectionView: View {
    let section: PolicySection
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(section.heading)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(section.items) { item in
                        PolicyItemView(item: item)
                    }
                }
                .padding(16)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

// MARK: - PolicyItemView

private struct PolicyItemView: View {
    let item: PolicyItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = item.label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
            }
            Text(item.body)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - Data Models

struct PolicyDocument: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let effectiveDate: String
    let sections: [PolicySection]

    static let all: [PolicyDocument] = [
        .privacyPolicy,
        .securityPolicy,
        .accessControlsPolicy,
        .dataRetentionPolicy,
    ]
}

struct PolicySection: Identifiable {
    let id = UUID()
    let heading: String
    let items: [PolicyItem]
}

struct PolicyItem: Identifiable {
    let id = UUID()
    let label: String?
    let body: String

    init(_ body: String, label: String? = nil) {
        self.label = label
        self.body  = body
    }
}

// MARK: - Privacy Policy

extension PolicyDocument {
    static let privacyPolicy = PolicyDocument(
        title: "Privacy Policy",
        subtitle: "How we collect, use & protect your data",
        icon: "hand.raised.fill",
        color: .blue,
        effectiveDate: "20 March 2026",
        sections: [
            PolicySection(heading: "What We Collect", items: [
                PolicyItem("Account information you provide: name, email address, and password (stored as a bcrypt hash — never in plaintext).", label: "Account Data"),
                PolicyItem("Financial data from connected integrations: bank account names, transaction history, balances, and account types retrieved via Plaid, TrueLayer, or Salt Edge.", label: "Financial Data"),
                PolicyItem("Exchange API keys you enter for Binance, Kraken, Coinbase, etc. These are encrypted with AES-256 before being stored.", label: "Exchange Credentials"),
                PolicyItem("Manually entered transactions, holdings, accounts, and recurring transaction templates.", label: "Portfolio Data"),
            ]),
            PolicySection(heading: "How We Use Your Data", items: [
                PolicyItem("To calculate and display your real-time net worth and portfolio performance."),
                PolicyItem("To authenticate you securely and maintain your session."),
                PolicyItem("To sync transactions from connected banks and exchanges."),
                PolicyItem("To send price alert notifications you have configured."),
                PolicyItem("We do not sell, rent, or share your personal data with advertisers or third parties for marketing purposes."),
            ]),
            PolicySection(heading: "Third-Party Integrations", items: [
                PolicyItem("Plaid, TrueLayer, and Salt Edge are used to connect bank accounts. These providers have their own privacy policies and are subject to their respective regulatory frameworks.", label: "Bank Connections"),
                PolicyItem("CoinGecko, Yahoo Finance, and open.er-api.com are used to fetch live market prices. Only asset symbols — never personal data — are sent to these services.", label: "Market Data"),
                PolicyItem("Railway provides our backend hosting and PostgreSQL database. All data is stored in Railway's encrypted infrastructure.", label: "Infrastructure"),
            ]),
            PolicySection(heading: "Your Rights", items: [
                PolicyItem("Access: you can export all your transaction and portfolio data from More → Export / Import."),
                PolicyItem("Erasure: you can delete your account and all associated data permanently from More → Profile."),
                PolicyItem("Rectification: you can edit your profile details at any time from More → Profile."),
                PolicyItem("Portability: your data can be exported as CSV at any time."),
            ]),
            PolicySection(heading: "Contact", items: [
                PolicyItem("For privacy-related questions or data requests, contact: privacy@ledgervault.app"),
                PolicyItem("This policy is reviewed annually. Material changes will be communicated within the app."),
            ]),
        ]
    )
}

// MARK: - Information Security Policy

extension PolicyDocument {
    static let securityPolicy = PolicyDocument(
        title: "Information Security Policy",
        subtitle: "How we secure your financial data",
        icon: "lock.shield.fill",
        color: .indigo,
        effectiveDate: "20 March 2026",
        sections: [
            PolicySection(heading: "Encryption", items: [
                PolicyItem("All data in transit is encrypted using TLS 1.2 or higher. Plain HTTP connections are rejected.", label: "In Transit"),
                PolicyItem("Sensitive credentials (exchange API keys, bank access tokens) are encrypted at rest using AES-256 (Fernet). Railway's PostgreSQL additionally encrypts all data at the disk level.", label: "At Rest"),
                PolicyItem("Passwords are hashed using bcrypt with a work factor of 12 — never stored in plaintext.", label: "Passwords"),
            ]),
            PolicySection(heading: "Authentication & Sessions", items: [
                PolicyItem("All API requests are authenticated using signed JWTs (HS256) with a 30-day expiry."),
                PolicyItem("Tokens include an issued-at timestamp. Signing out immediately invalidates all tokens across all devices via server-side revocation."),
                PolicyItem("Social sign-in (Apple, Google) tokens are validated against published JWKS endpoints before any session is created."),
            ]),
            PolicySection(heading: "Infrastructure", items: [
                PolicyItem("The backend runs on Railway, which is hosted on AWS/GCP infrastructure with SOC 2 Type II certification.", label: "Hosting"),
                PolicyItem("The PostgreSQL database has no public network port. It is only accessible from within Railway's private network.", label: "Database"),
                PolicyItem("All production secrets (database URL, JWT secret, API keys) are stored in Railway's encrypted environment variable store — never in source code.", label: "Secrets"),
            ]),
            PolicySection(heading: "Access Controls", items: [
                PolicyItem("Every API endpoint is scoped to the authenticated user's ID. No user can access another user's data."),
                PolicyItem("Rate limiting is enforced on all endpoints to prevent brute-force attacks."),
                PolicyItem("Administrative access to production infrastructure requires Railway SSO authentication with 2FA enabled."),
            ]),
            PolicySection(heading: "Vulnerability Management", items: [
                PolicyItem("Python dependencies are audited regularly using pip-audit. No known vulnerabilities were found as of 20 March 2026."),
                PolicyItem("Dependencies are updated when security patches are released. End-of-life software is actively monitored and replaced."),
                PolicyItem("This policy is reviewed annually or after any significant security incident."),
            ]),
        ]
    )
}

// MARK: - Access Controls Policy

extension PolicyDocument {
    static let accessControlsPolicy = PolicyDocument(
        title: "Access Controls Policy",
        subtitle: "Authentication, authorisation & session management",
        icon: "person.badge.key.fill",
        color: .purple,
        effectiveDate: "20 March 2026",
        sections: [
            PolicySection(heading: "Guiding Principles", items: [
                PolicyItem("Least Privilege: every user and service is granted only the minimum access required. Plaid connections are read-only — no payment or write permissions are ever requested.", label: "Least Privilege"),
                PolicyItem("Separation of Duties: users can only access their own data. No cross-user data leakage is possible at the API framework level.", label: "Separation of Duties"),
                PolicyItem("Defence in Depth: access controls are enforced at the client (Keychain), transport (TLS), and server (JWT + DB revocation) layers.", label: "Defence in Depth"),
            ]),
            PolicySection(heading: "Consumer Authentication", items: [
                PolicyItem("Passwords are hashed with bcrypt (12 rounds) before storage. Plaintext passwords are never stored or logged."),
                PolicyItem("Sign in with Apple and Google OAuth are supported. Identity tokens are validated server-side before a session is created."),
                PolicyItem("New accounts require email verification via a time-limited one-time code (OTP) expiring after 10 minutes."),
                PolicyItem("The app enforces Face ID / Touch ID biometric authentication each time it returns from the background, before any financial data is displayed."),
            ]),
            PolicySection(heading: "Session Management", items: [
                PolicyItem("JWT tokens are valid for 30 days and include an issued-at (iat) timestamp.", label: "Token Lifetime"),
                PolicyItem("Signing out sets a logout_at timestamp in the database. Any token issued before that timestamp is immediately rejected — across all devices.", label: "Server-Side Revocation"),
                PolicyItem("On sign-out, the JWT is deleted from the iOS Keychain and all local cached data is wiped.", label: "Client-Side Cleanup"),
                PolicyItem("The app auto-locks after a configurable inactivity timeout (default 30 seconds) and re-requires biometric authentication.", label: "Auto-Lock"),
            ]),
            PolicySection(heading: "Infrastructure Access", items: [
                PolicyItem("Production infrastructure (Railway) is protected by SSO + authenticator app 2FA + passkey. No direct shell access to production compute exists."),
                PolicyItem("The PostgreSQL database has no public port — it is only reachable from within Railway's private network."),
                PolicyItem("All infrastructure access is logged in Railway's audit trail."),
            ]),
        ]
    )
}

// MARK: - Data Retention & Disposal Policy

extension PolicyDocument {
    static let dataRetentionPolicy = PolicyDocument(
        title: "Data Retention & Disposal",
        subtitle: "What we keep, for how long, and how it's deleted",
        icon: "trash.slash.fill",
        color: .orange,
        effectiveDate: "20 March 2026",
        sections: [
            PolicySection(heading: "Retention Periods", items: [
                PolicyItem("Retained for the lifetime of your account. Deleted within 24 hours of an account deletion request.", label: "Account & Profile Data"),
                PolicyItem("Active connection lifetime only. Deleted immediately when you disconnect a bank or delete your account.", label: "Bank / Plaid Access Tokens"),
                PolicyItem("Retained for the lifetime of your account. Fully deleted on account deletion.", label: "Transaction History"),
                PolicyItem("30 days (token expiry). Immediately invalidated server-side on sign-out.", label: "Session Tokens (JWT)"),
                PolicyItem("90 days, managed by Railway's logging infrastructure.", label: "Access & Audit Logs"),
                PolicyItem("7-day rolling backups managed by Railway. No LedgerVault data is archived to cold storage.", label: "Database Backups"),
            ]),
            PolicySection(heading: "How Deletion Works", items: [
                PolicyItem("Account deletion triggers a cascading hard-delete in this order: transaction legs → transaction events → holdings → bank/exchange connections → accounts → user record. No orphaned records are left behind."),
                PolicyItem("When a Plaid connection is removed, the access token is deleted from the database immediately."),
                PolicyItem("All deletions are permanent SQL hard-deletes — data is not moved to a recycle bin or archive."),
                PolicyItem("Railway's PostgreSQL infrastructure handles secure disk disposal in accordance with its SOC 2 Type II certified policies."),
            ]),
            PolicySection(heading: "Your Rights", items: [
                PolicyItem("You can delete your account and all data at any time from More → Profile → Delete Account."),
                PolicyItem("You can export all your data at any time from More → Export / Import."),
                PolicyItem("Data deletion and export requests are processed within 30 days, as required by GDPR and CCPA."),
            ]),
            PolicySection(heading: "Policy Review", items: [
                PolicyItem("This policy is reviewed annually or whenever significant changes are made to how data is processed."),
                PolicyItem("Next review: March 2027. Contact: privacy@ledgervault.app"),
            ]),
        ]
    )
}
