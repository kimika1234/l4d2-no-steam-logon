# build.ps1 — 构建并打包 l4d2-no-steam-logon（Linux+Windows 双平台）
#
# 用法: powershell -ExecutionPolicy Bypass -File build.ps1
#
# 依赖: SourceMod 1.12 编译器 (spcomp64.exe) + include 目录（含 sourcescramble.inc）
#       路径通过下面 $SPCOMP / $INCLUDE 变量指定，或设同名环境变量。

param(
    [string]$SPCOMP  = $env:SPCOMP,
    [string]$INCLUDE = $env:SM_INCLUDE
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# 默认编译器：默认取 PATH 下的 spcomp64.exe / ./include。
# 用 -SPCOMP <path> -INCLUDE <path> 或环境变量 SPCOMP / SM_INCLUDE 指定。
if (-not $SPCOMP)  { $SPCOMP  = "spcomp64.exe" }
if (-not $INCLUDE) { $INCLUDE = (Join-Path $PSScriptRoot "include") }

$src   = Join-Path $root "src\l4d2_block_no_steam_logon_all.sp"
$dist  = Join-Path $root "dist"
$pkg   = Join-Path $root "pkg"
$gd    = Join-Path $root "gamedata\l4d2_block_no_steam_logon_all.txt"

New-Item -ItemType Directory -Force -Path $dist | Out-Null

if (-not (Test-Path $SPCOMP))  { throw "spcomp64.exe 未找到: $SPCOMP" }
if (-not (Test-Path $INCLUDE)) { throw "include 目录未找到: $INCLUDE" }

$smx = Join-Path $dist "l4d2_block_no_steam_logon_all.smx"

Write-Host "=== 编译 $src ==="
$p = Start-Process -FilePath $SPCOMP `
     -ArgumentList @($src, "-i$INCLUDE", "-o$smx") `
     -NoNewWindow -Wait -PassThru `
     -RedirectStandardOutput "$dist\_c_out.txt" -RedirectStandardError "$dist\_c_err.txt"
$stdout = Get-Content "$dist\_c_out.txt" -Raw
$stderr = Get-Content "$dist\_c_err.txt" -Raw
Remove-Item "$dist\_c_out.txt","$dist\_c_err.txt" -ErrorAction SilentlyContinue
Write-Host $stdout
if ($stderr) { Write-Host $stderr }

if ($p.ExitCode -ne 0 -or -not (Test-Path $smx)) {
    throw "编译失败 (exit=$($p.ExitCode))"
}
Write-Host "OK -> $smx ($((Get-Item $smx).Length) bytes)"

# ---- 组装 pkg/ ----
Write-Host "=== 组装 pkg/ ==="
$pkgPlugin  = Join-Path $pkg "addons\sourcemod\plugins"
$pkgGd      = Join-Path $pkg "addons\sourcemod\gamedata"
$pkgScript  = Join-Path $pkg "addons\sourcemod\scripting"
New-Item -ItemType Directory -Force -Path $pkgPlugin,$pkgGd,$pkgScript | Out-Null

Copy-Item $smx $pkgPlugin -Force
Copy-Item $gd  $pkgGd -Force
Copy-Item $src $pkgScript -Force
Write-Host "pkg/ 已更新"

# ---- SHA256 ----
$sums = Join-Path $dist "SHA256SUMS.txt"
$hash = (Get-FileHash $smx -Algorithm SHA256).Hash
"$hash  l4d2_block_no_steam_logon_all.smx" | Set-Content $sums -Encoding ASCII
Write-Host "SHA256: $hash"


# ---- 打包 zip（版本号从源码 #define PLUGIN_VERSION 读取）----

$verLine = Select-String -Path $src -Pattern '#define\s+PLUGIN_VERSION\s+"([^"]+)"' | Select-Object -First 1

$version = if ($verLine) { $verLine.Matches[0].Groups[1].Value } else { "0.0.0" }

$zip = Join-Path $dist "l4d2-no-steam-logon-v$version.zip"

Remove-Item $zip -ErrorAction SilentlyContinue

Compress-Archive -Path (Join-Path $pkg "*"), (Join-Path $root "README.md") -DestinationPath $zip -Force

Write-Host "打包: $zip ($((Get-Item $zip).Length) bytes)"


Write-Host ""
Write-Host "完成。部署：把 pkg/ 下内容合并进 服务器 left4dead2 目录 即可。"
