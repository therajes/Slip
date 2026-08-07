import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""

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
                                HStack {
                                    Image(systemName: model.selectedAccount == account ? "checkmark.circle.fill" : "person.crop.circle")
                                        .foregroundStyle(model.selectedAccount == account ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(account).fontWeight(.medium)
                                        Text(model.selectedAccount == account ? "Used for the next install" : "Stored in macOS Keychain")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedAccount != account {
                                        Button("Use") { model.chooseAccount(account) }
                                    }
                                    Button("Remove", role: .destructive) { model.deleteAccount(account) }
                                }
                                .padding(.vertical, 10)
                                if account != model.accounts.last { Divider() }
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Saved accounts", systemImage: "key.horizontal")
                }

                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                        GridRow {
                            Text("Apple Account")
                            TextField("name@example.com", text: $email)
                                .textContentType(.username)
                                .frame(minWidth: 320)
                        }
                        GridRow {
                            Text("Password")
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        }
                    }
                    .padding(10)
                    HStack {
                        Label("Protected by macOS Keychain", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Account") {
                            model.saveAccount(email: email, password: password)
                            if model.errorMessage == nil {
                                email = ""
                                password = ""
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(email.isEmpty || password.isEmpty)
                    }
                    .padding([.horizontal, .bottom], 10)
                } label: {
                    Label("Add an account", systemImage: "plus.circle")
                }

                Text("Slip does not upload your IPA or Apple Account credentials to its own service. Apple authentication requires the selected Anisette provider, currently \(model.anisetteServer).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .background(.background)
    }
}
