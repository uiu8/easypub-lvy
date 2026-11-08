param(
  [Parameter(Mandatory = $true)][string]$PackageZip,
  [Parameter(Mandatory = $true)][string]$PackageEvidence,
  [string]$Compiler = 'D:/software/InnoSetup-6.7.3/ISCC.exe',
  [string]$OutputRoot = 'artifacts/release',
  [string]$EvidencePath = '',
  [switch]$SmokeTest
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$zip = (Resolve-Path -LiteralPath $PackageZip).Path
$proof = Get-Content -LiteralPath $PackageEvidence -Raw -Encoding UTF8 | ConvertFrom-Json
$zipHash = (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant()
if (-not $proof.passed -or $proof.zip_sha256 -ne $zipHash) {
  throw '便携包尚未验收，或与打包证据不一致。'
}
$work = Join-Path $root ('artifacts/installer-build-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
Expand-Archive -LiteralPath $zip -DestinationPath $work
$package = Join-Path $work $proof.package_name
$version = Get-Content -LiteralPath (Join-Path $package 'version.json') -Raw | ConvertFrom-Json
if ($version.release -ne $proof.release) { throw '版本号与验包记录不一致。' }
$output = [IO.Path]::GetFullPath((Join-Path $root $OutputRoot))
$name = $proof.package_name + '-setup'
if ($SmokeTest) { $name += '-smoke' }
$installer = Join-Path $output ($name + '.exe')
if (Test-Path -LiteralPath $installer) { throw "安装包已经存在，不覆盖：$installer" }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$arguments = @('/Q', "/O$output", "/DPackageDir=$package", "/DRelease=$($version.release)", "/DOutputName=$name")
if ($SmokeTest) { $arguments += '/DSmokeTest' }
& $Compiler @arguments (Join-Path $PSScriptRoot 'installer/easypub.iss') *> (Join-Path $work 'compile.log')
if ($LASTEXITCODE -ne 0) { throw "安装包编译失败：$work/compile.log" }
$record = [ordered]@{
  release = $version.release
  source_commit = $version.commit
  source_zip_sha256 = $zipHash
  installer = $installer
  bytes = (Get-Item -LiteralPath $installer).Length
  sha256 = (Get-FileHash -LiteralPath $installer).Hash.ToLowerInvariant()
  compiler = (Get-Item -LiteralPath $Compiler).VersionInfo.FileVersion
  compiler_sha256 = (Get-FileHash -LiteralPath $Compiler).Hash.ToLowerInvariant()
  script_sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'installer/easypub.iss')).Hash.ToLowerInvariant()
  smoke_test_identity = [bool]$SmokeTest
  built = $true
  authenticode_status = [string](Get-AuthenticodeSignature -LiteralPath $installer).Status
  build_log = (Join-Path $work 'compile.log')
}
if ($EvidencePath) {
  $record | ConvertTo-Json | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}
$record | ConvertTo-Json
