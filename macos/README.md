# NetworkSwitch for macOS — 1.0.0

1.0.0 正式版沿用已获用户确认可用的 beta 2 网络逻辑，保留 IPv6 `utun` 默认路由误报修复。IPv6 路由不阻止 IPv4 切换；真实的 IPv4 半默认路由和其他网卡默认出口仍会阻止切换，并显示具体接口与网关。无需删除系统接口或关闭 IPv6。

原生 AppKit 窗口和菜单栏程序。支持 macOS 13 或更新系统，Apple 芯片和 Intel 共用一个 Universal 应用。无需 Python、Homebrew 或 PowerShell。

## 使用

1. 解压 ZIP，将 `NetworkSwitch.app` 拖到“应用程序”。
2. 打开程序，选择通过 DHCP 连接家庭网络的 Wi-Fi 或以太网。
3. 点击“切到旁路由”，在 macOS 系统授权框中输入管理员凭据；程序不保存密码。
4. 确认显示“旁路由已开启 · 配置已保存”，再测试网页和 NAS。
5. 点击“恢复原配置”回到切换前的路由及 DNS。原来是自动 DNS 就恢复自动，原来是静态 DNS 就恢复原列表。

本正式版使用 ad-hoc 签名，尚未使用 Apple Developer ID 签名或公证。首次打开可能被 Gatekeeper 阻止：确认来源后，在“系统设置 → 隐私与安全性”中选择“仍要打开”。不需要关闭系统安全保护。若系统询问本地网络访问，请允许，否则旁路由检查可能失败。

## 网络行为

- 适用网段固定为 `192.168.1.x/24`，旁路由和 DNS 固定为 `192.168.1.192`。启用前检查 DHCP、网络出口、路由冲突、系统代理、旁路由 TCP 80 和 DNS 响应。
- 使用 macOS SystemConfiguration 保存两条附加 IPv4 路由：`0.0.0.0/1` 和 `128.0.0.0/1`，并设置该网络服务的 DNS。保留原有附加路由、DHCP 地址及原默认网关。
- 同子网访问 NAS 仍匹配更具体的本地路由；IPv6、系统代理和其他网卡设置不变。IPv6、浏览器安全 DNS、Private Relay 或应用自带代理可能使用其他路径；本工具不保证所有流量都经过旁路由。
- 配置保存在系统网络服务中，设计为退出、重连和重启后保留；不安装开机启动、后台守护进程或自动修复任务。**用户已反馈修复版可用；睡眠唤醒、重启和各项恢复场景尚无完整实机验证记录。**
- 后台每 15 秒只读检查，关闭窗口后可从菜单栏重新打开。退出程序保留配置。离开家庭网络、切换 Wi-Fi 或开启 VPN 前，应先恢复。
- 修改失败会尝试恢复；恢复失败会保留记录。若其他程序改了 DNS 或附加路由，本工具停止恢复以避免覆盖外部变更，不会重新开启旁路由。

恢复记录位于 `/Library/Application Support/NetworkSwitch/restore.json`，由 root 创建和管理，跨程序升级保留。网络仍处于切换状态时，不要手动删除恢复记录或原网络服务。

## 验证与限制

GitHub Actions 在 macOS 上编译两种架构，执行模拟事务检查、应用签名验证、Info.plist 检查和真实系统只读网卡枚举。具体结果见构建附件 `TEST-RESULTS.txt`。模拟测试覆盖部分失败回滚、重开程序后恢复、自动/静态 DNS、外部修改冲突、备份失败及重复开启。

用户在 beta 2 修复 VPN 误报后反馈“可以了”，据此发布 1.0.0；这不等于所有网卡、系统版本、恢复及重启场景都已验证。CI 不接触家庭旁路由，不执行真实网络修改。第一次使用应依次验证：开启 → 网页和 NAS → 恢复；确认成功后再测试开启状态下的睡眠唤醒及重启。界面的开启状态表示配置和路由检查通过，不代表外部代理节点一定可用。

若图形界面无法打开，可在终端执行以下恢复命令（会请求管理员密码）：

```sh
sudo /Applications/NetworkSwitch.app/Contents/MacOS/NetworkSwitch --worker restore
```

## 在 Mac 上自行构建

安装 Xcode Command Line Tools 后，在仓库根目录运行：

```sh
bash macos/build.sh
```

输出在 `macos/build/`，含 Universal `.app`、ZIP、校验值及测试结果。

实现使用 Apple 的 [SystemConfiguration API](https://developer.apple.com/documentation/systemconfiguration/scnetworkconfiguration)，附加路由与 DHCP 配置的合并行为见 Apple [configd IPMonitor 源码](https://github.com/apple-oss-distributions/configd/blob/main/Plugins/IPMonitor/ip_plugin.c)。
