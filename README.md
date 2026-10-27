<p align="center">
  <img src="source/NetworkSwitch-logo.png" width="96" alt="NetworkSwitch Logo">
</p>

<h1 align="center">NetworkSwitch</h1>

<p align="center">
  <strong>Switch your Windows gateway in one click.</strong><br>
  Windows 旁路由切换工具 · 保持 DHCP 自动获取 IP · 一键恢复原配置
</p>

<p align="center">
  <a href="https://github.com/ziwuxin1/NetworkSwitch/releases/tag/v2.1.1"><img src="badge-version.svg" alt="Version v2.1.1"></a>
  <img src="badge-platform.svg" alt="Platform Windows">
  <img src="badge-ui.svg" alt="UI WinForms">
  <img src="badge-private.svg" alt="Private repository">
</p>

<p align="center">
  <a href="https://github.com/ziwuxin1/NetworkSwitch/releases/latest">下载程序</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#功能一览">功能一览</a> ·
  <a href="#开发与构建">开发与构建</a> ·
  <a href="#版本说明">版本说明</a>
</p>

---

## 界面预览

![NetworkSwitch Cyberpunk 风格界面](interface-preview.png)

<sub>界面预览使用模拟网络数据，仅展示布局与操作状态，不代表当前电脑的实际网络配置。</sub>

## 项目介绍

在主路由与旁路由之间切换时，手动修改网关和 DNS 容易漏改，也不方便还原。**NetworkSwitch** 将这一步整理成两个操作：切到旁路由、恢复原配置。

程序采用 C# WinForms 界面和 PowerShell 网络操作脚本。切换时保持 IPv4 地址由 DHCP 自动获取，将所选网卡的默认网关与 DNS 指向 `192.168.1.192`，并保存切换前的配置用于恢复。

## 功能一览

| 功能 | 说明 |
| --- | --- |
| 一键切换 | 将所选网卡的默认网关和 DNS 切换至旁路由 `192.168.1.192`。 |
| 保留自动 IP | IPv4 地址保持 DHCP 自动获取，无需手动填写静态地址。 |
| 一键恢复 | 恢复切换前保存的默认网关与 DNS 配置。 |
| 网卡选择 | 选择需要切换的网卡，刷新并查看当前网络状态。 |
| 状态展示 | 展示 IPv4、默认网关、DNS 和代理入口状态。 |
| 操作记录 | 在窗口内查看读取、保存、切换和恢复过程。 |
| 关闭后保持 | 关闭窗口后保留当前网络配置，需要还原时重新打开程序操作。 |
| Cyberpunk 界面 | 黑黄与青色配色、切角按钮、自定义下拉框和内嵌 Logo。 |

## 下载

**[下载 NetworkSwitch v2.1.1 完整包](https://github.com/ziwuxin1/NetworkSwitch/releases/download/v2.1.1/NetworkSwitch-v2.1.1.zip)**

| 文件 | 用途 |
| --- | --- |
| [NetworkSwitch-v2.1.1.zip](https://github.com/ziwuxin1/NetworkSwitch/releases/download/v2.1.1/NetworkSwitch-v2.1.1.zip) | 推荐下载，包含 EXE、中文使用说明和完整源码。 |
| [NetworkSwitch-Cyber-v2.1.1.exe](https://github.com/ziwuxin1/NetworkSwitch/releases/download/v2.1.1/NetworkSwitch-Cyber-v2.1.1.exe) | 独立程序，下载后直接运行。 |
| [source/](source/) | 在线查看源码、构建脚本、图标和模拟测试。 |

此仓库为私有仓库，下载需要登录具有访问权限的 GitHub 账号。正式版本及校验文件见 [Releases](https://github.com/ziwuxin1/NetworkSwitch/releases/latest)。

## 快速开始

1. 下载并解压完整 ZIP，退出已经运行的旧版本。
2. 双击 `NetworkSwitch-Cyber-v2.1.1.exe`，允许管理员权限。
3. 选择连接家庭网络的网卡，核对界面显示的 IPv4、网关与 DNS。
4. 点击 **「切到旁路由」**，将默认网关和 DNS 切换至 `192.168.1.192`。
5. 需要恢复时，点击 **「恢复自动」**，恢复切换前保存的设置。

正常使用无需安装 Python，也无需单独运行 PowerShell 脚本。旁路由地址需要能够从所选网卡访问。

## 网络行为

- **IPv4 地址保持 DHCP 自动获取**，`ipconfig` 中的本机 IP 不一定会改变。
- 切换的目标是本机默认网关与 DNS，公网出口是否变化由旁路由的配置和分流规则决定。
- **关闭窗口不会自动还原网络**，还原请使用「恢复自动」。
- IPv6 保持原配置，不随 IPv4 网关切换。
- 重新联网或 DHCP 续租可能改变默认网关，必要时重新打开程序确认并切换。
- 程序不提供代理节点。网页、视频或其他服务是否可用，取决于旁路由代理、DNS 和分流配置。

## 开发与构建

使用 Windows PowerShell 和 Windows .NET Framework C# 编译器。

```powershell
.\source\build.ps1
```

构建脚本会将 `NetworkWorker.ps1`、程序图标及 manifest 嵌入 EXE，输出至项目根目录：

```text
NetworkSwitch-Cyber-v2.1.1.exe
```

运行网络逻辑模拟检查：

```powershell
.\source\Test-Simple.ps1 -Scratch "$env:TEMP\NetworkSwitch-tests"
```

这些检查替换系统网络操作，不会实际切换电脑网关。图标已经包含在仓库中；仅重新运行 `make-icon.py` 生成图标时需要 Python 和 Pillow。

| 文件 | 职责 |
| --- | --- |
| `source/NetworkSwitch.cs` | WinForms 界面、状态显示及操作入口。 |
| `source/NetworkWorker.ps1` | 网络信息读取、配置保存、网关切换与恢复。 |
| `source/build.ps1` | Windows EXE 构建脚本。 |
| `source/Test-Simple.ps1` | 网络逻辑模拟检查。 |
| `source/app.manifest` | Windows 应用程序 manifest。 |
| `source/NetworkSwitch.ico` | 多尺寸程序图标。 |
| `source/make-icon.py` | 图标生成工具。 |

## 版本说明

| 版本 | 内容 |
| --- | --- |
| **v2.1.1** | 当前打包版本，包含 Cyberpunk 界面、内嵌 Logo、自定义深色下拉框和调整后的版本号位置；保留已确认可用的网关切换与恢复逻辑。 |

本次 README 更新仅整理项目展示与使用文档，程序版本与网络行为保持不变。

