# 桥接第 2 批测速：大书热点调用拆成跨桥耗时、返回大小、Dart 解码耗时。
# 先构建：flutter build windows --release --target lib/bridge_breakdown_perf_main.dart
# 测试书：python tools/generate_r1_bridge_perf.py（20 / 100 MiB，各一万章）。
# -Builds 可给多个“名字=Release 目录;DLL”组合，按轮交替运行，保证同一时段可比。
param(
  [Parameter(Mandatory)][string[]]$Builds,
  [int[]]$Sizes = @(20, 100),
  [ValidateRange(1, 5)][int]$Runs = 3,
  [string]$Name = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Name) { $Name = Get-Date -Format 'yyyyMMdd-HHmmss' }
$out = Join-Path $root "artifacts\bridge-breakdown-$Name"
if (Test-Path -LiteralPath $out) { throw '输出目录已存在，换一个 -Name。' }
New-Item -ItemType Directory -Path $out | Out-Null
$parsed = foreach ($b in $Builds) {
  $label, $rest = $b -split '=', 2
  $dir, $dll = $rest -split ';', 2
  [pscustomobject]@{ label = $label; exe = (Resolve-Path -LiteralPath (Join-Path $dir 'easypub_desktop.exe')).Path; dll = (Resolve-Path -LiteralPath $dll).Path }
}
foreach ($size in $Sizes) {
  $source = Join-Path $root "artifacts\r1-bridge-perf\sample-$size.txt"
  for ($run = 1; $run -le $Runs; $run++) {
    foreach ($build in $parsed) {
      $case = Join-Path $out "$($build.label)-$size-run$run"
      New-Item -ItemType Directory -Path $case | Out-Null
      $report = Join-Path $case 'report.json'
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = $build.exe
      $start.WorkingDirectory = Split-Path -Parent $build.exe
      $start.UseShellExecute = $false
      $start.Environment['LOCALAPPDATA'] = Join-Path $case 'user-data'
      $start.Environment['EASYPUB_WINDOW_STATE'] = 'ignore'
      $start.Environment['EASYPUB_TEST_DLL'] = $build.dll
      $start.Environment['EASYPUB_BRIDGE_PERF_SOURCE'] = $source
      $start.Environment['EASYPUB_BRIDGE_PERF_REPORT'] = $report
      $p = [Diagnostics.Process]::Start($start)
      if (-not $p.WaitForExit(600000)) { $p.Kill(); throw "超时：$case" }
      if (-not (Test-Path -LiteralPath $report)) { throw "没有报告：$case" }
      $r = Get-Content -LiteralPath $report -Raw -Encoding utf8 | ConvertFrom-Json
      if (-not $r.probe_completed) { throw "失败：$case $($r.error)" }
      Write-Output "完成 $($build.label) $size MiB 第 $run 次"
    }
  }
}
# 汇总：每个构建、每个大小、每项操作取各次 p50 的中位数。
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# 桥接调用拆分测速（$Name）")
$lines.Add('')
$lines.Add("每项 20 次取 p50，再取 $Runs 次运行的中位数；构建按轮交替运行。单位：毫秒、字节。")
foreach ($size in $Sizes) {
  $lines.Add('')
  $lines.Add("## $size MiB")
  $lines.Add('')
  $header = '| 操作 |'; $sep = '|---|'
  foreach ($build in $parsed) { $header += " $($build.label) 跨桥 | $($build.label) 解码 | $($build.label) 字节 |"; $sep += '---:|---:|---:|' }
  $lines.Add($header); $lines.Add($sep)
  $reports = @{}
  foreach ($build in $parsed) {
    $reports[$build.label] = @(1..$Runs | ForEach-Object { Get-Content -LiteralPath (Join-Path $out "$($build.label)-$size-run$_\report.json") -Raw -Encoding utf8 | ConvertFrom-Json })
  }
  $ops = @($parsed | ForEach-Object { $reports[$_.label][0].operations.PSObject.Properties.Name } | Select-Object -Unique)
  foreach ($op in $ops) {
    $row = "| $op |"
    foreach ($build in $parsed) {
      $vals = $reports[$build.label] | ForEach-Object { $_.operations.$op }
      if (-not $vals -or $null -eq $vals[0] -or $null -ne $vals[0].error) { $row += ' - | - | - |'; continue }
      $mid = { param($xs) $s = @($xs | Sort-Object); $s[[int][math]::Floor(($s.Count - 1) / 2)] }
      $row += " {0:N2} | {1:N2} | {2} |" -f (& $mid ($vals | ForEach-Object call_p50_ms)), (& $mid ($vals | ForEach-Object decode_p50_ms)), (($vals | ForEach-Object max_response_bytes | Measure-Object -Maximum).Maximum)
    }
    $lines.Add($row)
  }
}
$lines | Set-Content -LiteralPath (Join-Path $out 'summary.md') -Encoding utf8
Write-Output "结果：$out"
