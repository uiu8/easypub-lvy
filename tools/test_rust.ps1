param(
    [string[]]$Packages = @('easypub_core', 'easypub_app'),
    [int]$Runs = 1
)
# Runs the Rust test suites and keeps the complete output, so an intermittent
# failure always leaves the failing test names and panic messages on disk.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$run = Join-Path $root ('artifacts/rust-tests-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $run | Out-Null
Push-Location $root
try {
    . (Join-Path $PSScriptRoot 'project_env.ps1')
    $arguments = @('test', '--locked') + ($Packages | ForEach-Object { @('-p', $_) })
    $failed = 0
    for ($i = 1; $i -le $Runs; $i++) {
        $log = Join-Path $run "run-$i.log"
        & cargo @arguments *> $log
        $code = $LASTEXITCODE
        $summary = (Select-String -LiteralPath $log -Pattern '^test result').Line -join ' | '
        Write-Output "run $i (exit $code): $summary"
        if ($code -ne 0) {
            $failed++
            Select-String -LiteralPath $log -Pattern '^test .* FAILED$|^---- |panicked at' |
                ForEach-Object { Write-Output ('   ' + $_.Line) }
        }
    }
    Write-Output "Logs: $run"
    if ($failed -gt 0) { throw "Rust tests failed in $failed of $Runs runs. See $run" }
}
finally {
    Pop-Location
}
