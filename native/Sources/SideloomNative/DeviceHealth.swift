import Foundation

struct DeviceHealthEvidence: Equatable {
    var lastSeen: Date?
    var lastCheck: Date?
    var transport: String?
    var recentConnectionChange: String?

    static func maskedIdentity(_ udid: String) -> String {
        udid.isEmpty ? "Unknown" : "…" + udid.suffix(4)
    }
}

extension AppModel {
    func updateDeviceHealth(discovered: [DeviceInfo], at date: Date = Date()) {
        let present = Set(discovered.map(\.udid))
        for previous in devices where !present.contains(previous.udid) {
            var evidence = deviceHealth[previous.udid] ?? .init()
            evidence.lastCheck = date
            evidence.recentConnectionChange = "No longer returned by discovery. The cause is unknown; reconnect USB or retest Wi-Fi."
            deviceHealth[previous.udid] = evidence
        }
        for device in discovered {
            var evidence = deviceHealth[device.udid] ?? .init()
            if let transport = evidence.transport, transport != device.connectionType {
                evidence.recentConnectionChange = "Transport changed from \(transport) to \(device.connectionType)."
            }
            evidence.lastSeen = date
            evidence.lastCheck = date
            evidence.transport = device.connectionType
            deviceHealth[device.udid] = evidence
        }
        if deviceHealth.count > 64 {
            let retained = deviceHealth.sorted { ($0.value.lastSeen ?? .distantPast) > ($1.value.lastSeen ?? .distantPast) }.prefix(64)
            deviceHealth = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
    }
}
