import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var profileName = ""

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
                activeAppIDs
                addAccount

                Text("Slip does not upload your IPA or Apple Account credentials to its own service. Apple authentication requires the selected Anisette provider, currently \(model.anisetteServer). Apple’s sign-in response supplies the profile name and active App ID records.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .scrollIndicators(.hidden)
        .background(SlipBackdrop())
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
            displayName: "Apple Account"
        )
        let selected = model.selectedAccount == account
        return HStack(spacing: 14) {
            AccountAvatar(profile: profile, selected: selected, size: 48)

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
                    .disabled(model.isLoadingAppIDs || model.isInstalling)
            } else {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Button("Remove", role: .destructive) { model.deleteAccount(account) }
                .disabled(model.isLoadingAppIDs || model.isInstalling)
        }
        .padding(.vertical, 10)
    }

    private var activeAppIDs: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.appIDTeamName.isEmpty ? "Selected Apple Account" : model.appIDTeamName)
                            .font(.headline)
                        Text(model.selectedAccount.isEmpty ? "Choose an account above" : model.selectedAccount)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let maximum = model.appIDMaxQuantity {
                        let available = max(0, model.appIDAvailableQuantity ?? 0)
                        SlipStatusPill(
                            title: "\(model.activeAppIDs.count)/\(maximum) active · \(available) free",
                            symbol: "square.stack.3d.up.fill",
                            tint: available > 0 ? .green : .orange
                        )
                        .fixedSize()
                    }
                    Button {
                        Task { await model.loadActiveAppIDs() }
                    } label: {
                        if model.isLoadingAppIDs {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(model.activeAppIDs.isEmpty ? "Load App IDs" : "Reload", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.selectedAccount.isEmpty || model.isLoadingAppIDs || model.isInstalling)
                }

                Divider()

                if model.activeAppIDs.isEmpty {
                    ContentUnavailableView(
                        "No App IDs loaded",
                        systemImage: "square.stack.3d.up",
                        description: Text("Load Apple’s active App IDs for the selected account. Apple may request a verification code.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 130)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.activeAppIDs) { appID in
                            appIDRow(appID)
                            if appID.id != model.activeAppIDs.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Active App IDs", systemImage: "square.stack.3d.up")
        }
    }

    private func appIDRow(_ appID: DeveloperAppIDInfo) -> some View {
        let usage = appIDUsage(appID)
        return HStack(spacing: 13) {
            Image(systemName: usage.isExtension ? "puzzlepiece.extension.fill" : "app.fill")
                .font(.system(size: 17, weight: .semibold))
                .slipDimensionalSymbol()
                .foregroundStyle(usage.isExtension ? Color.cyan : Color.accentColor)
                .frame(width: 38, height: 38)
                .slipGlassSurface(
                    tint: (usage.isExtension ? Color.cyan : Color.accentColor).opacity(0.13),
                    cornerRadius: 12
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(appID.name.isEmpty ? usage.title : appID.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(appID.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(usage.title, systemImage: usage.isExtension ? "puzzlepiece.extension" : "iphone")
                    .font(.caption2)
                    .foregroundStyle(usage.isExtension ? Color.cyan : .secondary)
                if let teamName = appID.teamName,
                   !teamName.isEmpty,
                   teamName != model.appIDTeamName {
                    Text(teamName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 18)

            VStack(alignment: .trailing, spacing: 3) {
                if let resetDate = appID.resetDate {
                    Text("Resets \(resetDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.weight(.semibold))
                    Text(resetDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(resetDate > Date() ? .secondary : Color.green)
                } else {
                    Text("Reset time unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    private func appIDUsage(_ appID: DeveloperAppIDInfo) -> (title: String, isExtension: Bool) {
        let matchingInstalls = model.managedInstallations.filter {
            $0.account.caseInsensitiveCompare(model.selectedAccount) == .orderedSame
        }
        if let installation = matchingInstalls.first(where: { $0.bundleId == appID.identifier }) {
            return (installation.appName, false)
        }
        if let installation = matchingInstalls
            .filter({ appID.identifier.hasPrefix($0.bundleId + ".") })
            .max(by: { $0.bundleId.count < $1.bundleId.count }) {
            return ("\(installation.appName) extension", true)
        }
        if let installed = model.installedApps.first(where: { $0.bundleId == appID.identifier }) {
            return (installed.name.isEmpty ? "Installed app" : installed.name, false)
        }
        if let parent = model.activeAppIDs
            .filter({ candidate in
                candidate.id != appID.id && appID.identifier.hasPrefix(candidate.identifier + ".")
            })
            .max(by: { $0.identifier.count < $1.identifier.count }) {
            let parentName = parent.name.isEmpty ? "Registered app" : parent.name
            return ("\(parentName) extension", true)
        }
        let likelyExtension = appID.name.localizedCaseInsensitiveContains("extension") ||
            appID.name.localizedCaseInsensitiveContains("widget") ||
            appID.name.localizedCaseInsensitiveContains("share")
        return (likelyExtension ? "Registered extension" : "Registered app", likelyExtension)
    }

    private var addAccount: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 20) {
                AccountAvatar(profile: draftProfile, selected: false, size: 64)

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
                                profileName: profileName
                            ) {
                                email = ""
                                password = ""
                                profileName = ""
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            email.isEmpty || password.isEmpty ||
                                model.isLoadingAppIDs || model.isInstalling
                        )
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
            displayName: trimmedName.isEmpty ? (inferred.isEmpty ? "Apple Account" : inferred) : trimmedName
        )
    }
}

private struct AccountAvatar: View {
    let profile: AccountProfile
    let selected: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
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
        .accessibilityLabel("\(profile.displayName) account")
    }
}
