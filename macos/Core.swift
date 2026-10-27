import Foundation

let appVersion = "1.0.0-beta.1"
let bypassGateway = "192.168.1.192"

struct SwitchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Keep the full dictionaries so additional routes belonging to other software
// survive a round trip, including keys unknown to this application.
struct Settings: Codable, Equatable {
    var routes: [[String: String]]?
    var dns: [String]?
    static let bypassRoutes: [[String: String]] = ["0.0.0.0", "128.0.0.0"].map {
        ["DestinationAddress": $0, "SubnetMask": "128.0.0.0", "GatewayAddress": bypassGateway]
    }
    var enabled: Settings {
        Settings(routes: (routes ?? []) + Self.bypassRoutes, dns: [bypassGateway])
    }
    var hasHalfDefault: Bool {
        (routes ?? []).contains {
            $0["SubnetMask"] == "128.0.0.0" &&
                ["0.0.0.0", "128.0.0.0"].contains($0["DestinationAddress"] ?? "")
        }
    }
}

struct ServiceInfo {
    let id: String
    let name: String
    let device: String
    let addresses: [String]
    let masks: [String]
    let dhcp: Bool
    let router: String
    let dns: [String]
    var eligible: Bool {
        guard dhcp, addresses.count == 1, masks == ["255.255.255.0"] else { return false }
        let parts = addresses[0].split(separator: ".").map(String.init)
        guard parts.count == 4, parts.prefix(3) == ["192", "168", "1"],
              let host = Int(parts[3]), (2...254).contains(host), host != 192 else { return false }
        return true
    }
}

struct Backup: Codable {
    var schema = 1
    let serviceID: String
    let serviceName: String
    let device: String
    let original: Settings
    var restorePending = false
    let created: Date

    func validate() throws {
        guard schema == 1, UUID(uuidString: serviceID) != nil,
              device.range(of: "^en[0-9]+$", options: .regularExpression) != nil,
              !original.hasHalfDefault else { throw SwitchError("恢复记录格式异常，未修改网络。") }
    }
}

protocol StateStore {
    func load() throws -> Backup?
    func save(_ backup: Backup) throws
    func remove() throws
}

protocol NetworkBackend {
    func preflight(_ serviceID: String) throws -> ServiceInfo
    func settings(_ serviceID: String) throws -> Settings
    func apply(_ settings: Settings, to serviceID: String) throws
    func verifyRuntime(_ backup: Backup, enabled: Bool) throws
}

// Privileged and UI code share no writable command scripts. The root worker
// serializes operations and owns recovery storage; tests inject both boundaries.
final class SwitchEngine {
    let network: NetworkBackend
    let store: StateStore
    init(network: NetworkBackend, store: StateStore) { self.network = network; self.store = store }

    func enable(_ serviceID: String) throws {
        guard try store.load() == nil else { throw SwitchError("已有恢复记录，请先恢复原配置。") }
        let service = try network.preflight(serviceID)
        guard service.eligible else { throw SwitchError("请选择通过 DHCP 连接 192.168.1.x/24 的家庭网卡。") }
        let original = try network.settings(serviceID)
        guard !original.hasHalfDefault else { throw SwitchError("已有 VPN 或半默认路由，请先处理原路由。") }
        let backup = Backup(serviceID: service.id, serviceName: service.name,
                            device: service.device, original: original, created: Date())
        try backup.validate()
        try store.save(backup) // durable recovery BEFORE the first system write
        do {
            try network.apply(original.enabled, to: serviceID)
            guard try network.settings(serviceID) == original.enabled else {
                throw SwitchError("持久路由或 DNS 保存校验失败。")
            }
            try network.verifyRuntime(backup, enabled: true)
        } catch {
            let reason = error.localizedDescription
            do { try restore() }
            catch { throw SwitchError("开启失败：\(reason)\n自动恢复未完成：\(error.localizedDescription)\n恢复记录已保留，请点击恢复原配置。") }
            throw SwitchError("开启失败，已恢复原配置：\(reason)")
        }
    }

    func restore() throws {
        guard var backup = try store.load() else { return }
        try backup.validate()
        backup.restorePending = true
        try store.save(backup)
        let current = try network.settings(backup.serviceID)
        let desired = backup.original.enabled
        // Accept a partial previous attempt, but never overwrite a third party's
        // new DNS/routes or silently delete the only remaining recovery record.
        guard (current.routes == desired.routes || current.routes == backup.original.routes),
              (current.dns == desired.dns || current.dns == backup.original.dns) else {
            throw SwitchError("路由或 DNS 已被其他程序更改。为避免覆盖新设置，恢复已停止，备份保留。")
        }
        try network.apply(backup.original, to: backup.serviceID)
        guard try network.settings(backup.serviceID) == backup.original else {
            throw SwitchError("恢复校验失败，备份保留，可再次恢复。")
        }
        try network.verifyRuntime(backup, enabled: false)
        try store.remove()
    }
}

struct RouteRow {
    let destination: String
    let gateway: String
    let device: String
    var halfDefault: Bool { ["0/1", "0.0.0.0/1", "128.0/1", "128/1", "128.0.0.0/1"].contains(destination) }
}

func parseRouteTable(_ text: String) -> [RouteRow] {
    var deviceColumn: Int?
    var rows: [RouteRow] = []
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if fields.first == "Destination" { deviceColumn = fields.firstIndex(of: "Netif"); continue }
        guard let column = deviceColumn, fields.count > column, fields.count >= 3 else { continue }
        rows.append(RouteRow(destination: fields[0], gateway: fields[1], device: fields[column]))
    }
    return rows
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleScriptString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r") + "\""
}
