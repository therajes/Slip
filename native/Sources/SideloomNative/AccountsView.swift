import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var profileName = ""
    @State private var profileImageURL: URL?
    @State private var photoTargetAccount: String?
    @State private var showPhotoImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    eyebrow: "SECURE SIGNING",
                    title: "Apple Accounts",
                    subtitle: "Passwords are stored by macOS Keychain and are sent only to Apple during signing."
                )
                .padding(.horizontal, -28)
                .padding(.top, -24)

                savedAccounts
                addAccount

                Text("Slip does not upload your IPA or Apple Account credentials to its own service. Apple authentication requires the selected Anisette provider, currently \(model.anisetteServer). Apple’s sign-in response supplies the profile name; Apple does not expose the private Apple Account photo to third-party apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .scrollIndicators(.hidden)
        .background(SlipBackdrop())
        .fileImporter(isPresented: $showPhotoImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else {
                photoTargetAccount = nil
                return
            }
            if let account = photoTargetAccount {
                model.updateAccountPhoto(url, for: account)
            } else {
                profileImageURL = url
            }
            photoTargetAccount = nil
        }
    }

    private var savedAccounts: some View {
        GroupBox {
            VStack(spacing: 0) {
                if model.accounts.isEmpty {
                    ContentUnavailableView(
                        "No saved accounts",
                        systemImage: "person.badge.key",
                        description: Text("Add the Apple Account used by your free Personal Team.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(model.accounts, id: \.self) { account in
                        accountRow(account)
                        if account != model.accounts.last { Divider() }
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Saved accounts", systemImage: "key.horizontal")
        }
    }

    private func accountRow(_ account: String) -> some View {
        let profile = model.accountProfiles[account.lowercased()] ?? AccountProfile(
            email: account,
            displayName: "Apple Account",
            imagePath: nil
        )
        let selected = model.selectedAccount == account
        return HStack(spacing: 14) {
            Menu {
                Button("Choose Profile Picture…") {
                    photoTargetAccount = account
                    showPhotoImporter = true
                }
                if profile.imagePath != nil {
                    Button("Remove Profile Picture", role: .destructive) {
                        model.removeAccountPhoto(for: account)
                    }
                }
            } label: {
                AccountAvatar(profile: profile, selected: selected, size: 48)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 48, height: 48)
            .fixedSize(horizontal: true, vertical: true)
            .help("Change profile picture")

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(selected ? "Used for the next install" : "Password stored in macOS Keychain")
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            Spacer()
            if !selected {
                Button("Use") { model.chooseAccount(account) }
            } else {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Button("Remove", role: .destructive) { model.deleteAccount(account) }
        }
        .padding(.vertical, 10)
    }

    private var addAccount: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 9) {
                    AccountAvatar(
                        profile: draftProfile,
                        overrideImageURL: profileImageURL,
                        selected: false,
                        size: 64
                    )
                    Button(profileImageURL == nil ? "Choose Photo…" : "Change Photo…") {
                        photoTargetAccount = nil
                        showPhotoImporter = true
                    }
                    .controlSize(.small)
                    if profileImageURL != nil {
                        Button("Remove", role: .destructive) { profileImageURL = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                        GridRow {
                            Text("Profile name")
                            TextField("Shown until Apple supplies the verified name", text: $profileName)
                                .frame(minWidth: 330)
                        }
                        GridRow {
                            Text("Apple Account")
                            TextField("name@example.com", text: $email)
                                .textContentType(.username)
                        }
                        GridRow {
                            Text("Password")
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        }
                    }

                    HStack {
                        Label("Protected by macOS Keychain", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Account") {
                            if model.saveAccount(
                                email: email,
                                password: password,
                                profileName: profileName,
                                profileImageURL: profileImageURL
                            ) {
                                email = ""
                                password = ""
                                profileName = ""
                                profileImageURL = nil
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(email.isEmpty || password.isEmpty)
                    }
                }
            }
            .padding(10)
        } label: {
            Label("Add an account", systemImage: "plus.circle")
        }
    }

    private var draftProfile: AccountProfile {
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPart = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let inferred = localPart
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { String($0).capitalized }
            .joined(separator: " ")
        return AccountProfile(
            email: email,
            displayName: trimmedName.isEmpty ? (inferred.isEmpty ? "Apple Account" : inferred) : trimmedName,
            imagePath: nil
        )
    }
}

private struct AccountAvatar: View {
    let profile: AccountProfile
    var overrideImageURL: URL?
    let selected: Bool
    let size: CGFloat

    init(profile: AccountProfile, overrideImageURL: URL? = nil, selected: Bool, size: CGFloat) {
        self.profile = profile
        self.overrideImageURL = overrideImageURL
        self.selected = selected
        self.size = size
    }

    private var image: NSImage? {
        if let overrideImageURL, let image = NSImage(contentsOf: overrideImageURL) { return image }
        guard let imagePath = profile.imagePath else { return nil }
        return NSImage(contentsOfFile: imagePath)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.76), Color.cyan.opacity(0.42), .white.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(profile.initials)
                    .font(.system(size: size * 0.29, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(
                LinearGradient(
                    colors: [.white.opacity(0.86), .white.opacity(0.15), .white.opacity(0.50)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .overlay(alignment: .bottomTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.31, weight: .semibold))
                    .slipDimensionalSymbol(strength: 0.8)
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(.green).padding(1.5))
                    .offset(x: 2, y: 2)
            }
        }
        .shadow(color: .white.opacity(0.16), radius: 1, x: -0.5, y: -0.5)
        .shadow(color: .black.opacity(0.34), radius: 5, y: 3)
        .accessibilityLabel("\(profile.displayName) profile picture")
    }
}
