import SwiftUI
import Combine

final class ProfileManager: ObservableObject {
    @Published var profiles: [APIService.AccountProfile] = []
    @Published var selectedProfileId: String? = nil  // nil = Personal (all accounts)
    @Published var isLoading = false

    var selectedProfile: APIService.AccountProfile? {
        guard let id = selectedProfileId else { return nil }
        return profiles.first { $0.id == id }
    }

    var displayName: String {
        selectedProfile?.name ?? "Personal"
    }

    var displayEmoji: String {
        selectedProfile?.emoji ?? "👤"
    }

    func load() async {
        guard let loaded = try? await APIService.shared.fetchProfiles() else { return }
        await MainActor.run { self.profiles = loaded }
    }

    func createProfile(name: String, emoji: String, accountIds: [String]) async throws {
        let p = try await APIService.shared.createProfile(name: name, emoji: emoji, accountIds: accountIds)
        await MainActor.run { self.profiles.append(p) }
    }

    func updateProfile(id: String, name: String? = nil, emoji: String? = nil, accountIds: [String]? = nil) async throws {
        let p = try await APIService.shared.updateProfile(id: id, name: name, emoji: emoji, accountIds: accountIds)
        await MainActor.run {
            if let idx = self.profiles.firstIndex(where: { $0.id == id }) {
                self.profiles[idx] = p
            }
        }
    }

    func deleteProfile(id: String) async throws {
        try await APIService.shared.deleteProfile(id: id)
        await MainActor.run {
            self.profiles.removeAll { $0.id == id }
            if self.selectedProfileId == id { self.selectedProfileId = nil }
        }
    }
}
