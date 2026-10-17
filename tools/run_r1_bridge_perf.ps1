$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $root 'artifacts\r1-bridge-perf'
$report = Join-Path $fixtureRoot 'report.json'
$exe = Join-Path $root 'flutter\build\windows\x64\runner\Release\easypub_desktop.exe'
$previous = $env:EASYPUB_PERF_ROOT
$process = $null
try {
    $env:EASYPUB_PERF_ROOT = $fixtureRoot
    Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
    if (!$process.WaitForExit(180000)) { throw 'Bridge performance probe timed out' }
    if (!(Test-Path -LiteralPath $report)) { throw 'Probe exited without a report' }
    $result = Get-Content -Raw -Encoding UTF8 $report | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or !$result.passed) { throw "Probe failed: $(Get-Content -Raw $report)" }
    Copy-Item -LiteralPath $report -Destination (Join-Path $root 'docs\evidence\r1-dart-bridge-perf.json')
    Get-Content -Raw -Encoding UTF8 $report
} finally {
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force }
    $env:EASYPUB_PERF_ROOT = $previous
}
