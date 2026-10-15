# ClashTimeZone

**根据 Clash Verge Rev 的已验证公网出口，自动切换 Windows 系统时区。**

支持日本、美国各地区，以及 Clash 完全退出后的中国大陆直连恢复。默认 Dry Run，使用两次独立出口确认和两家地理定位服务，异常时保持当前时区。

Windows time-zone automation for Clash Verge Rev, with verified egress, dual confirmation, and dry-run-first operation.

## 功能

- 日本出口切为东京；美国出口按地区使用对应 Windows 时区，自动处理夏令时。
- Clash 完全退出、系统代理和隧道均停用，且确认中国大陆直连后，恢复北京时间。
- 本地状态约每 5 秒检测；状态变化触发公网复核，稳定时每 10 分钟复核。
- 两次新出口查询至少间隔 5 秒；IPv4/IPv6、两家定位商、系统代理/TUN 路径必须一致。
- 支持暂停、恢复、停止、登录自启、日志轮转、手动恢复和安全卸载。
- 普通用户常驻，不创建 SYSTEM 服务，不重启电脑或 Clash，不修改节点和规则。

只修改**时区**，不修改 UTC 系统时间、NTP、DNS、防火墙、浏览器数据或 VPN 规则。

## 支持与验证范围

- 面向 Windows 10/11，依赖系统 Windows PowerShell 5.1、`Get-NetAdapter` / `Get-NetRoute` 等 Windows 网络命令。
- 已在 Windows 11、Clash Verge Rev 2.5.8、Mihomo 1.19.32 验证命名管道、系统代理 + TUN、双栈出口及真实日本时区写入。
- 核心 55 项离线测试分别在 PowerShell 5.1/7.6 通过，另有 12 项 HTTP 故障注入、10 项本地环境注入。
- 美国、退出 Clash 后恢复中国的逻辑有模拟测试，**尚未进行真实端到端验收**。不同 Windows、Clash 分支和网络环境需自行验证。

日本 `Tokyo Standard Time`；美国白名单包含洛杉矶、丹佛、凤凰城、芝加哥、纽约、阿拉斯加、阿留申、夏威夷等；中国大陆直连使用 `China Standard Time`。国家或 IANA 时区不受支持时保持原时区，不猜 UTC 偏移。

## 本地部署

### 1. 获取源码

在本仓库页面选择 **Code → Download ZIP** 并解压，或使用 Git：

```powershell
git clone https://github.com/yeyeye-tgu/ClashTimeZone.git
Set-Location .\ClashTimeZone
```

进入解压/克隆后的目录，用**普通权限** PowerShell 操作。

先查看脚本和 `config.json`。项目不包含 Clash 安装包、订阅和第三方程序，不需要 Python、Node 或额外安装运行库。

以下命令使用 Windows PowerShell 新进程的 `RemoteSigned` 策略，不更改系统或当前用户的持久执行策略，也不能绕过组织策略。

### 2. 运行不联网、不改时区的离线测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-Network.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-Local.ps1
```

### 3. 运行限时预览

保持 Clash 当前配置不变：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Auto-TimeZone.ps1 -DurationSeconds 60
```

默认不修改时区。`Confirm` 表示等待第二次确认；`WouldChange` 表示已满足切换条件；`Keep / AlreadyCorrect` 表示时区已经正确。`-Once` 仅采样一次，不代表通过双确认。

如果已经安装并运行本工具，单例会拒绝第二个预览实例。需测试新版本时先停止已有监控，而非退出 Clash。

### 4. 处理 Windows 自动时区冲突

在 Windows **设置 → 时间和语言 → 日期和时间** 中关闭“自动设置时区”，保留“自动设置时间”和时间同步设置不变。此系统设置可能需要管理员确认；不要用管理员 PowerShell 常驻运行本工具。

程序会检查 `tzautoupdate`：Start=3 代表自动时区开启，Start=4 代表关闭。即使服务暂时停止，Start=3 仍视为冲突。程序不会自动提权修改此设置。

当前用户令牌必须具备 `SeTimeZonePrivilege`。可用 `whoami /priv` 只读检查；Disabled 通常表示权限尚未激活，不等于权限不存在。若实际写入被拒绝，记录错误并停止，不自动提权或更改权限。

### 5. 安装计划预览

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Install.ps1 -EnableAutomaticSwitching -RegisterStartup -StartNow
```

没有 `-ApproveInstall` 时只输出计划，不安装、不自启、不改时区。

默认目录：

| 内容 | 路径 |
|---|---|
| 程序 | `%LOCALAPPDATA%\ClashTimeZone\App` |
| 状态、日志和原时区记录 | `%LOCALAPPDATA%\ClashTimeZone\Data` |
| 登录自启 | 当前用户 Startup 文件夹的 `ClashTimeZone.lnk` |

### 6. 正式安装并启用

确认预览路径及修改范围后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Install.ps1 -ApproveInstall -EnableAutomaticSwitching -RegisterStartup -StartNow
```

自定义程序目录示例：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Install.ps1 -InstallDirectory "D:\Tools\ClashTimeZone" -ApproveInstall -EnableAutomaticSwitching -RegisterStartup -StartNow
```

目标程序目录须不存在，状态目录也不能含既有安装资料；安装器拒绝覆盖旧安装。已安装版本请先检查并妥善备份，不要直接覆盖 `installation.json`，其中保存安装前时区。

安装器再次执行离线测试、保存原时区，对程序/数据目录设置当前用户、SYSTEM、Administrators 专用 ACL，创建普通用户登录快捷方式。登录自启不会重启电脑、网络或 Clash。

## 日常操作

进入实际安装的程序目录，再执行下列命令。默认安装时可先运行：

```powershell
Set-Location "$env:LOCALAPPDATA\ClashTimeZone\App"
```

| 目的 | 命令（均在新 PowerShell 进程中运行） |
|---|---|
| 状态与日志 | `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Status.ps1 -Logs -Tail 30` |
| 暂停 | `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Pause.ps1` |
| 恢复 | `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Resume.ps1` |
| 停止本工具 | `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Stop.ps1` |
| 启动自动调整 | `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Start.ps1 -Apply` |
| 启动仅预览 | `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Start.ps1` |

Stop 不退出 Clash，不恢复时区，也不移除登录自启。Resume 只解除暂停；已停止时还需 Start。`Start.ps1` 输出 launched 后，以 Status 的进程锁和心跳判断是否健康。

## 手动恢复与卸载

```powershell
# 默认只预览；加 -Apply 才停止监控并实际恢复
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Restore-TimeZone.ps1 -Original
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Restore-TimeZone.ps1 -China

# 按需要选择一种实际操作
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Restore-TimeZone.ps1 -Original -Apply
# 或：Restore-TimeZone.ps1 -China -Apply

# 卸载预览
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Uninstall.ps1

# 确认后卸载并恢复安装前时区
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Uninstall.ps1 -ApproveUninstall -Restore Original
```

卸载的 `-Restore` 可选 `Original`、`China`、`None`。只删除本项目白名单文件和确认指向本项目的自启快捷方式，不递归删除未知文件；Data 日志和原时区记录保留。Windows 自带自动时区的恢复需要单独由用户决定，不会擅自改回系统设置。

## 如何确认实际出口

只读调用现有 Mihomo GET `/version`、`/configs`、`/proxies`；优先动态发现 Windows 命名管道，没有则仅尝试已有配置中的 loopback 控制器，不猜固定端口或开放接口。全局组会递归解析所选链，所有组的 `now` 变化参与指纹，节点名不决定时区。

显式经系统正在使用、且确认归属核心进程的 HTTP/mixed 端口进行 HTTPS 公网查询。TUN 开启时，再经不使用应用层代理的 Windows 网络路径查询并对比；该路径仍可能经过 TUN，不能称为物理直连。

使用 ipify 的 IPv4/双栈查询建立出口组合；每个 IP 交由 ipwho.is 和 ipapi.co 独立定位。两次出口验证之间间隔至少 5 秒，且 IP 组合、国家、目标时区及本地状态一致，才允许切换。地理缓存可以复用，第二次公网 IP 查询必须重新执行。

## 限制与失败处理

- 系统时区只有一份；规则分流下，查询端点的出口不能证明浏览器、游戏或其他程序都走同一路径。
- PAC/自动发现、其他活动 VPN、无可用控制器、系统代理和 TUN 出口不一致时保持原时区。
- 两家定位商或 IPv4/IPv6 定位不一致、未知地区、定位失败均不切换；共同误判仍可能发生。
- 完全退出后的恢复只接受确认的中国大陆直连，不把港澳台或海外直连当成中国大陆。
- 每次成功修改后至少冷却 60 秒；API 错误指数退避，429 尊重 Retry-After。公网地址/配额存在共享出口影响。
- 日志约 1 MiB 轮转、保留 4 份旧档；IP 掩码和哈希可用于排查，不持久化完整 IP、订阅、认证 Header、控制器 secret。
- 默认稳定复核 600 秒，地理缓存 6 小时；每家定位商最多 200 次/UTC 日，ipify 各端点最多 1000 次/UTC 日。供应商免费服务及条款可能变化，本工具不保证永久免费或可用，也不会自动购买服务。

## 文件说明

`Auto-TimeZone.ps1` 常驻；`ClashTimeZone.psm1` 检测/验证/状态机；`config.json` 安全默认值；Install/Uninstall 管理安装；Start/Stop/Status/Pause/Resume 管理运行；Restore-TimeZone 手动恢复；三份 Test 脚本用于离线验证。

真实验收和已知未测项见 [Acceptance.md](Acceptance.md)。第三方项目和服务关系见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可证

本仓库自身脚本与文档采用 [MIT License](LICENSE)。MIT 不授予 Clash Verge、Mihomo 或定位服务的代码、商标、数据及商业服务权利。仓库不附带这些项目的源码、二进制或订阅。本项目与它们无官方隶属关系。
