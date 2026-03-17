import SwiftUI
import PhotosUI

// ── Country data ──────────────────────────────────────────────────────────────
struct Country: Identifiable, Hashable {
    let id: String        // ISO code e.g. "MT"
    let name: String
    let flag: String
    let dialCode: String
}

let countries: [Country] = [
    Country(id:"AF", name:"Afghanistan",          flag:"🇦🇫", dialCode:"+93"),
    Country(id:"AL", name:"Albania",              flag:"🇦🇱", dialCode:"+355"),
    Country(id:"DZ", name:"Algeria",              flag:"🇩🇿", dialCode:"+213"),
    Country(id:"AR", name:"Argentina",            flag:"🇦🇷", dialCode:"+54"),
    Country(id:"AU", name:"Australia",            flag:"🇦🇺", dialCode:"+61"),
    Country(id:"AT", name:"Austria",              flag:"🇦🇹", dialCode:"+43"),
    Country(id:"BE", name:"Belgium",              flag:"🇧🇪", dialCode:"+32"),
    Country(id:"BR", name:"Brazil",               flag:"🇧🇷", dialCode:"+55"),
    Country(id:"BG", name:"Bulgaria",             flag:"🇧🇬", dialCode:"+359"),
    Country(id:"CA", name:"Canada",               flag:"🇨🇦", dialCode:"+1"),
    Country(id:"CN", name:"China",                flag:"🇨🇳", dialCode:"+86"),
    Country(id:"HR", name:"Croatia",              flag:"🇭🇷", dialCode:"+385"),
    Country(id:"CY", name:"Cyprus",               flag:"🇨🇾", dialCode:"+357"),
    Country(id:"CZ", name:"Czech Republic",       flag:"🇨🇿", dialCode:"+420"),
    Country(id:"DK", name:"Denmark",              flag:"🇩🇰", dialCode:"+45"),
    Country(id:"EG", name:"Egypt",                flag:"🇪🇬", dialCode:"+20"),
    Country(id:"FI", name:"Finland",              flag:"🇫🇮", dialCode:"+358"),
    Country(id:"FR", name:"France",               flag:"🇫🇷", dialCode:"+33"),
    Country(id:"DE", name:"Germany",              flag:"🇩🇪", dialCode:"+49"),
    Country(id:"GR", name:"Greece",               flag:"🇬🇷", dialCode:"+30"),
    Country(id:"HK", name:"Hong Kong",            flag:"🇭🇰", dialCode:"+852"),
    Country(id:"HU", name:"Hungary",              flag:"🇭🇺", dialCode:"+36"),
    Country(id:"IN", name:"India",                flag:"🇮🇳", dialCode:"+91"),
    Country(id:"ID", name:"Indonesia",            flag:"🇮🇩", dialCode:"+62"),
    Country(id:"IE", name:"Ireland",              flag:"🇮🇪", dialCode:"+353"),
    Country(id:"IL", name:"Israel",               flag:"🇮🇱", dialCode:"+972"),
    Country(id:"IT", name:"Italy",                flag:"🇮🇹", dialCode:"+39"),
    Country(id:"JP", name:"Japan",                flag:"🇯🇵", dialCode:"+81"),
    Country(id:"JO", name:"Jordan",               flag:"🇯🇴", dialCode:"+962"),
    Country(id:"KE", name:"Kenya",                flag:"🇰🇪", dialCode:"+254"),
    Country(id:"KW", name:"Kuwait",               flag:"🇰🇼", dialCode:"+965"),
    Country(id:"LV", name:"Latvia",               flag:"🇱🇻", dialCode:"+371"),
    Country(id:"LB", name:"Lebanon",              flag:"🇱🇧", dialCode:"+961"),
    Country(id:"LT", name:"Lithuania",            flag:"🇱🇹", dialCode:"+370"),
    Country(id:"LU", name:"Luxembourg",           flag:"🇱🇺", dialCode:"+352"),
    Country(id:"MY", name:"Malaysia",             flag:"🇲🇾", dialCode:"+60"),
    Country(id:"MT", name:"Malta",                flag:"🇲🇹", dialCode:"+356"),
    Country(id:"MX", name:"Mexico",               flag:"🇲🇽", dialCode:"+52"),
    Country(id:"NL", name:"Netherlands",          flag:"🇳🇱", dialCode:"+31"),
    Country(id:"NZ", name:"New Zealand",          flag:"🇳🇿", dialCode:"+64"),
    Country(id:"NG", name:"Nigeria",              flag:"🇳🇬", dialCode:"+234"),
    Country(id:"NO", name:"Norway",               flag:"🇳🇴", dialCode:"+47"),
    Country(id:"OM", name:"Oman",                 flag:"🇴🇲", dialCode:"+968"),
    Country(id:"PK", name:"Pakistan",             flag:"🇵🇰", dialCode:"+92"),
    Country(id:"PH", name:"Philippines",          flag:"🇵🇭", dialCode:"+63"),
    Country(id:"PL", name:"Poland",               flag:"🇵🇱", dialCode:"+48"),
    Country(id:"PT", name:"Portugal",             flag:"🇵🇹", dialCode:"+351"),
    Country(id:"QA", name:"Qatar",                flag:"🇶🇦", dialCode:"+974"),
    Country(id:"RO", name:"Romania",              flag:"🇷🇴", dialCode:"+40"),
    Country(id:"RU", name:"Russia",               flag:"🇷🇺", dialCode:"+7"),
    Country(id:"SA", name:"Saudi Arabia",         flag:"🇸🇦", dialCode:"+966"),
    Country(id:"SG", name:"Singapore",            flag:"🇸🇬", dialCode:"+65"),
    Country(id:"SK", name:"Slovakia",             flag:"🇸🇰", dialCode:"+421"),
    Country(id:"SI", name:"Slovenia",             flag:"🇸🇮", dialCode:"+386"),
    Country(id:"ZA", name:"South Africa",         flag:"🇿🇦", dialCode:"+27"),
    Country(id:"KR", name:"South Korea",          flag:"🇰🇷", dialCode:"+82"),
    Country(id:"ES", name:"Spain",                flag:"🇪🇸", dialCode:"+34"),
    Country(id:"SE", name:"Sweden",               flag:"🇸🇪", dialCode:"+46"),
    Country(id:"CH", name:"Switzerland",          flag:"🇨🇭", dialCode:"+41"),
    Country(id:"TW", name:"Taiwan",               flag:"🇹🇼", dialCode:"+886"),
    Country(id:"TH", name:"Thailand",             flag:"🇹🇭", dialCode:"+66"),
    Country(id:"TR", name:"Turkey",               flag:"🇹🇷", dialCode:"+90"),
    Country(id:"AE", name:"UAE",                  flag:"🇦🇪", dialCode:"+971"),
    Country(id:"GB", name:"United Kingdom",       flag:"🇬🇧", dialCode:"+44"),
    Country(id:"US", name:"United States",        flag:"🇺🇸", dialCode:"+1"),
].sorted { $0.name < $1.name }

// ── Profile View ──────────────────────────────────────────────────────────────
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("profile_name")      private var name      = ""
    @AppStorage("profile_nickname")  private var nickname  = ""
    @AppStorage("profile_email")     private var email     = ""
    @AppStorage("profile_phone")     private var phone     = ""
    @AppStorage("profile_dob")       private var dobStr    = ""
    @AppStorage("profile_country_id")private var countryId = "MT"
    @AppStorage("profile_dial_id")   private var dialId    = "MT"
    @AppStorage("baseCurrency")      private var currency  = "EUR"

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showSavedBanner = false
    @State private var showCountryPicker = false
    @State private var showDialPicker    = false
    @State private var countrySearch     = ""
    @State private var dialSearch        = ""

    private let currencies = ["EUR","USD","GBP","CHF","CAD","AUD","JPY","PLN","SEK","NOK"]

    private var avatarImage: UIImage? {
        guard let data = UserDefaults.standard.data(forKey: "profile_avatar") else { return nil }
        return UIImage(data: data)
    }

    private var selectedCountry: Country {
        countries.first { $0.id == countryId } ?? countries.first { $0.id == "MT" }!
    }

    private var selectedDial: Country {
        countries.first { $0.id == dialId } ?? countries.first { $0.id == "MT" }!
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        return parts.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    // Auto-generate nickname from name
    private func generateNickname(from fullName: String) -> String {
        let parts = fullName.split(separator: " ")
        guard let first = parts.first else { return "" }
        let suffixes = ["_vault", "_fx", "_trade", "_hq"]
        let suffix = suffixes[abs(fullName.hashValue) % suffixes.count]
        return "\(first.lowercased())\(suffix)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // ── Avatar + Name ────────────────────────────────────
                    VStack(spacing: 10) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                avatarCircle
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 30, height: 30)
                                    .overlay(Image(systemName: "camera.fill").font(.caption2).foregroundColor(.white))
                            }
                        }
                        .onChange(of: selectedPhoto) { _, item in
                            Task {
                                if let data = try? await item?.loadTransferable(type: Data.self) {
                                    UserDefaults.standard.set(data, forKey: "profile_avatar")
                                }
                            }
                        }

                        Text(name.isEmpty ? "Your Name" : name)
                            .font(.title2.weight(.bold))
                        Text(nickname.isEmpty ? "tap to set nickname" : "@\(nickname)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 12)

                    // ── Personal Details ──────────────────────────────────
                    VStack(spacing: 0) {
                        profileField("Full Name",   "person.fill",    $name,    "Matthew Degiorgio")
                        Divider().padding(.leading, 52)

                        // Nickname with auto-generate button
                        HStack(spacing: 14) {
                            Image(systemName: "at").foregroundColor(.blue).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Nickname").font(.caption).foregroundColor(.secondary)
                                TextField("your_nickname", text: $nickname)
                                    .font(.subheadline).autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            if !name.isEmpty {
                                Button {
                                    nickname = generateNickname(from: name)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption).foregroundColor(.blue)
                                }
                            }
                        }
                        .padding(16)

                        Divider().padding(.leading, 52)
                        profileField("Email",        "envelope.fill",  $email,   "you@example.com")
                        Divider().padding(.leading, 52)

                        // Phone with country dial code picker
                        HStack(spacing: 14) {
                            Image(systemName: "phone.fill").foregroundColor(.blue).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Phone").font(.caption).foregroundColor(.secondary)
                                HStack(spacing: 8) {
                                    Button {
                                        dialSearch = ""
                                        showDialPicker = true
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(selectedDial.flag)
                                            Text(selectedDial.dialCode)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.primary)
                                            Image(systemName: "chevron.down")
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color(.systemGray5))
                                        .cornerRadius(8)
                                    }
                                    TextField("9999 9999", text: $phone)
                                        .font(.subheadline)
                                        .keyboardType(.phonePad)
                                }
                            }
                        }
                        .padding(16)

                        Divider().padding(.leading, 52)
                        profileField("Date of Birth","calendar",       $dobStr,  "DD/MM/YYYY")
                        Divider().padding(.leading, 52)

                        // Country picker
                        HStack(spacing: 14) {
                            Image(systemName: "globe").foregroundColor(.blue).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Country").font(.caption).foregroundColor(.secondary)
                                Button {
                                    countrySearch = ""
                                    showCountryPicker = true
                                } label: {
                                    HStack {
                                        Text("\(selectedCountry.flag) \(selectedCountry.name)")
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)

                    // ── Preferred Currency ────────────────────────────────
                    HStack(spacing: 14) {
                        Image(systemName: "dollarsign.circle.fill")
                            .foregroundColor(.green).frame(width: 28)
                        Text("Preferred Currency").font(.subheadline)
                        Spacer()
                        Picker("", selection: $currency) {
                            ForEach(currencies, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(16)
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)

                    // Save button
                    Button {
                        save()
                    } label: {
                        Text("Save Profile")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                }
                .padding()
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            // Country picker sheet
            .sheet(isPresented: $showCountryPicker) {
                CountryPickerSheet(search: $countrySearch, selectedId: $countryId)
            }
            // Dial code picker sheet
            .sheet(isPresented: $showDialPicker) {
                CountryPickerSheet(search: $dialSearch, selectedId: $dialId, title: "Phone Prefix")
            }
            .overlay {
                if showSavedBanner {
                    VStack {
                        Spacer()
                        Label("Profile saved", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(20)
                            .padding(.bottom, 40)
                    }
                }
            }
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarCircle: some View {
        if let img = avatarImage {
            Image(uiImage: img)
                .resizable().scaledToFill()
                .frame(width: 100, height: 100)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 100, height: 100)
                .overlay(
                    Text(initials.isEmpty ? "?" : initials)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.blue)
                )
        }
    }

    // MARK: - Profile Field

    @ViewBuilder
    private func profileField(_ label: String, _ icon: String, _ binding: Binding<String>, _ placeholder: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundColor(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundColor(.secondary)
                TextField(placeholder, text: binding)
                    .font(.subheadline)
                    .onSubmit { save() }
            }
        }
        .padding(16)
    }

    private func save() {
        // Auto-set nickname if empty
        if nickname.isEmpty && !name.isEmpty {
            nickname = generateNickname(from: name)
        }
        showSavedBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showSavedBanner = false }
    }
}

// ── Country Picker Sheet ──────────────────────────────────────────────────────
struct CountryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var search: String
    @Binding var selectedId: String
    var title: String = "Select Country"

    private var filtered: [Country] {
        search.isEmpty ? countries : countries.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.dialCode.contains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { country in
                Button {
                    selectedId = country.id
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        Text(country.flag).font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(country.name).font(.subheadline).foregroundColor(.primary)
                            Text(country.dialCode).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if selectedId == country.id {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Search country")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
