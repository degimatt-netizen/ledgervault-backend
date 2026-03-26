import SwiftUI
import PhotosUI
import LocalAuthentication
import UserNotifications

struct OnboardingView: View {

    // Persisted profile fields (same keys as ProfileView)
    @AppStorage("onboardingComplete")    private var onboardingComplete = false
    @AppStorage("onboardingCompletedFor")private var onboardingFor      = ""
    @AppStorage("profile_name")          private var profileName        = ""
    @AppStorage("profile_email")         private var profileEmail       = ""
    @AppStorage("profile_phone")         private var profilePhone       = ""
    @AppStorage("profile_dob")           private var profileDob         = ""
    @AppStorage("profile_dial_id")       private var dialId             = "MT"
    @AppStorage("baseCurrency")          private var baseCurrency       = "EUR"

    @AppStorage("requiresAuth")          private var requiresAuth   = false
    @AppStorage("useBiometrics")         private var useBiometrics  = false

    @State private var step           = 0
    @State private var selectedPhoto  : PhotosPickerItem?
    @State private var pickedImage    : UIImage?
    @State private var dob            = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    @State private var phoneNumber    = ""
    @State private var showDobSheet   = false
    @State private var showDialPicker = false
    @State private var dialSearch     = ""
    @State private var dobError       = false
    @State private var phoneError     = false

    // Security step
    @State private var biometryType   : LABiometryType = .none
    @State private var faceIDEnabled  = false
    @State private var authEnabled    = false

    // Notifications step
    @State private var notifStatus    : UNAuthorizationStatus = .notDetermined
    @State private var notifGranted   = false

    private let totalSteps = 5

    private let currencies = [
        "EUR","USD","GBP","CHF","CAD","AUD","JPY",
        "PLN","SEK","NOK","SGD","HKD","DKK","NZD","TRY"
    ]

    private var firstName: String {
        profileName.split(separator: " ").first.map(String.init) ?? profileName
    }
    private var avatarImage: UIImage? {
        guard let data = UserDefaults.standard.data(forKey: "profile_avatar") else { return nil }
        return UIImage(data: data)
    }
    private var selectedDial: Country {
        countries.first { $0.id == dialId } ?? countries.first { $0.id == "MT" }!
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0F0F1A"), Color(hex: "1a1a2e"), Color(hex: "16213e")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Progress indicator ────────────────────────────────────
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps) { i in
                        Capsule()
                            .fill(i <= step ? Color.white : Color.white.opacity(0.18))
                            .frame(width: i == step ? 28 : 8, height: 6)
                            .animation(.spring(response: 0.4), value: step)
                    }
                }
                .padding(.top, 60)
                .padding(.bottom, 36)

                // ── Step content ──────────────────────────────────────────
                Group {
                    switch step {
                    case 0:  photoStep
                    case 1:  personalStep
                    case 2:  currencyStep
                    case 3:  securityStep
                    default: notificationsStep
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
                .id(step)

                Spacer()

                // ── Bottom buttons ────────────────────────────────────────
                VStack(spacing: 14) {
                    Button { nextStep() } label: {
                        Text(step < totalSteps - 1 ? "Continue" : "Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.white)
                            .foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if step > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) { step -= 1 }
                        } label: {
                            Text("Back")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.35))
                        }
                    } else {
                        // Spacer so layout doesn't jump when Back appears
                        Color.clear.frame(height: 22)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
        }
        .sheet(isPresented: $showDobSheet) { dobPickerSheet }
        .sheet(isPresented: $showDialPicker) {
            CountryPickerSheet(search: $dialSearch, selectedId: $dialId, title: "Phone Prefix")
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Step 1 — Profile Photo
    // ─────────────────────────────────────────────

    private var photoStep: some View {
        VStack(spacing: 32) {

            VStack(spacing: 10) {
                Text("Welcome\(firstName.isEmpty ? "" : ", \(firstName)")!")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Let's set up your profile.\nYour photo is completely optional.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 28)

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    // Avatar
                    if let img = pickedImage ?? avatarImage {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 130, height: 130)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 2))
                    } else {
                        let initials: String = {
                            let parts = profileName.split(separator: " ")
                            return parts.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
                        }()
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 130, height: 130)
                            .overlay(
                                VStack(spacing: 6) {
                                    if initials.isEmpty {
                                        Image(systemName: "camera.fill")
                                            .font(.title)
                                            .foregroundColor(.white.opacity(0.4))
                                        Text("Add Photo")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.35))
                                    } else {
                                        Text(initials)
                                            .font(.system(size: 42, weight: .bold))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                            )
                    }

                    // Camera badge
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 36, height: 36)
                        .overlay(Image(systemName: "camera.fill").font(.caption).foregroundColor(.white))
                        .offset(x: 2, y: 2)
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        await MainActor.run {
                            pickedImage = img
                            UserDefaults.standard.set(data, forKey: "profile_avatar")
                        }
                    }
                }
            }

            if avatarImage != nil {
                Label("Photo added", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.green.opacity(0.85))
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text("You can always add one later in Profile")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Step 2 — Personal Info
    // ─────────────────────────────────────────────

    private var personalStep: some View {
        VStack(spacing: 24) {

            VStack(spacing: 10) {
                Text("A bit about you")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Both fields are required to continue.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                // ── Date of Birth ──────────────────────────────────────
                Button { showDobSheet = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "calendar")
                            .foregroundColor(dobError ? .red.opacity(0.8) : .white.opacity(0.35))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text("Date of Birth")
                                    .font(.caption)
                                    .foregroundColor(dobError ? .red.opacity(0.7) : .white.opacity(0.4))
                                if dobError {
                                    Text("Required")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.red.opacity(0.8))
                                }
                            }
                            Text(profileDob.isEmpty ? "Tap to select" : profileDob)
                                .font(.subheadline)
                                .foregroundColor(profileDob.isEmpty ? .white.opacity(0.25) : .white)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 15)
                    .background(dobError ? Color.red.opacity(0.1) : Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                dobError ? Color.red.opacity(0.5) :
                                !profileDob.isEmpty ? Color.blue.opacity(0.4) : Color.clear,
                                lineWidth: 1.5
                            )
                    )
                }
                .onChange(of: profileDob) { _, v in if !v.isEmpty { dobError = false } }

                // ── Mobile Number ──────────────────────────────────────
                HStack(spacing: 14) {
                    Image(systemName: "phone.fill")
                        .foregroundColor(phoneError ? .red.opacity(0.8) : .white.opacity(0.35))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("Mobile Number")
                                .font(.caption)
                                .foregroundColor(phoneError ? .red.opacity(0.7) : .white.opacity(0.4))
                            if phoneError {
                                Text("Required")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.red.opacity(0.8))
                            }
                        }
                        HStack(spacing: 8) {
                            Button {
                                dialSearch = ""
                                showDialPicker = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(selectedDial.flag)
                                    Text(selectedDial.dialCode)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.white)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.white.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            TextField("Mobile number", text: $phoneNumber)
                                .keyboardType(.phonePad)
                                .foregroundColor(.white)
                                .onChange(of: phoneNumber) { _, v in if !v.isEmpty { phoneError = false } }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 15)
                .background(phoneError ? Color.red.opacity(0.1) : Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            phoneError ? Color.red.opacity(0.5) :
                            !phoneNumber.isEmpty ? Color.blue.opacity(0.4) : Color.clear,
                            lineWidth: 1.5
                        )
                )
            }
            .padding(.horizontal, 28)
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Step 3 — Currency
    // ─────────────────────────────────────────────

    private var currencyStep: some View {
        VStack(spacing: 24) {

            VStack(spacing: 10) {
                Text("Your main currency")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Your portfolio will be shown in this currency. You can change it anytime.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                ForEach(currencies, id: \.self) { cur in
                    Button { baseCurrency = cur } label: {
                        Text(cur)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(baseCurrency == cur
                                        ? Color.white
                                        : Color.white.opacity(0.07))
                            .foregroundColor(baseCurrency == cur ? .black : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        baseCurrency == cur
                                            ? Color.clear
                                            : Color.white.opacity(0.1),
                                        lineWidth: 1
                                    )
                            )
                            .scaleEffect(baseCurrency == cur ? 1.04 : 1.0)
                            .animation(.spring(response: 0.2), value: baseCurrency)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
    }

    // ─────────────────────────────────────────────
    // MARK: DOB Picker Sheet
    // ─────────────────────────────────────────────

    private var dobPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                DatePicker("", selection: $dob, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                Button {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "dd/MM/yyyy"
                    profileDob = fmt.string(from: dob)
                    showDobSheet = false
                } label: {
                    Text("Confirm")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)
            }
            .padding(.top, 8)
            .navigationTitle("Date of Birth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showDobSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // ─────────────────────────────────────────────
    // MARK: Navigation
    // ─────────────────────────────────────────────

    private func nextStep() {
        if step == 1 {
            dobError   = profileDob.trimmingCharacters(in: .whitespaces).isEmpty
            phoneError = phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty
            guard !dobError && !phoneError else { return }
            profilePhone = phoneNumber
            Task { try? await APIService.shared.updateProfile(phone: phoneNumber) }
        }
        if step < totalSteps - 1 {
            withAnimation(.easeInOut(duration: 0.3)) { step += 1 }
            if step == 3 { checkBiometry() }
            if step == 4 { checkNotifStatus() }
        } else {
            AppSettings.shared.baseCurrency = baseCurrency
            onboardingFor = profileEmail
            onboardingComplete = true
        }
    }

    private func checkBiometry() {
        let ctx = LAContext(); var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            biometryType = ctx.biometryType
        }
    }

    private func checkNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notifStatus = s.authorizationStatus }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Step 4 — Security
    // ─────────────────────────────────────────────

    private var securityStep: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 80, height: 80)
                    Image(systemName: biometryType == .faceID ? "faceid" : "touchid")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.9))
                }
                Text("Secure your account")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Enable app lock so only you can access your financial data.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                // Enable authentication toggle
                HStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require Authentication")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                        Text("Lock the app when it goes to the background")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.45))
                    }
                    Spacer()
                    Toggle("", isOn: $authEnabled)
                        .labelsHidden()
                        .onChange(of: authEnabled) { _, on in
                            requiresAuth = on
                            if on { authenticateToEnable() }
                        }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                // Face ID / Touch ID toggle (only if auth enabled + biometrics available)
                if authEnabled && biometryType != .none {
                    HStack(spacing: 14) {
                        Image(systemName: biometryType == .faceID ? "faceid" : "touchid")
                            .foregroundColor(.blue.opacity(0.9))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(biometryType == .faceID ? "Face ID" : "Touch ID")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white)
                            Text("Use biometrics instead of device passcode")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Toggle("", isOn: $faceIDEnabled)
                            .labelsHidden()
                            .onChange(of: faceIDEnabled) { _, on in useBiometrics = on }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 28)
            .animation(.easeInOut(duration: 0.2), value: authEnabled)

            if !authEnabled {
                Text("You can enable this later in More → Security")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    private func authenticateToEnable() {
        let ctx = LAContext(); var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Confirm to enable app lock") { success, _ in
            DispatchQueue.main.async {
                if !success { authEnabled = false; requiresAuth = false }
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Step 5 — Notifications
    // ─────────────────────────────────────────────

    private var notificationsStep: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 80, height: 80)
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.9))
                }
                Text("Stay informed")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Get notified when your price alerts trigger or weekly portfolio summaries are ready.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                if notifGranted || notifStatus == .authorized {
                    // Already granted
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("Notifications enabled!")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.3), lineWidth: 1))
                } else {
                    Button {
                        requestNotifications()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bell.fill")
                                .font(.title3)
                            Text("Allow Notifications")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if notifStatus == .denied {
                        Text("Notifications are blocked. Enable them in Settings → LedgerVault.")
                            .font(.caption)
                            .foregroundColor(.orange.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.horizontal, 28)
            .animation(.easeInOut(duration: 0.3), value: notifGranted)

            Text("You can manage this anytime in your device Settings.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                notifGranted = granted
                notifStatus  = granted ? .authorized : .denied
            }
        }
    }
}
