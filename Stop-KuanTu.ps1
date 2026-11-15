#Requires -Version 5.1
<#
.SYNOPSIS
    停止宽途后台拨号，并移除开机自启，便于安全地重命名/移动文件夹。
.DESCRIPTION
    只移除“自启”和“当前守护进程”，不删除 config.json、secrets 或日志。
    重新启用：重新打开“宽带自动拨号设置.exe”并保存设置，或运行 Install.cmd。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'AutoDialer.Core.ps1')

$removed = @()

try {
    $task = Get-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Disable-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue | Out-Null
        Stop-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue
        $removed += '计划任务已禁用'
    }
}
catch {
}

$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) $script:AutoDialerStartupLinkName
if (Test-Path -LiteralPath $startupLink) {
    Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $startupLink)) {
        $removed += '启动文件夹快捷方式已移除'
    }
}

& (Join-Path $PSScriptRoot 'Control.ps1') -Action Stop | Out-Host
$stopCode = $LASTEXITCODE

Write-Host ''
Write-Host '宽途已停止。' -ForegroundColor Green
if ($removed.Count -gt 0) {
    Write-Host ('已处理：' + ($removed -join '；')) -ForegroundColor DarkGray
}
Write-Host '现在可以重命名或移动整个文件夹。' -ForegroundColor Cyan
Write-Host '重新启用：重新打开“宽带自动拨号设置.exe”并保存，或运行 Install.cmd。' -ForegroundColor DarkGray

if ($stopCode -ne 0) {
    exit $stopCode
}
exit 0
