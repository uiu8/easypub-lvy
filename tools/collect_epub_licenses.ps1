$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools/project_env.ps1')
Push-Location $root
try {
  $metadata = cargo metadata --locked --format-version 1 | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'Cannot read locked dependency metadata' }
  $names = @('zip','time','time-core','deranged','num-conv','powerfmt','arbitrary','derive_arbitrary')
  $packages = @($metadata.packages | Where-Object { $_.name -in $names })
  if ($packages.Count -ne $names.Count) { throw 'EPUB dependency license inventory changed' }
  $destination = Join-Path $root 'third_party/epub_export'
  $rows = @($packages | ForEach-Object {
    $package = $_
    $directory = Split-Path -Parent $package.manifest_path
    $target = Join-Path $destination ($package.name + '-' + $package.version)
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $licenses = @(Get-ChildItem -LiteralPath $directory -File | Where-Object Name -Match '^(LICENSE|COPYING)')
    if ($licenses.Count -eq 0) { throw "No license text for $($package.name)" }
    $files = @($licenses | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.Name)
      [ordered]@{file=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    [ordered]@{name=$package.name;version=$package.version;license=$package.license;source=$package.source;files=$files}
  })
  $report = [ordered]@{scope='EPUB export lockfile additions, including optional packages; not a full application dependency inventory';packages=$rows}
  [IO.File]::WriteAllText((Join-Path $destination 'provenance.json'), ($report | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
  Write-Output "Collected license text for $($rows.Count) locked packages"
} finally { Pop-Location }
