#Requires -Version 5.1
<#
.SYNOPSIS
    AutoDialer 公共核心模块。
.DESCRIPTION
    提供配置读取、日志、DPAPI 凭据、RAS 拨号/状态查询、网卡与自启检测等函数。
    本文件只被同目录下的脚本点源（dot-source），不直接运行。
.NOTES
    仅使用 Windows 11 自带组件：PowerShell 5.1、rasapi32.dll、DPAPI。
#>

Set-StrictMode -Version 2.0

$script:AutoDialerVersion = '1.0.0'
$script:AutoDialerRoot = $PSScriptRoot
$script:AutoDialerConfigPath = Join-Path $PSScriptRoot 'config.json'
$script:AutoDialerTaskName = 'AutoDialer-Broadband'
$script:AutoDialerStartupLinkName = 'AutoDialer.lnk'
$script:AutoDialerSecretEntropy = [System.Text.Encoding]::UTF8.GetBytes('AutoDialer.PPPoE.v1|7b1f9c2e-5a44-4f0b-9d0a-2a6a3f6c8e11')

$script:LogFile = $null
$script:LogMaxBytes = 1MB
$script:LogKeepFiles = 5
$script:LogMinPriority = 1
$script:LogConsole = $false

$script:RasStateText = @{
    0    = '正在打开端口'
    1    = '端口已打开'
    2    = '正在连接设备'
    3    = '设备已连接'
    4    = '所有设备已连接'
    5    = '正在验证身份'
    6    = '身份验证通知'
    7    = '身份验证重试'
    8    = '身份验证回调'
    9    = '身份验证 EAP'
    10   = '身份验证 MSCHAP'
    11   = '身份验证重试'
    12   = '正在应用设置'
    13   = '正在投影'
    14   = '正在验证用户名'
    15   = '正在验证密码'
    16   = '正在投影'
    17   = '身份验证质询'
    18   = '身份验证响应'
    19   = '正在验证'
    20   = '身份验证结果'
    21   = '正在登录网络'
    22   = '正在启动子条目'
    23   = '正在启动身份验证'
    24   = '正在回调'
    25   = '需要交互'
    26   = '重试身份验证'
    27   = '回调已设置'
    28   = '密码已过期'
    29   = '调用 EAP UI'
    8192 = '已连接'
    8193 = '已断开'
}

$script:RasErrorMap = @{
    0   = @{ Text = '成功'; Fatal = $false; Auth = $false }
    5   = @{ Text = '拒绝访问。请确认当前用户有权操作该拨号连接。'; Fatal = $true; Auth = $false }
    600 = @{ Text = '操作被挂起。'; Fatal = $false; Auth = $false }
    601 = @{ Text = '端口无效。'; Fatal = $true; Auth = $false }
    602 = @{ Text = '端口已打开。'; Fatal = $false; Auth = $false }
    603 = @{ Text = '缓冲区不足。'; Fatal = $false; Auth = $false }
    604 = @{ Text = '设备信息无效。'; Fatal = $true; Auth = $false }
    605 = @{ Text = '无法设置端口信息。'; Fatal = $true; Auth = $false }
    606 = @{ Text = '端口未连接。'; Fatal = $false; Auth = $false }
    607 = @{ Text = '事件无效。'; Fatal = $true; Auth = $false }
    608 = @{ Text = '设备不存在。'; Fatal = $true; Auth = $false }
    609 = @{ Text = '设备类型不存在。'; Fatal = $true; Auth = $false }
    610 = @{ Text = '缓冲区无效。'; Fatal = $true; Auth = $false }
    611 = @{ Text = '路由不可用。'; Fatal = $false; Auth = $false }
    612 = @{ Text = '路由未分配。'; Fatal = $false; Auth = $false }
    613 = @{ Text = '路由无效。'; Fatal = $false; Auth = $false }
    614 = @{ Text = '缓冲区不足。'; Fatal = $false; Auth = $false }
    615 = @{ Text = '找不到端口。'; Fatal = $true; Auth = $false }
    616 = @{ Text = '异步请求被挂起。'; Fatal = $false; Auth = $false }
    617 = @{ Text = '端口或设备已断开。'; Fatal = $false; Auth = $false }
    618 = @{ Text = '端口未打开。'; Fatal = $false; Auth = $false }
    619 = @{ Text = '无法建立到远程计算机的连接。请检查网线、光猫和运营商线路。'; Fatal = $false; Auth = $false }
    620 = @{ Text = '没有可用的端点。'; Fatal = $false; Auth = $false }
    621 = @{ Text = '无法打开电话簿。'; Fatal = $true; Auth = $false }
    622 = @{ Text = '无法加载电话簿。'; Fatal = $true; Auth = $false }
    623 = @{ Text = '找不到电话簿条目。请检查 config.json 中的 connectionName，或先创建「宽带连接」。'; Fatal = $true; Auth = $false }
    624 = @{ Text = '无法创建电话簿条目。'; Fatal = $true; Auth = $false }
    625 = @{ Text = '电话簿条目无效。'; Fatal = $true; Auth = $false }
    626 = @{ Text = '无法加载电话簿。'; Fatal = $true; Auth = $false }
    627 = @{ Text = '无法连接到远程访问服务器。'; Fatal = $false; Auth = $false }
    628 = @{ Text = '连接被关闭。'; Fatal = $false; Auth = $false }
    629 = @{ Text = '连接被远程计算机终止。'; Fatal = $false; Auth = $false }
    630 = @{ Text = '端口被断开。'; Fatal = $false; Auth = $false }
    631 = @{ Text = '端口被断开。'; Fatal = $false; Auth = $false }
    632 = @{ Text = '结构大小无效（RAS 接口版本不兼容）。'; Fatal = $true; Auth = $false }
    633 = @{ Text = '端口已被占用。'; Fatal = $false; Auth = $false }
    634 = @{ Text = '无法连接到远程计算机。'; Fatal = $false; Auth = $false }
    635 = @{ Text = '发生未知错误。'; Fatal = $false; Auth = $false }
    636 = @{ Text = '端口连接到了错误的设备。'; Fatal = $true; Auth = $false }
    637 = @{ Text = '无法打开电话簿。'; Fatal = $true; Auth = $false }
    638 = @{ Text = '连接超时。'; Fatal = $false; Auth = $false }
    639 = @{ Text = '电话簿条目已存在。'; Fatal = $false; Auth = $false }
    640 = @{ Text = '无法创建电话簿条目。'; Fatal = $true; Auth = $false }
    651 = @{ Text = '调制解调器报告错误。'; Fatal = $false; Auth = $false }
    652 = @{ Text = '无法识别设备。'; Fatal = $true; Auth = $false }
    653 = @{ Text = '找不到设备。'; Fatal = $true; Auth = $false }
    654 = @{ Text = '设备不支持该操作。'; Fatal = $true; Auth = $false }
    655 = @{ Text = '消息无效。'; Fatal = $true; Auth = $false }
    656 = @{ Text = '找不到设备。'; Fatal = $true; Auth = $false }
    657 = @{ Text = '无法打开设备。'; Fatal = $true; Auth = $false }
    658 = @{ Text = '无法读取设备。'; Fatal = $true; Auth = $false }
    659 = @{ Text = '无法写入设备。'; Fatal = $true; Auth = $false }
    660 = @{ Text = '设备命令无效。'; Fatal = $true; Auth = $false }
    661 = @{ Text = '设备错误。'; Fatal = $true; Auth = $false }
    662 = @{ Text = '无法设置设备。'; Fatal = $true; Auth = $false }
    663 = @{ Text = '设备未就绪。'; Fatal = $false; Auth = $false }
    664 = @{ Text = '无法分配内存。'; Fatal = $true; Auth = $false }
    665 = @{ Text = '设备未连接。'; Fatal = $false; Auth = $false }
    666 = @{ Text = '设备未就绪。'; Fatal = $false; Auth = $false }
    667 = @{ Text = '无法读取电话簿。'; Fatal = $true; Auth = $false }
    668 = @{ Text = '连接已终止。'; Fatal = $false; Auth = $false }
    669 = @{ Text = '参数无效。'; Fatal = $true; Auth = $false }
    670 = @{ Text = '无法读取电话簿。'; Fatal = $true; Auth = $false }
    676 = @{ Text = '线路忙。'; Fatal = $false; Auth = $false }
    677 = @{ Text = '无人接听。'; Fatal = $false; Auth = $false }
    678 = @{ Text = '无人应答。请检查线路或稍后重试。'; Fatal = $false; Auth = $false }
    679 = @{ Text = '无法检测到载波。'; Fatal = $false; Auth = $false }
    680 = @{ Text = '没有拨号音。'; Fatal = $false; Auth = $false }
    681 = @{ Text = '调制解调器报告一般错误。'; Fatal = $false; Auth = $false }
    691 = @{ Text = '身份验证失败：宽带账号或密码错误。'; Fatal = $false; Auth = $true }
    692 = @{ Text = '调制解调器硬件故障。'; Fatal = $true; Auth = $false }
    693 = @{ Text = '调制解调器不支持该操作。'; Fatal = $true; Auth = $false }
    694 = @{ Text = '调制解调器未就绪。'; Fatal = $false; Auth = $false }
    695 = @{ Text = '调制解调器状态错误。'; Fatal = $false; Auth = $false }
    696 = @{ Text = '调制解调器未响应。'; Fatal = $false; Auth = $false }
    697 = @{ Text = '调制解调器未响应。'; Fatal = $false; Auth = $false }
    698 = @{ Text = '调制解调器未响应。'; Fatal = $false; Auth = $false }
    699 = @{ Text = '调制解调器错误。'; Fatal = $false; Auth = $false }
    718 = @{ Text = '等待远程计算机应答超时。'; Fatal = $false; Auth = $false }
    719 = @{ Text = '连接被远程计算机终止。'; Fatal = $false; Auth = $false }
    720 = @{ Text = '无法建立 PPP 连接。请确认宽带账号类型与运营商要求一致。'; Fatal = $false; Auth = $false }
    721 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    722 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    723 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    724 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    725 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    726 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    727 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    728 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    729 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    730 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    731 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    732 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    733 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    734 = @{ Text = 'PPP 链路控制协议终止。'; Fatal = $false; Auth = $false }
    735 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    736 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    737 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    738 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    739 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    740 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    741 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    742 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    743 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    744 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    745 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    746 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    747 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    748 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    749 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    750 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    751 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    752 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    753 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    754 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    755 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    756 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    757 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    758 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    759 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    760 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    761 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    762 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    763 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    764 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    765 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    766 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    767 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    768 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    769 = @{ Text = '无法连接到远程计算机。'; Fatal = $false; Auth = $false }
    770 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    771 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    772 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    773 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    774 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    775 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    776 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    777 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    778 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    779 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    780 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    781 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    782 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    783 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    784 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    785 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    786 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    787 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    788 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    789 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    790 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    791 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    792 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    793 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    794 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    795 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    796 = @{ Text = '远程计算机无响应。'; Fatal = $false; Auth = $false }
    797 = @{ Text = '找不到调制解调器或宽带设备。请检查网卡/光猫驱动。'; Fatal = $true; Auth = $false }
    798 = @{ Text = '找不到证书。'; Fatal = $true; Auth = $false }
    799 = @{ Text = '无法加载电话簿。'; Fatal = $true; Auth = $false }
    815 = @{ Text = '宽带网络连接失败。请检查 VLAN、光猫桥接和运营商线路。'; Fatal = $false; Auth = $false }
    868 = @{ Text = '无法解析服务器名称。请检查 DNS 或运营商网络。'; Fatal = $false; Auth = $false }
}

function Get-AutoDialerConfig {
    [CmdletBinding()]
    param(
        [string]$Path = $script:AutoDialerConfigPath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "配置文件不存在：$Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        throw "读取 config.json 失败：$($_.Exception.Message)"
    }

    $connectionName = [string](Get-AutoDialerJsonProperty -Object $raw -Name 'connectionName' -Default '')
    if ([string]::IsNullOrWhiteSpace($connectionName)) {
        throw 'config.json 中的 connectionName 不能为空。'
    }

    $credentialFile = [string](Get-AutoDialerJsonProperty -Object $raw -Name 'credentialFile' -Default 'secrets\credential.dat')
    if ([string]::IsNullOrWhiteSpace($credentialFile)) {
        $credentialFile = 'secrets\credential.dat'
    }

    $logLevel = [string](Get-AutoDialerJsonProperty -Object $raw -Name 'logLevel' -Default 'Info')
    if ($logLevel -notin @('Debug', 'Info', 'Warn', 'Error')) {
        $logLevel = 'Info'
    }

    return [pscustomobject]@{
        connectionName             = $connectionName.Trim()
        credentialFile             = $credentialFile
        checkIntervalSeconds       = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'checkIntervalSeconds' -Default 10) -Default 10 -Min 3 -Max 3600
        connectRetryDelaySeconds   = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'connectRetryDelaySeconds' -Default 5) -Default 5 -Min 1 -Max 3600
        maxBackoffSeconds          = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'maxBackoffSeconds' -Default 300) -Default 300 -Min 10 -Max 86400
        maxTransientRetries       = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'maxTransientRetries' -Default 0) -Default 0 -Min 0 -Max 100000
        maxAuthFailures            = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'maxAuthFailures' -Default 3) -Default 3 -Min 1 -Max 100
        requirePhysicalAdapter     = ConvertTo-AutoDialerBoolean -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'requirePhysicalAdapter' -Default $true) -Default $true
        physicalAdapterName        = [string](Get-AutoDialerJsonProperty -Object $raw -Name 'physicalAdapterName' -Default '')
        skipWhenInternetAvailable  = ConvertTo-AutoDialerBoolean -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'skipWhenInternetAvailable' -Default $false) -Default $false
        verifyConnectedAfterDial   = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'verifyConnectedAfterDialSeconds' -Default 3) -Default 3 -Min 1 -Max 60
        showErrorPopup             = ConvertTo-AutoDialerBoolean -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'showErrorPopup' -Default $false) -Default $false
        installDelaySeconds        = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'installDelaySeconds' -Default 20) -Default 20 -Min 0 -Max 600
        logLevel                   = $logLevel
        logMaxKB                   = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'logMaxKB' -Default 1024) -Default 1024 -Min 64 -Max 102400
        logKeepFiles               = Get-AutoDialerNumber -Value (Get-AutoDialerJsonProperty -Object $raw -Name 'logKeepFiles' -Default 5) -Default 5 -Min 1 -Max 50
    }
}

function Get-AutoDialerJsonProperty {
    param(
        $Object,
        [string]$Name,
        $Default
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Get-AutoDialerNumber {
    param(
        $Value,
        [int]$Default,
        [int]$Min,
        [int]$Max
    )

    $number = $Default
    if ($null -ne $Value -and "$Value" -ne '') {
        $parsed = 0
        if ([int]::TryParse([string]$Value, [ref]$parsed)) {
            $number = $parsed
        }
    }
    if ($number -lt $Min) { $number = $Min }
    if ($number -gt $Max) { $number = $Max }
    return $number
}

function ConvertTo-AutoDialerBoolean {
    param(
        $Value,
        [bool]$Default
    )

    if ($null -eq $Value) {
        return $Default
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    switch ($text.Trim().ToLowerInvariant()) {
        'true'  { return $true }
        'yes'   { return $true }
        '1'     { return $true }
        'false' { return $false }
        'no'    { return $false }
        '0'     { return $false }
        default { return $Default }
    }
}

function Get-AutoDialerCredentialPath {
    param($Config)

    $path = [string]$Config.credentialFile
    if ([System.IO.Path]::IsPathRooted($path)) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $script:AutoDialerRoot $path))
    }

    # 凭据文件限定在工具目录内，避免配置被篡改后卸载程序误删其他文件。
    $rootPrefix = [System.IO.Path]::GetFullPath($script:AutoDialerRoot).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "credentialFile 必须位于工具目录内：$script:AutoDialerRoot"
    }

    return $fullPath
}

function Initialize-AutoDialerLogging {
    [CmdletBinding()]
    param(
        $Config,
        [switch]$Console
    )

    $logDir = Join-Path $script:AutoDialerRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $script:LogFile = Join-Path $logDir 'autodialer.log'
    $script:LogMaxBytes = [int64]$Config.logMaxKB * 1024
    if ($script:LogMaxBytes -lt 65536) { $script:LogMaxBytes = 65536 }
    $script:LogKeepFiles = [int]$Config.logKeepFiles
    $script:LogConsole = [bool]$Console
    $script:LogMinPriority = switch ([string]$Config.logLevel) {
        'Debug' { 0 }
        'Info'  { 1 }
        'Warn'  { 2 }
        'Error' { 3 }
        default { 1 }
    }
}

function Protect-AutoDialerDirectory {
    [CmdletBinding()]
    param(
        [string]$Path = $script:AutoDialerRoot
    )

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $driveRoot = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
        if ($fullPath -eq $driveRoot -or $fullPath -match '^[A-Za-z]:\\Windows(\\|$)') {
            throw "拒绝对磁盘根目录或 Windows 目录修改 ACL：$fullPath"
        }

        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $sid = $identity.User.Value
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (-not (Test-Path -LiteralPath $icacls)) {
            throw '找不到 icacls.exe。'
        }

        # 先断开继承，再只授予当前用户/管理员/SYSTEM 完全控制、Users 只读执行。
        & $icacls $Path /inheritance:r /Q | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "icacls /inheritance:r 失败，退出码 $LASTEXITCODE。"
        }

        $grants = @(
            "*${sid}:(OI)(CI)F"
            '*S-1-5-18:(OI)(CI)F'
            '*S-1-5-32-544:(OI)(CI)F'
            '*S-1-5-32-545:(OI)(CI)RX'
        )
        foreach ($grant in $grants) {
            & $icacls $Path /grant:r $grant /Q | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "icacls /grant:r $grant 失败，退出码 $LASTEXITCODE。"
            }
        }

        return $true
    }
    catch {
        Write-AutoDialerLog -Level Warn -Message "收紧目录 ACL 失败（不影响拨号，但建议手动检查目录权限）：$($_.Exception.Message)"
        return $false
    }
}

function Protect-AutoDialerFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }

        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        & $icacls $Path /inheritance:r /Q | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "icacls /inheritance:r 失败，退出码 $LASTEXITCODE。"
        }

        foreach ($grant in @("*${sid}:F", '*S-1-5-18:F')) {
            & $icacls $Path /grant:r $grant /Q | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "icacls /grant:r $grant 失败，退出码 $LASTEXITCODE。"
            }
        }
        return $true
    }
    catch {
        Write-AutoDialerLog -Level Warn -Message "收紧凭据文件 ACL 失败：$($_.Exception.Message)"
        return $false
    }
}

function Write-AutoDialerLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
        [string]$Level = 'Info',
        [string]$Message
    )

    $priority = switch ($Level) {
        'Debug' { 0 }
        'Info'  { 1 }
        'Warn'  { 2 }
        'Error' { 3 }
        default { 1 }
    }

    if ($priority -lt $script:LogMinPriority) {
        return
    }

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $levelText = $Level.ToUpperInvariant().PadRight(5)
    $line = '[{0}] [{1}] {2}' -f $timestamp, $levelText, (($Message -replace "`r?`n", ' | '))

    if ($script:LogConsole) {
        switch ($Level) {
            'Error' { Write-Host $line -ForegroundColor Red }
            'Warn'  { Write-Host $line -ForegroundColor Yellow }
            'Debug' { Write-Host $line -ForegroundColor DarkGray }
            default { Write-Host $line }
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:LogFile)) {
        return
    }

    try {
        if (Test-Path -LiteralPath $script:LogFile) {
            $length = (Get-Item -LiteralPath $script:LogFile).Length
            if ($length -ge $script:LogMaxBytes) {
                Invoke-AutoDialerLogRotation
            }
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        if ($script:LogConsole) {
            Write-Host "日志写入失败：$($_.Exception.Message)" -ForegroundColor DarkRed
        }
    }
}

function Invoke-AutoDialerLogRotation {
    $log = $script:LogFile
    if ([string]::IsNullOrWhiteSpace($log) -or -not (Test-Path -LiteralPath $log)) {
        return
    }

    $oldest = "$log.$($script:LogKeepFiles)"
    if (Test-Path -LiteralPath $oldest) {
        Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue
    }

    for ($i = $script:LogKeepFiles - 1; $i -ge 1; $i--) {
        $source = "$log.$i"
        $target = "$log.$($i + 1)"
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination $target -Force -ErrorAction SilentlyContinue
        }
    }

    Move-Item -LiteralPath $log -Destination "$log.1" -Force -ErrorAction SilentlyContinue
}

function Protect-AutoDialerSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlainText
    )

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $script:AutoDialerSecretEntropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Convert]::ToBase64String($protected)
}

function Get-AutoDialerSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "凭据文件不存在：$Path。请先运行 Setup-Credential.ps1 保存宽带账号密码。"
    }

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    try {
        $base64 = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
        $encrypted = [Convert]::FromBase64String($base64)
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted,
            $script:AutoDialerSecretEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $json = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        $secret = $json | ConvertFrom-Json
    }
    catch {
        throw "凭据解密失败。该文件只能由保存它的 Windows 用户解密，请重新运行 Setup-Credential.ps1。原始错误：$($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace([string]$secret.username) -or [string]::IsNullOrEmpty([string]$secret.password)) {
        throw '凭据文件内容不完整，请重新运行 Setup-Credential.ps1。'
    }

    return [pscustomobject]@{
        username = [string]$secret.username
        password = [string]$secret.password
    }
}

$autoDialerTempDir = Join-Path $script:AutoDialerRoot 'temp'
try {
    if (-not (Test-Path -LiteralPath $autoDialerTempDir)) {
        New-Item -ItemType Directory -Path $autoDialerTempDir -Force | Out-Null
    }
    $env:TEMP = $autoDialerTempDir
    $env:TMP = $autoDialerTempDir
}
catch {
}

if (-not ('AutoDialer.NativeRas' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AutoDialer
{
    public static class NativeRas
    {
        [StructLayout(LayoutKind.Sequential, Pack = 4, CharSet = CharSet.Unicode)]
        public struct RASDIALPARAMS
        {
            public int dwSize;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szEntryName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szPhoneNumber;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szCallbackNumber;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szUserName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szPassword;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string szDomain;
            public int dwSubEntry;
            public IntPtr dwCallbackId;
        }

        [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "RasDialW", SetLastError = true)]
        public static extern int RasDial(
            IntPtr lpRasDialExtensions,
            string lpszPhonebook,
            ref RASDIALPARAMS lpRasDialParams,
            int dwNotifierType,
            IntPtr lpvNotifier,
            out IntPtr lphRasConn);

        [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "RasEnumConnectionsW", SetLastError = true)]
        public static extern int RasEnumConnections(
            IntPtr lprasconn,
            ref int lpcb,
            out int lpcConnections);

        [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "RasGetConnectStatusW", SetLastError = true)]
        public static extern int RasGetConnectStatus(
            IntPtr hrasconn,
            IntPtr lprasconnstatus);

        [DllImport("rasapi32.dll", EntryPoint = "RasHangUp", SetLastError = true)]
        public static extern int RasHangUp(IntPtr hrasconn);
    }
}
'@
}

function Get-AutoDialerRasConnections {
    [CmdletBinding()]
    param()

    $recordSize = if ([IntPtr]::Size -eq 8) { 1372 } else { 1368 }
    $entryOffset = if ([IntPtr]::Size -eq 8) { 12 } else { 8 }

    $count = 16
    $buffer = [IntPtr]::Zero
    try {
        while ($true) {
            $bufferBytes = $recordSize * $count
            $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bufferBytes)
            for ($i = 0; $i -lt $count; $i++) {
                [System.Runtime.InteropServices.Marshal]::WriteInt32($buffer, $i * $recordSize, $recordSize)
            }

            $bufferSize = $bufferBytes
            $connectionCount = 0
            $result = [AutoDialer.NativeRas]::RasEnumConnections(
                $buffer,
                [ref]$bufferSize,
                [ref]$connectionCount
            )

            if ($result -eq 603) {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
                $buffer = [IntPtr]::Zero
                $needed = [int][Math]::Ceiling([double]$bufferSize / [double]$recordSize) + 2
                $count = [int][Math]::Max([double]($connectionCount + 2), [double]$needed)
                if ($count -gt 1024) {
                    throw 'RAS 连接数量异常，停止枚举。'
                }
                continue
            }

            if ($result -ne 0) {
                throw "RasEnumConnections 失败，错误码 $result。"
            }

            if ($connectionCount -gt $count) {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
                $buffer = [IntPtr]::Zero
                $count = $connectionCount + 2
                continue
            }

            break
        }

        $connections = @()
        for ($i = 0; $i -lt $connectionCount; $i++) {
            $baseOffset = $i * $recordSize
            $handle = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buffer, $baseOffset + 4)
            $entryName = [System.Runtime.InteropServices.Marshal]::PtrToStringUni(
                [IntPtr]::Add($buffer, $baseOffset + $entryOffset)
            )

            $state = -1
            $errorCode = 0
            if ($handle -ne [IntPtr]::Zero) {
                $statusBuffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(512)
                try {
                    for ($j = 0; $j -lt 512; $j++) {
                        [System.Runtime.InteropServices.Marshal]::WriteByte($statusBuffer, $j, 0)
                    }
                    [System.Runtime.InteropServices.Marshal]::WriteInt32($statusBuffer, 0, 304)
                    $statusResult = [AutoDialer.NativeRas]::RasGetConnectStatus($handle, $statusBuffer)
                    if ($statusResult -eq 0) {
                        $state = [System.Runtime.InteropServices.Marshal]::ReadInt32($statusBuffer, 4)
                        $errorCode = [System.Runtime.InteropServices.Marshal]::ReadInt32($statusBuffer, 8)
                    }
                }
                finally {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($statusBuffer)
                }
            }

            $connections += [pscustomobject]@{
                EntryName = [string]$entryName
                Handle    = $handle
                State     = $state
                ErrorCode = $errorCode
            }
        }

        return $connections
    }
    finally {
        if ($buffer -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
        }
    }
}

function Get-AutoDialerRasStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName
    )

    try {
        $connections = @(Get-AutoDialerRasConnections)
        $connected = $connections | Where-Object {
            $_.EntryName -eq $ConnectionName -and $_.State -eq 8192
        } | Select-Object -First 1

        if ($null -ne $connected) {
            return [pscustomobject]@{
                Connected = $true
                StateCode = 8192
                State     = '已连接'
                ErrorCode = 0
                Source    = 'RAS'
            }
        }

        $known = $connections | Where-Object { $_.EntryName -eq $ConnectionName } | Select-Object -First 1
        if ($null -ne $known -and $known.State -ge 0) {
            return [pscustomobject]@{
                Connected = $false
                StateCode = $known.State
                State     = Get-AutoDialerRasStateText -State $known.State
                ErrorCode = $known.ErrorCode
                Source    = 'RAS'
            }
        }
        if ($null -ne $known -and $known.State -lt 0) {
            throw 'RasGetConnectStatus 未返回有效状态。'
        }

        return [pscustomobject]@{
            Connected = $false
            StateCode = 8193
            State     = '未连接'
            ErrorCode = 0
            Source    = 'RAS'
        }
    }
    catch {
        Write-AutoDialerLog -Level Warn -Message "RAS 状态查询失败，改用网络配置文件判断：$($_.Exception.Message)"
        $profile = Get-NetConnectionProfile -InterfaceAlias $ConnectionName -ErrorAction SilentlyContinue
        $isConnected = $false
        if ($null -ne $profile) {
            $isConnected = $profile.IPv4Connectivity -in @('Internet', 'LocalNetwork')
        }
        return [pscustomobject]@{
            Connected = $isConnected
            StateCode = if ($isConnected) { 8192 } else { 8193 }
            State     = if ($isConnected) { '已连接（按网络配置文件判断）' } else { '未连接（按网络配置文件判断）' }
            ErrorCode = 0
            Source    = 'NetProfile'
        }
    }
}

function Get-AutoDialerRasStateText {
    param([int]$State)

    if ($script:RasStateText.ContainsKey($State)) {
        return $script:RasStateText[$State]
    }
    return "状态($State)"
}

function Connect-AutoDialer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName,
        [Parameter(Mandatory = $true)]
        $Credential
    )

    $phonebook = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
    if (-not (Test-Path -LiteralPath $phonebook)) {
        throw "找不到当前用户的 RAS 电话簿：$phonebook"
    }

    $parameters = New-Object 'AutoDialer.NativeRas+RASDIALPARAMS'
    $parameters.dwSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'AutoDialer.NativeRas+RASDIALPARAMS')
    $parameters.szEntryName = $ConnectionName
    $parameters.szPhoneNumber = ''
    $parameters.szCallbackNumber = ''
    $parameters.szUserName = [string]$Credential.username
    $parameters.szPassword = [string]$Credential.password
    $parameters.szDomain = ''
    $parameters.dwSubEntry = 0
    $parameters.dwCallbackId = [IntPtr]::Zero

    $handle = [IntPtr]::Zero
    try {
        $result = [AutoDialer.NativeRas]::RasDial(
            [IntPtr]::Zero,
            $phonebook,
            [ref]$parameters,
            0,
            [IntPtr]::Zero,
            [ref]$handle
        )
    }
    finally {
        # 尽早清空托管字符串引用；结构体内存仍会被 .NET 回收，不写入任何文件。
        $parameters.szPassword = ''
        $parameters.szUserName = ''
    }

    return [pscustomobject]@{
        ResultCode = [int]$result
        Handle     = $handle
    }
}

function Disconnect-AutoDialerConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName
    )

    try {
        $connections = @(Get-AutoDialerRasConnections | Where-Object { $_.EntryName -eq $ConnectionName })
        $hungUp = 0
        foreach ($connection in $connections) {
            if ($connection.Handle -ne [IntPtr]::Zero) {
                $result = [AutoDialer.NativeRas]::RasHangUp($connection.Handle)
                if ($result -eq 0) {
                    $hungUp++
                }
            }
        }

        if ($hungUp -gt 0) {
            Start-Sleep -Seconds 1
            return [pscustomobject]@{
                Success = $true
                Count   = $hungUp
                Message = "已断开 $hungUp 个活动连接。"
            }
        }
    }
    catch {
        Write-AutoDialerLog -Level Warn -Message "RasHangUp 失败，改用 rasdial /disconnect：$($_.Exception.Message)"
    }

    $output = & "$env:SystemRoot\System32\rasdial.exe" $ConnectionName /disconnect 2>&1
    $exitCode = $LASTEXITCODE
    Start-Sleep -Seconds 1
    $after = Get-AutoDialerRasStatus -ConnectionName $ConnectionName
    $success = -not $after.Connected
    return [pscustomobject]@{
        Success = $success
        Count   = if ($success) { 1 } else { 0 }
        Message = if ($success) { '已发送断开请求，连接已断开。' } else { "断开失败（退出码 $exitCode）：$output" }
    }
}

function Get-AutoDialerErrorInfo {
    [CmdletBinding()]
    param([int]$Code)

    if ($script:RasErrorMap.ContainsKey($Code)) {
        $item = $script:RasErrorMap[$Code]
        return [pscustomobject]@{
            Code  = $Code
            Text  = $item.Text
            Fatal = [bool]$item.Fatal
            Auth  = [bool]$item.Auth
        }
    }

    $systemMessage = ''
    try {
        $systemMessage = (New-Object System.ComponentModel.Win32Exception($Code)).Message
    }
    catch {
        $systemMessage = ''
    }

    $text = if ([string]::IsNullOrWhiteSpace($systemMessage)) {
        "未知拨号错误（代码 $Code）。"
    }
    else {
        "拨号错误 $Code：$systemMessage"
    }

    return [pscustomobject]@{
        Code  = $Code
        Text  = $text
        Fatal = $false
        Auth  = $false
    }
}

function Test-AutoDialerPhonebookEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName
    )

    $candidates = @(
        (Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'),
        (Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk')
    )

    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
                $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
            }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
                $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
            }
            elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            }
            else {
                $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            }

            $matches = [regex]::Matches($text, '(?m)^\[(.+?)\]\s*$')
            foreach ($match in $matches) {
                if ($match.Groups[1].Value.Trim() -eq $ConnectionName) {
                    return $true
                }
            }
        }
        catch {
            Write-AutoDialerLog -Level Debug -Message "读取电话簿失败：$path，$($_.Exception.Message)"
        }
    }

    return $false
}

function Get-AutoDialerAdapterInfo {
    [CmdletBinding()]
    param($Config)

    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $upAdapters = @($adapters | Where-Object { $_.Status -eq 'Up' })

    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.physicalAdapterName)) {
        $selected = $adapters | Where-Object {
            $_.Name -eq $Config.physicalAdapterName -and $_.Status -eq 'Up'
        } | Select-Object -First 1
    }
    else {
        $selected = $upAdapters | Select-Object -First 1
    }

    return [pscustomobject]@{
        Ready       = [bool]($null -ne $selected)
        Name        = if ($null -ne $selected) { [string]$selected.Name } else { '' }
        Status      = if ($null -ne $selected) { [string]$selected.Status } else { 'Down' }
        UpAdapters  = @($upAdapters | ForEach-Object { $_.Name })
        AllAdapters = @($adapters | ForEach-Object { $_.Name })
    }
}

function Test-AutoDialerPhysicalAdapter {
    [CmdletBinding()]
    param($Config)

    if (-not $Config.requirePhysicalAdapter) {
        return $true
    }

    return (Get-AutoDialerAdapterInfo -Config $Config).Ready
}

function Get-AutoDialerInternetProfile {
    [CmdletBinding()]
    param()

    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    $internet = @($profiles | Where-Object { $_.IPv4Connectivity -eq 'Internet' })

    return [pscustomobject]@{
        Available  = ($internet.Count -gt 0)
        Interfaces = @($internet | ForEach-Object { $_.InterfaceAlias })
    }
}

function Get-AutoDialerConnectionIpv4 {
    [CmdletBinding()]
    param([string]$ConnectionName)

    $address = Get-NetIPAddress -InterfaceAlias $ConnectionName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1

    $profile = Get-NetConnectionProfile -InterfaceAlias $ConnectionName -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Address      = if ($null -ne $address) { [string]$address.IPAddress } else { '' }
        Connectivity = if ($null -ne $profile) { [string]$profile.IPv4Connectivity } else { '' }
        ProfileName  = if ($null -ne $profile) { [string]$profile.Name } else { '' }
    }
}

function Get-AutoDialerAutostartInfo {
    [CmdletBinding()]
    param()

    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue
    }
    catch {
        $task = $null
    }

    $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) $script:AutoDialerStartupLinkName

    return [pscustomobject]@{
        TaskName        = $script:AutoDialerTaskName
        TaskRegistered  = [bool]($null -ne $task)
        TaskState       = if ($null -ne $task) { [string]$task.State } else { '' }
        StartupLink     = $startupLink
        StartupLinkExists = Test-Path -LiteralPath $startupLink
    }
}

function Get-AutoDialerRuntimePath {
    param([string]$Name)

    $dir = Join-Path $script:AutoDialerRoot 'run'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return Join-Path $dir $Name
}

function Start-AutoDialerProcess {
    [CmdletBinding()]
    param()

    $vbs = Join-Path $script:AutoDialerRoot 'AutoDialer.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) {
        throw "找不到启动器：$vbs"
    }

    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $wscript)) {
        throw "找不到 wscript.exe：$wscript"
    }

    Start-Process -FilePath $wscript -ArgumentList "`"$vbs`"" -WorkingDirectory $script:AutoDialerRoot -WindowStyle Hidden
}

function Test-AutoDialerProcessMatch {
    param(
        [string]$CommandLine,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    $normalizedRoot = $Root.TrimEnd('\')
    $pattern = '(?i)-File\s+["'']?' + [regex]::Escape($normalizedRoot) + '[\\/]+AutoDialer\.ps1'
    return [regex]::IsMatch($CommandLine, $pattern)
}

function Stop-AutoDialerProcess {
    [CmdletBinding()]
    param()

    $root = [System.IO.Path]::GetFullPath($script:AutoDialerRoot).TrimEnd('\')
    $pidFile = Join-Path $script:AutoDialerRoot 'run\autodialer.pid'
    $ids = @()

    if (Test-Path -LiteralPath $pidFile) {
        $text = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $text -and $text.Trim() -match '^\d+$') {
            $candidateId = [int]$text.Trim()
            $candidate = Get-CimInstance Win32_Process -Filter "ProcessId=$candidateId" -ErrorAction SilentlyContinue
            if ($null -ne $candidate -and
                $candidate.Name -eq 'powershell.exe' -and
                (Test-AutoDialerProcessMatch -CommandLine ([string]$candidate.CommandLine) -Root $root)) {
                $ids += $candidateId
            }
        }
    }

    $processes = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
    foreach ($process in $processes) {
        if (Test-AutoDialerProcessMatch -CommandLine ([string]$process.CommandLine) -Root $root) {
            $ids += [int]$process.ProcessId
        }
    }

    $stopped = 0
    foreach ($processId in ($ids | Sort-Object -Unique)) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        if ($process.ProcessName -ne 'powershell') { continue }
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
            $stopped++
        }
        catch {
            Write-AutoDialerLog -Level Warn -Message "停止进程 $processId 失败：$($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $pidFile) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }

    return $stopped
}

function Show-AutoDialerErrorPopup {
    [CmdletBinding()]
    param(
        [string]$Message,
        $Config
    )

    if (-not $Config.showErrorPopup) {
        return
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shell.Popup($Message, 30, '自动拨号提醒', 16) | Out-Null
    }
    catch {
        Write-AutoDialerLog -Level Debug -Message "弹出提示失败：$($_.Exception.Message)"
    }
}

function Update-AutoDialerConnectionName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName
    )

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $raw | Add-Member -NotePropertyName connectionName -NotePropertyValue $ConnectionName -Force
    $json = $raw | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}
