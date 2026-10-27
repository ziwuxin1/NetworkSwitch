# NetworkSwitch v2.1.1

Windows 旁路由网关一键切换工具，Cyberpunk 风格界面。

## 使用

1. 双击程序并允许管理员权限，选择家庭网络网卡。
2. 点击「切到旁路由」，默认网关和 DNS 切换到 `192.168.1.192`，IPv4 保持 DHCP 自动获取。
3. 点击「恢复自动」，恢复切换前的默认网关和 DNS 设置。

关闭窗口不会自动还原，IPv6 保持原配置。重新联网或 DHCP 续租后，必要时重新切换。程序仅负责本机网络配置，旁路由代理功能取决于路由器设置。

## 构建

在 Windows PowerShell 中运行 `source\build.ps1`，使用 Windows .NET Framework C# 编译器生成 EXE。图标嵌入程序；仅重新生成图标时需要 Python 和 Pillow。

当前程序包及源码正在整理上传。
