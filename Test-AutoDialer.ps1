#Requires -Version 5.1
<#
.SYNOPSIS
    只读自检：检查配置、电话簿、凭据、RAS 接口、网卡和自启项。
.DESCRIPTION
    本脚本不会拨号、不会断开连接、不会修改系统设置。
    返回码 = 失败项数量（0 表示全部通过）。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'AutoDialer.Core.ps1')

$failures = 0
$warnings = 0

function Write-Check {
    param(
        [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')]
        [string]$Status,
        [string]$Name,
        [string]$Detail
    )

    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $Status.PadRight(4), $Name) -ForegroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-Host "       $Detail" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host "AutoDialer v$script:AutoDialerVersion 自检" -ForegroundColor Cyan
Write-Host "目录：$script:AutoDialerRoot"
Write-Host ''

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($null -ne $os -and [int]$os.BuildNumber -ge 22000) {
    Write-Check -Status PASS -Name '操作系统' -Detail "$($os.Caption) Build $($os.BuildNumber)"
}
else {
    $buildText = if ($null -ne $os) { [string]$os.BuildNumber } else { '未知' }
    Write-Check -Status WARN -Name '操作系统' -Detail "当前不是 Windows 11（Build $buildText），脚本可能仍可用。"
    $warnings++
}

if ($PSVersionTable.PSVersion.Major -ge 5) {
    Write-Check -Status PASS -Name 'PowerShell' -Detail "$($PSVersionTable.PSVersion)"
}
else {
    Write-Check -Status FAIL -Name 'PowerShell' -Detail '需要 PowerShell 5.1 或更高版本。'
    $failures++
}

if ([IntPtr]::Size -eq 8) {
    Write-Check -Status PASS -Name '进程位数' -Detail '64 位（RAS 结构按 64 位布局）'
}
else {
    Write-Check -Status WARN -Name '进程位数' -Detail '32 位 PowerShell；RAS 结构按 32 位布局，建议使用 64 位 PowerShell。'
    $warnings++
}

$config = $null
try {
    $config = Get-AutoDialerConfig
    Write-Check -Status PASS -Name 'config.json' -Detail "连接名=$($config.connectionName)"
}
catch {
    Write-Check -Status FAIL -Name 'config.json' -Detail $_.Exception.Message
    $failures++
}

if ($null -ne $config) {
    $configText = Get-Content -LiteralPath $script:AutoDialerConfigPath -Raw -Encoding UTF8
    if ($configText -match '(?i)"password"\s*:') {
        Write-Check -Status FAIL -Name '明文密码检查' -Detail 'config.json 中出现 password 字段；请删除并改用 Setup-Credential.ps1。'
        $failures++
    }
    else {
        Write-Check -Status PASS -Name '明文密码检查' -Detail 'config.json 中没有 password 字段。'
    }

    if (Test-AutoDialerPhonebookEntry -ConnectionName $config.connectionName) {
        Write-Check -Status PASS -Name '电话簿条目' -Detail "找到连接「$($config.connectionName)」。"
    }
    else {
        Write-Check -Status FAIL -Name '电话簿条目' -Detail "找不到「$($config.connectionName)」，请先创建宽带连接。"
        $failures++
    }

    $credentialPath = Get-AutoDialerCredentialPath -Config $config
    if (-not (Test-Path -LiteralPath $credentialPath)) {
        Write-Check -Status FAIL -Name '宽带凭据' -Detail "凭据文件不存在：$credentialPath（请双击 宽带自动拨号设置.exe）"
        $failures++
    }
    else {
        try {
            $secret = Get-AutoDialerSecret -Path $credentialPath
            Write-Check -Status PASS -Name '宽带凭据' -Detail "可解密；账号=$($secret.username)；密码已加密，不显示。"
            $secret = $null
        }
        catch {
            Write-Check -Status FAIL -Name '宽带凭据' -Detail $_.Exception.Message
            $failures++
        }
    }

    try {
        $status = Get-AutoDialerRasStatus -ConnectionName $config.connectionName
        if ($status.Connected) {
            Write-Check -Status PASS -Name 'RAS 状态查询' -Detail "已连接（代码 $($status.StateCode)，来源 $($status.Source)）"
        }
        else {
            Write-Check -Status INFO -Name 'RAS 状态查询' -Detail "未连接（$($status.State)）；这不影响工具在下次启动时拨号。"
        }
    }
    catch {
        Write-Check -Status FAIL -Name 'RAS 状态查询' -Detail $_.Exception.Message
        $failures++
    }

    $adapter = Get-AutoDialerAdapterInfo -Config $config
    if ($adapter.Ready) {
        Write-Check -Status PASS -Name '物理网卡' -Detail "$($adapter.Name)（$($adapter.Status)）"
    }
    elseif ($config.requirePhysicalAdapter) {
        Write-Check -Status WARN -Name '物理网卡' -Detail '当前没有 Up 状态的物理网卡；开机时会等待。'
        $warnings++
    }
    else {
        Write-Check -Status PASS -Name '物理网卡' -Detail '未强制要求物理网卡。'
    }

    $autostart = Get-AutoDialerAutostartInfo
    if ($autostart.TaskRegistered -or $autostart.StartupLinkExists) {
        $text = @()
        if ($autostart.TaskRegistered) { $text += "任务 $($autostart.TaskName)（$($autostart.TaskState)）" }
        if ($autostart.StartupLinkExists) { $text += "启动快捷方式 $($autostart.StartupLink)" }
        Write-Check -Status PASS -Name '开机自启' -Detail ($text -join '；')
    }
    else {
        Write-Check -Status WARN -Name '开机自启' -Detail '尚未安装自启，请双击 宽带自动拨号设置.exe 或运行 Install.ps1。'
        $warnings++
    }

    $logDir = Join-Path $script:AutoDialerRoot 'logs'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $probe = Join-Path $logDir '.write-test'
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force
        Write-Check -Status PASS -Name '日志目录' -Detail '可写。'
    }
    catch {
        Write-Check -Status FAIL -Name '日志目录' -Detail "不可写：$($_.Exception.Message)"
        $failures++
    }
}

$requiredFiles = @(
    'AutoDialer.ps1',
    'AutoDialer.vbs',
    'AutoDialer.Core.ps1',
    'Setup-Credential.ps1',
    'Install.ps1',
    'Uninstall.ps1',
    'config.json'
)
$missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:AutoDialerRoot $_)) })
if ($missing.Count -eq 0) {
    Write-Check -Status PASS -Name '文件完整性' -Detail '必需文件齐全。'
}
else {
    Write-Check -Status FAIL -Name '文件完整性' -Detail "缺少：$($missing -join ', ')"
    $failures++
}

$gui = Join-Path $script:AutoDialerRoot '宽带自动拨号设置.exe'
if (Test-Path -LiteralPath $gui) {
    $guiSize = [Math]::Round((Get-Item -LiteralPath $gui).Length / 1KB, 1)
    Write-Check -Status PASS -Name '图形设置程序' -Detail "存在（$guiSize KB）。"
}
else {
    Write-Check -Status WARN -Name '图形设置程序' -Detail '不存在；仍可使用命令行方式设置。'
    $warnings++
}

try {
    $folderAcl = Get-Acl -LiteralPath $script:AutoDialerRoot
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $allowedWriters = @($currentUser, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')
    $writeMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000
    $dangerous = @()
    foreach ($rule in $folderAcl.Access) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if ($allowedWriters -contains [string]$rule.IdentityReference) { continue }
        if (([int]$rule.FileSystemRights -band $writeMask) -ne 0) {
            $dangerous += "$($rule.IdentityReference): $($rule.FileSystemRights)"
        }
    }

    if ($dangerous.Count -eq 0) {
        Write-Check -Status PASS -Name '目录权限' -Detail '除当前用户/管理员/SYSTEM 外，没有其他用户可写。'
    }
    else {
        Write-Check -Status WARN -Name '目录权限' -Detail ("以下主体可写，建议收紧 ACL：" + ($dangerous -join '；'))
        $warnings++
    }
}
catch {
    Write-Check -Status WARN -Name '目录权限' -Detail "无法读取 ACL：$($_.Exception.Message)"
    $warnings++
}

$rasDll = Join-Path $env:SystemRoot 'System32\rasapi32.dll'
if (Test-Path -LiteralPath $rasDll) {
    Write-Check -Status PASS -Name '系统组件' -Detail 'rasapi32.dll 存在。'
}
else {
    Write-Check -Status FAIL -Name '系统组件' -Detail '找不到 rasapi32.dll。'
    $failures++
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host "自检通过（警告 $warnings 项）。" -ForegroundColor Green
}
else {
    Write-Host "自检失败：$failures 项失败，$warnings 项警告。" -ForegroundColor Red
}
Write-Host ''

exit $failures
