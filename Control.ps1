#Requires -Version 5.1
<#
.SYNOPSIS
    AutoDialer 状态查看与手动控制。
.PARAMETER Action
    Status（默认）、Connect、Disconnect、Start、Stop、Restart。
.PARAMETER Yes
    断开连接时跳过确认。
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Connect', 'Disconnect', 'Start', 'Stop', 'Restart')]
    [string]$Action = 'Status',
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

. (Join-Path $PSScriptRoot 'AutoDialer.Core.ps1')

$config = Get-AutoDialerConfig
Initialize-AutoDialerLogging -Config $config -Console:$false

function Show-AutoDialerStatus {
    param($Config)

    $status = Get-AutoDialerRasStatus -ConnectionName $Config.connectionName
    $ipv4 = Get-AutoDialerConnectionIpv4 -ConnectionName $Config.connectionName
    $adapter = Get-AutoDialerAdapterInfo -Config $Config
    $autostart = Get-AutoDialerAutostartInfo
    $internet = Get-AutoDialerInternetProfile

    Write-Host ''
    Write-Host "AutoDialer v$script:AutoDialerVersion" -ForegroundColor Cyan
    Write-Host "连接名称 : $($Config.connectionName)"
    $ipv4Text = if ([string]::IsNullOrWhiteSpace($ipv4.Address)) { '无' } else { $ipv4.Address }
    $connectivityText = if ([string]::IsNullOrWhiteSpace($ipv4.Connectivity)) { '无' } else { $ipv4.Connectivity }
    $adapterText = if ($adapter.Ready) { "$($adapter.Name)（$($adapter.Status)）" } else { '未就绪' }
    $internetText = if ($internet.Available) { "是（$($internet.Interfaces -join ', ')）" } else { '否' }

    Write-Host ("RAS 状态 : {0}（代码 {1}，来源 {2}）" -f $status.State, $status.StateCode, $status.Source)
    Write-Host ("IPv4     : {0}" -f $ipv4Text)
    Write-Host ("网络配置 : {0}" -f $connectivityText)
    Write-Host ("物理网卡 : {0}" -f $adapterText)
    Write-Host ("可上网   : {0}" -f $internetText)

    $autostartText = @()
    if ($autostart.TaskRegistered) {
        $autostartText += "计划任务 $($autostart.TaskName)（$($autostart.TaskState)）"
    }
    if ($autostart.StartupLinkExists) {
        $autostartText += "启动文件夹 $($autostart.StartupLink)"
    }
    if ($autostartText.Count -eq 0) {
        $autostartText += '未安装'
    }
    Write-Host ("自启方式 : {0}" -f ($autostartText -join '；'))
    Write-Host "凭据文件 : $(Get-AutoDialerCredentialPath -Config $Config)"
    Write-Host "日志文件 : $(Join-Path $script:AutoDialerRoot 'logs\autodialer.log')"

    $pidFile = Join-Path $script:AutoDialerRoot 'run\autodialer.pid'
    if (Test-Path -LiteralPath $pidFile) {
        Write-Host "守护进程 : PID $((Get-Content -LiteralPath $pidFile -Raw).Trim())"
    }
    else {
        Write-Host '守护进程 : 未运行'
    }
    Write-Host ''
}

switch ($Action) {
    'Status' {
        Show-AutoDialerStatus -Config $config
    }

    'Connect' {
        $credentialPath = Get-AutoDialerCredentialPath -Config $config
        if (-not (Test-Path -LiteralPath $credentialPath)) {
            throw "凭据文件不存在：$credentialPath。请先运行 Setup-Credential.ps1。"
        }

        $status = Get-AutoDialerRasStatus -ConnectionName $config.connectionName
        if ($status.Connected) {
            Write-Host '当前已经连接，无需重复拨号。' -ForegroundColor Green
            exit 0
        }

        $credential = Get-AutoDialerSecret -Path $credentialPath
        try {
            Write-Host "正在拨号：$($config.connectionName) ..."
            $result = Connect-AutoDialer -ConnectionName $config.connectionName -Credential $credential
        }
        finally {
            $credential = $null
        }

        if ($result.ResultCode -eq 0) {
            Start-Sleep -Seconds $config.verifyConnectedAfterDial
            $after = Get-AutoDialerRasStatus -ConnectionName $config.connectionName
            if ($after.Connected) {
                Write-Host '拨号成功。' -ForegroundColor Green
                exit 0
            }
            Write-Host "RasDial 返回成功，但当前状态为：$($after.State)" -ForegroundColor Yellow
            exit 1
        }

        $errorInfo = Get-AutoDialerErrorInfo -Code $result.ResultCode
        Write-Host "拨号失败 [代码 $($errorInfo.Code)]：$($errorInfo.Text)" -ForegroundColor Red
        exit 1
    }

    'Disconnect' {
        $status = Get-AutoDialerRasStatus -ConnectionName $config.connectionName
        if (-not $status.Connected) {
            Write-Host '当前未连接，无需断开。'
            exit 0
        }

        if (-not $Yes) {
            $answer = Read-Host "确认断开「$($config.connectionName)」？输入 Y 继续"
            if ($answer -notmatch '^[Yy]') {
                Write-Host '已取消。'
                exit 0
            }
        }

        $result = Disconnect-AutoDialerConnection -ConnectionName $config.connectionName
        if ($result.Success) {
            Write-Host $result.Message -ForegroundColor Green
            exit 0
        }
        Write-Host $result.Message -ForegroundColor Red
        exit 1
    }

    'Start' {
        Start-AutoDialerProcess
        $pidFile = Join-Path $script:AutoDialerRoot 'run\autodialer.pid'
        for ($i = 0; $i -lt 10; $i++) {
            if (Test-Path -LiteralPath $pidFile) { break }
            Start-Sleep -Milliseconds 500
        }
        if (Test-Path -LiteralPath $pidFile) {
            $runningPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
            Write-Host "已启动守护进程，PID $runningPid。" -ForegroundColor Green
        }
        else {
            Write-Host '启动命令已发出，请用 Status 查看运行状态。' -ForegroundColor Yellow
        }
    }

    'Stop' {
        $count = Stop-AutoDialerProcess
        Write-Host "已停止 $count 个后台进程。" -ForegroundColor Green
        $autostart = Get-AutoDialerAutostartInfo
        if ($autostart.TaskRegistered -or $autostart.StartupLinkExists) {
            Write-Host '注意：自启项仍保留，下次登录时还会自动启动。' -ForegroundColor DarkGray
        }
        else {
            Write-Host '当前未安装自启项。' -ForegroundColor DarkGray
        }
    }

    'Restart' {
        $count = Stop-AutoDialerProcess
        Write-Host "已停止 $count 个后台进程，正在重新启动 ..."
        Start-Sleep -Seconds 1
        Start-AutoDialerProcess
        Write-Host '已发送启动命令。' -ForegroundColor Green
    }
}
