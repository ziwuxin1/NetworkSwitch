# Source

运行 `build.ps1` 编译 Windows 程序，输出到上一级目录。

- NetworkSwitch.cs：WinForms 界面
- NetworkWorker.ps1：当前/持久 IPv4 路由与 DNS 切换、备份与还原
- Test-Simple.ps1：网络逻辑模拟检查
- Test-Ui.ps1 / Test-Ui.cs：使用模拟工作器检查定时回调、手动操作和状态展示
- NetworkSwitch.ico：内嵌程序图标
- make-icon.py：图标生成工具，需要 Pillow

v2.3.0 使用 Schema 2 保存恢复记录；同时兼容 Schema 1 旧版还原。
网络写入仅由用户操作或该操作失败后的回滚触发，定时器只调用 Inspect。
测试不修改实际网络。生成的验证程序与输出位于项目根目录的 validation/。
