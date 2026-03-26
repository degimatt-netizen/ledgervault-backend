import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - TOTPSetupView

/// Two-step sheet: (1) scan QR / copy secret → (2) enter 6-digit code to confirm.
struct TOTPSetupView: View {

    let onEnabled: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var step: SetupStep = .loading
    @State private var secret = ""
    @State private var uri    = ""
    @State private var code   = ""
    @State private var errorMessage: String?
    @State private var isVerifying = false
    @State private var showCopied  = false

    enum SetupStep { case loading, scan, verify, done }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .loading:  loadingView
                case .scan:     scanView
                case .verify:   verifyView
                case .done:     doneView
                }
            }
            .navigationTitle("Set Up Authenticator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .done {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .task { await startSetup() }
        .interactiveDismissDisabled(step == .verify || step == .loading)
    }

    // ─────────────────────────────────────────────
    // MARK: Loading
    // ─────────────────────────────────────────────

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Preparing…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ─────────────────────────────────────────────
    // MARK: Step 1 — Scan QR
    // ─────────────────────────────────────────────

    private var scanView: some View {
        ScrollView {
            VStack(spacing: 28) {

                // Instructions
                VStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                    Text("Scan with your Authenticator app")
                        .font(.title3.bold())
                    Text("Open Google Authenticator, Authy, or any TOTP app, then scan the QR code below.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                // QR Code
                if let qrImage = generateQRCode(from: uri) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
                }

                // Manual entry fallback
                VStack(spacing: 8) {
                    Text("Can't scan? Enter this code manually:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Text(formattedSecret)
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                        Button {
                            UIPasteboard.general.string = secret
                            withAnimation { showCopied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { showCopied = false }
                            }
                        } label: {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .foregroundColor(showCopied ? .green : .blue)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(10)

                    if showCopied {
                        Text("Copied!")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                }

                // Continue button
                Button {
                    withAnimation { step = .verify }
                } label: {
                    Text("I've Scanned the Code")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
    }

    // ─────────────────────────────────────────────
    // MARK: Step 2 — Verify Code
    // ─────────────────────────────────────────────

    private var verifyView: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "lock.badge.clock")
                    .font(.system(size: 52))
                    .foregroundColor(.blue)
                Text("Enter the 6-digit code")
                    .font(.title3.bold())
                Text("Enter the current code shown in your authenticator app to confirm setup.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            // Code input
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(14)
                .onChange(of: code) { _, v in
                    code = String(v.filter { $0.isNumber }.prefix(6))
                    errorMessage = nil
                }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Verify button
            Button {
                Task { await verify() }
            } label: {
                HStack(spacing: 10) {
                    if isVerifying { ProgressView().tint(.white) }
                    Text(isVerifying ? "Verifying…" : "Enable Two-Factor Auth")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(code.count == 6 ? Color.blue : Color.gray.opacity(0.4))
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .disabled(code.count < 6 || isVerifying)
            .padding(.horizontal, 24)

            Button("Back — re-scan QR") {
                withAnimation { step = .scan }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 24)
        .background(Color(.systemGroupedBackground))
    }

    // ─────────────────────────────────────────────
    // MARK: Step 3 — Done
    // ─────────────────────────────────────────────

    private var doneView: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 100, height: 100)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                }

                Text("Two-Factor Auth Enabled!")
                    .font(.title2.bold())

                Text("Your account is now protected with an authenticator app. You'll be asked for a code each time you sign in.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Button {
                onEnabled()
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Color(.systemGroupedBackground))
    }

    // ─────────────────────────────────────────────
    // MARK: Helpers
    // ─────────────────────────────────────────────

    private var formattedSecret: String {
        // Split into groups of 4 for readability: ABCD EFGH IJKL …
        stride(from: 0, to: secret.count, by: 4).map { i -> String in
            let start = secret.index(secret.startIndex, offsetBy: i)
            let end   = secret.index(start, offsetBy: min(4, secret.count - i))
            return String(secret[start..<end])
        }.joined(separator: " ")
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter  = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func startSetup() async {
        do {
            let result = try await APIService.shared.totpSetup()
            secret = result.secret
            uri    = result.uri
            withAnimation { step = .scan }
        } catch {
            errorMessage = error.localizedDescription
            // Dismiss on failure — can't proceed without a secret
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { dismiss() }
        }
    }

    private func verify() async {
        isVerifying = true
        defer { isVerifying = false }
        do {
            try await APIService.shared.totpEnable(code: code)
            withAnimation { step = .done }
        } catch {
            errorMessage = "Incorrect code. Please check your authenticator app and try again."
        }
    }
}

// MARK: - TOTPChallengeView

/// Presented on the sign-in screen when the server responds with `totp_required`.
struct TOTPChallengeView: View {
    let email: String
    let password: String
    let onSuccess: (String, String, String) -> Void  // token, email, name

    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 88, height: 88)
                        Image(systemName: "lock.badge.clock.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.blue)
                    }
                    Text("Two-Factor Authentication")
                        .font(.title3.bold())
                    Text("Enter the 6-digit code from your authenticator app.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Code input
                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    .onChange(of: code) { _, v in
                        code = String(v.filter { $0.isNumber }.prefix(6))
                        errorMessage = nil
                    }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button {
                    Task { await verify() }
                } label: {
                    HStack(spacing: 10) {
                        if isLoading { ProgressView().tint(.white) }
                        Text(isLoading ? "Signing In…" : "Sign In")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(code.count == 6 ? Color.blue : Color.gray.opacity(0.4))
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(code.count < 6 || isLoading)
                .padding(.horizontal, 24)

                Spacer()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Authenticator Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func verify() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await APIService.shared.login(email: email, password: password, totpCode: code)
            if let token = resp.access_token {
                onSuccess(token, resp.email ?? email, resp.name ?? "")
            } else {
                errorMessage = "Sign-in failed. Please try again."
            }
        } catch {
            errorMessage = "Invalid code. Please check your authenticator app and try again."
        }
    }
}

// MARK: - TOTPDisableView

/// Confirms current TOTP code before disabling 2FA.
struct TOTPDisableView: View {
    let onDisabled: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "lock.open.trianglebadge.exclamationmark.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.orange)
                    Text("Disable Two-Factor Auth")
                        .font(.title3.bold())
                    Text("Enter the current code from your authenticator app to confirm you want to disable 2FA.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                    .onChange(of: code) { _, v in
                        code = String(v.filter { $0.isNumber }.prefix(6))
                        errorMessage = nil
                    }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button(role: .destructive) {
                    Task { await disable() }
                } label: {
                    HStack(spacing: 10) {
                        if isLoading { ProgressView().tint(.white) }
                        Text(isLoading ? "Disabling…" : "Disable Two-Factor Auth")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(code.count == 6 ? Color.red : Color.gray.opacity(0.4))
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(code.count < 6 || isLoading)
                .padding(.horizontal, 24)

                Spacer()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Disable 2FA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func disable() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await APIService.shared.totpDisable(code: code)
            onDisabled()
            dismiss()
        } catch {
            errorMessage = "Incorrect code. Check your authenticator app and try again."
        }
    }
}
