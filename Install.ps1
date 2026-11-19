#Requires -Version 5.1
<#
.SYNOPSIS
    安装开机/登录自启。
.DESCRIPTION
    默认创建「当前用户登录时触发」的计划任务（无需管理员权限；若注册失败则回退到启动文件夹）。
    不修改防火墙、DNS 或其他网络配置。
.PARAMETER ConnectionName
    可选。写入 config.json 的宽带连接名，例如「宽带连接」。
.PARAMETER Mode
    Task = 计划任务（推荐）；Startup = 当前用户启动文件夹快捷方式。
.PARAMETER SkipCredential
    跳过凭据检查。仅在已经运行过 Setup-Credential.ps1 时使用。
.PARAMETER NoFallback
    计划任务注册失败时不再回退到启动文件夹，直接报错。
.PARAMETER StartNow
    安装完成后立即启动一次守护进程。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConnectionName,
    [ValidateSet('Task', 'Startup')]
    [string]$Mode = 'Task',
    [switch]$SkipCredential,
    [switch]$NoFallback,
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

. (Join-Path $PSScriptRoot 'AutoDialer.Core.ps1')

function Install-AutoDialerTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [int]$DelaySeconds
    )

    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $vbs = Join-Path $Root 'AutoDialer.vbs'
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $action = New-ScheduledTaskAction -Execute $wscript -Argument "`"$vbs`"" -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    if ($DelaySeconds -gt 0) {
        # 登录触发器的延迟必须是 ISO 8601 持续时间，例如 PT20S。
        $trigger.Delay = "PT${DelaySeconds}S"
    }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -Hidden

    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $script:AutoDialerTaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description '登录后自动完成宽带(PPPoE)拨号，断线自动重连。' `
        -Force | Out-Null
}

function Install-AutoDialerStartupShortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $startup = [Environment]::GetFolderPath('Startup')
    if ([string]::IsNullOrWhiteSpace($startup)) {
        throw '无法获取当前用户的启动文件夹路径。'
    }

    $linkPath = Join-Path $startup $script:AutoDialerStartupLinkName
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($linkPath)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = "`"$(Join-Path $Root 'AutoDialer.vbs')`""
    $shortcut.WorkingDirectory = $Root
    $shortcut.WindowStyle = 7
    $shortcut.Description = '登录后自动完成宽带(PPPoE)拨号'
    $shortcut.Save()

    return $linkPath
}

function Install-AutoDialerRunEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $valueName = 'KuanTu-AutoDialer'
    $vbs = Join-Path $Root 'AutoDialer.vbs'
    $command = 'wscript.exe "' + $vbs + '"'

    if (-not (Test-Path -LiteralPath $runKey)) {
        New-Item -Path $runKey -Force | Out-Null
    }
    Set-ItemProperty -Path $runKey -Name $valueName -Value $command -Type String
    return $command
}

function Remove-AutoDialerAutostart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $task = Get-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        # 先停止正在运行的任务，避免任务实例占用导致 Unregister-ScheduledTask 拒绝访问。
        try {
            Stop-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
        }
        catch {
        }
        Unregister-ScheduledTask -TaskName $script:AutoDialerTaskName -Confirm:$false
        Write-Host "已移除旧计划任务：$script:AutoDialerTaskName"
    }

    $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) $script:AutoDialerStartupLinkName
    if (Test-Path -LiteralPath $startupLink) {
        Remove-Item -LiteralPath $startupLink -Force
        Write-Host "已移除旧启动快捷方式：$startupLink"
    }

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path -LiteralPath $runKey) {
        Remove-ItemProperty -Path $runKey -Name 'KuanTu-AutoDialer' -ErrorAction SilentlyContinue
    }
}

$configPath = Join-Path $PSScriptRoot 'config.json'
$config = Get-AutoDialerConfig -Path $configPath

if (-not [string]::IsNullOrWhiteSpace($ConnectionName) -and $ConnectionName -ne $config.connectionName) {
    if ($PSCmdlet.ShouldProcess($configPath, "将宽带连接名改为「$ConnectionName」")) {
        Update-AutoDialerConnectionName -Path $configPath -ConnectionName $ConnectionName
        $config = Get-AutoDialerConfig -Path $configPath
    }
}

if (-not $WhatIfPreference) {
    $aclProtected = Protect-AutoDialerDirectory -Path $PSScriptRoot
    if (-not $aclProtected) {
        Write-Warning '未能自动收紧程序目录权限。若目录允许其他用户写入，请手动把写权限限制为当前用户。'
    }
}

Write-Host ''
Write-Host "AutoDialer v$script:AutoDialerVersion 安装程序" -ForegroundColor Cyan
Write-Host "目录：$PSScriptRoot"
Write-Host "连接：$($config.connectionName)"
Write-Host ''

if (-not (Test-AutoDialerPhonebookEntry -ConnectionName $config.connectionName)) {
    throw @"
电话簿中找不到连接「$($config.connectionName)」。
请先在 Windows 中创建宽带连接：
  设置 > 网络和 Internet > 拨号 > 设置新连接 > 连接到 Internet > 宽带(PPPoE)
创建后把连接名填入 config.json 的 connectionName，或重新运行：
  Install.ps1 -ConnectionName "你的连接名"
"@
}

$credentialPath = Get-AutoDialerCredentialPath -Config $config
if (-not $SkipCredential) {
    $needCredential = -not (Test-Path -LiteralPath $credentialPath)
    if (-not $needCredential) {
        try {
            $null = Get-AutoDialerSecret -Path $credentialPath
            Write-Host '已检测到可解密的宽带凭据。' -ForegroundColor Green
        }
        catch {
            $needCredential = $true
        }
    }

    if ($needCredential) {
        if ($WhatIfPreference) {
            Write-Host '[-WhatIf] 未保存凭据：实际安装时会提示输入宽带账号密码。' -ForegroundColor Yellow
        }
        else {
            & (Join-Path $PSScriptRoot 'Setup-Credential.ps1') -ConnectionName $config.connectionName
            if (-not (Test-Path -LiteralPath $credentialPath)) {
                throw '凭据未保存成功，安装中止。'
            }
            $null = Get-AutoDialerSecret -Path $credentialPath
        }
    }
}
else {
    Write-Host '已按 -SkipCredential 跳过凭据检查。' -ForegroundColor Yellow
}

if ($PSCmdlet.ShouldProcess('当前用户自启项', "安装 AutoDialer（模式：$Mode）")) {
    $installedMode = $null
    $taskInstalled = $false
    $desiredVbs = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'AutoDialer.vbs'))
    $existingTask = Get-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue
    $existingTaskMatches = $false
    $existingVbs = $null

    if ($null -ne $existingTask -and $existingTask.Actions.Count -gt 0) {
        try {
            $existingVbs = ([string]$existingTask.Actions[0].Arguments).Trim().Trim('"')
            $existingTaskMatches = ([IO.Path]::GetFullPath($existingVbs) -eq $desiredVbs)
        }
        catch {
        }
    }

    if ($Mode -eq 'Task' -and $null -ne $existingTask) {
        # 已存在同名任务时优先复用，避免任务实例运行中重复注册被拒绝访问。
        if ($existingVbs -and -not $existingTaskMatches) {
            Write-Warning "现有计划任务指向：$existingVbs；将继续使用该任务。"
        }
        try {
            Enable-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue | Out-Null
            Start-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction SilentlyContinue
        }
        catch {
        }
        $taskInstalled = $true
        $installedMode = '计划任务（沿用现有任务）'
    }
    else {
        try {
            Remove-AutoDialerAutostart -Root $PSScriptRoot
        }
        catch {
            Write-Warning "清理旧自启项时出现问题：$($_.Exception.Message)"
        }

        if ($Mode -eq 'Task') {
            try {
                Install-AutoDialerTask -Root $PSScriptRoot -DelaySeconds $config.installDelaySeconds
                $taskInstalled = $true
                $installedMode = '计划任务（登录触发，固定延迟约 ' + $config.installDelaySeconds + ' 秒）'
            }
            catch {
                $taskError = $_.Exception.Message
                Write-Warning "计划任务注册失败：$taskError"
                if ($NoFallback) {
                    throw '计划任务注册失败，且已指定 -NoFallback。'
                }
                Write-Host '改用当前用户启动文件夹。' -ForegroundColor Yellow
                try {
                    $link = Install-AutoDialerStartupShortcut -Root $PSScriptRoot
                    $installedMode = "启动文件夹（$link）"
                }
                catch {
                    Write-Warning "启动文件夹快捷方式失败：$($_.Exception.Message)"
                    $runCommand = Install-AutoDialerRunEntry -Root $PSScriptRoot
                    $installedMode = "当前用户 Run 注册表（$runCommand）"
                }
            }
        }
        else {
            try {
                $link = Install-AutoDialerStartupShortcut -Root $PSScriptRoot
                $installedMode = "启动文件夹（$link）"
            }
            catch {
                Write-Warning "启动文件夹快捷方式失败：$($_.Exception.Message)"
                $runCommand = Install-AutoDialerRunEntry -Root $PSScriptRoot
                $installedMode = "当前用户 Run 注册表（$runCommand）"
            }
        }
    }

    Write-Host ''
    Write-Host '安装完成。' -ForegroundColor Green
    Write-Host "自启方式：$installedMode"
    Write-Host "日志文件：$(Join-Path $PSScriptRoot 'logs\autodialer.log')"
    Write-Host "凭据文件：$credentialPath（DPAPI 加密）"
    Write-Host ''
    Write-Host '常用命令：' -ForegroundColor Cyan
    Write-Host '  .\Control.ps1 -Action Status        # 查看当前状态'
    Write-Host '  .\Control.ps1 -Action Start         # 立即启动守护进程'
    Write-Host '  .\Control.ps1 -Action Stop          # 停止守护进程'
    Write-Host '  .\Uninstall.ps1                     # 取消自启并清理运行数据'

    if ($StartNow) {
        try {
            if ($taskInstalled) {
                Start-ScheduledTask -TaskName $script:AutoDialerTaskName -ErrorAction Stop
                Write-Host '已立即启动计划任务。' -ForegroundColor Green
            }
            else {
                Start-AutoDialerProcess
                Write-Host '已立即启动后台进程。' -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "立即启动失败：$($_.Exception.Message)"
        }
    }
}
else {
    Write-Host '[-WhatIf] 未修改自启项。' -ForegroundColor Yellow
}
