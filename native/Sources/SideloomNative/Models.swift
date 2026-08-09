import Foundation

struct DeviceInfo: Codable, Hashable, Identifiable {
    let name: String
    let id: UInt32
    let udid: String
    let connectionType: String
    let version: String
    let productType: String?
    let deviceColor: String?

    var identity: String { "\(udid)-\(id)" }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? marketingName : trimmed
    }

    var showsModelBesideName: Bool {
        displayName.caseInsensitiveCompare(marketingName) != .orderedSame
    }

    var marketingName: String {
        guard let productType, !productType.isEmpty else { return "iPhone" }
        return Self.marketingNames[productType] ?? "iPhone · \(productType)"
    }

    var usesDynamicIsland: Bool {
        guard let productType else { return false }
        if productType == "iPhone17,5" { return false }
        let islandModels: Set<String> = ["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4"]
        if islandModels.contains(productType) { return true }
        return Int(productType.dropFirst("iPhone".count).split(separator: ",").first ?? "0") ?? 0 >= 18
    }

    var isLargeDisplayModel: Bool {
        guard let productType else { return false }
        return ["iPhone13,4", "iPhone14,3", "iPhone14,8", "iPhone15,3", "iPhone15,5", "iPhone16,2", "iPhone17,2", "iPhone17,4", "iPhone18,2"].contains(productType)
    }

    private static let marketingNames: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE (3rd generation)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air"
    ]
}

struct IpaExtensionInfo: Codable, Hashable, Identifiable {
    let path: String
    let bundleId: String
    let name: String
    let extensionPoint: String?

    var id: String { path }
}

struct IpaInfo: Codable, Hashable {
    let path: String
    let fileName: String
    let appName: String
    let bundleId: String
    let version: String
    let buildVersion: String
    let minimumOsVersion: String?
    let executable: String?
    let encryptionStatus: String
    let sizeBytes: UInt64
    let extensions: [IpaExtensionInfo]
    let appIdCost: Int
    let warnings: [String]
}

struct CertificateInfo: Codable, Hashable, Identifiable {
    let name: String?
    let serialNumber: String?
    let machineName: String?

    var id: String { serialNumber ?? UUID().uuidString }
}

struct InstalledAppInfo: Codable, Hashable, Identifiable {
    let bundleId: String
    let name: String
    let version: String
    let buildVersion: String
    let applicationType: String

    var id: String { bundleId }
}

struct CoreEvent: Codable {
    let type: String
    let devices: [DeviceInfo]?
    let errors: [String]?
    let ipa: IpaInfo?
    let stage: String?
    let value: Double?
    let message: String?
    let certificates: [CertificateInfo]?
    let apps: [InstalledAppInfo]?
    let bundleIds: [String]?
    let email: String?
    let accountName: String?
}

struct UninstallAppsRequest: Codable {
    let device: DeviceInfo
    let bundleIds: [String]
}

struct PlistOverride: Codable, Hashable, Identifiable {
    var id: UUID
    var key: String
    var valueType: String
    var value: String

    init(id: UUID = UUID(), key: String = "", valueType: String = "String", value: String = "") {
        self.id = id
        self.key = key
        self.valueType = valueType
        self.value = value
    }
}

struct IpaInstallOptions: Codable, Hashable {
    let appPath: String
    let displayName: String?
    let bundleId: String?
    let removedExtensions: [String]
    let customIconPath: String?
    let increasedMemoryLimit: Bool
    let minimumOsVersion: String?
    let removeSupportedDevices: Bool
    let enableFileSharing: Bool
    let plistOverrides: [PlistOverride]

    init(
        appPath: String,
        displayName: String?,
        bundleId: String?,
        removedExtensions: [String],
        customIconPath: String?,
        increasedMemoryLimit: Bool,
        minimumOsVersion: String? = nil,
        removeSupportedDevices: Bool = false,
        enableFileSharing: Bool = false,
        plistOverrides: [PlistOverride] = []
    ) {
        self.appPath = appPath
        self.displayName = displayName
        self.bundleId = bundleId
        self.removedExtensions = removedExtensions
        self.customIconPath = customIconPath
        self.increasedMemoryLimit = increasedMemoryLimit
        self.minimumOsVersion = minimumOsVersion
        self.removeSupportedDevices = removeSupportedDevices
        self.enableFileSharing = enableFileSharing
        self.plistOverrides = plistOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case appPath, displayName, bundleId, removedExtensions, customIconPath
        case increasedMemoryLimit, minimumOsVersion, removeSupportedDevices
        case enableFileSharing, plistOverrides
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appPath = try values.decode(String.self, forKey: .appPath)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        bundleId = try values.decodeIfPresent(String.self, forKey: .bundleId)
        removedExtensions = try values.decodeIfPresent([String].self, forKey: .removedExtensions) ?? []
        customIconPath = try values.decodeIfPresent(String.self, forKey: .customIconPath)
        increasedMemoryLimit = try values.decodeIfPresent(Bool.self, forKey: .increasedMemoryLimit) ?? false
        minimumOsVersion = try values.decodeIfPresent(String.self, forKey: .minimumOsVersion)
        removeSupportedDevices = try values.decodeIfPresent(Bool.self, forKey: .removeSupportedDevices) ?? false
        enableFileSharing = try values.decodeIfPresent(Bool.self, forKey: .enableFileSharing) ?? false
        plistOverrides = try values.decodeIfPresent([PlistOverride].self, forKey: .plistOverrides) ?? []
    }
}

struct ExportRequest: Codable {
    let destination: String
    let options: IpaInstallOptions
}

struct InstallRequest: Codable {
    let email: String
    let password: String
    let anisetteServer: String
    let storagePath: String
    let device: DeviceInfo
    let options: IpaInstallOptions
}

enum SideloomError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
