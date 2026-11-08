param([string]$SourceDirectory = 'D:/software/EasyPub-Engines/bokai-0.2.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project_env.ps1')
$sourceArchive = Join-Path $root 'third_party/bokai/bokai-0.2.0.crate'
$provenance = Get-Content -LiteralPath (Join-Path $root 'third_party/bokai/UPSTREAM.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $provenance.source_sha256) { throw 'Bokai源归档哈希不符。' }
if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory 'Cargo.toml'))) {
  $parent = Split-Path -Parent $SourceDirectory
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  & python -c 'import sys,tarfile; tarfile.open(sys.argv[1]).extractall(sys.argv[2],filter="data")' $sourceArchive $parent
  if ($LASTEXITCODE -ne 0) { throw 'Bokai源码展开失败。' }
}
& python (Join-Path $root 'third_party/bokai/apply_patches.py') $SourceDirectory
if ($LASTEXITCODE -ne 0) { throw 'Bokai兼容补丁应用失败。' }
& cargo build --locked --release --no-default-features --features bin,svg,validate --bin bokai --manifest-path (Join-Path $SourceDirectory 'Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'Bokai编译失败。' }
$destination = Join-Path $root 'artifacts/engines'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceDirectory 'target/release/bokai.exe') -Destination (Join-Path $destination 'bokai.exe')
& (Join-Path $destination 'bokai.exe') --version
