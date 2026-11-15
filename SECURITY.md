# 宽途 KuanTu 安全审计记录

审计日期：2026-11-14  
审计对象：`%LOCALAPPDATA%\KuanTu`（宽途 KuanTu 1.0.0 + 图形设置程序）  
审计方式：源代码审查、文件权限检查、签名/哈希检查、静态敏感模式扫描、安装/卸载流程验证。  
说明：这是一次**本地静态审计**，不是渗透测试，也不是杀毒软件认证。

---

## 1. 结论摘要

| 项目 | 结论 |
|---|---|
| 密码是否明文落盘 | 否。DPAPI `CurrentUser` 加密，配置文件/日志不含密码 |
| 密码是否进入命令行 | 否。使用 RAS API `RasDial` 直接填结构体 |
| 是否联网下载代码 | 否。脚本和源码中没有 HTTP/下载/`Invoke-Expression` 逻辑 |
| 是否要求管理员常驻 | 否。计划任务为当前用户、`Interactive`、`RunLevel Limited` |
| 是否修改防火墙/DNS/代理 | 否 |
| 程序目录是否允许其他用户写入 | 审计发现初始继承 ACL 允许 `Authenticated Users` 修改，已收紧 |
| 数字签名 | 未签名（本地编译 EXE） |
| 运行数据是否应提交 | 否。`secrets/`、`logs/`、`run/` 已加入 `.gitignore`，不得上传 |

**总体评价：适合个人单机使用，风险中低。**  
主要剩余风险是：EXE 未签名、同用户进程可读取内存中的明文密码、以及任何拥有当前 Windows 用户权限的恶意程序都可使用该凭据——这些是此类自动拨号工具难以完全消除的边界。

---

## 2. 凭据安全

### 已确认

- `config.json` 中没有 `password`、`passwd`、`pwd` 字段。
- 密码仅存在于 `secrets\credential.dat` 的 DPAPI 密文中。
- DPAPI 使用 `DataProtectionScope.CurrentUser` + 应用专属 entropy。
- 只有保存凭据的 Windows 用户能解密；复制到其他用户/电脑会失败。
- GUI 调用 `Install.ps1` 时，命令行只包含连接名，不包含账号密码。
- 拨号使用 `RasDial` P/Invoke，密码写入 `RASDIALPARAMS`，不传给 `rasdial.exe` 子进程。
- 日志不记录账号、密码或凭据内容。
- 本报告不读取、不记录实际账号密码；凭据是否存在属于用户运行状态，不应提交到仓库。

### 剩余风险

- 密码在 GUI/守护进程内存中以 .NET 字符串存在，理论上可被同用户进程的内存读取工具获取。
- DPAPI 只隔离不同 Windows 用户，不隔离同一用户下的恶意程序。
- 如果 Windows 账户本身已被攻破，本工具的加密不能提供额外保护。

---

## 3. 代码执行与自启

### 已确认

- 计划任务由当前用户创建，`LogonType Interactive`，`RunLevel Limited`，**不以 SYSTEM/管理员运行**。
- 任务动作是 `wscript.exe` 启动同目录 `AutoDialer.vbs`，路径带引号，不依赖不安全的 PATH 搜索。
- 隐藏启动器使用固定的 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` 路径。
- 图形程序调用 PowerShell 使用 `CreateNoWindow`，不弹出控制台。
- 安装/卸载不写 `HKLM`、不添加防火墙规则、不修改 DNS/代理。
- 没有 `Invoke-Expression`、`EncodedCommand`、`mshta`、`certutil`、`bitsadmin`、下载执行等模式。

### 本次发现并已修复：目录 ACL 过宽

审计时发现程序目录曾从 `C:\` 继承了：

```text
NT AUTHORITY\Authenticated Users : Modify
```

这意味着同机其他标准用户可以修改本目录中的脚本/EXE。由于登录任务会执行这些脚本，这是一个**本地持久化/权限滥用风险**。

已处理：

- 断开目录 ACL 继承；
- 仅保留：
  - 当前 Windows 用户：完全控制
  - `SYSTEM`：完全控制
  - `BUILTIN\Administrators`：完全控制
  - `BUILTIN\Users`：只读和执行
- 新的 ACL 已设置为保护状态（`AreAccessRulesProtected = True`）。
- `Install.ps1`、`Setup-Credential.ps1` 和图形程序在保存/安装时会尝试再次收紧目录 ACL。
- `Test-AutoDialer.ps1` 会检查目录权限，若其他主体可写则给出警告。

### 破坏性操作保护

- 卸载脚本拒绝在磁盘根目录或 `C:\Windows` 下执行。
- `Uninstall.ps1 -RemoveAll` 只删除已知的工具文件，不再批量删除目录内的所有文件；用户自己放入的其他文件会保留。
- 计划任务、启动项和凭据的清理路径均由脚本自身目录推导，不使用外部输入拼接删除路径。

### 剩余风险

- 图形程序是**未签名 EXE**。如果它被替换，用户无法通过数字签名发现。
- 自启任务执行的是用户目录里的脚本；如果当前 Windows 用户被攻破，攻击者可以修改这些脚本。
- 隐藏调用 PowerShell 可能被某些企业 AppLocker/EDR 策略视为可疑行为。

---

## 4. 网络行为

静态扫描结果：

- 脚本、VBS、CMD、C# 源码中没有 `http://`、`https://`。
- 没有 `Invoke-WebRequest`、`Invoke-RestMethod`、`WebClient`、`DownloadString`、`DownloadFile`、BITS、`certutil -urlcache` 等下载/外联代码。
- 唯一的网络操作是按配置调用 RAS API 拨号，以及用 `Get-NetAdapter`/`Get-NetConnectionProfile` 读取本机网络状态。
- 没有遥测、自动更新、远程配置或账号上传。

这表示从代码层面没有发现外联行为；未做抓包审计。

---

## 5. 卸载与残留

已验证：

- 卸载会停止守护进程；
- 删除计划任务 `AutoDialer-Broadband`；
- 删除启动文件夹快捷方式（如果使用回退模式）；
- 删除 DPAPI 凭据；
- 删除日志和运行文件；
- 不删除“宽带连接”电话簿条目；
- 不修改其他网络设置。

发布前检查原则：

```text
secrets/          不提交
logs/             不提交
run/              不提交
计划任务/启动项    属于本机状态，不进入仓库
```

---

## 6. 文件与签名

```text
文件：%LOCALAPPDATA%\KuanTu\宽带自动拨号设置.exe
大小：24,576 字节
SHA-256：6672228C311B27B7B3DC9CC472B63B4D8053785929C77F2070EC24F4168EDC60
数字签名：NotSigned（未签名）
```

未签名是本地小工具的正常状态，但会触发 Windows SmartScreen。请只从你信任的来源获取本工具；如重新编译，请使用本目录的 `Build-GUI.ps1` 并重新核对哈希。

---

## 7. 建议

1. **不要**把工具放到共享目录或允许其他用户写入的目录。
2. 复制到新位置后，双击图形程序保存一次，或运行 `Install.ps1`，让 ACL 重新收紧。
3. 首次使用前用 `Test-AutoDialer.ps1` 自检，确认“目录权限”为 PASS。
4. 如机器上有可用的杀毒软件，建议对 `宽带自动拨号设置.exe` 做一次自定义扫描。
5. 不要以管理员身份日常运行本工具；当前设计不需要管理员权限。
6. 不要共享 `secrets\credential.dat`；它只对当前 Windows 用户有效。
7. 如果使用企业设备，请先确认公司策略允许计划任务和 PowerShell 脚本。

---

## 8. 审计命令（可复现）

```powershell
# 签名与哈希
Get-AuthenticodeSignature .\宽带自动拨号设置.exe
Get-FileHash .\宽带自动拨号设置.exe -Algorithm SHA256

# 目录权限
(Get-Acl .).Access | Format-Table IdentityReference,FileSystemRights,IsInherited

# 只读自检
.\Test-AutoDialer.ps1

# 明文密码检查
Select-String .\config.json -Pattern 'password|passwd|pwd'

# 静态外联/危险模式扫描
Select-String .\*.ps1,.\src\*.cs -Pattern 'Invoke-WebRequest|WebClient|DownloadString|Invoke-Expression|EncodedCommand|https?://'
```
