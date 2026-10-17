param(
  [string]$PackageName = 'EasyPub-R4-repair-preview-20260926-1420-win-x64',
  [string]$OutputRoot = 'artifacts/release',
  [string]$EvidencePath = 'docs/evidence/r4-package.json',
  [string]$KindlingPath = '',
  [string]$BokaiPath = '',
  [string]$BokaiEvidencePath = 'docs/evidence/kfx-engine-20261008.json',
  [string]$CompletionEvidence = '',
  [string]$ReleaseDescription = '',
  [string]$InstructionsPath = '',
  [switch]$FrontendRewriteReview
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'flutter/build/windows/x64/runner/Release'
$releaseRoot = Join-Path $root $OutputRoot
$staging = Join-Path $releaseRoot $PackageName
$zip = Join-Path $releaseRoot ($PackageName + '.zip')
$evidence = Join-Path $root $EvidencePath
$completionAccepted = $false
if ($CompletionEvidence) {
  $completionPath = (Resolve-Path -LiteralPath (Join-Path $root $CompletionEvidence)).Path
  $completionRecord = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $completionRecord.completed -or $completionRecord.requirement_count -ne 41 -or $completionRecord.scene_count -ne 59 -or $completionRecord.pending_requirements -ne 0 -or $completionRecord.pending_scenes -ne 0) {
    throw '补全验收记录未关闭41项需求和59场景，不能生成完成标记。'
  }
  $completionAccepted = $true
}
if (-not (Test-Path -LiteralPath (Join-Path $source 'easypub_desktop.exe'))) {
  throw "普通 Release 不存在，请先构建：$source"
}
if ((Test-Path -LiteralPath $staging) -or (Test-Path -LiteralPath $zip)) {
  throw "目标已存在，为避免覆盖请换 PackageName：$PackageName"
}
# Verify the exact engine before creating a package. With no override, build the
# current patched Kindling source; never silently omit it or reuse an old bundle.
$engineVerification = & (Join-Path $PSScriptRoot 'verify_kindling_release.ps1') -EnginePath $KindlingPath -DllPath (Join-Path $source 'easypub_bridge.dll')
if (-not $engineVerification.passed) { throw '转换器未通过真实书目验证，禁止打包。' }
$KindlingPath = $engineVerification.engine
if (-not $BokaiPath) { $BokaiPath = Join-Path $root 'artifacts/engines/bokai.exe' }
$bokai = (Resolve-Path -LiteralPath $BokaiPath).Path
$bokaiProofPath = Join-Path $root $BokaiEvidencePath
$bokaiProof = Get-Content -LiteralPath $bokaiProofPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bokaiHash = (Get-FileHash -LiteralPath $bokai -Algorithm SHA256).Hash.ToLowerInvariant()
$dllHash = (Get-FileHash -LiteralPath (Join-Path $source 'easypub_bridge.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $bokaiProof.independent_calibre_passed -or -not $bokaiProof.passed -or $bokaiProof.engine_sha256 -ne $bokaiHash -or $bokaiProof.dll_sha256 -ne $dllHash) { throw 'Bokai/后端与实际KFX验证版本不一致。' }
$bokaiVersion = & $bokai --version
if ($LASTEXITCODE -ne 0 -or $bokaiVersion -notmatch '^bokai 0\.2\.0') { throw 'Bokai版本不符合固定引擎。' }
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
Copy-Item -LiteralPath $source -Destination $staging -Recurse
# Kindling is a separate source/build workspace; never copy its target directory
# (or its source tree) wholesale into a portable application.
$thirdPartyDestination = Join-Path $staging 'third_party'
New-Item -ItemType Directory -Path $thirdPartyDestination -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $root 'third_party') | Where-Object Name -ne 'kindling' | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $thirdPartyDestination -Recurse
}
if ($KindlingPath) {
  $engineSource = (Resolve-Path -LiteralPath $KindlingPath).Path
  $engineDestination = Join-Path $staging 'converters'
  New-Item -ItemType Directory -Path $engineDestination | Out-Null
  Copy-Item -LiteralPath $engineSource -Destination (Join-Path $engineDestination 'kindling.exe')
  $copiedHash = (Get-FileHash -LiteralPath (Join-Path $engineDestination 'kindling.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($copiedHash -ne $engineVerification.sha256) { throw '复制的转换器与验证版本不一致，禁止打包。' }
  Copy-Item -LiteralPath (Join-Path $engineVerification.evidence_directory 'verification.json') -Destination (Join-Path $engineDestination 'verification.json')
  $engineNotices = Join-Path $thirdPartyDestination 'kindling'
  New-Item -ItemType Directory -Path $engineNotices | Out-Null
  foreach ($notice in @('LICENSE','UPSTREAM.json','EASYPUB_PATCHES.md')) {
    Copy-Item -LiteralPath (Join-Path $root "third_party/kindling/$notice") -Destination $engineNotices
  }
}

Copy-Item -LiteralPath $bokai -Destination (Join-Path $staging 'converters/bokai.exe')
Copy-Item -LiteralPath $bokaiProofPath -Destination (Join-Path $staging 'converters/bokai-verification.json')
# 真机预览组件（V30，LAY-108）：独立的网页组件，由排版页用系统 Edge 打开。
$pluginSource = Join-Path $root 'plugins/kindle-preview'
if (-not (Test-Path -LiteralPath (Join-Path $pluginSource 'plugin.json'))) { throw '缺少真机预览组件 plugins/kindle-preview' }
New-Item -ItemType Directory -Force -Path (Join-Path $staging 'plugins') | Out-Null
Copy-Item -LiteralPath $pluginSource -Destination (Join-Path $staging 'plugins') -Recurse

$instructionsSource = if ($InstructionsPath) { $InstructionsPath } elseif ($FrontendRewriteReview) { 'docs/前端重写评审版使用说明.txt' } else { 'docs/便携版使用说明.txt' }
$instructions = Get-Content -LiteralPath (Join-Path $root $instructionsSource) -Raw -Encoding UTF8
$instructionsName = if ($InstructionsPath) { '先读我.txt' } elseif ($FrontendRewriteReview) { '先读我-前端评审版.txt' } else { 'R4-查看说明.txt' }
[IO.File]::WriteAllText((Join-Path $staging $instructionsName), $instructions, [Text.UTF8Encoding]::new($false))
# 应用内显示的版本信息（V22，SET-066）：版本与日期取自包名，记录构建提交；
# 打包时工作区有未提交的改动则在提交号后加“+”，界面如实注明。
$versionMatch = [regex]::Match($PackageName, 'desk-(v\d+[a-z]?)-(\d{8})')
$commit = "$(& git -C $root rev-parse --short HEAD 2>$null)".Trim()
$dirty = "$(& git -C $root status --porcelain --untracked-files=no 2>$null)".Trim()
$versionInfo = [ordered]@{
  schema = 1
  package = $PackageName
  version = if ($versionMatch.Success) { "desk-$($versionMatch.Groups[1].Value)" } else { $PackageName }
  date = if ($versionMatch.Success) { $d = $versionMatch.Groups[2].Value; "$($d.Substring(0,4))-$($d.Substring(4,2))-$($d.Substring(6,2))" } else { Get-Date -Format 'yyyy-MM-dd' }
  commit = $commit
  uncommitted_changes = [bool]$dirty
  notes = $instructionsName
}
[IO.File]::WriteAllText((Join-Path $staging 'version.json'), (($versionInfo | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))

if ($completionAccepted) { Copy-Item -LiteralPath $completionPath -Destination (Join-Path $staging 'completion-acceptance.json') }
$files = @(Get-ChildItem -LiteralPath $staging -Recurse -File)
$manifest = [ordered]@{
  package_name = $PackageName
  created_at = (Get-Date).ToString('o')
  source = 'flutter/build/windows/x64/runner/Release'
  executable = 'easypub_desktop.exe'
  product_stage = 'EasyPub++ final functionality package; EPUB resource import, body image anchors, project origin paths, chapter editing and Kindle conversion; external device and full matrix acceptance remain separate'
  font_subset_and_full_resources = $true
  paragraph_and_page_parameters = $true
  legacy_cleanup_candidate_migration = $true
  persisted_layout_origins = $true
  project_save_as_and_reopen = $true
  synthetic_data = $true
  real_txt_import = $true
  repair_plan_preview = $true
  safe_duplicate_commit_api = $true
  manual_batch_draft_roundtrip = $true
  explicit_line_cleanup = $true
  ordered_cleanup_pipeline = $true
  ocr_scoped_steps_and_presets = $true
  chinese_variant_dictionary = 'ferrous-opencc-0.4.0'
  step_bound_exclusions = $true
  duplicate_title_cleanup_rule = $true
  cleanup_algorithm = 'cleanup-v7'
  combined_txt_output = $true
  confirmed_epub_export = $true
  confirmed_azw3_export = $true
  confirmed_mobi_export = $true
  conversion_preflight_gate = $true
  conversion_preflight_uses_current_source_version = $true
  conversion_preflight_requires_warning_ack = $true
  batch_preflight_persisted = $true
  batch_preflight_requires_rerun_after_restart = $true
  batch_failed_item_resume = $true
  azw3_requires_external_kindling = -not [bool]$KindlingPath
  bundled_kindling = [bool]$KindlingPath
  bundled_bokai = $true
  bokai_version = $bokaiVersion
  confirmed_kfx_export = $true
  azw3_metadata_checked_before_publish = $true
  azw3_translator_contributor_checked = $true
  effective_structure_page_jump = $true
  primary_reader = 'Kindle'
  kindle_device_acceptance = $false
  azw3_stage_cancellation = $true
  epub_reader_acceptance = $false
  catalog_effective_editor_and_output = $true
  effective_subtree_editing = $true
  folder_rule_editor_and_persistence = $true
  extended_bibliographic_fields = $true
  cover_crop_editor_and_resources = $true
  exif_visual_orientation = $true
  paragraph_alignment = $true
  additional_css_editor_and_offline_project = $true
  css_dependency_rewrite_and_relocation = $true
  css_font_hash_permissions = $true
  navigation_settings_and_relations = $true
  versioned_global_layout_defaults = $true
  project_and_global_layout_presets = $true
  project_and_global_cleanup_presets = $true
  selective_restore_layout_defaults = $true
  legacy_xml_json_partial_layout_migration = $true
  deep_volume_insertion = $true
  explicit_cross_parent_role_merge = $true
  exact_duplicate_block_review = $true
  missing_heading_prefix_review = $true
  contextual_number_typo_repair = $true
  writes_user_books = $false
  creates_epub_or_mobi = $true
  creates_mobi = $true
  epub_resource_import = $true
  epub_body_image_anchors = $true
  epub_project_origin_paths = $true
  epub_pending_image_review = $true
  files = @($files | ForEach-Object {
    $relative = $_.FullName.Substring($staging.Length + 1).Replace('\','/')
    [ordered]@{ path = $relative; bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
  })
}
if ($FrontendRewriteReview) {
  $manifest = [ordered]@{
    package_name = $PackageName
    created_at = (Get-Date).ToString('o')
    source = 'flutter/build/windows/x64/runner/Release'
    entrypoint = 'lib/frontend_rewrite_main.dart'
    executable = 'easypub_desktop.exe'
    product_stage = if ($completionAccepted) { 'software completion plan accepted; external device/account/IME/multi-monitor verification excluded' } else { 'Bokai KFX extension; local output verification passed; device acceptance excluded' }
    final_frontend_accepted = $completionAccepted
    primary_reader = 'Kindle'
    kindle_device_acceptance = $false
    bundled_kindling = [bool]$KindlingPath
  bundled_bokai = $true
  bokai_version = $bokaiVersion
  confirmed_kfx_export = $true
    files = $manifest.files
  }
}
if ($ReleaseDescription) { $manifest['product_stage'] = $ReleaseDescription }
$manifest['bokai_verification'] = [ordered]@{sha256=$bokaiHash;dll_sha256=$dllHash;patch_version=$bokaiProof.patch_version;checks_before_publish='bokai validate all';calibre_acceptance=$bokaiProof.independent_calibre_passed;reader_acceptance=$false}
$manifest['kindling_verification'] = [ordered]@{sha256=$engineVerification.sha256;metadata_gate_passed=$true;formats=$engineVerification.formats;reader_acceptance=$false}
$manifestText = $manifest | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $staging 'package-manifest.json'), $manifestText + "`n", [Text.UTF8Encoding]::new($false))
Compress-Archive -LiteralPath $staging -DestinationPath $zip -CompressionLevel Optimal

$verify = Join-Path $releaseRoot ($PackageName + '-unpacked-check')
Expand-Archive -LiteralPath $zip -DestinationPath $verify
$launchRoot = Join-Path $verify $PackageName
$licenseFound = Test-Path -LiteralPath (Join-Path $launchRoot 'third_party/chinese_variant/LICENSE-APACHE-2.0.txt')
$provenanceFound = Test-Path -LiteralPath (Join-Path $launchRoot 'third_party/chinese_variant/provenance.json')
if (-not ($licenseFound -and $provenanceFound)) { throw '解压包缺少词典许可或来源清单' }
$fontProvenance = Test-Path -LiteralPath (Join-Path $launchRoot 'third_party/fontations/provenance.json')
if (-not $fontProvenance) { throw '解压包缺少字体依赖来源' }
$epubProvenance = Test-Path -LiteralPath (Join-Path $launchRoot 'third_party/epub_export/provenance.json')
if (-not $epubProvenance) { throw '解压包缺少 EPUB 依赖许可来源' }
$kindlePreviewPlugin = Test-Path -LiteralPath (Join-Path $launchRoot 'plugins/kindle-preview/plugin.json')
if (-not $kindlePreviewPlugin) { throw '解压包缺少真机预览组件' }
foreach ($entry in $manifest.files) {
  $verifiedPath = Join-Path $launchRoot $entry.path
  if (-not (Test-Path -LiteralPath $verifiedPath -PathType Leaf)) { throw "解压包缺少文件：$($entry.path)" }
  $actualHash = (Get-FileHash -LiteralPath $verifiedPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $entry.sha256) { throw "解压包哈希不一致：$($entry.path)" }
}
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = Join-Path $launchRoot 'easypub_desktop.exe'
$psi.WorkingDirectory = $launchRoot
$psi.UseShellExecute = $false
$psi.Environment['EASYPUB_WINDOW_STATE'] = 'ignore'
$psi.Environment['LOCALAPPDATA'] = Join-Path $verify 'smoke-user-data'
$process = [Diagnostics.Process]::Start($psi)
$ownedId = $process.Id
$windowFound = $false
$forcedExit = $false
$exitCode = $null
try {
  for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 100
    $process.Refresh()
    if ($process.MainWindowHandle -ne [IntPtr]::Zero) { $windowFound = $true; break }
  }
} finally {
  if ($process -and -not $process.HasExited) {
    $process.CloseMainWindow() | Out-Null
    if (-not $process.WaitForExit(5000)) {
      $forcedExit = $true
      $process.Kill($true)
      $process.WaitForExit()
    }
  }
  $exitCode = $process.ExitCode
  $process.Dispose()
}
$leftover = @(Get-Process -Id $ownedId -ErrorAction SilentlyContinue)
$zipInfo = Get-Item -LiteralPath $zip
$report = [ordered]@{
  package_name = $PackageName
  folder = $staging.Substring($root.Length + 1).Replace('\','/')
  zip = $zip.Substring($root.Length + 1).Replace('\','/')
  zip_bytes = $zipInfo.Length
  zip_sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  file_count = @($files).Count + 1
  startup_window_found = $windowFound
  isolated_startup_data = $psi.Environment['LOCALAPPDATA']
  exit_code = $exitCode
  forced_exit = $forcedExit
  verified_from_extracted_zip = $true
  dictionary_license_and_provenance_present = $licenseFound -and $provenanceFound
  font_provenance_present = $fontProvenance
  epub_provenance_present = $epubProvenance
  kindle_preview_plugin_present = $kindlePreviewPlugin
  manifest_hashes_verified = $true
  leftover_processes = $leftover.Count
  passed = $windowFound -and $leftover.Count -eq 0 -and -not $forcedExit -and $exitCode -eq 0
  note = 'EasyPub++ 最终功能包；启动、依赖来源、逐文件哈希和转换器随包验证通过。Kindle Previewer/真机、完整36格矩阵、原 EPUB 完整 CSS 页面布局、字体扩展和 DPI/IME 人工验收仍需单独完成。启动验证不是阅读器验收。'
}
if ($FrontendRewriteReview) {
  $report.note = '前端从零重写评审包，用户要求当前可运行版本。独立新入口；启动、依赖与逐文件哈希验证仅证明包完整性，不代表59场景或Kindle真机验收通过。'
  $report['entrypoint'] = 'lib/frontend_rewrite_main.dart'
  $report['final_frontend_accepted'] = $completionAccepted
  if ($completionAccepted) { $report.note = '41项软件补全需求及59场景本地验收完成；详见包内completion-acceptance.json。Kindle真机、个人账号站点、IME和多显示器按约定外列。' }
}
if ($ReleaseDescription) { $report.note = $ReleaseDescription }
[IO.File]::WriteAllText($evidence, (($report | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 5
if (-not $report.passed) { exit 1 }

