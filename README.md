# NetworkSwitch v2.1.1

Windows 旁路由网关一键切换工具，采用 Cyberpunk 风格界面。

## 使用

下载并解压 `NetworkSwitch-v2.1.1.zip`，或直接下载 `NetworkSwitch-Cyber-v2.1.1.exe`。

1. 退出旧版，双击 EXE 并允许管理员权限。
2. 选择家庭网络使用的网卡。
3. 点击「切到旁路由」，默认网关和 DNS 切换到 `192.168.1.192`，IPv4 保持 DHCP 自动获取。
4. 点击「恢复自动」，恢复切换前的默认网关和 DNS 设置。

关闭窗口不会自动还原。IPv6 保持原配置。重新联网或 DHCP 续租后，默认网关可能变化，必要时重新切换。

程序仅负责本机网关与 DNS 切换；旁路由代理及播放服务是否可用取决于旁路由配置。

## 源码与编译

`source/` 包含 C# WinForms 界面、PowerShell 网络操作脚本、图标及构建脚本。完整 ZIP 也包含源码和中文使用说明。

在 Windows PowerShell 中运行：

```powershell
.\source\build.ps1
```

使用 Windows 自带的 .NET Framework C# 编译器，生成根目录的 EXE。图标已嵌入程序，正常运行不需要 Python。仅重新生成图标时需要 Python 和 Pillow。

网络逻辑模拟检查：

```powershell
.\source\Test-Simple.ps1 -Scratch "$env:TEMP\NetworkSwitch-tests"
```
