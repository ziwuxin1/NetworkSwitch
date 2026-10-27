import Foundation
import SystemConfiguration
import Darwin

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SwitchError(message) }
}

final class SecureStore: StateStore {
    static let directory = "/Library/Application Support/NetworkSwitch"
    let statePath = directory + "/restore.json"
    private var lockFD: Int32 = -1

    init(writable: Bool = false) throws {
        if writable {
            try require(geteuid() == 0, "修改网络需要管理员授权。")
            if mkdir(Self.directory, 0o755) != 0 && errno != EEXIST {
                throw SwitchError("无法创建恢复目录。")
            }
        }
        if FileManager.default.fileExists(atPath: Self.directory) {
            try Self.validatePath(Self.directory, directory: true)
        }
        if writable {
            lockFD = open(Self.directory + "/operation.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            try require(lockFD >= 0, "无法创建操作锁。")
            var info = stat()
            try require(fstat(lockFD, &info) == 0 && info.st_uid == 0 &&
                        (info.st_mode & 0o022) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1,
                        "操作锁权限异常。")
            try require(flock(lockFD, LOCK_EX | LOCK_NB) == 0, "另一个网络操作正在执行，请稍后重试。")
        }
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }

    static func validatePath(_ path: String, directory: Bool) throws {
        var info = stat()
        try require(lstat(path, &info) == 0 && info.st_uid == 0 && (info.st_mode & 0o022) == 0 &&
                    (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) && (directory || info.st_nlink == 1),
                    "恢复文件权限或类型异常，未修改网络：\(path)")
    }
    func load() throws -> Backup? {
        var info = stat()
        if lstat(statePath, &info) != 0 {
            if errno == ENOENT { return nil }
            throw SwitchError("无法读取恢复记录。")
        }
        try Self.validatePath(Self.directory, directory: true)
        try Self.validatePath(statePath, directory: false)
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))
        try backup.validate()
        return backup
    }
    func save(_ backup: Backup) throws {
        try require(lockFD >= 0, "恢复记录只读。")
        try backup.validate()
        let data = try JSONEncoder().encode(backup)
        let temporary = Self.directory + "/.restore-" + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        try require(fd >= 0, "无法写入恢复记录。")
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                try require(amount > 0, "恢复记录写入失败。")
                offset += amount
            }
        }
        try require(fsync(fd) == 0 && rename(temporary, statePath) == 0, "恢复记录保存失败。")
        syncDirectory()
    }
    func remove() throws {
        try require(lockFD >= 0, "恢复记录只读。")
        try Self.validatePath(statePath, directory: false)
        try require(unlink(statePath) == 0, "网络已恢复，但备份清理失败。")
        syncDirectory()
    }
    private func syncDirectory() {
        let fd = open(Self.directory, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
}

// All child commands are fixed system binaries with argv arrays, never shells.
// Read the pipe concurrently to avoid deadlock on a large route table.
func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let completed = DispatchSemaphore(value: 0)
    var output = Data()
    DispatchQueue.global().async { output = pipe.fileHandleForReading.readDataToEndOfFile(); completed.signal() }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.04) }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        _ = completed.wait(timeout: .now() + 2)
        throw SwitchError("系统查询超时：\(URL(fileURLWithPath: executable).lastPathComponent)")
    }
    process.waitUntilExit()
    completed.wait()
    let text = String(data: output, encoding: .utf8) ?? ""
    try require(process.terminationStatus == 0, "系统命令失败：\(text.prefix(600))")
    return text
}

final class MacNetwork: NetworkBackend {
    let preferences: SCPreferences
    let dynamic: SCDynamicStore
    private let locked: Bool

    init(writable: Bool = false) throws {
        guard let p = SCPreferencesCreate(nil, "NetworkSwitch" as CFString, nil),
              let d = SCDynamicStoreCreate(nil, "NetworkSwitch" as CFString, nil, nil) else {
            throw SwitchError("无法读取 macOS 网络配置。")
        }
        preferences = p; dynamic = d
        if writable { try require(SCPreferencesLock(p, false), "网络设置正被其他程序修改，请稍后重试。") }
        locked = writable
    }
    deinit { if locked { SCPreferencesUnlock(preferences) } }

    func state(_ key: String) -> [String: Any] {
        SCDynamicStoreCopyValue(dynamic, key as CFString) as? [String: Any] ?? [:]
    }
    func currentServices() -> [SCNetworkService] {
        guard let set = SCNetworkSetCopyCurrent(preferences) else { return [] }
        return SCNetworkSetCopyServices(set) as? [SCNetworkService] ?? []
    }
    func service(_ id: String) throws -> SCNetworkService {
        guard UUID(uuidString: id) != nil, let service = SCNetworkServiceCopy(preferences, id as CFString) else {
            throw SwitchError("找不到原网络服务，恢复记录保留；请重新连接原网卡。")
        }
        return service
    }
    func proto(_ id: String, _ type: CFString) throws -> SCNetworkProtocol {
        guard let p = SCNetworkServiceCopyProtocol(try service(id), type) else {
            throw SwitchError("网络服务缺少所需协议，未修改网络。")
        }
        return p
    }
    func config(_ id: String, _ type: CFString) throws -> [String: Any] {
        SCNetworkProtocolGetConfiguration(try proto(id, type)) as? [String: Any] ?? [:]
    }
    func info(_ service: SCNetworkService) -> ServiceInfo? {
        guard SCNetworkServiceGetEnabled(service), let interface = SCNetworkServiceGetInterface(service),
              let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
              bsd.range(of: "^en[0-9]+$", options: .regularExpression) != nil,
              let type = SCNetworkInterfaceGetInterfaceType(interface),
              [kSCNetworkInterfaceTypeEthernet, kSCNetworkInterfaceTypeIEEE80211].contains(type) else { return nil }
        guard let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
        let live = state("State:/Network/Service/\(id)/IPv4")
        let configuredDNS = (try? config(id, kSCNetworkProtocolTypeDNS))?["ServerAddresses"] as? [String]
        let dns = configuredDNS ?? (state("State:/Network/Service/\(id)/DNS")["ServerAddresses"] as? [String] ?? [])
        return ServiceInfo(id: id, name: SCNetworkServiceGetName(service) as String? ?? bsd,
                           device: bsd, addresses: live["Addresses"] as? [String] ?? [],
                           masks: live["SubnetMasks"] as? [String] ?? [],
                           dhcp: (try? config(id, kSCNetworkProtocolTypeIPv4)["ConfigMethod"] as? String) == "DHCP",
                           router: live["Router"] as? String ?? "—", dns: dns)
    }
    func services() -> [ServiceInfo] { currentServices().compactMap(info).sorted { $0.name < $1.name } }

    func settings(_ serviceID: String) throws -> Settings {
        let ip = try config(serviceID, kSCNetworkProtocolTypeIPv4)
        let dns = try config(serviceID, kSCNetworkProtocolTypeDNS)
        if ip["AdditionalRoutes"] != nil && !(ip["AdditionalRoutes"] is [[String: String]]) {
            throw SwitchError("存在无法无损保存的附加路由配置，未修改网络。")
        }
        if dns["ServerAddresses"] != nil && !(dns["ServerAddresses"] is [String]) {
            throw SwitchError("DNS 配置格式不受支持，未修改网络。")
        }
        return Settings(routes: ip["AdditionalRoutes"] as? [[String: String]], dns: dns["ServerAddresses"] as? [String])
    }

    func apply(_ settings: Settings, to serviceID: String) throws {
        try require(locked && geteuid() == 0, "修改网络需要管理员授权。")
        let ipProtocol = try proto(serviceID, kSCNetworkProtocolTypeIPv4)
        let dnsProtocol = try proto(serviceID, kSCNetworkProtocolTypeDNS)
        var ip = try config(serviceID, kSCNetworkProtocolTypeIPv4)
        var dns = try config(serviceID, kSCNetworkProtocolTypeDNS)
        ip["AdditionalRoutes"] = settings.routes
        dns["ServerAddresses"] = settings.dns
        try require(SCNetworkProtocolSetConfiguration(ipProtocol, ip as CFDictionary) &&
                    SCNetworkProtocolSetConfiguration(dnsProtocol, dns as CFDictionary), "无法准备网络设置。")
        try require(SCPreferencesCommitChanges(preferences), "网络设置保存失败。")
        try require(SCPreferencesApplyChanges(preferences), "网络设置已保存，但应用失败，请恢复原配置。")
        SCPreferencesSynchronize(preferences)
    }

    func preflight(_ serviceID: String) throws -> ServiceInfo {
        guard let selected = services().first(where: { $0.id == serviceID }), selected.eligible else {
            throw SwitchError("仅支持通过 DHCP 连接 192.168.1.x/24 的家庭以太网或 Wi-Fi。")
        }
        let primary = state("State:/Network/Global/IPv4")["PrimaryService"] as? String
        try require(primary == serviceID, "所选网卡不是当前 IPv4 主出口，请选择正在上网的网卡。")
        for s in currentServices() where SCNetworkServiceGetEnabled(s) {
            guard let id = SCNetworkServiceGetServiceID(s) as String? else { continue }
            if let ip = try? config(id, kSCNetworkProtocolTypeIPv4),
               let routes = ip["AdditionalRoutes"] as? [[String: String]] {
                try require(!Settings(routes: routes, dns: nil).hasHalfDefault, "网络服务中已有持久 IPv4 半默认路由，请先处理原路由。")
            }
        }
        let v4 = parseRouteTable(try command("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        let v6 = parseRouteTable(try command("/usr/sbin/netstat", ["-rn", "-f", "inet6"]))
        try NetworkRoutes(ipv4: v4, ipv6: v6).validateIPv4Switch(selectedDevice: selected.device)
        let proxies = SCDynamicStoreCopyProxies(dynamic) as? [String: Any] ?? [:]
        let enabledKeys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
        let serviceProxies = (try? config(serviceID, kSCNetworkProtocolTypeProxies)) ?? [:]
        try require(!enabledKeys.contains { (proxies[$0] as? NSNumber)?.boolValue == true ||
                    (serviceProxies[$0] as? NSNumber)?.boolValue == true }, "系统代理或 PAC 已开启，请先关闭。")
        _ = try command("/usr/bin/nc", ["-z", "-G", "2", bypassGateway, "80"], timeout: 4)
        try checkDNS()
        return selected
    }
    func checkDNS() throws {
        let output = try command("/usr/bin/dig", ["@" + bypassGateway, "example.com", "A", "+short", "+time=2", "+tries=1"], timeout: 4)
        try require(output.split(separator: "\n").contains { line in
            let pieces = line.split(separator: ".")
            return pieces.count == 4 && pieces.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        }, "旁路由 DNS 没有返回有效 IPv4 地址。")
    }
    func active(_ backup: Backup) throws -> Bool {
        guard let current = info(try service(backup.serviceID)), current.device == backup.device,
              current.eligible, try settings(backup.serviceID) == backup.original.enabled,
              state("Setup:/Network/Service/\(backup.serviceID)/DNS")["ServerAddresses"] as? [String] == [bypassGateway] else { return false }
        for address in ["1.1.1.1", "208.67.222.222"] {
            let output = try command("/sbin/route", ["-n", "get", address])
            let fields = Dictionary(output.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }, uniquingKeysWith: { _, last in last })
            if fields["gateway"] != bypassGateway || fields["interface"] != backup.device { return false }
        }
        return true
    }
    func verifyRuntime(_ backup: Backup, enabled: Bool) throws {
        for _ in 0..<20 {
            if enabled {
                if (try? active(backup)) == true { try checkDNS(); return }
            } else {
                let rows = parseRouteTable(try command("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
                let routesGone = !rows.contains { $0.halfDefault && $0.device == backup.device && $0.gateway == bypassGateway }
                let configuredDNS = state("Setup:/Network/Service/\(backup.serviceID)/DNS")["ServerAddresses"] as? [String]
                // configd's State DNS can still contain DHCP-provided servers;
                // applied manual overrides live in Setup, not in the DHCP dictionary.
                let dnsApplied = configuredDNS == backup.original.dns
                if routesGone && dnsApplied { return }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw SwitchError("配置已保存，但实际路由/DNS 尚未通过校验；恢复记录保留。")
    }
}
