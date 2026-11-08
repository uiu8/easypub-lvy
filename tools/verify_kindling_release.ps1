param(
  [string]$EnginePath = '',
  [string]$DllPath = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project_env.ps1')
if (-not $DllPath) { $DllPath = Join-Path $root 'target/release/easypub_bridge.dll' }
$dll = (Resolve-Path -LiteralPath $DllPath).Path
$proofRoot = Join-Path $root ('artifacts/kindling-release-check-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $proofRoot | Out-Null
$names = @('EASYPUB_TEST_DLL','EASYPUB_TEST_KINDLING','LOCALAPPDATA','EASYPUB_KINDLE_METADATA_EVIDENCE')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
Push-Location $root
try {
  if (-not $EnginePath) {
    & cargo build --locked --release --manifest-path (Join-Path $root 'third_party/kindling/Cargo.toml') --bin kindling-cli *> (Join-Path $proofRoot 'build.log')
    if ($LASTEXITCODE -ne 0) { throw "Kindling构建失败：$proofRoot/build.log" }
    $EnginePath = Join-Path $root 'third_party/kindling/target/release/kindling-cli.exe'
  }
  $engine = (Resolve-Path -LiteralPath $EnginePath).Path
  $beforeHash = (Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash.ToLowerInvariant()
  $env:EASYPUB_TEST_DLL = $dll
  $env:EASYPUB_TEST_KINDLING = $engine
  $env:LOCALAPPDATA = Join-Path $proofRoot 'user-data'
  $env:EASYPUB_KINDLE_METADATA_EVIDENCE = Join-Path $proofRoot 'outputs.json'
  Set-Location (Join-Path $root 'flutter')
  & flutter test test/completion/kindle_metadata_test.dart --reporter expanded *> (Join-Path $proofRoot 'test.log')
  if ($LASTEXITCODE -ne 0) { throw "Kindling书目保真验证失败，禁止打包：$proofRoot/test.log" }
  $afterHash = (Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($beforeHash -ne $afterHash) { throw '验证期间转换器发生改变，禁止打包。' }
  $sourceRoot = Join-Path $root 'third_party/kindling'
  $sourceFiles = @((Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'src') -Recurse -File))
  $sourceFiles += Get-Item -LiteralPath (Join-Path $sourceRoot 'Cargo.toml'),(Join-Path $sourceRoot 'Cargo.lock')
  $proof = [ordered]@{
    engine = $engine
    sha256 = $afterHash
    dll_sha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant()
    test_sha256 = (Get-FileHash -LiteralPath (Join-Path $root 'flutter/test/completion/kindle_metadata_test.dart') -Algorithm SHA256).Hash.ToLowerInvariant()
    formats = @('MOBI','AZW3')
    sections_checked = @('MOBI7','KF8')
    checked_fields = @('title','author','publisher','description','isbn','translator','category','publication_date','language')
    passed = $true
    reader_acceptance = $false
    sources = @($sourceFiles | Sort-Object FullName | ForEach-Object { [ordered]@{path=$_.FullName.Substring($sourceRoot.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} })
    evidence_directory = $proofRoot
  }
  [IO.File]::WriteAllText((Join-Path $proofRoot 'verification.json'),($proof | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  [pscustomobject]$proof
} finally {
  Pop-Location
  foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
}
