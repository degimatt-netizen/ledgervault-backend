import SwiftUI

// MARK: - ManageProfilesView

struct ManageProfilesView: View {
    @EnvironmentObject var pm: ProfileManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAddEdit = false
    @State private var editingProfile: APIService.AccountProfile? = nil
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if pm.profiles.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "person.2.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No Profiles Yet")
                            .font(.title2.bold())
                        Text("Create profiles to filter your Home, Portfolio,\nand Markets views by a group of accounts.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            editingProfile = nil
                            showAddEdit = true
                        } label: {
                            Label("Create Profile", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(pm.profiles) { profile in
                            Button {
                                editingProfile = profile
                                showAddEdit = true
                            } label: {
                                HStack(spacing: 14) {
                                    Text(profile.emoji)
                                        .font(.title2)
                                        .frame(width: 42, height: 42)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.body.weight(.medium))
                                            .foregroundColor(.primary)
                                        Text("\(profile.account_ids.count) account\(profile.account_ids.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task {
                                        do {
                                            try await pm.deleteProfile(id: profile.id)
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingProfile = nil
                        showAddEdit = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddEdit) {
                AddEditProfileView(profile: editingProfile)
                    .environmentObject(pm)
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

// MARK: - AddEditProfileView

struct AddEditProfileView: View {
    @EnvironmentObject var pm: ProfileManager
    @Environment(\.dismiss) private var dismiss
    let profile: APIService.AccountProfile?  // nil = create, non-nil = edit

    @State private var name = ""
    @State private var emoji = "👤"
    @State private var selectedAccountIds: Set<String> = []
    @State private var accounts: [APIService.Account] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    let emojiOptions = ["👤","👨","👩","👴","👵","👦","👧","👨‍💼","👩‍💼","🧑‍💼","💼","📊","💰","🏦","🏠","🎯","🌍","🚀","⭐️","🔥"]

    private var isEditing: Bool { profile != nil }

    var body: some View {
        NavigationStack {
            Form {
                // Name field
                Section("Profile Name") {
                    TextField("e.g. Dad, Son, Personal", text: $name)
                }

                // Emoji picker
                Section("Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(emojiOptions, id: \.self) { option in
                                Button {
                                    emoji = option
                                } label: {
                                    Text(option)
                                        .font(.title2)
                                        .frame(width: 44, height: 44)
                                        .background(emoji == option ? Color.accentColor.opacity(0.2) : Color(.systemGray6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(emoji == option ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Account selection
                Section("Linked Accounts") {
                    if accounts.isEmpty {
                        Text("Loading accounts…")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(accounts) { account in
                            Button {
                                if selectedAccountIds.contains(account.id) {
                                    selectedAccountIds.remove(account.id)
                                } else {
                                    selectedAccountIds.insert(account.id)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.name)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("\(account.account_type.replacingOccurrences(of: "_", with: " ").capitalized) · \(account.base_currency)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedAccountIds.contains(account.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedAccountIds.contains(account.id) ? .accentColor : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Profile" : "New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .task {
                // Populate accounts list
                if let loaded = try? await APIService.shared.fetchAccounts() {
                    accounts = loaded
                }
                // Pre-fill from existing profile
                if let p = profile {
                    name = p.name
                    emoji = p.emoji
                    selectedAccountIds = Set(p.account_ids)
                }
            }
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        do {
            if let p = profile {
                try await pm.updateProfile(
                    id: p.id,
                    name: trimmedName,
                    emoji: emoji,
                    accountIds: Array(selectedAccountIds)
                )
            } else {
                try await pm.createProfile(
                    name: trimmedName,
                    emoji: emoji,
                    accountIds: Array(selectedAccountIds)
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
