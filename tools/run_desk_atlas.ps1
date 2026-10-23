# 全页面图集（R0，正式版打磨）：真实字体与测试假数据，按窗口宽度 × 主题 × 字号给每个页面出图，
# 输出到 artifacts/atlas-<时间>/，打开其中的 index.html 逐页翻看。
# 用法：tools/run_desk_atlas.ps1 [-Sizes 1100,1500,1900] [-Themes paper,night] [-Scales 1.0,1.3]
param(
  [string[]]$Sizes = @('1100', '1500', '1900'),
  [string[]]$Themes = @('paper', 'night'),
  [string[]]$Scales = @('1.0', '1.3'),
  [string]$Dll = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root ('artifacts\atlas-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $out | Out-Null
if (-not $Dll) { $Dll = Join-Path $root 'target\release\easypub_bridge.dll' }
$saved = @{}
foreach ($name in @('DESK_ATLAS_OUT', 'SIZES', 'THEMES', 'SCALES', 'EASYPUB_TEST_DLL')) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
  $env:DESK_ATLAS_OUT = $out
  $env:SIZES = $Sizes -join ','
  $env:THEMES = $Themes -join ','
  $env:SCALES = $Scales -join ','
  $env:EASYPUB_TEST_DLL = (Resolve-Path -LiteralPath $Dll).Path
  Push-Location (Join-Path $root 'flutter')
  try {
    & flutter test --no-pub test/atlas/desk_atlas_test.dart *> (Join-Path $out 'flutter.log')
    if ($LASTEXITCODE -ne 0) { throw "图集生成失败，见 $out\flutter.log" }
  } finally { Pop-Location }
  $count = (Get-ChildItem -LiteralPath $out -Filter '*.png').Count
  Write-Output "图集：$out\index.html（$count 张）"
} finally {
  foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
