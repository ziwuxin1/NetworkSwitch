import AppKit

@main
enum NetworkSwitchApp {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 2 && args[1] == "--worker" {
            do {
                guard args.count == 3 || args.count == 4 else { throw SwitchError("参数无效。") }
                let store = try SecureStore(writable: true)
                let network = try MacNetwork(writable: true)
                let engine = SwitchEngine(network: network, store: store)
                if args[2] == "enable", args.count == 4, UUID(uuidString: args[3]) != nil {
                    try engine.enable(args[3])
                    print("旁路由已开启，配置已保存。退出程序后仍保留，直到恢复原配置。")
                } else if args[2] == "restore", args.count == 3 {
                    try engine.restore()
                    print("已恢复切换前的路由和 DNS 配置。")
                } else { throw SwitchError("参数无效。") }
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        if args.count == 2 && args[1] == "--inspect-json" {
            do {
                let network = try MacNetwork()
                let rows: [[String: Any]] = network.services().map {
                    ["id": $0.id, "name": $0.name, "device": $0.device,
                     "addresses": $0.addresses, "dhcp": $0.dhcp, "eligible": $0.eligible]
                }
                let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.maxs.networkswitch")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps]); return
        }
        let delegate = AppDelegate()
        if args.count == 3 && args[1] == "--render-preview" { delegate.previewPath = args[2] }
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var previewPath: String?
    private var window: NSWindow!
    private var tray: NSStatusItem!
    private var timer: Timer?
    private let networkQueue = DispatchQueue(label: "com.maxs.networkswitch.read")
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "正在读取网络…")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let activity = NSTextField(wrappingLabelWithString: "")
    private let enableButton = NSButton(title: "切到旁路由", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复原配置", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private var trayStatus: NSMenuItem!
    private var trayRestore: NSMenuItem!
    private var services: [ServiceInfo] = []
    private var hasBackup = false
    private var busy = false
    private var refreshing = false
    private var generation = 0
    private var selectedID: String? { picker.selectedItem?.representedObject as? String }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NetworkSwitch · macOS \(appVersion)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.04, blue: 0.065, alpha: 1)

        let title = NSTextField(labelWithString: "旁路由切换")
        title.font = .systemFont(ofSize: 29, weight: .bold)
        let subtitle = NSTextField(labelWithString: "NETWORK SWITCH  /  MACOS BETA")
        subtitle.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = .systemCyan
        let heading = NSStackView(views: [title, subtitle]); heading.orientation = .vertical; heading.alignment = .leading
        let hero = NSStackView(); hero.orientation = .horizontal; hero.spacing = 18
        if let url = Bundle.main.url(forResource: "NetworkSwitch-logo", withExtension: "png"), let image = NSImage(contentsOf: url) {
            let logo = NSImageView(image: image)
            logo.widthAnchor.constraint(equalToConstant: 64).isActive = true
            logo.heightAnchor.constraint(equalToConstant: 64).isActive = true
            hero.addArrangedSubview(logo)
            tray.button?.image = image
            tray.button?.image?.size = NSSize(width: 18, height: 18)
            tray.button?.title = ""
        }
        hero.addArrangedSubview(heading)
        status.font = .systemFont(ofSize: 19, weight: .semibold)
        status.textColor = .systemYellow
        details.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        details.maximumNumberOfLines = 7
        picker.target = self; picker.action = #selector(selectionChanged)
        for button in [enableButton, restoreButton, refreshButton] {
            button.bezelStyle = .rounded; button.controlSize = .large; button.target = self
        }
        enableButton.action = #selector(enable)
        restoreButton.action = #selector(restore)
        refreshButton.action = #selector(refreshPressed)
        enableButton.bezelColor = .systemYellow
        let buttons = NSStackView(views: [enableButton, restoreButton, refreshButton]); buttons.spacing = 12
        activity.font = .systemFont(ofSize: 12)
        activity.textColor = .secondaryLabelColor
        activity.maximumNumberOfLines = 5
        let note = NSTextField(wrappingLabelWithString:
            "适用家庭网络：192.168.1.x/24 → 192.168.1.192\n保留 DHCP 地址和 IPv6；仅调整 IPv4 路由与 DNS。\n配置会保留在系统中，离开家庭网络或启用 VPN 前请先恢复。\n首次测试请先验证切换与恢复，再测试睡眠唤醒和重启。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [hero, status, picker, details, buttons, activity, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            picker.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activity.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center(); showWindow()
        if let path = previewPath {
            services = [ServiceInfo(id: "11111111-1111-1111-1111-111111111111", name: "Wi-Fi", device: "en0",
                addresses: ["192.168.1.25"], masks: ["255.255.255.0"], dhcp: true, router: "192.168.1.1", dns: ["192.168.1.1"])]
            picker.addItem(withTitle: "Wi-Fi  ·  192.168.1.25")
            picker.lastItem?.representedObject = services[0].id
            status.stringValue = "未启用本工具的旁路由配置"
            activity.stringValue = "界面预览使用模拟数据；没有读取或修改系统网络。"
            updateDetails()
            enableButton.isEnabled = false; restoreButton.isEnabled = false; refreshButton.isEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let view = self.window.contentView!
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
                do { try data.write(to: URL(fileURLWithPath: path)) }
                catch { fputs(error.localizedDescription, stderr); exit(2) }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    private func makeMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 NetworkSwitch（保留配置）", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        NSApplication.shared.mainMenu = main
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        tray.button?.title = "⇄"
        tray.button?.toolTip = "NetworkSwitch macOS \(appVersion)"
        let menu = NSMenu()
        trayStatus = NSMenuItem(title: "正在读取网络", action: nil, keyEquivalent: "")
        menu.addItem(trayStatus); menu.addItem(.separator())
        let open = NSMenuItem(title: "打开窗口", action: #selector(showWindow), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        trayRestore = NSMenuItem(title: "恢复原配置", action: #selector(restore), keyEquivalent: "")
        trayRestore.target = self; menu.addItem(trayRestore)
        let quit = NSMenuItem(title: "退出（保留当前配置）", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit); menu.autoenablesItems = false; trayStatus.isEnabled = false
        tray.menu = menu
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { showWindow(); activity.stringValue = "网络操作正在执行，请等待完成后退出。"; return .terminateCancel }
        return .terminateNow
    }
    @objc func selectionChanged() { updateDetails(); updateButtons() }
    @objc func refreshPressed() { refresh() }
    private func updateButtons() {
        enableButton.isEnabled = !busy && !refreshing && !hasBackup && services.first { $0.id == selectedID }?.eligible == true
        restoreButton.isEnabled = !busy && !refreshing && hasBackup
        trayRestore.isEnabled = restoreButton.isEnabled
        refreshButton.isEnabled = !busy && !refreshing
        picker.isEnabled = !busy
    }
    private func updateDetails() {
        guard let service = services.first(where: { $0.id == selectedID }) else { details.stringValue = "没有可用的物理网卡。"; return }
        details.stringValue = "网卡   \(service.device) · \(service.dhcp ? "DHCP" : "手动地址")\nIPv4   \(service.addresses.joined(separator: ", "))\n原网关 \(service.router)\nDNS    \(service.dns.joined(separator: ", "))\n旁路由 \(bypassGateway)"
    }
    private func refresh() {
        guard !busy, !refreshing else { return }
        refreshing = true; updateButtons()
        let requestedGeneration = generation
        networkQueue.async {
            do {
                let network = try MacNetwork()
                let services = network.services()
                let backup = try SecureStore().load()
                let active = try backup.map { try network.active($0) } ?? false
                DispatchQueue.main.async {
                    self.refreshing = false
                    guard !self.busy, requestedGeneration == self.generation else { self.updateButtons(); return }
                    let previous = self.selectedID
                    self.services = services; self.hasBackup = backup != nil
                    self.picker.removeAllItems()
                    for service in services {
                        self.picker.addItem(withTitle: "\(service.name)  ·  \(service.addresses.first ?? "未连接")")
                        self.picker.lastItem?.representedObject = service.id
                    }
                    let preferred = previous ?? backup?.serviceID ?? services.first(where: { $0.eligible })?.id
                    if let index = services.firstIndex(where: { $0.id == preferred }) { self.picker.selectItem(at: index) }
                    let label = backup?.restorePending == true ? "恢复尚未完成 · 请重试恢复" : active ? "旁路由已开启 · 配置已保存" : backup != nil ? "存在恢复记录 · 路由状态需检查" : "未启用本工具的旁路由配置"
                    self.status.stringValue = label; self.trayStatus.title = label
                    self.updateDetails(); self.updateButtons()
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.refreshing = false
                    guard !self.busy, requestedGeneration == self.generation else { self.updateButtons(); return }
                    self.status.stringValue = "状态读取失败"
                    self.activity.stringValue = message
                    self.enableButton.isEnabled = false
                    // Allow recovery even when inspecting a removed service fails.
                    self.hasBackup = FileManager.default.fileExists(atPath: SecureStore.directory + "/restore.json")
                    self.updateButtons(); self.enableButton.isEnabled = false
                }
            }
        }
    }
    @objc func enable() { guard let id = selectedID, !hasBackup else { return }; operate("enable", serviceID: id) }
    @objc func restore() { operate("restore", serviceID: nil) }
    private func operate(_ operation: String, serviceID: String?) {
        guard !busy, !refreshing, let executable = Bundle.main.executableURL?.path else { return }
        busy = true; generation += 1; updateButtons()
        activity.stringValue = "等待管理员授权；操作完成前请勿断开网络或退出程序。"
        var arguments = [executable, "--worker", operation]
        if let id = serviceID { arguments.append(id) }
        let script = "do shell script " + appleScriptString(arguments.map(shellQuote).joined(separator: " ")) + " with administrator privileges"
        // Execute AppleScript on the main thread, where the authorization UI belongs.
        // The worker itself performs all mutations synchronously and retains backups.
        DispatchQueue.main.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            self.busy = false
            if let error = error {
                let cancelled = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128
                let message = cancelled ? "已取消管理员授权，未执行本次操作。" : (error[NSAppleScript.errorMessage] as? String ?? error.description)
                self.activity.stringValue = message
                if !cancelled { let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = message; alert.runModal() }
            } else { self.activity.stringValue = result?.stringValue ?? "操作结束，请检查当前状态。" }
            self.refresh()
        }
    }
}
