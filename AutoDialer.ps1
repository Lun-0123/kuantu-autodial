#Requires -Version 5.1
<#
.SYNOPSIS
    宽带自动拨号守护进程。
.DESCRIPTION
    单实例后台运行：检测 PPPoE 连接状态，掉线后按指数退避重拨；
    遇到账号密码错误等不可恢复问题时停止并记录日志，避免无限重试和账号锁定。
.PARAMETER Once
    只执行一轮检测/拨号，然后退出。用于调试和验收。
.PARAMETER Console
    同时把日志输出到控制台。
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutoDialer.ps1 -Once -Console
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Console
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'AutoDialer.Core.ps1')

function Get-AutoDialerBackoff {
    param(
        [int]$Attempt,
        [int]$BaseSeconds,
        [int]$MaxSeconds
    )

    $exponent = [Math]::Min([Math]::Max($Attempt - 1, 0), 10)
    $delay = [double]$BaseSeconds * [Math]::Pow(2.0, $exponent)
    if ($delay -gt $MaxSeconds) {
        $delay = $MaxSeconds
    }
    $delay = [int][Math]::Round($delay)
    $jitter = Get-Random -Minimum 0 -Maximum 3
    return [int]($delay + $jitter)
}

$mutex = $null
$mutexAcquired = $false
$pidFile = $null
$exitCode = 0
$fatalMessage = $null

try {
    $config = Get-AutoDialerConfig
    Initialize-AutoDialerLogging -Config $config -Console:$Console

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $osText = if ($null -ne $os) { "$($os.Caption) Build=$($os.BuildNumber)" } else { '系统信息不可用' }
    $modeText = if ($Once) { '单次模式' } else { '守护模式' }
    Write-AutoDialerLog -Level Info -Message "=== AutoDialer v$script:AutoDialerVersion 启动（PID $PID，$modeText） ==="
    Write-AutoDialerLog -Level Info -Message "系统=$osText；连接名=$($config.connectionName)；目录=$script:AutoDialerRoot"

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:AutoDialerRoot.ToLowerInvariant()))
        $rootHash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').Substring(0, 12)
    }
    finally {
        $sha1.Dispose()
    }

    $mutexName = "Global\AutoDialer_$rootHash"
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        $mutexAcquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $mutexAcquired = $true
        Write-AutoDialerLog -Level Warn -Message '检测到上一次实例异常退出，已接管互斥锁。'
    }

    if (-not $mutexAcquired) {
        Write-AutoDialerLog -Level Warn -Message '已有 AutoDialer 实例在运行，本实例退出。'
        exit 0
    }

    $pidFile = Get-AutoDialerRuntimePath -Name 'autodialer.pid'
    Set-Content -LiteralPath $pidFile -Value ([string]$PID) -Encoding ASCII

    $authFailures = 0
    $transientFailures = 0
    $lastAdapterWarning = [DateTime]::MinValue
    $lastInternetSkipLog = [DateTime]::MinValue
    $credentialPath = Get-AutoDialerCredentialPath -Config $config

    while ($true) {
        $status = Get-AutoDialerRasStatus -ConnectionName $config.connectionName

        if ($status.Connected) {
            if ($authFailures -gt 0) {
                Write-AutoDialerLog -Level Info -Message '连接已恢复，认证失败计数清零。'
            }
            $authFailures = 0
            $transientFailures = 0

            if ($Once) {
                Write-AutoDialerLog -Level Info -Message "当前已连接（$($status.State)），单次检查结束。"
                break
            }

            Start-Sleep -Seconds $config.checkIntervalSeconds
            continue
        }

        if ($Once) {
            Write-AutoDialerLog -Level Info -Message "当前未连接（$($status.State)），开始尝试拨号。"
        }

        $adapter = Get-AutoDialerAdapterInfo -Config $config
        if ($config.requirePhysicalAdapter -and -not $adapter.Ready) {
            if (((Get-Date) - $lastAdapterWarning).TotalSeconds -ge 60) {
                if ([string]::IsNullOrWhiteSpace([string]$config.physicalAdapterName)) {
                    Write-AutoDialerLog -Level Warn -Message '没有处于 Up 状态的物理网卡，等待网卡/光猫就绪。'
                }
                else {
                    Write-AutoDialerLog -Level Warn -Message "物理网卡「$($config.physicalAdapterName)」未就绪，等待中。"
                }
                $lastAdapterWarning = Get-Date
            }

            if ($Once) {
                $exitCode = 1
                break
            }
            Start-Sleep -Seconds ([Math]::Min(15, $config.checkIntervalSeconds))
            continue
        }

        if ($config.skipWhenInternetAvailable) {
            $internet = Get-AutoDialerInternetProfile
            if ($internet.Available) {
                if (((Get-Date) - $lastInternetSkipLog).TotalMinutes -ge 5) {
                    Write-AutoDialerLog -Level Info -Message "已有其他网络可上网（$($internet.Interfaces -join ', ')），按配置跳过拨号。"
                    $lastInternetSkipLog = Get-Date
                }
                if ($Once) {
                    break
                }
                Start-Sleep -Seconds $config.checkIntervalSeconds
                continue
            }
        }

        if (-not (Test-AutoDialerPhonebookEntry -ConnectionName $config.connectionName)) {
            $fatalMessage = "电话簿中找不到连接「$($config.connectionName)」。请检查 config.json，或先在 Windows 设置中创建宽带(PPPoE)连接。"
            break
        }

        if (-not (Test-Path -LiteralPath $credentialPath)) {
            $fatalMessage = "凭据文件不存在：$credentialPath。请先运行 Setup-Credential.ps1，然后重新启动本工具。"
            break
        }

        try {
            $credential = Get-AutoDialerSecret -Path $credentialPath
        }
        catch {
            $fatalMessage = $_.Exception.Message
            break
        }

        Write-AutoDialerLog -Level Info -Message "开始拨号：$($config.connectionName)"
        $result = $null
        try {
            $result = Connect-AutoDialer -ConnectionName $config.connectionName -Credential $credential
        }
        catch {
            Write-AutoDialerLog -Level Error -Message "调用 RasDial 异常：$($_.Exception.Message)"
            $result = [pscustomobject]@{ ResultCode = -1; Handle = [IntPtr]::Zero }
        }
        finally {
            $credential = $null
        }

        if ($result.ResultCode -eq 0) {
            Start-Sleep -Seconds $config.verifyConnectedAfterDial
            $after = Get-AutoDialerRasStatus -ConnectionName $config.connectionName
            if ($after.Connected) {
                Write-AutoDialerLog -Level Info -Message '拨号成功，连接已建立。'
                $authFailures = 0
                $transientFailures = 0
                if ($Once) {
                    break
                }
                Start-Sleep -Seconds $config.checkIntervalSeconds
                continue
            }

            Write-AutoDialerLog -Level Warn -Message "RasDial 返回成功，但状态仍为「$($after.State)」；继续观察。"
            if ($Once) {
                $exitCode = 1
                break
            }
            Start-Sleep -Seconds $config.checkIntervalSeconds
            continue
        }

        $errorInfo = Get-AutoDialerErrorInfo -Code $result.ResultCode
        Write-AutoDialerLog -Level Error -Message "拨号失败 [代码 $($errorInfo.Code)]：$($errorInfo.Text)"

        if ($errorInfo.Auth) {
            $authFailures++
            if ($authFailures -ge $config.maxAuthFailures) {
                $fatalMessage = "连续 $authFailures 次认证失败（错误 691）。已停止自动重拨，避免账号被锁定；请运行 Setup-Credential.ps1 更正账号或密码后重新启动。"
                break
            }

            $delay = Get-AutoDialerBackoff -Attempt $authFailures -BaseSeconds $config.connectRetryDelaySeconds -MaxSeconds $config.maxBackoffSeconds
            Write-AutoDialerLog -Level Warn -Message "认证失败第 $authFailures/$($config.maxAuthFailures) 次，$delay 秒后重试。"
        }
        elseif ($errorInfo.Fatal) {
            $fatalMessage = "遇到不可恢复的拨号错误 [$($errorInfo.Code)]：$($errorInfo.Text)"
            break
        }
        else {
            $transientFailures++
            if ($config.maxTransientRetries -gt 0 -and $transientFailures -ge $config.maxTransientRetries) {
                $fatalMessage = "连续 $transientFailures 次临时失败，已达到 maxTransientRetries，停止重试。最后错误：[$($errorInfo.Code)] $($errorInfo.Text)"
                break
            }

            $delay = Get-AutoDialerBackoff -Attempt $transientFailures -BaseSeconds $config.connectRetryDelaySeconds -MaxSeconds $config.maxBackoffSeconds
            Write-AutoDialerLog -Level Warn -Message "第 $transientFailures 次临时失败，$delay 秒后重试。"
        }

        if ($Once) {
            $exitCode = 1
            break
        }

        Start-Sleep -Seconds $delay
    }
}
catch {
    if ([string]::IsNullOrWhiteSpace($script:LogFile)) {
        Write-Host "AutoDialer 启动失败：$($_.Exception.Message)" -ForegroundColor Red
    }
    else {
        Write-AutoDialerLog -Level Error -Message "未处理异常：$($_.Exception.Message)"
        Write-AutoDialerLog -Level Debug -Message "异常位置：$($_.ScriptStackTrace)"
    }
    $exitCode = 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($fatalMessage)) {
        Write-AutoDialerLog -Level Error -Message "停止：$fatalMessage"
        Show-AutoDialerErrorPopup -Message $fatalMessage -Config $config
        if ($Once) {
            # 单次诊断模式用非零退出码，方便脚本/验收判断；守护模式保持 0，避免任务计划反复重启。
            $exitCode = 1
        }
    }

    Write-AutoDialerLog -Level Info -Message '=== AutoDialer 退出 ==='

    if ($null -ne $pidFile -and (Test-Path -LiteralPath $pidFile)) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }

    if ($mutexAcquired -and $null -ne $mutex) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
            # 进程退出时由系统回收，忽略释放失败。
        }
    }

    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}

exit $exitCode
