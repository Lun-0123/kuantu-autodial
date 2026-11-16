#Requires -Version 5.1
<#
.SYNOPSIS
    停止宽途后台拨号，并移除开机自启，便于安全地重命名/移动文件夹。
.DESCRIPTION
    不加载 AutoDialer.Core.ps1，因此不会触发 Add-Type 的临时文件问题。
    只停止守护进程、禁用计划任务、移除启动快捷方式；不删除账号、配置、日志或凭据。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$taskName = 'AutoDialer-Broadband'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'AutoDialer.lnk'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    Disable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

$stopped = 0
$daemonPath = Join-Path $PSScriptRoot 'AutoDialer.ps1'
$daemonPattern = '-File\s+"?' + [regex]::Escape($daemonPath) + '"?\s*$'
$processes = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match $daemonPattern -and
        $_.ProcessId -ne $PID
    }

foreach ($process in $processes) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    if (-not (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) {
        $stopped++
    }
}

if (Test-Path -LiteralPath $startupLink) {
    Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '宽途已停止。' -ForegroundColor Green
Write-Host ('已停止守护进程：' + $stopped + ' 个') -ForegroundColor DarkGray
Write-Host '计划任务已禁用，启动快捷方式已移除。' -ForegroundColor DarkGray
Write-Host '现在可以重命名或移动整个文件夹。' -ForegroundColor Cyan
Write-Host '重新启用：重新打开“宽带自动拨号设置.exe”并保存，或运行 Install.cmd。' -ForegroundColor DarkGray
exit 0
