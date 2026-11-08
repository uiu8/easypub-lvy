param([int[]]$Sizes = @(20, 100))
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $root "artifacts\frontend-rewrite\perf-$stamp"
$release = Join-Path $root 'flutter\build\windows\x64\runner\Release'
$dll = Join-Path $root 'target\release\easypub_bridge.dll'
New-Item -ItemType Directory -Path $output | Out-Null
$saved = @{}
foreach ($name in @('EASYPUB_REWRITE_PERF_SOURCE','EASYPUB_REWRITE_PERF_REPORT','EASYPUB_TEST_DLL')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$process = $null
try {
    $env:EASYPUB_TEST_DLL = $dll
    $cases = @()
    foreach ($size in $Sizes) {
        if ($size -notin @(20, 100)) { throw 'Only fixed 20/100 MiB fixtures are allowed' }
        $source = Join-Path $root "artifacts\r1-bridge-perf\sample-$size.txt"
        $report = Join-Path $output "sample-$size.json"
        $beforeHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $env:EASYPUB_REWRITE_PERF_SOURCE = $source
        $env:EASYPUB_REWRITE_PERF_REPORT = $report
        $process = Start-Process -FilePath (Join-Path $release 'easypub_desktop.exe') -WorkingDirectory $release -WindowStyle Hidden -PassThru
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (!$process.WaitForExit(1000)) {
            if ($watch.Elapsed.TotalMinutes -gt 5) { throw "Probe $size MiB timed out" }
        }
        if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $report)) { throw "Probe $size MiB failed: $($process.ExitCode)" }
        $result = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
        if (!$result.probe_completed) { throw "Probe failed: $($result.error)" }
        $afterHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        if ($beforeHash -ne $afterHash) { throw 'Source hash changed' }
        $cases += @{ report = $report; input_sha256 = $beforeHash; size_mib = $size; process_exit_code = $process.ExitCode }
        Write-Output "Completed $size MiB probe: $report"
    }
    $metadata = @{
        recorded_at = (Get-Date).ToString('o'); cases = $cases
        cpu = (Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
        os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, TotalVisibleMemorySize)
        dll_sha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
        exe_sha256 = (Get-FileHash -LiteralPath (Join-Path $release 'easypub_desktop.exe') -Algorithm SHA256).Hash
        aot_sha256 = (Get-FileHash -LiteralPath (Join-Path $release 'data\app.so') -Algorithm SHA256).Hash
        scope = 'One independent Release process per input. Query timing pilot; no frame or full performance acceptance.'
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding UTF8
    Write-Output "Evidence: $output"
} finally {
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
