import Foundation

enum SlipIssueLevel {
    case ready
    case warning
    case blocking
}

struct SlipReadinessIssue: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let level: SlipIssueLevel
}

extension AppModel {
    static let protectedPlistKeys: Set<String> = [
        "CFBundleIdentifier",
        "CFBundleExecutable",
        "CFBundlePackageType",
        "CFBundleSupportedPlatforms",
        "DTPlatformName",
        "DTPlatformVersion",
        "LSRequiresIPhoneOS"
    ]

    var effectiveBundleID: String {
        let custom = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? (ipa?.bundleId ?? "") : custom
    }

    var effectiveMinimumOS: String? {
        let custom = minimumOSVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? ipa?.minimumOsVersion : custom
    }

    var keptExtensionCount: Int {
        ipa?.extensions.filter { !removedExtensions.contains($0.path) }.count ?? 0
    }

    var effectiveAppIDCost: Int {
        ipa == nil ? 0 : keptExtensionCount + 1
    }

    var customizationCount: Int {
        var count = 0
        if !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if !customBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if customIconURL != nil { count += 1 }
        if !removedExtensions.isEmpty { count += 1 }
        if !minimumOSVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if removeSupportedDevices { count += 1 }
        if enableFileSharing { count += 1 }
        if increasedMemoryLimit { count += 1 }
        count += plistOverrides.count
        return count
    }

    var customizationIssues: [SlipReadinessIssue] {
        guard let ipa else { return [] }
        var result: [SlipReadinessIssue] = []

        if !isValidBundleID(effectiveBundleID) {
            result.append(.init(
                id: "bundle-id",
                title: "Bundle ID is invalid",
                detail: "Use dot-separated letters, numbers, and hyphens, such as com.example.app.",
                symbol: "text.badge.xmark",
                level: .blocking
            ))
        }

        if let minimum = effectiveMinimumOS, !minimum.isEmpty {
            if versionComponents(minimum) == nil {
                result.append(.init(
                    id: "minimum-ios",
                    title: "Minimum iOS version is invalid",
                    detail: "Use a numeric version such as 17.0 or 27.0.1.",
                    symbol: "number",
                    level: .blocking
                ))
            } else if let original = ipa.minimumOsVersion,
                      compareVersions(minimum, original) == .orderedAscending {
                result.append(.init(
                    id: "minimum-ios-lowered",
                    title: "Lowering compatibility cannot add missing APIs",
                    detail: "The app may still fail to launch on systems older than " + original + ".",
                    symbol: "exclamationmark.triangle",
                    level: .warning
                ))
            }
        }

        let normalizedKeys = plistOverrides.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
        let duplicates = Dictionary(grouping: normalizedKeys.filter { !$0.isEmpty }, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        if !duplicates.isEmpty {
            result.append(.init(
                id: "duplicate-plist",
                title: "Duplicate Info.plist keys",
                detail: duplicates.joined(separator: ", "),
                symbol: "square.on.square",
                level: .blocking
            ))
        }

        for item in plistOverrides {
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                result.append(.init(id: "empty-\(item.id)", title: "Info.plist key is empty", detail: "Enter a key or remove the row.", symbol: "list.bullet.rectangle", level: .blocking))
            } else if Self.protectedPlistKeys.contains(key) {
                result.append(.init(id: "protected-\(item.id)", title: key + " is protected", detail: "Use Slip’s dedicated identity controls instead.", symbol: "lock.fill", level: .blocking))
            }

            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid: Bool
            switch item.valueType {
            case "Boolean": valid = value == "true" || value == "false"
            case "Integer": valid = Int64(value) != nil
            case "Real": valid = Double(value) != nil
            default: valid = true
            }
            if !valid {
                result.append(.init(id: "value-\(item.id)", title: "Invalid " + item.valueType.lowercased() + " for " + (key.isEmpty ? "plist key" : key), detail: "Correct the typed value before continuing.", symbol: "exclamationmark.circle", level: .blocking))
            }
        }

        if let customIconURL, !FileManager.default.fileExists(atPath: customIconURL.path) {
            result.append(.init(id: "missing-icon", title: "Custom icon is unavailable", detail: "Choose the image again.", symbol: "photo.badge.exclamationmark", level: .blocking))
        }

        return result
    }

    var installReadiness: [SlipReadinessIssue] {
        var result = customizationIssues
        guard let ipa else {
            return [.init(id: "ipa", title: "Choose an IPA", detail: "Drop a decrypted IPA or select one in Finder.", symbol: "shippingbox", level: .blocking)]
        }
        if selectedDevice == nil {
            result.append(.init(id: "device", title: "Connect an iPhone", detail: "Unlock it and complete Trust pairing once over USB.", symbol: "iphone.slash", level: .blocking))
        }
        if selectedAccount.isEmpty {
            result.append(.init(id: "account", title: "Choose an Apple Account", detail: "Add one in Apple Accounts; its password stays in Keychain.", symbol: "person.badge.key", level: .blocking))
        }
        if ipa.encryptionStatus == "Encrypted" {
            result.append(.init(id: "encrypted", title: "App Store encryption detected", detail: "This IPA can be signed but will not launch. Use a legitimately decrypted IPA.", symbol: "lock.fill", level: .blocking))
        }
        if let device = selectedDevice,
           let minimum = effectiveMinimumOS,
           compareVersions(device.version, minimum) == .orderedAscending {
            result.append(.init(id: "device-version", title: "iPhone is below the app’s minimum iOS", detail: device.name + " runs iOS " + device.version + "; this setup requires iOS " + minimum + ".", symbol: "iphone.badge.exclamationmark", level: .blocking))
        }
        if selectedDevice?.connectionType.caseInsensitiveCompare("Network") == .orderedSame,
           ipa.sizeBytes > 250_000_000 {
            result.append(.init(id: "large-wifi", title: "USB will be faster for this IPA", detail: "The selected network transfer is " + Int64(ipa.sizeBytes).formatted(.byteCount(style: .file)) + ".", symbol: "cable.connector", level: .warning))
        }
        if effectiveAppIDCost > 1 {
            result.append(.init(id: "app-ids", title: "This setup uses " + String(effectiveAppIDCost) + " App IDs", detail: "Remove optional extensions to conserve a free Apple Account’s quota.", symbol: "square.stack.3d.up", level: .warning))
        }
        if result.isEmpty {
            result.append(.init(id: "ready", title: "Ready to sign and install", detail: "Slip validated the IPA, destination, account, and customizations.", symbol: "checkmark.seal.fill", level: .ready))
        }
        return result
    }

    var blockingInstallIssue: SlipReadinessIssue? {
        installReadiness.first { $0.level == .blocking }
    }

    var canInstall: Bool {
        !isInstalling && blockingInstallIssue == nil
    }

    var canExport: Bool {
        ipa != nil && !customizationIssues.contains { $0.level == .blocking } && ipa?.encryptionStatus != "Encrypted"
    }

    private func isValidBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.contains(".") && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private func versionComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.compactMap { Int($0) }
    }

    private func compareVersions(_ left: String, _ right: String) -> ComparisonResult? {
        guard var lhs = versionComponents(left), var rhs = versionComponents(right) else { return nil }
        while lhs.count < 3 { lhs.append(0) }
        while rhs.count < 3 { rhs.append(0) }
        for (a, b) in zip(lhs, rhs) {
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }
}
