import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @AppStorage("isSignedIn")       private var isSignedIn      = false
    @AppStorage("profile_name")     private var profileName     = ""
    @AppStorage("profile_email")    private var profileEmail    = ""
    @AppStorage("profile_nickname") private var profileNickname = ""

    @State private var isLoading     = false
    @State private var showGoogleInfo = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(hex: "0F0F1A"), Color(hex: "1a1a2e"), Color(hex: "16213e")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Logo ──────────────────────────────────────────────────
                VStack(spacing: 16) {
                    LVMonogram(size: 90)
                    Text("LedgerVault")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Track · Protect · Grow")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                        .tracking(2)
                }

                Spacer()

                // ── Buttons ───────────────────────────────────────────────
                VStack(spacing: 14) {

                    // ── Google (shows setup instructions) ─────────────────
                    Button {
                        showGoogleInfo = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(.white).frame(width: 28, height: 28)
                                Text("G")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.red, .orange, .yellow, .green, .blue],
                                            startPoint: .leading, endPoint: .trailing
                                        )
                                    )
                            }
                            Text("Continue with Google")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.black)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.white)
                        .cornerRadius(14)
                        .shadow(color: .black.opacity(0.2), radius: 8)
                    }

                    // ── Apple Sign In (real native implementation) ─────────
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 50)
                    .cornerRadius(14)

                    // ── Guest ─────────────────────────────────────────────
                    Button {
                        isSignedIn = true
                    } label: {
                        Text("Continue without signing in")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                            .underline()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 60)
            }

            if isLoading {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView().tint(.white).scaleEffect(1.5)
            }
        }
        // Google setup instructions
        .alert("Google Sign-In Setup Required", isPresented: $showGoogleInfo) {
            Button("Use Guest Mode") { isSignedIn = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Google Sign-In requires a Google Cloud project and the GoogleSignIn-iOS SDK. Instructions are in SignInView.swift. For now, use Apple Sign-In or Continue without signing in.")
        }
    }

    // MARK: - Apple Sign In Handler

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            if let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                // Save name (only provided on first sign-in)
                if let fullName = credential.fullName {
                    let givenName  = fullName.givenName  ?? ""
                    let familyName = fullName.familyName ?? ""
                    let combined   = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
                    if !combined.isEmpty {
                        profileName = combined
                        // Auto-generate nickname
                        let parts = combined.split(separator: " ")
                        if let first = parts.first {
                            let suffixes = ["_vault", "_fx", "_trade", "_hq"]
                            let suffix = suffixes[abs(combined.hashValue) % suffixes.count]
                            profileNickname = "\(first.lowercased())\(suffix)"
                        }
                    }
                }
                if let email = credential.email {
                    profileEmail = email
                }
                isSignedIn = true
            }
        case .failure(let error):
            // User cancelled — don't show error
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                print("Apple Sign-In error: \(error)")
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
