import Foundation

final class MemoryStore: StateStore {
    var backup: Backup?
    var failSave = false
    func load() throws -> Backup? { backup }
    func save(_ backup: Backup) throws { if failSave { throw SwitchError("disk full") }; self.backup = backup }
    func remove() throws { backup = nil }
}

final class FakeNetwork: NetworkBackend {
    let store: MemoryStore
    var configuration: Settings
    var failApplyOnce = false
    var failEnableVerify = false
    var failRestoreVerify = false
    var changeDNSOnVerify = false
    var writes = 0
    var allowPreflight = true
    let id = "11111111-1111-1111-1111-111111111111"
    init(_ store: MemoryStore, _ settings: Settings = Settings(routes: nil, dns: nil)) {
        self.store = store; configuration = settings
    }
    func preflight(_ serviceID: String) throws -> ServiceInfo {
        if !allowPreflight { throw SwitchError("VPN conflict") }
        return ServiceInfo(id: id, name: "Wi-Fi", device: "en0", addresses: ["192.168.1.25"],
                           masks: ["255.255.255.0"], dhcp: true, router: "192.168.1.1", dns: ["192.168.1.1"])
    }
    func settings(_ serviceID: String) throws -> Settings { configuration }
    func apply(_ settings: Settings, to serviceID: String) throws {
        if store.backup == nil { fatalError("System write without durable backup") }
        writes += 1
        if failApplyOnce {
            failApplyOnce = false; configuration.dns = settings.dns
            throw SwitchError("partial commit")
        }
        configuration = settings
    }
    func verifyRuntime(_ backup: Backup, enabled: Bool) throws {
        if enabled && changeDNSOnVerify { configuration.dns = ["9.9.9.9"] }
        if (enabled && (failEnableVerify || changeDNSOnVerify)) || (!enabled && failRestoreVerify) {
            throw SwitchError("runtime verification failed")
        }
    }
}

@main enum Tests {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: " + message) }
        count += 1; print("PASS: " + message)
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAIL expected rejection: " + message) }
        catch { check(true, message) }
    }
    static func main() throws {
        let original = Settings(routes: [["DestinationAddress": "10.0.0.0", "SubnetMask": "255.0.0.0",
                                         "GatewayAddress": "192.168.1.2", "InterfaceName": "en0"]], dns: ["1.1.1.1", "8.8.8.8"])
        let store = MemoryStore(); let net = FakeNetwork(store, original)
        let engine = SwitchEngine(network: net, store: store)
        try engine.enable(net.id)
        check(net.configuration.routes?.count == 3, "Existing routes are preserved alongside both half-default routes")
        check(net.configuration.dns == [bypassGateway], "Bypass DNS is saved")
        check(store.backup?.original == original, "Backup retains static DNS and unknown route keys")
        rejects("A second enable never replaces recovery data") { try engine.enable(net.id) }
        check(net.writes == 1, "Duplicate enable performs no additional writes")
        // New engine simulates exiting the app and reopening it, using durable state.
        try SwitchEngine(network: net, store: store).restore()
        check(net.configuration == original && store.backup == nil, "Reopened app restores original configuration exactly")
        try engine.restore()
        check(net.writes == 2, "Restore with no backup is a no-op")

        let automatic = Settings(routes: nil, dns: nil)
        net.configuration = automatic
        try engine.enable(net.id); try engine.restore()
        check(net.configuration == automatic, "Automatic DNS and absent additional-route keys survive round trip")
        net.failApplyOnce = true
        rejects("Partial mutation triggers rollback") { try engine.enable(net.id) }
        check(net.configuration == automatic && store.backup == nil, "Partial DNS-only mutation rolls back safely")
        net.failEnableVerify = true
        rejects("Runtime route verification failure triggers rollback") { try engine.enable(net.id) }
        check(net.configuration == automatic && store.backup == nil, "Saved settings alone do not count as success")
        net.failRestoreVerify = true
        rejects("Failed rollback retains recovery") { try engine.enable(net.id) }
        check(store.backup?.restorePending == true, "Restore intent survives a failed verification")
        rejects("Recovery-pending state blocks another enable") { try engine.enable(net.id) }
        net.failEnableVerify = false; net.failRestoreVerify = false
        try engine.restore()
        check(store.backup == nil, "Restoration can be retried after settings were already restored")

        net.changeDNSOnVerify = true
        rejects("Concurrent DNS modification stops automatic restoration") { try engine.enable(net.id) }
        check(net.configuration.dns == ["9.9.9.9"] && store.backup != nil, "External DNS is not overwritten and backup remains")
        net.configuration.dns = [bypassGateway]; net.changeDNSOnVerify = false
        try engine.restore()
        check(net.configuration == automatic, "Recovery succeeds after resolving conflict")
        store.failSave = true
        let writesBefore = net.writes
        rejects("Disk failure stops enable before mutation") { try engine.enable(net.id) }
        check(net.writes == writesBefore, "No network mutation without durable backup")
        store.failSave = false; net.allowPreflight = false
        rejects("VPN/preflight failure stops enable") { try engine.enable(net.id) }
        check(store.backup == nil && net.writes == writesBefore, "Preflight rejection changes neither network nor backup")
        net.allowPreflight = true; net.configuration = Settings(routes: Settings.bypassRoutes, dns: nil)
        rejects("Preexisting half-default routes are never taken over") { try engine.enable(net.id) }

        let encoded = try JSONEncoder().encode(Backup(serviceID: net.id, serviceName: "Ethernet", device: "en5", original: original, created: Date()))
        let decoded = try JSONDecoder().decode(Backup.self, from: encoded)
        try decoded.validate()
        check(decoded.original == original, "Recovery encoding is lossless")
        var invalid = decoded; invalid.schema = 999
        rejects("Unknown recovery schemas fail closed") { try invalid.validate() }
        check(shellQuote("a'b $(touch /tmp/no)") == "'a'\\''b $(touch /tmp/no)'", "Shell quoting keeps metacharacters literal")
        check(appleScriptString("a\\\"b") == "\"a\\\\\\\"b\"", "AppleScript quoting escapes nested shell command")
        let rows = parseRouteTable("""
        Routing tables
        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            192.168.1.1        UGScg          en0
        0/1                192.168.1.192      UGSc           en0
        128.0/1            192.168.1.192      UGSc           en0
        10.0.0.0/8         link#12            UCS           utun3
        """)
        check(rows.count == 4 && rows.filter { $0.halfDefault }.count == 2, "Darwin netstat half-default formats are parsed")
        check(rows[0].device == "en0", "Route interface uses header position, not the expiring column")
        let good = try net.preflight(net.id)
        check(good.eligible, "Home DHCP interface is eligible")
        let manual = ServiceInfo(id: net.id, name: "Ethernet", device: "en0", addresses: ["192.168.1.25"], masks: ["255.255.255.0"], dhcp: false, router: "", dns: [])
        check(!manual.eligible, "Manual IPv4 configuration is rejected")
        let reserved = ServiceInfo(id: net.id, name: "Ethernet", device: "en0", addresses: [bypassGateway], masks: ["255.255.255.0"], dhcp: true, router: "", dns: [])
        check(!reserved.eligible, "The bypass router address cannot be used as a client")
        print("TOTAL: \(count) checks passed; no system network writes")
    }
}
