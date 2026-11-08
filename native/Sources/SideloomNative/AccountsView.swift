// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Jordy Spruit (Droppy)
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Modified by Slip: native sideloading interface, controls and compatibility.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var email = ""
    @State private var password = ""
    @State private var profileName = ""
    @State private var profileImageURL: URL?
    @State private var photoTargetAccount: String?
    @State private var showPhotoImporter = false
    @State private var pendingCertificate: CertificateInfo?
    @State private var pendingCertificateBatch: CertificateRevocationPlan?
    @State private var pendingCertificateAccount = ""
    @State private var pendingAppID: AppleAppID?
    @State private var pendingAccountRemoval: String?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    eyebrow: "SECURE SIGNING",
                    title: "Apple Accounts",
                    subtitle: "Passwords are stored by macOS Keychain and are sent only to Apple during signing."
                )

                thisMac
                savedAccounts
                authenticationSource
                accountResources
                DeviceHealthPanel().environmentObject(model)
                addAccount.id("signInForm")


                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How Sign-In & Two-Factor Authentication (OTP) Work")
                            .font(.subheadline.weight(.semibold))
                        Text("Sign In & Save verifies your credentials with Apple before storing them securely in macOS Keychain. Slip also authenticates when signing apps or managing developer resources. If Apple requires two-factor verification, a six-digit code field appears beneath your password. The field stays in place until Apple finishes verification and prepares the developer session. If Apple already trusts this machine session, sign-in succeeds automatically without needing an OTP.")
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                }
                .padding(14)
                .slipGlassSurface(cornerRadius: 12)

                Text("Slip does not upload your IPA or Apple Account credentials to its own service. The selected authentication source prepares data for Apple sign-in. Apple’s sign-in response supplies the profile name; Apple does not expose the private Apple Account photo to third-party apps.")
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.7))

            }
            .padding(28)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .onChange(of: model.showInlineTwoFactor) { _, visible in
            if visible {
                withAnimation(motionAllowed ? .easeInOut(duration: 0.24) : nil) { proxy.scrollTo("signInForm", anchor: .bottom) }
            }
        }
        .onAppear {
            if model.showInlineTwoFactor { proxy.scrollTo("signInForm", anchor: .bottom) }
        }
        }
        .background(SlipBackdrop())
        .task {
            if model.hostIdentity == nil { await model.loadHostIdentity() }
        }
        .confirmationDialog("Revoke this development certificate?", isPresented: Binding(
            get: { pendingCertificate != nil }, set: { if !$0 { pendingCertificate = nil } }
        ), titleVisibility: .visible) {
            Button("Revoke Certificate", role: .destructive) {
                let serial = pendingCertificate?.serialNumber
                pendingCertificate = nil
                if let serial { Task { await model.manageAccount(command: "revoke-certificate", serialNumber: serial) } }
            }
        } message: {
            Text("Apps signed with this certificate may stop opening and must be signed and installed again. This also affects apps signed by other tools. Serial: \(pendingCertificate?.serialNumber ?? "Unknown").")
        }
        .confirmationDialog(pendingCertificateBatch?.title ?? "Revoke development certificates?", isPresented: Binding(
            get: { pendingCertificateBatch != nil }, set: { if !$0 { pendingCertificateBatch = nil } }
        ), titleVisibility: .visible) {
            Button(pendingCertificateBatch?.confirmationAction ?? "Revoke Certificates", role: .destructive) {
                guard let plan = pendingCertificateBatch else { return }
                let account = pendingCertificateAccount
                pendingCertificateBatch = nil
                Task { await model.revokeAccountCertificates(plan, for: account) }
            }
            Button("Keep Certificates", role: .cancel) { pendingCertificateBatch = nil }
        } message: {
            Text(pendingCertificateBatch?.confirmationMessage ?? "")
        }
        .confirmationDialog("Delete this App ID?", isPresented: Binding(
            get: { pendingAppID != nil }, set: { if !$0 { pendingAppID = nil } }
        ), titleVisibility: .visible) {
            Button("Delete App ID", role: .destructive) {
                let id = pendingAppID?.id
                pendingAppID = nil
                if let id { Task { await model.manageAccount(command: "delete-app-id", appIdId: id) } }
            }
        } message: {
            Text("Delete \(pendingAppID?.bundleId ?? "this identifier") from your Apple developer team? Its provisioning profiles can become invalid. Apple may restrict deletion or keep free-account quota reserved until it expires.")
        }
        .confirmationDialog("Remove this saved account?", isPresented: Binding(
            get: { pendingAccountRemoval != nil }, set: { if !$0 { pendingAccountRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) {
                if let account = pendingAccountRemoval { model.deleteAccount(account) }
                pendingAccountRemoval = nil
            }
        } message: {
            Text("This removes the saved password, local signing session, and this account's automatic refresh schedules from Slip. Apple certificates and App IDs remain on your account.")
        }
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

    private var authenticationSource: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Authentication", selection: $model.authenticationMode) {
                    Text("This Mac").tag("local")
                    Text("Remote compatibility").tag("remote")
                }
                .pickerStyle(.segmented)
                .disabled(model.isAuthenticating)
                if model.authenticationMode == "local" {
                    Text("Uses authentication data generated by this Mac. Sign-in stops if macOS cannot provide it. Slip never switches to an external service automatically.")
                        .font(.caption).foregroundStyle(Color.primary.opacity(0.7))
                } else {
                    RemoteAnisetteSettings(address: $model.anisetteServer, isAuthenticating: model.isAuthenticating || model.isRunningInstallQueue)
                }
                if let identity = model.hostIdentity, let available = identity.localAuthenticationAvailable {
                    Label(available ? "Local Mac authentication is available" : "Local authentication is unavailable on this Mac", systemImage: available ? "checkmark.circle" : "info.circle")
                        .font(.caption).foregroundStyle(Color.primary.opacity(0.7))
                    if !available, let message = identity.localAuthenticationMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if available && model.authenticationMode != "local" {
                        Button("Use This Mac") { model.authenticationMode = "local" }
                            .disabled(model.isAuthenticating)
                    }
                }
                if let notice = model.authenticationNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(Color.accentColor).textSelection(.enabled)
                }
            }
            .padding(10)
        } label: {
            Label("Authentication source", systemImage: "network")
        }
    }

    private var thisMac: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let identity = model.hostIdentity {
                            Text(identity.computerName).font(.headline).textSelection(.enabled)
                            Text("\(identity.modelIdentifier) · macOS \(identity.osVersion) (\(identity.osBuild))")
                                .font(.caption).foregroundStyle(Color.primary.opacity(0.7)).textSelection(.enabled)
                        } else {
                            Text(model.isLoadingHostIdentity ? "Reading this Mac's identity…" : "Mac identity unavailable")
                                .foregroundStyle(Color.primary.opacity(0.7))
                        }
                    }
                    Spacer()
                    if model.isLoadingHostIdentity { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await model.loadHostIdentity() } }
                        .disabled(model.isLoadingHostIdentity)
                        .accessibilityLabel("Refresh this Mac's identity")
                }
                if let error = model.hostIdentityError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("Slip uses this computer name for new development certificates. This Mac requires local authentication data from macOS; availability depends on the macOS version and Apple permissions. Remote compatibility is an explicit choice and may show another device in Apple alerts. Developer sign-in does not add this Mac as a trusted Apple Account device.")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        } label: {
            Label("This Mac", systemImage: "laptopcomputer")
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
                AccountAvatar(profile: profile, selected: selected, size: 40)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40, height: 40)
            .fixedSize(horizontal: true, vertical: true)
            .help("Change profile picture")

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(account)
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(1)
                Text(selected ? "Used for the next install" : "Password stored in macOS Keychain")
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            Spacer()
            if !selected {
                Button("Use") { model.chooseAccount(account) }
                    .disabled(model.isAuthenticating)
            } else {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Button("Remove", role: .destructive) { pendingAccountRemoval = account }
                .disabled(model.isAuthenticating)
        }
        .padding(.vertical, 10)
    }

    private var accountResources: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selectedAccount.isEmpty ? "Select a saved account" : model.selectedAccount)
                            .font(.subheadline.weight(.semibold))
                        Text("Manage the development team used by Slip. Refresh contacts Apple and may request a verification code.")
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                    Spacer()
                    if model.isManagingAccount {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelInstall() }
                    } else {
                        Button(model.resourcesError == nil ? "Refresh" : "Retry") { Task { await model.manageAccount() } }
                            .disabled(model.selectedAccount.isEmpty || model.isAuthenticating)
                    }
                }
                if let error = model.resourcesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let notice = model.certificateRevocationNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.resourcesAccount == model.selectedAccount, let updated = model.resourcesUpdatedAt {
                    Text("Last successful refresh: \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(Color.primary.opacity(0.7))
                }
                if model.resourcesLoaded && model.resourcesAccount == model.selectedAccount {
                    Divider()
                    HStack {
                        Text("Development certificates").font(.headline)
                        Spacer()
                        Button("Revoke All…", role: .destructive) {
                            pendingCertificateAccount = model.selectedAccount
                            let all = Set(CertificateRevocationPlan.availableSerialNumbers(in: model.accountCertificates))
                            pendingCertificateBatch = CertificateRevocationPlan(certificates: model.accountCertificates, selection: all, includesAll: true)
                        }
                        .disabled(model.isAuthenticating || CertificateRevocationPlan.availableSerialNumbers(in: model.accountCertificates).isEmpty)
                    }
                    if model.accountCertificates.isEmpty {
                        Text("No development certificates found.").foregroundStyle(Color.primary.opacity(0.7))
                    }
                    ForEach(model.accountCertificates) { certificate in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(certificate.name ?? "Development certificate")
                                Text([certificate.machineName, certificate.serialNumber].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Color.primary.opacity(0.7)).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Revoke…", role: .destructive) { pendingCertificate = certificate }
                                .disabled(model.isAuthenticating || certificate.serialNumber?.isEmpty != false)
                        }
                    }
                    Divider()
                    HStack {
                        Text("Registered App IDs").font(.headline)
                        Spacer()
                        Text("\(model.accountAppIDs.count) registered")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let quota = model.appIDQuota {
                        Label(quota.summary, systemImage: "number.circle")
                            .font(.callout.weight(.medium))
                        if let message = quota.message, message != quota.summary {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Text("Free Personal Teams allow up to 10 App IDs per seven-day period. Each app and retained extension can require an ID. Apple controls renewal; deleting an ID may not immediately make space.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.accountAppIDs.isEmpty {
                        Text("No registered App IDs found.").foregroundStyle(Color.primary.opacity(0.7))
                    }
                    ForEach(model.accountAppIDs) { appID in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(appID.name)
                                Text(appID.bundleId).font(.caption).foregroundStyle(Color.primary.opacity(0.7)).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Delete…", role: .destructive) { pendingAppID = appID }
                                .disabled(model.isAuthenticating)
                        }
                    }
                } else if !model.isManagingAccount {
                    Text(model.resourcesError == nil ? "Refresh to view certificates and App IDs registered with Apple." : "The current certificate and App ID list is unavailable. Retry to fetch it from Apple.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.7))
                }
            }
            .padding(2)
        } label: {
            Label("Certificates & App IDs", systemImage: "signature")
        }
    }

    private var addAccount: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 9) {
                    AccountAvatar(
                        profile: draftProfile,
                        overrideImageURL: profileImageURL,
                        selected: false,
                        size: 48
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
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("Profile name")
                            TextField("Shown until Apple supplies the verified name", text: $profileName)
                                .frame(minWidth: 180, maxWidth: .infinity)
                                .disabled(model.isAuthenticating)
                        }
                        GridRow {
                            Text("Apple Account")
                            TextField("name@example.com", text: $email)
                                .textContentType(.username)
                                .disabled(model.isAuthenticating)
                        }
                        GridRow {
                            Text("Password")
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .disabled(model.isAuthenticating)
                                .onSubmit { if !model.showInlineTwoFactor { signIn() } }
                        }
                        if model.showInlineTwoFactor {
                            GridRow(alignment: .top) {
                                Text("Verification code").padding(.top, 5)
                                InlineTwoFactorView(code: $model.verificationCode, flow: model.authentication,
                                                    onSubmit: model.submitTwoFactorCode,
                                                    onResend: model.resendTwoFactor,
                                                    onCancel: model.cancelSignIn,
                                                    onChooseMethod: { model.selectTwoFactorMethod(numberID: $0) })
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    .animation(motionAllowed ? .easeInOut(duration: 0.24) : nil, value: model.showInlineTwoFactor)

                    if model.isLoggingIn && !model.showInlineTwoFactor {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(model.loginStage.isEmpty ? "Signing in…" : model.loginStage)
                                .font(.caption)
                                .foregroundStyle(Color.primary.opacity(0.7))
                        }
                    }

                    if !model.showInlineTwoFactor, let error = model.authentication.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if model.authentication.phase == .signedIn {
                        Label("Signed in and saved securely", systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                    }

                    if let notice = model.authenticationNotice {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Label("Protected by macOS Keychain", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.7))
                        Spacer()
                        if model.isLoggingIn && !model.showInlineTwoFactor {
                            Button("Cancel Sign-In", action: model.cancelSignIn)
                        }
                        Button(model.isLoggingIn ? "Signing In…" : (model.authentication.phase == .failed ? "Try Sign-In Again" : "Sign In & Save"), action: signIn)
                            .foregroundStyle(.primary)
                            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || model.isAuthenticating)
                    }

                }
            }
            .padding(2)
        } label: {
            Label("Add an account", systemImage: "plus.circle")
        }
    }

    private var motionAllowed: Bool { appearance.motionAllowed && !reduceMotion }

    private func signIn() {
        guard !model.isAuthenticating, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        let targetEmail = email
        let targetPassword = password
        let targetName = profileName
        let targetURL = profileImageURL
        Task {
            let success = await model.signInAccount(email: targetEmail, password: targetPassword,
                                                    profileName: targetName, profileImageURL: targetURL)
            if success {
                email = ""
                password = ""
                profileName = ""
                profileImageURL = nil
                appearance.completionFeedback()
            }
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
                Circle()
                    .fill(Color.primary.opacity(0.065))
                Text(profile.initials)
                    .font(.system(size: size * 0.29, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .overlay {
            if selected {
                Circle().stroke(Color.accentColor, lineWidth: 2)
            }
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
        .accessibilityLabel("\(profile.displayName) profile picture")
    }
}
