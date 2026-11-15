#Requires -Version 5.1
<#
.SYNOPSIS
    保存或更新宽带账号密码（DPAPI 加密）。
.DESCRIPTION
    密码不会写入配置文件，也不会以明文落盘：
    使用 Windows DPAPI（CurrentUser 范围）加密后保存到 secrets\credential.dat。
    只有保存该文件的 Windows 用户才能解密。
.PARAMETER ConnectionName
    仅用于提示，不修改 config.json。
.PARAMETER Username
    可选。提供后不再交互询问账号，但仍会安全地询问密码。
#>
[CmdletBinding()]
param(
    [string]$ConnectionName,
    [string]$Username
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'AutoDialer.Core.ps1')

$config = Get-AutoDialerConfig
if ([string]::IsNullOrWhiteSpace($ConnectionName)) {
    $ConnectionName = $config.connectionName
}

$null = Protect-AutoDialerDirectory -Path $PSScriptRoot

$credentialPath = Get-AutoDialerCredentialPath -Config $config
$existing = $null
if (Test-Path -LiteralPath $credentialPath) {
    try {
        $existing = Get-AutoDialerSecret -Path $credentialPath
    }
    catch {
        Write-Host '检测到旧凭据，但当前用户无法解密，将重新保存。' -ForegroundColor Yellow
    }
}

if ([string]::IsNullOrWhiteSpace($Username)) {
    if ($null -ne $existing) {
        $inputUser = Read-Host "宽带账号 [$($existing.username)]（直接回车保留）"
        if ([string]::IsNullOrWhiteSpace($inputUser)) {
            $Username = $existing.username
        }
        else {
            $Username = $inputUser.Trim()
        }
    }
    else {
        $Username = (Read-Host '宽带账号').Trim()
    }
}

if ([string]::IsNullOrWhiteSpace($Username)) {
    throw '宽带账号不能为空。'
}

$passwordPrompt = if ($null -ne $existing) {
    '宽带密码（直接回车沿用已保存密码）'
}
else {
    '宽带密码'
}

$securePassword = Read-Host -AsSecureString $passwordPrompt
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}
finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrEmpty($plainPassword)) {
    if ($null -ne $existing) {
        $plainPassword = $existing.password
    }
    else {
        throw '宽带密码不能为空。'
    }
}

$secretDir = Split-Path -Parent $credentialPath
if (-not (Test-Path -LiteralPath $secretDir)) {
    New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
}

$payload = [pscustomobject]@{
    version   = 1
    username  = $Username
    password  = $plainPassword
    updatedAt = (Get-Date).ToString('o')
} | ConvertTo-Json -Compress

$protected = Protect-AutoDialerSecret -PlainText $payload
[System.IO.File]::WriteAllText($credentialPath, $protected, (New-Object System.Text.UTF8Encoding($false)))

# 限制文件 ACL：只保留当前用户和 SYSTEM 的完全控制，降低同机其他用户读取密文的可能。
if (-not (Protect-AutoDialerFile -Path $credentialPath)) {
    Write-Host '提示：未能收紧凭据文件 ACL（DPAPI 加密仍然有效）。' -ForegroundColor Yellow
}

# 立即验证一次，避免保存后才发现在别的用户下无法解密。
$verify = Get-AutoDialerSecret -Path $credentialPath
if ($verify.username -ne $Username) {
    throw '凭据写入后验证失败，请重试。'
}

$verify = $null
$plainPassword = $null
$payload = $null

Write-Host ''
Write-Host '凭据已保存。' -ForegroundColor Green
Write-Host "连接名称：$ConnectionName"
Write-Host "宽带账号：$Username"
Write-Host "凭据文件：$credentialPath"
Write-Host '密码已使用 Windows DPAPI 加密，不会以明文写入磁盘或日志。' -ForegroundColor DarkGray
