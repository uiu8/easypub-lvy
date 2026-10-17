param(
  [Parameter(Mandatory)][ValidateSet('Bridge', 'Frames')][string]$Mode,
  [Parameter(Mandatory)][string]$ExecutablePath,
  [string]$DllPath = '',
  [string]$RunDirectory = '',
  [int[]]$Sizes = @(20, 100),
  [int[]]$ChapterCounts = @(1834, 10000),
  [int]$Runs = 1,
  [ValidateSet('chapters', 'issues')][string[]]$Targets = @('chapters', 'issues'),
  [string]$BaselineDirectory = 'artifacts/frontend-rewrite/perf-20261009-121349'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $RunDirectory) { $RunDirectory = 'artifacts/chapter-workspace-perf-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Mode.ToLowerInvariant() }
$runRoot = [IO.Path]::GetFullPath((Join-Path $root $RunDirectory))
$artifactsRoot = [IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + '\'
if (-not $runRoot.StartsWith($artifactsRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'RunDirectory must be inside project artifacts.' }
if (Test-Path -LiteralPath $runRoot) { throw 'Use a new run directory to preserve evidence.' }
if ($Runs -lt 1 -or $Runs -gt 3) { throw 'Runs must be between 1 and 3.' }
$executable = (Resolve-Path -LiteralPath $ExecutablePath).Path
if (-not $DllPath) { $DllPath = Join-Path (Split-Path -Parent $executable) 'easypub_bridge.dll' }
$bridge = (Resolve-Path -LiteralPath $DllPath).Path
New-Item -ItemType Directory -Path $runRoot | Out-Null
$cases = @()
if ($Mode -eq 'Bridge') {
  foreach ($size in $Sizes) {
    if ($size -notin @(20, 100)) { throw 'Bridge inputs are fixed at 20 and 100 MiB.' }
    $cases += @{name="sample-$size"; source=(Join-Path $root "artifacts/r1-bridge-perf/sample-$size.txt"); target='bridge'}
  }
} else {
  foreach ($count in $ChapterCounts) {
    if ($count -notin @(1834, 10000)) { throw 'Frame inputs are fixed at 1834 and 10000 chapters.' }
    if ('chapters' -in $Targets) { $cases += @{name="chapters-$count"; source=(Join-Path $root "artifacts/completion-final-tree-frames/chapters-$count.txt"); target='chapters'} }
    if ('issues' -in $Targets) { $cases += @{name="issues-$count"; source=(Join-Path $root "artifacts/completion-issue-frames/issues-$count.txt"); target='issues'} }
  }
}
$records = @()
$owned = $null
try {
  foreach ($case in $cases) {
    $inputHash = (Get-FileHash -LiteralPath $case.source -Algorithm SHA256).Hash
    for ($attempt = 1; $attempt -le $Runs; $attempt++) {
      $caseRoot = Join-Path $runRoot ($case.name + '-' + $attempt)
      New-Item -ItemType Directory -Path $caseRoot | Out-Null
      $reportPath = Join-Path $caseRoot 'report.json'
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = $executable
      $start.WorkingDirectory = Split-Path -Parent $executable
      $start.UseShellExecute = $false
      $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
      $start.Environment['LOCALAPPDATA'] = Join-Path $caseRoot 'user-data'
      $start.Environment['EASYPUB_WINDOW_STATE'] = 'ignore'
      $start.Environment['EASYPUB_TEST_DLL'] = $bridge
      foreach ($key in @('EASYPUB_COMPLETION_PERF_REPORT', 'EASYPUB_REWRITE_PERF_SOURCE', 'EASYPUB_REWRITE_PERF_REPORT', 'EASYPUB_FRAME_SOURCE', 'EASYPUB_FRAME_TARGET', 'EASYPUB_FRAME_REPORT')) { $start.Environment.Remove($key) | Out-Null }
      if ($Mode -eq 'Bridge') {
        $start.Environment['EASYPUB_REWRITE_PERF_SOURCE'] = $case.source
        $start.Environment['EASYPUB_REWRITE_PERF_REPORT'] = $reportPath
      } else {
        $start.Environment['EASYPUB_FRAME_SOURCE'] = $case.source
        $start.Environment['EASYPUB_FRAME_TARGET'] = $case.target
        $start.Environment['EASYPUB_FRAME_REPORT'] = $reportPath
      }
      $owned = [Diagnostics.Process]::Start($start)
      @{pid=$owned.Id; executable=$executable; started=$owned.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $caseRoot 'process.json') -Encoding utf8
      $watch = [Diagnostics.Stopwatch]::StartNew()
      while (-not $owned.WaitForExit(1000)) {
        if ($watch.Elapsed.TotalMinutes -gt 5) { throw "Probe timed out: $($case.name)" }
      }
      if (-not (Test-Path -LiteralPath $reportPath)) { throw "Probe produced no report: $($case.name), exit=$($owned.ExitCode)" }
      $report = Get-Content -LiteralPath $reportPath -Raw -Encoding utf8 | ConvertFrom-Json
      $completed = if ($Mode -eq 'Bridge') { $report.probe_completed } else { $report.sample_completed }
      if ($owned.ExitCode -ne 0 -or -not $completed) { throw "Probe failed: $($case.name): $($report.error)" }
      if ((Get-FileHash -LiteralPath $case.source -Algorithm SHA256).Hash -ne $inputHash) { throw 'Source hash changed.' }
      $records += @{name=$case.name; run=$attempt; source=$case.source; input_sha256=$inputHash; report=$reportPath; elapsed_seconds=$watch.Elapsed.TotalSeconds; exit_code=$owned.ExitCode}
      Write-Output "Completed $($case.name) run $attempt : $reportPath"
    }
  }
} finally {
  if ($owned -and -not $owned.HasExited) { $owned.Kill(); $owned.WaitForExit() }
  $metadata = @{
    recorded_at=(Get-Date).ToString('o'); mode=$Mode; cases=$records; runs=$Runs
    cpu=(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    os=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, TotalVisibleMemorySize)
    executable=$executable; exe_sha256=(Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
    dll=$bridge; dll_sha256=(Get-FileHash -LiteralPath $bridge -Algorithm SHA256).Hash
    aot_sha256=(Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $executable) 'data/app.so') -Algorithm SHA256).Hash
    baseline_directory=$BaselineDirectory
    baseline_note= $(if ($Mode -eq 'Bridge') { 'Existing same-day baseline; compare identical input hashes and machine metadata. This script does not rerun the previous implementation.' } else { '2026-10-07 frame reports are historical reference only: old paginated UI and scroll pattern differ, so do not calculate an improvement percentage.' })
    scope='No builds; each case is a separate native process with isolated user data. Bridge timings include Dart request/response and Rust work; frame metrics are actual Profile FrameTiming, not widget-test elapsed time.'
  }
  $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runRoot 'environment.json') -Encoding utf8
}
Write-Output "Evidence: $runRoot"
