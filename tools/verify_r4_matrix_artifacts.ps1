param(
  [string]$EvidencePath = 'docs/evidence/r4-matrix-artifact-audit.json'
)

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rows = @()
$failures = @()
foreach ($scenario in 1..9) {
  foreach ($mode in 1..4) {
    $specific = Join-Path $root "docs/evidence/r4-matrix-s${scenario}-m${mode}-widget.json"
    $fallback = Join-Path $root "docs/evidence/r4-matrix-s${scenario}-widget.json"
    $file = if (Test-Path -LiteralPath $specific) { $specific } elseif (Test-Path -LiteralPath $fallback) { $fallback } else { $null }
    $cell = "S${scenario}/M${mode}"
    if ($null -eq $file) {
      $failures += "${cell}: evidence file missing"
      $rows += [pscustomobject]@{ cell = $cell; evidence = $null; paths_exist = $false; external_gates = $false }
      continue
    }
    try { $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch {
      $failures += "${cell}: invalid JSON"
      $rows += [pscustomobject]@{ cell = $cell; evidence = $file.Substring($root.Length + 1); paths_exist = $false; external_gates = $false }
      continue
    }
    $paths = @()
    foreach ($property in @('source', 'project', 'output')) {
      if ($json.PSObject.Properties.Name -contains $property -and $json.$property) { $paths += [string]$json.$property }
    }
    if ($json.PSObject.Properties.Name -contains 'products' -and $json.products) {
      foreach ($property in @('EPUB', 'AZW3')) {
        if ($json.products.PSObject.Properties.Name -contains $property -and $json.products.$property) { $paths += [string]$json.products.$property }
      }
    }
    $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) { $failures += "${cell}: missing artifact path(s): $($missing -join ', ')" }
    $rows += [pscustomobject]@{
      cell = $cell
      evidence = $file.Substring($root.Length + 1)
      paths_checked = $paths.Count
      paths_exist = ($missing.Count -eq 0)
      source_project_and_products_present = ($missing.Count -eq 0)
      external_gates = $false
      external_gates_note = '原生桌面逐格操作、Kindle Previewer/真机视觉仍需单独验收'
    }
  }
}
$result = [ordered]@{
  generated_at = (Get-Date).ToUniversalTime().ToString('o')
  matrix_cells = 36
  cells_with_evidence = @($rows | Where-Object { $_.evidence }).Count
  cells_with_all_referenced_paths = @($rows | Where-Object { $_.paths_exist }).Count
  passed_machine_artifact_audit = ($failures.Count -eq 0)
  rows = $rows
  failures = $failures
  not_verified = @('原生 Windows 桌面逐格操作', 'Kindle Previewer 视觉', '真实 Kindle 设备')
}
$target = Join-Path $root $EvidencePath
New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $target -Encoding UTF8
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Output ($result | ConvertTo-Json -Depth 3)
