import SwiftUI

public struct UserProfileView: View {
    @StateObject private var viewModel: ProfileViewModel
    @State private var showingAddProfile = false
    @State private var newProfileName = ""
    @State private var newProfilePin = ""
    @FocusState private var focusedItem: String?

    private static let addProfileFocusId = "add_profile"

    public init(viewModel: ProfileViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationView {
            ZStack {
                ProfileBackground()

                VStack(spacing: 0) {
                    Spacer().frame(height: 162)

                    Text("Who's watching?")
                        .font(.custom("Inter-Bold", size: 62))
                        .foregroundColor(.white)

                    Spacer().frame(height: 14)

                    Text("Select a profile to continue")
                        .font(.custom("Inter-Regular", size: 28))
                        .foregroundColor(.white.opacity(0.6))

                    Spacer()

                    // Centered single row of profiles.
                    HStack(alignment: .top, spacing: 56) {
                        ForEach(viewModel.profiles, id: \.id) { profile in
                            ProfileCard(
                                profile: profile,
                                isFocused: focusedItem == profile.id
                            ) {
                                handleProfileSelection(profile)
                            }
                            .focused($focusedItem, equals: profile.id)
                        }

                        AddProfileButton(
                            isFocused: focusedItem == Self.addProfileFocusId
                        ) {
                            showingAddProfile = true
                        }
                        .focused($focusedItem, equals: Self.addProfileFocusId)
                    }
                    .padding(.horizontal, 80)
                    .frame(maxWidth: .infinity)

                    Spacer()

                    Spacer().frame(height: 56)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.isPinEntryVisible {
                    ProfilePinView(viewModel: viewModel)
                }
            }
            .sheet(isPresented: $showingAddProfile) {
                AddProfileView(isPresented: $showingAddProfile, name: $newProfileName, pin: $newProfilePin) {
                    viewModel.createProfile(name: newProfileName, pin: newProfilePin.isEmpty ? nil : newProfilePin)
                    newProfileName = ""
                    newProfilePin = ""
                }
            }
        }
    }

    private func handleProfileSelection(_ profile: Profile) {
        viewModel.requestSwitch(to: profile)
    }
}

/// Dark navy base with a soft blue glow toward the top, matching the brand.
private struct ProfileBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.10, blue: 0.18),
                    Color(red: 0.02, green: 0.03, blue: 0.06),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(red: 0.12, green: 0.30, blue: 0.55).opacity(0.55), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 950
            )
        }
        .ignoresSafeArea()
    }
}

struct ProfileCard: View {
    let profile: Profile
    let isFocused: Bool
    let action: () -> Void

    private let avatarSize: CGFloat = 180

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(ProfileAvatarStyle.color(for: profile.id))

                    Text(initial)
                        .font(.custom("Inter-Bold", size: 74))
                        .foregroundColor(.white)
                }
                .frame(width: avatarSize, height: avatarSize)
                .overlay(alignment: .bottomTrailing) { badge }
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isFocused ? 0.86 : 0), lineWidth: isFocused ? 3 : 0)
                )
                .shadow(color: isFocused ? Color.white.opacity(0.3) : .clear, radius: 24)

                VStack(spacing: 4) {
                    Text(profile.name)
                        .font(.custom("Inter-Bold", size: 28))
                        .foregroundColor(isFocused ? .white : Color.white.opacity(0.6))
                        .lineLimit(1)

                    if profile.isAdmin {
                        Text("PRIMARY")
                            .font(.custom("Inter-Bold", size: 16))
                            .tracking(1.5)
                            .foregroundColor(ProfileAvatarStyle.accent)
                    }
                }
            }
            .scaleEffect(isFocused ? 1.12 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(ProfilePlainButtonStyle())
        .focusEffectDisabled() // suppress tvOS default white halo; we draw our own ring
    }

    @ViewBuilder private var badge: some View {
        if profile.isAdmin {
            Image(systemName: "star.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(11)
                .background(Circle().fill(ProfileAvatarStyle.accent))
                .offset(x: 4, y: 4)
        } else if profile.isPinProtected {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(12)
                .background(Circle().fill(Color.black.opacity(0.8)))
                .offset(x: 2, y: 2)
        }
    }

    private var initial: String {
        String(profile.name.prefix(1)).uppercased()
    }
}

struct AddProfileButton: View {
    let isFocused: Bool
    let action: () -> Void

    private let avatarSize: CGFloat = 180

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                Circle()
                    .fill(Color.white.opacity(isFocused ? 0.16 : 0.06))
                    .frame(width: avatarSize, height: avatarSize)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 62, weight: .light))
                            .foregroundColor(isFocused ? .white : Color.white.opacity(0.55))
                    )
                    .overlay(
                        Circle()
                            .stroke(isFocused ? Color.white.opacity(0.86) : Color.white.opacity(0.3),
                                    lineWidth: isFocused ? 3 : 2)
                    )
                    .shadow(color: isFocused ? Color.white.opacity(0.3) : .clear, radius: 24)

                Text("Add Profile")
                    .font(.custom("Inter-Bold", size: 28))
                    .foregroundColor(isFocused ? .white : Color.white.opacity(0.6))
            }
            .scaleEffect(isFocused ? 1.12 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(ProfilePlainButtonStyle())
        .focusEffectDisabled() // suppress tvOS default white halo; we draw our own ring
    }
}

/// Renders only the button's label so tvOS doesn't draw its default focused
/// platter -- the avatar's own scale + white ring is the sole focus visual.
private struct ProfilePlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Stable, per-profile avatar colors so a profile keeps the same tint across
/// launches (Swift's String.hashValue is seeded per run, so it can't be used).
enum ProfileAvatarStyle {
    static let accent = Color(red: 0.98, green: 0.67, blue: 0.12) // primary star / label

    private static let colors: [Color] = [
        Color(red: 0.18, green: 0.60, blue: 0.93), // blue
        Color(red: 0.92, green: 0.14, blue: 0.16), // red
        Color(red: 0.16, green: 0.88, blue: 0.64), // mint
        Color(red: 0.56, green: 0.32, blue: 0.93), // purple
        Color(red: 0.97, green: 0.58, blue: 0.16), // amber
        Color(red: 0.93, green: 0.31, blue: 0.61), // pink
    ]

    static func color(for id: String) -> Color {
        var hash = 5381
        for scalar in id.unicodeScalars {
            hash = (hash &* 33) &+ Int(scalar.value)
        }
        return colors[abs(hash) % colors.count]
    }
}

struct AddProfileView: View {
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var pin: String
    var onSave: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Profile Info")) {
                    TextField("Name", text: $name)
                    SecureField("PIN (Optional)", text: $pin)
                        .keyboardType(.numberPad)
                }

                Button("Save") {
                    onSave()
                    isPresented = false
                }
                .disabled(name.isEmpty)
            }
            .navigationTitle("Add Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }
}
