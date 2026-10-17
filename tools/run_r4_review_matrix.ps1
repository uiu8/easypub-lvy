param(
  [ValidateSet('S2', 'S7', 'S9')]
  [string[]]$Scenarios = @('S2', 'S7', 'S9'),
  [ValidateSet('M1', 'M2', 'M3', 'M4')]
  [string[]]$Modes = @('M1', 'M2', 'M3', 'M4')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project_env.ps1')
Push-Location (Join-Path $root 'flutter')
try {
  foreach ($scenario in $Scenarios) {
    $test = if ($scenario -eq 'S2') {
      'tool/verify_s2_duplicates_ui_test.dart'
    } else {
      'tool/verify_heading_repairs_ui_test.dart'
    }
    foreach ($mode in $Modes) {
      # String.fromEnvironment reads Dart compile-time definitions, not shell env.
      $evidence = Join-Path $root ('docs/evidence/r4-matrix-{0}-{1}-widget.json' -f $scenario.ToLowerInvariant(), $mode.ToLowerInvariant())
      $before = if (Test-Path -LiteralPath $evidence) {
        (Get-FileHash -LiteralPath $evidence -Algorithm SHA256).Hash
      } else { '' }
      & flutter test "--dart-define=MATRIX_SCENARIO=$scenario" "--dart-define=MATRIX_MODE=$mode" $test
      if ($LASTEXITCODE -ne 0) { throw "Matrix test failed: $scenario/$mode" }
      $report = Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
      $after = (Get-FileHash -LiteralPath $evidence -Algorithm SHA256).Hash
      if ($after -eq $before -or $report.scenario -ne $scenario -or $report.mode -ne $mode -or $report.passed_partial -ne $true) {
        throw "Missing fresh matching evidence: $scenario/$mode"
      }
      Write-Host "Verified fresh partial evidence: $scenario/$mode"
    }
  }
} finally {
  Pop-Location
}
