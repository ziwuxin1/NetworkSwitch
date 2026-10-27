NetworkSwitch Cyber v2.3.1 — 重启保留旁路由

行为
点击「切到旁路由」后，路由与 DNS 一起保存；退出程序、重启电脑后仍使用旁路由。
无需开机启动程序或计划任务。只有手动恢复（或手动切换/修复失败时的回滚）才撤销配置。
后台每 15 秒仅只读检查，不自动补路由、不因检测超时切换模式。

升级和使用
1. 退出旧版程序。若它仍在托盘运行，使用旧版的「恢复并退出」。
2. 退出 Clash Verge / 其他电脑 VPN 的 TUN 模式，避免和旁路由同时接管网络。
3. 运行本目录 NetworkSwitch-Cyber-v2.3.1.exe，允许管理员权限。
4. 若显示「旧版临时配置」，先点「恢复自动」，成功后再点「切到旁路由」。
   旧版重启后可能只剩 DNS 和恢复记录，新版可以使用该记录还原。
5. 选择 192.168.1.x 家庭网卡，点击「切到旁路由」。状态应显示「重启保留」。
6. 此后重启无需重开程序。需要直连时重新打开本版本，点击「恢复自动」。
7. 关闭窗口进入托盘。托盘「退出（保留当前配置）」只退出程序；
   「恢复并退出」会还原网络后退出。

旧版的问题
v2.2.x 将代理路由写入 ActiveStore，重启后消失；静态 DNS 会保留。
两类设置的生命周期不一致，可能导致重启后配置不完整。
v2.3.0 使用 Windows 的持久路由，并验证当前路由表和持久路由表均包含两条代理路由。
恢复时清除两个路由表中的工具自有路由，并还原原 DNS 和 IPv6 状态。
恢复失败时保留备份和待恢复标记，禁止修复重新开启代理。

兼容性
- 新版可还原旧版 Schema 1 的临时路由或更早的默认路由备份。
- 新开启的配置使用 Schema 2，避免旧版误删备份却漏掉持久路由。
- 新版开启后，请使用 v2.3.0 或后续兼容版本还原；旧版不能处理 Schema 2。
- 不直接把旧恢复备份覆盖成新的原设置，旧版配置需先还原后重新开启。

范围
- 家庭网段 192.168.1.x/24，旁路由 192.168.1.192；保留 DHCP 地址和默认网关。
- IPv6 保持原设置，可能经原 IPv6 出口；「路由生效」不等于外部代理节点可用。
- 不修改路由器、NAS、其他网卡、MTU 或开机启动项。
- 换到其他网络或改用电脑 VPN 前，请先「恢复自动」。
- 还原需要保留 ProgramData\MAXsGatewaySwitch 中的恢复记录。

验证结果（2026-10-27）
- Windows PowerShell 5：62 项模拟网络检查通过。
- WinForms：15 项界面逻辑检查通过，包括 24 次加速定时回调仅执行 Inspect。
- 模拟重启：丢弃活动路由、从持久路由重建，验证配置继续有效；未调用 Repair。
- 验证手动还原后再重启、持久路由部分写入失败、删除失败后重试、旧版升级、
  原自定义 DNS 还原、无关路由保留和读取权限错误不触发网络修改。
- .NET Framework 编译、--render 预览、内嵌脚本与测试源码一致性检查通过。
- 真实 Windows 只读 Inspect 通过；空持久路由表的 ObjectNotFound 行为已处理。
- 尚未执行真实网络切换或重启电脑测试，不能把模拟结果当作实机联网验证。

复测
source/build.ps1：构建 EXE。
source/Test-Simple.ps1：使用替身模拟所有网络读写，包括重启。
source/Test-Ui.ps1：使用替身工作器检查界面逻辑。
validation/TEST-RESULTS.txt：验证摘要。

Windows 官方语义依据
New-NetRoute：只指定 ActiveStore 时重启丢失；省略 PolicyStore 默认写入两个存储。
https://learn.microsoft.com/en-us/powershell/module/nettcpip/new-netroute?view=windowsserver2025-ps
Remove-NetRoute：可分别选择 ActiveStore 和 PersistentStore 删除。
https://learn.microsoft.com/en-us/powershell/module/nettcpip/remove-netroute?view=windowsserver2025-ps
