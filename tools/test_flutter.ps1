param(
    [string[]]$TestPaths = @('test'),
    [string]$PythonPath = 'D:/software/Malzahar精简版_20260829/runtime/python.exe',
    [string]$KindlingPath,
    [string]$BokaiPath,
    # 8 measured fastest on the 32-thread dev machine (11m26s -> 3m31s); 12 was
    # no faster because the longest single file bounds the run. Pass 1 to rerun
    # files one at a time when chasing a suspected cross-file interaction.
    [int]$Concurrency = 8
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$names = @('LOCALAPPDATA','EASYPUB_TEST_DLL','EASYPUB_TEST_PYTHON',
    'EASYPUB_TEST_KINDLING','EASYPUB_TEST_BOKAI','EASYPUB_MATRIX_ROOT')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$run = Join-Path $root ('artifacts/completion-regression-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $run | Out-Null
Push-Location $root
try {
    . (Join-Path $PSScriptRoot 'project_env.ps1')
    if (-not $KindlingPath) { $KindlingPath = Join-Path $root 'third_party/kindling/target/release/kindling-cli.exe' }
    if (-not $BokaiPath) { $BokaiPath = Join-Path $root 'artifacts/engines/bokai.exe' }
    foreach ($path in @($PythonPath, $KindlingPath, $BokaiPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing test dependency: $path" }
    }
    & cargo build --locked -p easypub_bridge --release *> (Join-Path $run 'build.log')
    if ($LASTEXITCODE -ne 0) { throw "Native bridge build failed. See $run/build.log" }
    # A test run owns its exact DLL so subsequent builds cannot change its
    # native version or contend with a Windows loader file lock.
    $testNative = Join-Path $run 'native'
    New-Item -ItemType Directory -Path $testNative | Out-Null
    $env:EASYPUB_TEST_DLL = Join-Path $testNative 'easypub_bridge.dll'
    Copy-Item -LiteralPath (Join-Path $root 'target/release/easypub_bridge.dll') -Destination $env:EASYPUB_TEST_DLL
    $env:EASYPUB_TEST_PYTHON = (Resolve-Path -LiteralPath $PythonPath).Path
    $env:EASYPUB_TEST_KINDLING = (Resolve-Path -LiteralPath $KindlingPath).Path
    $env:EASYPUB_TEST_BOKAI = (Resolve-Path -LiteralPath $BokaiPath).Path
    $env:LOCALAPPDATA = Join-Path $run 'localappdata'
    $env:EASYPUB_MATRIX_ROOT = Join-Path $run 'matrix'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA,$env:EASYPUB_MATRIX_ROOT | Out-Null
    $environment = @{}
    foreach ($name in $names) { $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $environment | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'environment.json') -Encoding utf8
    Set-Location (Join-Path $root 'flutter')
    & flutter test --no-pub --reporter expanded --concurrency $Concurrency @TestPaths *> (Join-Path $run 'flutter.log')
    $testExitCode = $LASTEXITCODE
    Write-Output "Test exit code: $testExitCode; logs: $run"
    Get-Content -LiteralPath (Join-Path $run 'flutter.log') -Tail 14
    if ($testExitCode -ne 0) { throw "Flutter regression failed. See $run/flutter.log" }
}
finally {
    Pop-Location
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
