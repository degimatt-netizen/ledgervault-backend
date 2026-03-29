import SwiftUI
import AuthenticationServices
import Security
import CryptoKit

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.ledgervault.app"

    static func save(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData:   data
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Google OAuth presentation helper

private class WebAuthPresentationDelegate: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// MARK: - Apple Sign In Coordinator (programmatic — no opacity hack)

private class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    var onResult: (Result<ASAuthorization, Error>) -> Void

    init(onResult: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.onResult = onResult
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        onResult(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        onResult(.failure(error))
    }
}

// MARK: - SignInView

struct SignInView: View {
    @AppStorage("isSignedIn")       private var isSignedIn      = false
    @AppStorage("profile_name")     private var profileName     = ""
    @AppStorage("profile_email")    private var profileEmail    = ""
    @AppStorage("profile_nickname") private var profileNickname = ""
    @AppStorage("profile_user_id")  private var profileUserId   = ""

    private enum Tab: Hashable { case signIn, signUp }
    private enum F            { case name, email, password, confirm }

    @State private var tab            : Tab    = .signIn
    @State private var pendingEmail   : String = ""   // non-empty → show verify screen
    @State private var name           : String = ""
    @State private var email          : String = ""
    @State private var password       : String = ""
    @State private var confirm        : String = ""
    @State private var errorMsg       : String?
    @State private var isLoading      : Bool   = false
    @FocusState private var focus     : F?

    @State private var showPassword       = false
    @State private var showConfirm        = false
    @State private var showForgotPassword = false
    @State private var prefillResetEmail  = ""

    // TOTP challenge (shown when server returns totp_required)
    @State private var showTotpChallenge    = false
    @State private var totpChallengeEmail   = ""
    @State private var totpChallengePassword = ""

    @State private var googleSession: ASWebAuthenticationSession?
    @State private var googleDelegate  = WebAuthPresentationDelegate()
    @State private var appleCoordinator: AppleSignInCoordinator?
    @State private var appeared = false

    @Namespace private var tabIndicator

    private let googleClientID = "334683680543-bg2o8tmg96ul9rmo1h9bti188ql4phis.apps.googleusercontent.com"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if pendingEmail.isEmpty {
                authScrollView
            } else {
                VerifyEmailView(
                    email: pendingEmail,
                    onSuccess: { token, userEmail, userName in
                        finishSignIn(token: token, email: userEmail, name: userName ?? "")
                    },
                    onBack: {
                        withAnimation { pendingEmail = "" }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: pendingEmail.isEmpty)
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordSheet(prefillEmail: prefillResetEmail) { token, userEmail, userName in
                finishSignIn(token: token, email: userEmail, name: userName ?? "")
            }
        }
        .sheet(isPresented: $showTotpChallenge) {
            TOTPChallengeView(
                email: totpChallengeEmail,
                password: totpChallengePassword
            ) { token, userEmail, userName in
                showTotpChallenge = false
                finishSignIn(token: token, email: userEmail, name: userName)
            }
        }
    }

    // MARK: - Auth scroll view

    private var authScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {

                // ── Logo ──────────────────────────────────────────────
                VStack(spacing: 14) {
                    LVWordmark(shieldSize: 52)
                        .shadow(color: LVBrand.navy.opacity(0.6), radius: 24, x: 0, y: 4)
                    Text("Private. Complete. Calm.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.40))
                        .tracking(0.3)
                }
                .padding(.top, 64)
                .padding(.bottom, 32)

                // ── Tab picker — sliding underline ────────────────────
                VStack(spacing: 0) {
                    // Labels row
                    HStack(spacing: 0) {
                        ForEach([Tab.signIn, .signUp], id: \.self) { t in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    tab = t; errorMsg = nil
                                }
                            } label: {
                                Text(t == .signIn ? "Sign In" : "Sign Up")
                                    .font(.system(size: 14,
                                                  weight: tab == t ? .semibold : .regular))
                                    .foregroundColor(tab == t ? .white : .white.opacity(0.35))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Sliding blue indicator — offset moves it left/right
                    HStack(spacing: 0) {
                        if tab == .signUp {
                            Spacer().frame(maxWidth: .infinity)
                        }
                        Rectangle()
                            .fill(Color(hex: "0A84FF"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 2)
                            .cornerRadius(1)
                        if tab == .signIn {
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: tab)

                    // Full-width hairline
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 22)

                // ── Form ──────────────────────────────────────────────
                VStack(spacing: 14) {
                    if tab == .signUp {
                        inputField(
                            icon: "person.fill", placeholder: "Full Name",
                            text: $name, field: .name
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    inputField(
                        icon: "envelope.fill", placeholder: "Email",
                        text: $email, field: .email, keyboard: .emailAddress
                    )
                    inputField(
                        icon: "lock.fill", placeholder: "Password",
                        text: $password, field: .password, isSecure: true, showSecure: $showPassword
                    )

                    if tab == .signIn {
                        Button {
                            prefillResetEmail = email
                            showForgotPassword = true
                        } label: {
                            Text("Forgot password?")
                                .font(.caption.weight(.medium))
                                .foregroundColor(Color(hex: "0A84FF"))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.top, -6)
                    }

                    if tab == .signUp {
                        inputField(
                            icon: "lock.fill", placeholder: "Confirm Password",
                            text: $confirm, field: .confirm, isSecure: true, showSecure: $showConfirm
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let msg = errorMsg {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    // ── Primary CTA — blue ─────────────────────────────
                    Button {
                        tab == .signIn ? signIn() : signUp()
                    } label: {
                        Group {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text(tab == .signIn ? "Sign In" : "Create Account")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(hex: "0A84FF"))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .disabled(isLoading)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 28)
                .animation(.easeInOut(duration: 0.22), value: tab)

                // ── Divider ───────────────────────────────────────────
                HStack(spacing: 12) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    Text("or")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white.opacity(0.25))
                        .fixedSize()
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 18)

                // ── Social icon buttons — Apple + Google ─────────────
                HStack(spacing: 14) {
                    // Apple — fully custom button, uses ASAuthorizationController directly
                    Button { triggerAppleSignIn() } label: {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(hex: "141414"))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .overlay(
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white)
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .disabled(isLoading)

                    // Google — white with Google G
                    Button { signInWithGoogle() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                )
                            Text("G")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color(hex: "4285F4"), Color(hex: "EA4335"),
                                                 Color(hex: "FBBC05"), Color(hex: "34A853")],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .disabled(isLoading)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 52)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Input field

    @ViewBuilder
    private func inputField(
        icon: String, placeholder: String,
        text: Binding<String>, field: F,
        keyboard: UIKeyboardType = .default,
        isSecure: Bool = false,
        showSecure: Binding<Bool>? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 20)

            Group {
                if isSecure && !(showSecure?.wrappedValue ?? false) {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        .keyboardType(keyboard)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(
                            isSecure || keyboard == .emailAddress ? .never : .words
                        )
                }
            }
            .foregroundColor(.white)
            .focused($focus, equals: field)
            .submitLabel(submitLabel(for: field))
            .onSubmit { advanceFocus(from: field) }

            if isSecure, let show = showSecure {
                Button { show.wrappedValue.toggle() } label: {
                    Image(systemName: show.wrappedValue ? "eye.slash.fill" : "eye.fill")
                        .foregroundColor(.white.opacity(0.35))
                        .frame(width: 20)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(Color(hex: "111111"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    focus == field
                        ? Color(hex: "0A84FF").opacity(0.75)
                        : Color.white.opacity(0.09),
                    lineWidth: focus == field ? 1.5 : 1
                )
        )
        .shadow(color: focus == field ? Color(hex: "0A84FF").opacity(0.15) : .clear,
                radius: 8, x: 0, y: 0)
    }

    private func submitLabel(for field: F) -> SubmitLabel {
        switch field {
        case .confirm:                           return .done
        case .password where tab == .signIn:     return .go
        default:                                 return .next
        }
    }

    private func advanceFocus(from field: F) {
        switch field {
        case .name:     focus = .email
        case .email:    focus = .password
        case .password: tab == .signIn ? signIn() : (focus = .confirm)
        case .confirm:  signUp()
        }
    }

    // MARK: - Auth logic

    private func signIn() {
        errorMsg = nil
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !e.isEmpty, !password.isEmpty else {
            errorMsg = "Please fill in all fields."; return
        }
        isLoading = true
        Task {
            do {
                let resp = try await APIService.shared.login(email: e, password: password)
                await MainActor.run {
                    isLoading = false
                    if resp.status == "needs_verification" {
                        withAnimation { pendingEmail = e }
                    } else if resp.status == "totp_required" || resp.totp_required == true {
                        // Server requires TOTP — show challenge sheet
                        totpChallengeEmail    = e
                        totpChallengePassword = password
                        showTotpChallenge     = true
                    } else if let token = resp.access_token {
                        finishSignIn(token: token, email: resp.email ?? e, name: resp.name ?? "",
                                     userId: resp.user_id ?? "")
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? error.localizedDescription
                }
            }
        }
    }

    private func signUp() {
        errorMsg = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n.isEmpty              else { errorMsg = "Please enter your name."; return }
        guard e.contains("@"), e.contains(".") else { errorMsg = "Enter a valid email."; return }
        guard password.count >= 6    else { errorMsg = "Password must be at least 6 characters."; return }
        guard password == confirm    else { errorMsg = "Passwords don't match."; return }
        isLoading = true
        Task {
            do {
                let resp = try await APIService.shared.register(name: n, email: e, password: password)
                await MainActor.run {
                    isLoading = false
                    if resp.status == "needs_verification" {
                        withAnimation { pendingEmail = e }
                    } else if let token = resp.access_token {
                        finishSignIn(token: token, email: resp.email ?? e, name: resp.name ?? n,
                                     userId: resp.user_id ?? "")
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    let raw = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? error.localizedDescription
                    if raw.lowercased().contains("already registered") || raw.lowercased().contains("already exists") {
                        errorMsg = "An account with this email already exists. Please Sign In instead."
                    } else {
                        errorMsg = raw
                    }
                }
            }
        }
    }

    private func finishSignIn(token: String, email: String, name: String, userId: String = "") {
        KeychainHelper.save(token, account: "auth_token")
        profileEmail = email
        profileName  = name.isEmpty ? profileName : name
        if !userId.isEmpty { profileUserId = userId }
        if !name.isEmpty, profileNickname.isEmpty {
            if let first = name.split(separator: " ").first {
                let suffixes = ["_vault", "_fx", "_trade", "_hq"]
                profileNickname = "\(first.lowercased())\(suffixes[abs(name.hashValue) % suffixes.count])"
            }
        }
        isSignedIn = true
    }

    // MARK: - Apple Sign In

    private func triggerAppleSignIn() {
        let coordinator = AppleSignInCoordinator { result in
            handleAppleSignIn(result)
        }
        appleCoordinator = coordinator   // retain so it isn't deallocated

        let provider = ASAuthorizationAppleIDProvider()
        let request  = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate                    = coordinator
        controller.presentationContextProvider = coordinator
        controller.performRequests()
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            var fullName = ""
            if let fn = credential.fullName {
                fullName = [fn.givenName, fn.familyName]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
            let cachedName = fullName.isEmpty
                ? (KeychainHelper.read(account: "apple_name:\(credential.user)") ?? "")
                : fullName
            if !fullName.isEmpty {
                KeychainHelper.save(fullName, account: "apple_name:\(credential.user)")
            }
            let cachedEmail = credential.email
                ?? KeychainHelper.read(account: "apple_email:\(credential.user)")
                ?? ""
            if let e = credential.email {
                KeychainHelper.save(e, account: "apple_email:\(credential.user)")
            }
            guard !cachedEmail.isEmpty else {
                errorMsg = "Could not get email from Apple. Try signing in again."; return
            }
            isLoading = true
            Task {
                do {
                    let resp = try await APIService.shared.socialAuth(
                        provider: "apple", email: cachedEmail, name: cachedName,
                        appleUserID: credential.user)
                    await MainActor.run {
                        isLoading = false
                        if let token = resp.access_token {
                            if tab == .signUp && resp.is_new_user == false {
                                errorMsg = "An account with this Apple ID already exists. Please use Sign In."
                            } else {
                                finishSignIn(token: token, email: resp.email ?? cachedEmail, name: resp.name ?? cachedName,
                                             userId: resp.user_id ?? "")
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        isLoading = false
                        errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                            ?? error.localizedDescription
                    }
                }
            }
        case .failure(let err):
            if (err as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMsg = err.localizedDescription
            }
        }
    }

    // MARK: - Google Sign In

    private func signInWithGoogle() {
        guard !googleClientID.isEmpty else { return }
        let parts = googleClientID
            .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        let callbackScheme = "com.googleusercontent.apps.\(parts)"
        let redirectURI    = "\(callbackScheme):/oauth2redirect/google"

        // PKCE
        let verifierData = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let codeVerifier = verifierData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let challengeData = Data(SHA256.hash(data: Data(codeVerifier.utf8)))
        let codeChallenge = challengeData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: googleClientID),
            URLQueryItem(name: "redirect_uri",           value: redirectURI),
            URLQueryItem(name: "response_type",          value: "code"),
            URLQueryItem(name: "scope",                  value: "openid email profile"),
            URLQueryItem(name: "code_challenge",         value: codeChallenge),
            URLQueryItem(name: "code_challenge_method",  value: "S256"),
        ]
        guard let authURL = comps.url else { return }

        isLoading = true
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            DispatchQueue.main.async {
                if let error {
                    isLoading = false
                    if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        errorMsg = error.localizedDescription
                    }
                    return
                }
                guard let callbackURL,
                      let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                    isLoading = false
                    errorMsg = "Google sign-in failed — no code received."
                    return
                }
                exchangeGoogleCode(code: code, verifier: codeVerifier,
                                   redirectURI: redirectURI, clientID: googleClientID)
            }
        }
        session.presentationContextProvider = googleDelegate
        session.prefersEphemeralWebBrowserSession = false
        googleSession = session
        session.start()
    }

    private func exchangeGoogleCode(code: String, verifier: String, redirectURI: String, clientID: String) {
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let body = [
                    "code": code, "client_id": clientID,
                    "redirect_uri": redirectURI, "code_verifier": verifier,
                    "grant_type": "authorization_code"
                ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
                 .joined(separator: "&")
                req.httpBody = body.data(using: .utf8)
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["access_token"] as? String else {
                    await MainActor.run { isLoading = false; errorMsg = "Google sign-in failed — token exchange error." }
                    return
                }
                await fetchGoogleProfile(accessToken: accessToken)
            } catch {
                await MainActor.run { isLoading = false; errorMsg = error.localizedDescription }
            }
        }
    }

    private func fetchGoogleProfile(accessToken: String) async {
        do {
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/userinfo/v2/me")!)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await MainActor.run { isLoading = false; errorMsg = "Couldn't read Google profile." }
                return
            }
            let googleEmail = json["email"] as? String ?? ""
            let googleName  = json["name"]  as? String ?? ""
            let googleSub   = json["id"]    as? String ?? ""
            let resp = try await APIService.shared.socialAuth(
                provider: "google", email: googleEmail, name: googleName, googleSub: googleSub)
            await MainActor.run {
                isLoading = false
                if let token = resp.access_token {
                    if tab == .signUp && resp.is_new_user == false {
                        errorMsg = "An account with this Google account already exists. Please use Sign In."
                    } else {
                        finishSignIn(token: token, email: resp.email ?? googleEmail, name: resp.name ?? googleName,
                                     userId: resp.user_id ?? "")
                    }
                }
            }
        } catch {
            await MainActor.run { isLoading = false; errorMsg = error.localizedDescription }
        }
    }
}

// MARK: - Press Scale Button Style

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Verify Email View

struct VerifyEmailView: View {
    let email: String
    let onSuccess: (String, String, String?) -> Void
    let onBack: () -> Void

    @State private var code      : String = ""
    @State private var errorMsg  : String?
    @State private var isLoading : Bool   = false
    @State private var resendMsg : String?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer().frame(height: 40)

                VStack(spacing: 12) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.white.opacity(0.75))

                    Text("Verify your email")
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    VStack(spacing: 4) {
                        Text("We sent a 6-digit code to")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                        Text(email)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }

                VStack(spacing: 12) {
                    // OTP input
                    HStack(spacing: 12) {
                        Image(systemName: "number.circle.fill")
                            .foregroundColor(.white.opacity(0.35))
                            .frame(width: 20)
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .foregroundColor(.white)
                            .onChange(of: code) { _, v in
                                code = String(v.filter { $0.isNumber }.prefix(6))
                            }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if let msg = errorMsg {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    if let msg = resendMsg {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.green.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    Button { verify() } label: {
                        Group {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Verify Email")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            Color(hex: "0A84FF")
                                .opacity(code.count == 6 ? 1.0 : 0.35)
                        )
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .disabled(isLoading || code.count != 6)
                }
                .padding(.horizontal, 28)

                // Resend
                Button { resend() } label: {
                    Text("Resend code")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.4))
                        .underline()
                }

                Button { onBack() } label: {
                    Text("Back")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.3))
                }

                Spacer()
            }
        }
    }

    private func verify() {
        guard code.count == 6 else { return }
        isLoading = true; errorMsg = nil
        Task {
            do {
                let resp = try await APIService.shared.verifyEmail(email: email, code: code)
                await MainActor.run {
                    isLoading = false
                    if let token = resp.access_token {
                        onSuccess(token, resp.email ?? email, resp.name)
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? error.localizedDescription
                }
            }
        }
    }

    private func resend() {
        Task {
            do {
                _ = try await APIService.shared.resendCode(email: email)
                await MainActor.run { resendMsg = "New code sent!"; errorMsg = nil }
            } catch {
                await MainActor.run {
                    resendMsg = nil
                    errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Forgot Password Sheet

struct ForgotPasswordSheet: View {
    let prefillEmail: String
    let onSuccess: (String, String, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Stage { case email, resetCode }

    @State private var stage       : Stage  = .email
    @State private var email       : String = ""
    @State private var code        : String = ""
    @State private var newPassword : String = ""
    @State private var confirmPw   : String = ""
    @State private var errorMsg    : String?
    @State private var isLoading   : Bool   = false
    @State private var showNewPw   : Bool   = false
    @State private var showConfirmPw: Bool  = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 40, height: 4)
                    .padding(.top, 12)

                Image(systemName: stage == .email ? "lock.rotation" : "key.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white.opacity(0.7))

                VStack(spacing: 8) {
                    Text(stage == .email ? "Reset Password" : "Enter Reset Code")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text(stage == .email
                         ? "Enter your email and we'll send you a 6-digit reset code."
                         : "Check your email for the code, then set a new password.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                if stage == .email {
                    emailStage
                } else {
                    resetCodeStage
                }

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .onAppear { email = prefillEmail }
    }

    private var emailStage: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.fill")
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 20)
                TextField("Email address", text: $email)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let msg = errorMsg {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            Button { sendCode() } label: {
                Group {
                    if isLoading { ProgressView().tint(.white) }
                    else         { Text("Send Reset Code").font(.system(size: 17, weight: .bold)) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color(hex: "0A84FF"))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(isLoading)

            Button { dismiss() } label: {
                Text("Cancel")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private var resetCodeStage: some View {
        VStack(spacing: 12) {
            // Code
            HStack(spacing: 12) {
                Image(systemName: "number.circle.fill")
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 20)
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .foregroundColor(.white)
                    .onChange(of: code) { _, v in
                        code = String(v.filter { $0.isNumber }.prefix(6))
                    }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // New password
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 20)
                Group {
                    if showNewPw {
                        TextField("New password", text: $newPassword)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("New password", text: $newPassword)
                    }
                }
                .foregroundColor(.white)
                Button { showNewPw.toggle() } label: {
                    Image(systemName: showNewPw ? "eye.slash.fill" : "eye.fill")
                        .foregroundColor(.white.opacity(0.35))
                        .frame(width: 20)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Confirm password
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 20)
                Group {
                    if showConfirmPw {
                        TextField("Confirm new password", text: $confirmPw)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("Confirm new password", text: $confirmPw)
                    }
                }
                .foregroundColor(.white)
                Button { showConfirmPw.toggle() } label: {
                    Image(systemName: showConfirmPw ? "eye.slash.fill" : "eye.fill")
                        .foregroundColor(.white.opacity(0.35))
                        .frame(width: 20)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let msg = errorMsg {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            Button { resetPassword() } label: {
                Group {
                    if isLoading { ProgressView().tint(.white) }
                    else         { Text("Reset Password").font(.system(size: 17, weight: .bold)) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color(hex: "0A84FF"))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(isLoading)

            Button { withAnimation { stage = .email } } label: {
                Text("Back")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private func sendCode() {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard e.contains("@"), e.contains(".") else {
            errorMsg = "Enter a valid email address."; return
        }
        isLoading = true; errorMsg = nil
        Task {
            do {
                _ = try await APIService.shared.forgotPassword(email: e)
                await MainActor.run {
                    isLoading = false
                    email = e
                    withAnimation { stage = .resetCode }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? error.localizedDescription
                }
            }
        }
    }

    private func resetPassword() {
        guard code.count == 6 else { errorMsg = "Enter the 6-digit code."; return }
        guard newPassword.count >= 6 else { errorMsg = "Password must be at least 6 characters."; return }
        guard newPassword == confirmPw else { errorMsg = "Passwords don't match."; return }
        isLoading = true; errorMsg = nil
        Task {
            do {
                let resp = try await APIService.shared.resetPassword(
                    email: email, code: code, newPassword: newPassword)
                await MainActor.run {
                    isLoading = false
                    if let token = resp.access_token {
                        onSuccess(token, resp.email ?? email, resp.name)
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a,r,g,b) = (255,(int>>8)*17,(int>>4&0xF)*17,(int&0xF)*17)
        case 6: (a,r,g,b) = (255,int>>16,int>>8&0xFF,int&0xFF)
        case 8: (a,r,g,b) = (int>>24,int>>16&0xFF,int>>8&0xFF,int&0xFF)
        default:(a,r,g,b) = (255,0,0,0)
        }
        self.init(.sRGB,
                  red: Double(r)/255, green: Double(g)/255,
                  blue: Double(b)/255, opacity: Double(a)/255)
    }
}
