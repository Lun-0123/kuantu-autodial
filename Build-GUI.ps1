#Requires -Version 5.1
<#
.SYNOPSIS
    重新编译图形设置程序。
.DESCRIPTION
    仅开发/维护时需要。普通用户直接运行“宽带自动拨号设置.exe”即可。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = $PSScriptRoot
$source = Join-Path $root 'src\AutoDialerSetup.cs'
$output = Join-Path $root '宽带自动拨号设置.exe'
$cscCandidates = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)

$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($csc)) {
    throw '找不到 .NET Framework C# 编译器 csc.exe。'
}
if (-not (Test-Path -LiteralPath $source)) {
    throw "找不到源码：$source"
}

$arguments = @(
    '/nologo'
    '/target:winexe'
    '/platform:anycpu'
    '/optimize+'
    '/codepage:65001'
    "/out:$output"
    '/reference:System.dll'
    '/reference:System.Core.dll'
    '/reference:System.Drawing.dll'
    '/reference:System.Windows.Forms.dll'
    '/reference:System.Security.dll'
    '/reference:System.Runtime.Serialization.dll'
    '/reference:System.Xml.dll'
    $source
)

& $csc $arguments
if ($LASTEXITCODE -ne 0) {
    throw "编译失败，csc 退出码：$LASTEXITCODE"
}

$file = Get-Item -LiteralPath $output
Write-Host "编译成功：$($file.FullName)（$([Math]::Round($file.Length / 1KB, 1)) KB）" -ForegroundColor Green
