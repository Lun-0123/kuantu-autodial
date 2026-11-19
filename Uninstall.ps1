#Requires -Version 5.1
<#
.SYNOPSIS
    卸载 AutoDialer：停止进程、取消自启、删除凭据和运行数据。
.DESCRIPTION
    默认保留程序文件与 README，方便日后重新安装；使用 -RemoveAll 删除配置和脚本（卸载脚本自身除外）。
    不会删除「宽带连接」电话簿条目，也不会修改其他网络设置。
.PARAMETER KeepLogs
    保留 logs 目录，便于事后排查。
.PARAMETER RemoveAll
    删除 config.json、核心脚本和辅助脚本（保留 Uninstall.ps1 与 README.md）。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$KeepLogs,
    [switch]$RemoveAll
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'AutoDialer.Core.ps1')

$rootFull = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$driveRoot = [System.IO.Path]::GetPathRoot($rootFull).TrimEnd('\')
if ($rootFull -eq $driveRoot -or $rootFull -match '^[A-Za-z]:\\Windows(\\|$)') {
    throw "拒绝在磁盘根目录或 Windows 目录执行卸载：$rootFull"
}

Write-Host ''
Write-Host "AutoDialer v$script:AutoDialerVersion 卸载程序" -ForegroundColor Cyan
Write-Host ''

$task = Get-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ($PSCmdlet.ShouldProcess("计划任务 $($script:AutoDialerTaskName)", '取消注册')) {
        try {
            Unregister-ScheduledTask -TaskName $script:AutoDialerTaskName -Confirm:$false -ErrorAction Stop
            Write-Host "已删除计划任务：$script:AutoDialerTaskName" -ForegroundColor Green
        }
        catch {
            Write-Warning "删除计划任务失败：$($_.Exception.Message)"
        }
    }
}
else {
    Write-Host '未发现 AutoDialer 计划任务。'
}

$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) $script:AutoDialerStartupLinkName
if (Test-Path -LiteralPath $startupLink) {
    if ($PSCmdlet.ShouldProcess($startupLink, '删除启动快捷方式')) {
        Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue
        Write-Host '已删除启动文件夹快捷方式。' -ForegroundColor Green
    }
}
else {
    Write-Host '未发现启动文件夹快捷方式。'
}

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path -LiteralPath $runKey) {
    Remove-ItemProperty -Path $runKey -Name 'KuanTu-AutoDialer' -ErrorAction SilentlyContinue
}

$stopped = 0
if ($PSCmdlet.ShouldProcess('AutoDialer 后台进程', '停止')) {
    $stopped = Stop-AutoDialerProcess
    Write-Host "已停止 $stopped 个后台进程。"
}

$config = $null
try {
    $config = Get-AutoDialerConfig
}
catch {
    Write-Host 'config.json 不可读，将按默认路径清理 secrets 目录。' -ForegroundColor Yellow
}

$credentialPath = if ($null -ne $config) {
    Get-AutoDialerCredentialPath -Config $config
}
else {
    Join-Path $PSScriptRoot 'secrets\credential.dat'
}

if (Test-Path -LiteralPath $credentialPath) {
    if ($PSCmdlet.ShouldProcess($credentialPath, '删除 DPAPI 加密凭据')) {
        Remove-Item -LiteralPath $credentialPath -Force -ErrorAction SilentlyContinue
        Write-Host '已删除加密凭据文件。' -ForegroundColor Green
    }
}

$secretDir = Join-Path $PSScriptRoot 'secrets'
if (Test-Path -LiteralPath $secretDir) {
    $remaining = @(Get-ChildItem -LiteralPath $secretDir -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $secretDir -Force -ErrorAction SilentlyContinue
    }
}

if (-not $KeepLogs) {
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (Test-Path -LiteralPath $logDir) {
        if ($PSCmdlet.ShouldProcess($logDir, '删除日志目录')) {
            Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host '已删除日志目录。'
        }
    }
}
else {
    Write-Host '已按 -KeepLogs 保留日志。'
}

$runDir = Join-Path $PSScriptRoot 'run'
if (Test-Path -LiteralPath $runDir) {
    Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($RemoveAll) {
    if ($PSCmdlet.ShouldProcess($PSScriptRoot, '删除已知程序文件（保留 Uninstall.ps1 与 README.md）')) {
        $toolFiles = @(
            'AutoDialer.ps1',
            'AutoDialer.Core.ps1',
            'AutoDialer.vbs',
            'config.json',
            'Setup-Credential.ps1',
            'Install.ps1',
            'Control.ps1',
            'Test-AutoDialer.ps1',
            'Debug-Run.cmd',
            'Install.cmd',
            'Setup-Credential.cmd',
            'Check.cmd',
            'Status.cmd',
            'Uninstall.cmd',
            'Build-GUI.ps1',
            '宽带自动拨号设置.exe',
            'SECURITY.md',
            '.gitignore',
            'docs\ui.png',
            'src\AutoDialerSetup.cs'
        )

        foreach ($relativePath in $toolFiles) {
            $target = Join-Path $PSScriptRoot $relativePath
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($dirName in @('secrets', 'logs', 'run', 'docs', 'src')) {
            $dir = Join-Path $PSScriptRoot $dirName
            if (Test-Path -LiteralPath $dir) {
                $remaining = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
                if ($remaining.Count -eq 0) {
                    Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Write-Host '已删除已知程序文件；Uninstall.ps1 与 README.md 保留。' -ForegroundColor Green
        Write-Host '目录中的其他文件不会被删除，确认不需要后可手动删除整个目录。' -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Green
Write-Host '未修改「宽带连接」电话簿条目，也未修改防火墙、DNS 或其他网络设置。' -ForegroundColor DarkGray
Write-Host '如仍需手动清理：删除本目录即可。'
