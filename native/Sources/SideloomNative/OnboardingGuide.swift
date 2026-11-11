import SwiftUI

struct OnboardingGuide: View {
    @AppStorage("slipOnboardingCompleted30") private var completed = false
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded || !completed }, set: { expanded = $0; if !$0 { completed = true } })) {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Inspect an authorized IPA offline. Sign-in is only needed when you sign or install.")
                Text("2. Connect your iPhone by USB, unlock it and accept Trust This Computer. Check Developer Mode on the iPhone. Wi-Fi requires a paired, reachable device.")
                Text("3. Add your Apple Account using the existing verification flow. Keychain password storage is your choice; unattended renewal requires usable saved credentials.")
                Text("4. Review Installation Readiness, signing identity, extensions and capabilities, then install. Slip verifies the intended iPhone or reports an unknown outcome.")
                Text("5. Approve the saved renewal source and optionally enable background refresh and notifications. Free profiles typically expire after seven days; Apple limits still apply. This Mac must be awake and the iPhone reachable.")
                Text("New in 3.0: a menu companion, shared renewal eligibility, explicit waiting reasons, source approval and private renewal history. Slip does not implement iPhone-only signing or restore private iPhone app data.")
                Button("I understand — keep these instructions in Settings") { completed = true; expanded = false }
            }.font(.callout).padding(.vertical, 8)
        } label: { Label("Getting started and What's New in 3.0", systemImage: "sparkles") }
    }
}
