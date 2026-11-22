# Aran — Windows packaging
#
# Builds, on a Windows host:
#   1. portable ZIP  (aran-<ver>-windows-x64-portable.zip) — unzip and run
#   2. installer     (aran-<ver>-windows-x64-setup.exe)    — requires Inno Setup 6
#
# Usage (PowerShell 5.1+):
#   .\scripts\package-windows.ps1                          # slim (no kernel)
#   .\scripts\package-windows.ps1 -Kernel C:\tools\mihomo.exe
#   .\scripts\package-windows.ps1 -Kernel ... -SmartDns C:\tools\smartdns.exe
#   .\scripts\package-windows.ps1 -SkipInstaller
#
# Nothing is embedded unless you pass -Kernel/-SmartDns: mihomo and smartdns are
# GPL-3.0, so a bundle containing them is distributed under GPL-3.0 as a whole.
[CmdletBinding()]
param(
  [string]$Kernel = "",
  [string]$SmartDns = "",
  [switch]$SkipInstaller,
  [switch]$PortableDefault
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$version = (Select-String -Path "app\pubspec.yaml" -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
Write-Host "==> Aran $version"

# ---------------------------------------------------------------- build
Write-Host "==> flutter build windows --release"
Push-Location app
flutter build windows --release --no-tree-shake-icons
Pop-Location

$bundle = "app\build\windows\x64\runner\Release"
if (-not (Test-Path $bundle)) { throw "build output not found: $bundle" }

# ---------------------------------------------------------------- kernel
$binDir = "app\assets\bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue "$binDir\mihomo.exe", "$binDir\smartdns.exe"

if ($Kernel) {
  if (-not (Test-Path $Kernel)) { throw "kernel not found: $Kernel" }
  Copy-Item $Kernel "$binDir\mihomo.exe" -Force
  Write-Host ("    内嵌内核: {0} ({1:N0} KB)" -f $Kernel, ((Get-Item $Kernel).Length / 1KB))
}
if ($SmartDns) {
  if (-not (Test-Path $SmartDns)) { throw "smartdns not found: $SmartDns" }
  Copy-Item $SmartDns "$binDir\smartdns.exe" -Force
  Write-Host ("    内嵌 SmartDNS: {0} ({1:N0} KB)" -f $SmartDns, ((Get-Item $SmartDns).Length / 1KB))
}

# 干净的 Windows（LTSC/Server）不自带 VC++ 运行库，缺 VC 运行库时 exe 直接
# 0xC0000135 退出。把运行库一起塞进便携包，做到解压即跑。
$redistDirs = @(
  "$env:VCToolsRedistDir\x64\Microsoft.VC143.CRT",
  "$env:VCINSTALLDIR\Redist\MSVC\*\x64\Microsoft.VC143.CRT"
)
$redist = $null
foreach ($d in $redistDirs) {
  $hit = Get-Item $d -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hit) { $redist = $hit.FullName; break }
}
if (-not $redist) {
  $vsRoot = "C:\Program Files\Microsoft Visual Studio"
  $redist = Get-ChildItem "$vsRoot\*\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
if ($redist) {
  foreach ($dll in @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','concrt140.dll')) {
    $src = Join-Path $redist $dll
    if (Test-Path $src) { Copy-Item $src "$bundle\$dll" -Force }
  }
  Write-Host "    已附带 VC++ 运行库（可解压即跑）"
} else {
  Write-Warning "未找到 VC++ 运行库（VCToolsRedistDir），便携包在干净系统上需先装 vc_redist.x64.exe"
}

if ($Kernel -or $SmartDns) {
  # Rebuild so the assets end up in the bundle.
  Push-Location app
  flutter build windows --release --no-tree-shake-icons
  Pop-Location
}
Remove-Item -Force -ErrorAction SilentlyContinue "$binDir\mihomo.exe", "$binDir\smartdns.exe"

# ---------------------------------------------------------------- stage
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$stage = Join-Path $env:TEMP "aran-stage-$version"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
$portable = Join-Path $stage "aran-$version-windows-x64"
New-Item -ItemType Directory -Force -Path $portable | Out-Null
Copy-Item "$bundle\*" $portable -Recurse -Force

# Licences (GPL-3.0 compliance when binaries are bundled)
$lic = Join-Path $portable "licenses"
New-Item -ItemType Directory -Force -Path $lic | Out-Null
Copy-Item "$root\LICENSE" "$lic\ARAN-LICENSE" -Force
foreach ($f in @("mihomo-LICENSE", "smartdns-LICENSE")) {
  $src = "packaging\licenses\$f"
  if (Test-Path $src) { Copy-Item $src "$lic\$f" -Force }
}

if ($PortableDefault) {
  # Marker makes the app keep all state next to the exe (no %LOCALAPPDATA%, no service).
  New-Item -ItemType File -Path (Join-Path $portable "portable") | Out-Null
}

@"
Aran — Windows 便携版
=====================

运行：
  aran_app.exe

数据目录：
  %LOCALAPPDATA%\Aran            （默认）
  .\aran-data\                   （本目录存在 portable 文件时）

内核：
  $(if ($Kernel) { "内嵌 mihomo.exe（首次运行解压到数据目录）" } else { "未内嵌。可用 设置 → 内核更新 → 下载，或安装 mihomo 到 PATH" })

SMARTDNS：
  $(if ($SmartDns) { "内嵌 smartdns.exe" } else { "未内嵌，可选" })

TUN 模式需要：
  * wintun.dll 与 mihomo.exe 同目录
  * 以管理员身份运行（Windows 没有 setcap 等价物）

许可证：
  licenses\ 目录下为 Aran、mihomo、smartdns 的许可证（均为 GPL-3.0）
"@ | Set-Content -Path (Join-Path $portable "README.txt") -Encoding UTF8

$zip = Join-Path $dist "aran-$version-windows-x64-portable.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $portable -DestinationPath $zip -CompressionLevel Optimal
Write-Host ("    {0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))

# ---------------------------------------------------------------- installer
if (-not $SkipInstaller) {
  $isccCandidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
  )
  $iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $iscc) {
    Write-Warning "未找到 Inno Setup 6（ISCC.exe），跳过安装包。可从 https://jrsoftware.org/isdl.php 安装后重跑。"
  } else {
    # Inno Setup 只自带英文；中文语言包是 Unofficial 目录里的独立文件，缺了就编不过
    $langDir = Join-Path (Split-Path -Parent $iscc) "Languages"
    $zh = Join-Path $langDir "ChineseSimplified.isl"
    if (-not (Test-Path $zh)) {
      Write-Host "    下载中文语言包 ChineseSimplified.isl"
      $url = "https://raw.githubusercontent.com/jrsoftware/issrc/main/Files/Languages/Unofficial/ChineseSimplified.isl"
      New-Item -ItemType Directory -Force $langDir | Out-Null
      try {
        Invoke-WebRequest -Uri $url -OutFile $zh -UseBasicParsing
      } catch {
        Write-Warning "语言包下载失败，改用纯英文安装包：$($_.Exception.Message)"
        (Get-Content packaging\windows\aran.iss) -replace 'MessagesFile: "compiler:Languages\\ChineseSimplified.isl"', 'MessagesFile: "compiler:Default.isl"' |
          Set-Content packaging\windows\aran.iss -Encoding UTF8
      }
    }
    Write-Host "==> 生成安装包"
    & $iscc `
      "/DMyAppVersion=$version" `
      "/DSourceDir=$portable" `
      "/DOutputDir=$dist" `
      "packaging\windows\aran.iss"
    $setup = Join-Path $dist "aran-$version-windows-x64-setup.exe"
    if (Test-Path $setup) { Write-Host ("    {0} ({1:N1} MB)" -f $setup, ((Get-Item $setup).Length / 1MB)) }
  }
}

Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue

Write-Host "==> 完成，产物在 dist\"
Get-ChildItem $dist -Filter "*windows*" | ForEach-Object {
  Write-Host ("    {0}  {1:N1} MB" -f $_.Name, ($_.Length / 1MB))
}
