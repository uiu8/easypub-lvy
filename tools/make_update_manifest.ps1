# 为发布包生成自动更新清单与签名（V68）。在 gh release create 时把输出的两个文件一起上传：
#   update-manifest.json、update-manifest.json.sig
# 私钥默认在 %USERPROFILE%\.easypub-lvy\release-signing.key（不在仓库里）；
# release_sign 会用程序内置公钥复核签名，私钥不对就失败。
param(
  [Parameter(Mandatory = $true)][string]$Zip,
  [Parameter(Mandatory = $true)][string]$NotesPath,
  [string]$OutDir = '',
  [string]$KeyPath = (Join-Path $env:USERPROFILE '.easypub-lvy\release-signing.key'),
  [int]$Release = 0,
  [string]$Tag = '',
  [string]$Date = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$zipPath = (Resolve-Path -LiteralPath $Zip).Path
$name = [IO.Path]::GetFileNameWithoutExtension($zipPath)
$m = [regex]::Match($name, '-v(\d+)-(\d{8})-')
if ($Release -le 0) {
  if (-not $m.Success) { throw '包名里没有 -vNN-YYYYMMDD-，请指定 -Release、-Tag、-Date。' }
  $Release = [int]$m.Groups[1].Value
}
if (-not $Tag) { $Tag = "v$Release-$($m.Groups[2].Value)" }
if (-not $Date) { $d = $m.Groups[2].Value; $Date = "$($d.Substring(0,4))-$($d.Substring(4,2))-$($d.Substring(6,2))" }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $zipPath) "$name-update" }
if (-not (Test-Path -LiteralPath $KeyPath)) { throw "找不到发布私钥：$KeyPath" }
& cargo run -q --release --locked -p easypub_updater --bin release_sign -- manifest `
  --key $KeyPath --zip $zipPath --release $Release --tag $Tag --date $Date `
  --root $name --notes (Resolve-Path -LiteralPath $NotesPath).Path --out $OutDir
if ($LASTEXITCODE -ne 0) { throw '生成更新清单失败。' }
Get-ChildItem -LiteralPath $OutDir | Select-Object Name, Length
