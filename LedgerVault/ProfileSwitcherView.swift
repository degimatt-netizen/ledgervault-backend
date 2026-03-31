import SwiftUI

struct ProfileSwitcherView: View {
    @EnvironmentObject var pm: ProfileManager
    @State private var showPicker = false
    @State private var showManage = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 5) {
                Text(pm.displayEmoji)
                    .font(.system(size: 13))
                Text(pm.displayName)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
        }
        .sheet(isPresented: $showPicker) {
            ProfilePickerSheet(showPicker: $showPicker, showManage: $showManage)
                .environmentObject(pm)
                .presentationDetents([.height(300)])
        }
        .sheet(isPresented: $showManage) {
            ManageProfilesView()
                .environmentObject(pm)
        }
    }
}

struct ProfilePickerSheet: View {
    @EnvironmentObject var pm: ProfileManager
    @Binding var showPicker: Bool
    @Binding var showManage: Bool

    var body: some View {
        NavigationStack {
            List {
                // Personal (all accounts)
                Button {
                    pm.selectedProfileId = nil
                    showPicker = false
                } label: {
                    HStack {
                        Text("👤")
                        Text("Personal")
                            .font(.body)
                            .foregroundColor(.primary)
                        Spacer()
                        if pm.selectedProfileId == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)

                // Custom profiles
                ForEach(pm.profiles) { profile in
                    Button {
                        pm.selectedProfileId = profile.id
                        showPicker = false
                    } label: {
                        HStack {
                            Text(profile.emoji)
                            Text(profile.name)
                                .font(.body)
                                .foregroundColor(.primary)
                            Spacer()
                            if pm.selectedProfileId == profile.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Switch Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Manage Profiles") {
                        showPicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showManage = true
                        }
                    }
                    .font(.subheadline)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showPicker = false }
                }
            }
        }
    }
}
