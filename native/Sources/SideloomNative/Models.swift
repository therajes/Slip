import Foundation

struct DeviceInfo: Codable, Hashable, Identifiable {
    let name: String
    let id: UInt32
    let udid: String
    let connectionType: String
    let version: String

    var identity: String { "\(udid)-\(id)" }
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
