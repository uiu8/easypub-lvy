# 切页与书库流畅度基线（R0，正式版打磨）：用 profile 构建的帧性能探针跑两个场景，
#   switch  — 按侧栏顺序切换页面 5 轮，记录到首帧时间与单帧最长构建；
#   library — 书库滚动到底再回顶，搜索框逐字输入再删除。
# 每个场景按书库规模（40 / 300 / 1000 本）各跑 -Runs 次；有书源插件程序时一并启用插件。
# 先构建：flutter build windows --profile --target lib/frontend_rewrite_frame_perf_main.dart --no-tree-shake-icons
# 结果在 artifacts/navigation-perf-<时间>/，summary.md 是基线表。
param(
  [ValidateSet('switch', 'library', 'booksource')][string[]]$Scenes = @('switch', 'library'),
  [ValidateSet(40, 300, 1000)][int[]]$Books = @(40, 300, 1000),
  # booksource 场景（R8）：书源数，每个数各测一组；书库固定 40 本。
  [int[]]$Sources = @(368, 2425),
  [ValidateRange(1, 3)][int]$Runs = 2,
  [string]$Name = '',
  [string]$ExecutablePath,
  [string]$BridgePath,
  [switch]$ImportProfile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { $ExecutablePath } else { Join-Path $root 'flutter\build\windows\x64\runner\Profile\easypub_desktop.exe' }
if (-not (Test-Path -LiteralPath $exe)) { throw '缺少 profile 构建，先按脚本开头的命令构建。' }
if (-not $Name) { $Name = Get-Date -Format 'yyyyMMdd-HHmmss' }
$out = Join-Path $root "artifacts\navigation-perf-$Name"
if (Test-Path -LiteralPath $out) { throw '输出目录已存在，换一个 -Name。' }
New-Item -ItemType Directory -Path $out | Out-Null
$dll = if ($BridgePath) { $BridgePath } else { Join-Path $root 'target\release\easypub_bridge.dll' }
# 插件目录：复制书源插件程序并写清单，只用于测量。
$plugins = Join-Path $out 'plugins'
$pluginExe = Join-Path $root 'target\release\easypub_plugin_booksource.exe'
if (Test-Path -LiteralPath $pluginExe) {
  $pdir = Join-Path $plugins 'booksource'
  New-Item -ItemType Directory -Force -Path $pdir | Out-Null
  Copy-Item $pluginExe $pdir -Force
  $sha = (Get-FileHash (Join-Path $pdir 'easypub_plugin_booksource.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
  @{ id = 'booksource'; name = '书源下载'; version = '0.1.0'; description = 'perf'; executable = 'easypub_plugin_booksource.exe'; sha256 = $sha; permissions = @('network', 'write-downloads') } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pdir 'plugin.json') -Encoding utf8
}
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add("# 切页与书库流畅度基线（$Name）")
$summary.Add('')
$summary.Add("profile 构建：``$((Get-FileHash $exe).Hash.Substring(0, 12))``；DLL：``$((Get-FileHash $dll).Hash.Substring(0, 12))``；每项取 $Runs 次运行的范围。")
$aot = Join-Path (Split-Path -Parent $exe) 'data/app.so'
$summary.Add("Dart AOT：``$((Get-FileHash $aot).Hash)``（EXE 仅是 Flutter 原生启动壳）。")
foreach ($scene in $Scenes) {
  $counts = if ($scene -eq 'booksource') { $Sources } else { $Books }
  foreach ($count in $counts) {
    $reports = @()
    for ($i = 1; $i -le $Runs; $i++) {
      $case = Join-Path $out "$scene-$count-run$i"
      New-Item -ItemType Directory -Path $case | Out-Null
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = $exe
      $start.WorkingDirectory = Split-Path -Parent $exe
      $start.UseShellExecute = $false
      $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
      if ($ImportProfile) { $start.Environment['EASYPUB_IMPORT_PROFILE'] = '1' }
      $start.Environment['LOCALAPPDATA'] = Join-Path $case 'user-data'
      $start.Environment['EASYPUB_WINDOW_STATE'] = 'ignore'
      $start.Environment['EASYPUB_TEST_DLL'] = $dll
      $start.Environment['EASYPUB_PLUGIN_DIR'] = $plugins
      $start.Environment['EASYPUB_FRAME_TARGET'] = $scene
      if ($scene -eq 'booksource') {
        # 假书源写进插件数据目录（不访问网络），格式同 b10_source_list_perf.py。
        $pdata = Join-Path $case 'user-data\EasyPub-RustFlutter\plugin-data\booksource'
        New-Item -ItemType Directory -Force -Path $pdata | Out-Null
        $fake = for ($k = 0; $k -lt $count; $k++) {
          @{ bookSourceUrl = "https://fixture-$k.invalid"; bookSourceName = "合成书源$k"; bookSourceGroup = "分组$($k % 12)";
             searchUrl = '/search?q={{key}}'; ruleSearch = @{ bookList = 'li'; name = 'a@text'; bookUrl = 'a@href' };
             ruleContent = @{ content = '#content@html' } }
        }
        [IO.File]::WriteAllText((Join-Path $pdata 'sources.json'), (ConvertTo-Json -InputObject @($fake) -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
        $start.Environment['EASYPUB_FRAME_SOURCES'] = "$count"
        $start.Environment['EASYPUB_FRAME_BOOKS'] = '40'
      } else {
        $start.Environment['EASYPUB_FRAME_BOOKS'] = "$count"
      }
      $start.Environment['EASYPUB_FRAME_REPORT'] = Join-Path $case 'report.json'
      $p = [Diagnostics.Process]::Start($start)
      if (-not $p.WaitForExit(900000)) { $p.Kill(); throw "超时：$scene $count" }
      if ($p.ExitCode -ne 0) { throw "失败：$scene $count，退出码 $($p.ExitCode)" }
      $reports += Get-Content -LiteralPath (Join-Path $case 'report.json') -Raw -Encoding utf8 | ConvertFrom-Json
      Write-Output "完成 $scene $count 本 第 $i 次"
    }
    function Range($values) {
      $v = $values | Measure-Object -Minimum -Maximum
      if ([Math]::Abs($v.Maximum - $v.Minimum) -lt 0.5) { return '{0:N1}' -f $v.Minimum }
      return '{0:N1}–{1:N1}' -f $v.Minimum, $v.Maximum
    }
    $summary.Add('')
    if ($scene -eq 'switch') {
      $summary.Add("## 切页 · $count 本（插件：$($reports[0].plugin_active)；导入 $(Range ($reports | ForEach-Object { $_.import_ms / 1000 })) 秒）")
      $summary.Add('')
      $summary.Add('| 页面 | 到首帧 ms | 单帧最长构建 ms | 卡顿帧 |')
      $summary.Add('| --- | --- | --- | --- |')
      foreach ($prop in $reports[0].median.PSObject.Properties) {
        $route = $prop.Name -replace '/books/[^/]+/', '/books/…/'
        $vals = $reports | ForEach-Object { $_.median.($prop.Name) }
        $summary.Add("| ``$route`` | $(Range ($vals | ForEach-Object first_frame_ms)) | $(Range ($vals | ForEach-Object max_build_ms)) | $(Range ($vals | ForEach-Object janky_frames)) |")
      }
    } elseif ($scene -eq 'booksource') {
      $summary.Add("## 书源页 · $count 个假书源")
      $summary.Add('')
      $summary.Add('| 项 | 数值 |')
      $summary.Add('| --- | --- |')
      $summary.Add("| 打开书源页到首帧 ms | $(Range ($reports | ForEach-Object { $_.open_first_frame_ms })) |")
      $summary.Add("| 切到书源页签到首帧 ms / 之后单帧最长构建 ms | $(Range ($reports | ForEach-Object { $_.tab_first_frame_ms })) / $(Range ($reports | ForEach-Object { $_.tab_frames.max_build_ms })) |")
      $summary.Add("| 书源列表读完 ms | $(Range ($reports | ForEach-Object { $_.sources_loaded_ms })) |")
      $summary.Add("| 滚动步数 | $(Range ($reports | ForEach-Object { $_.scroll.steps })) |")
      $summary.Add("| 滚动单帧构建 p95 / 最长 ms | $(Range ($reports | ForEach-Object { $_.scroll.build_p95_ms })) / $(Range ($reports | ForEach-Object { $_.scroll.max_build_ms })) |")
      $summary.Add("| 滚动帧总耗时 p95 ms | $(Range ($reports | ForEach-Object { $_.scroll.total_p95_ms })) |")
      $summary.Add("| 滚动卡顿帧 / 总帧 | $(Range ($reports | ForEach-Object { $_.scroll.janky_frames })) / $(Range ($reports | ForEach-Object { $_.scroll.frames })) |")
      $summary.Add("| 筛选每字到首帧 中位 / 最长 ms | $(Range ($reports | ForEach-Object { $_.filter.first_frame_median_ms })) / $(Range ($reports | ForEach-Object { $_.filter.first_frame_max_ms })) |")
      $summary.Add("| 筛选单帧最长构建 ms | $(Range ($reports | ForEach-Object { $_.filter.max_build_ms })) |")
    } else {
      $summary.Add("## 书库滚动与筛选 · $count 本（导入 $(Range ($reports | ForEach-Object { $_.import_ms / 1000 })) 秒）")
      $summary.Add('')
      $summary.Add('| 项 | 数值 |')
      $summary.Add('| --- | --- |')
      $summary.Add("| 滚动步数 | $(Range ($reports | ForEach-Object { $_.scroll.steps })) |")
      $summary.Add("| 滚动单帧构建 p95 / 最长 ms | $(Range ($reports | ForEach-Object { $_.scroll.build_p95_ms })) / $(Range ($reports | ForEach-Object { $_.scroll.max_build_ms })) |")
      $summary.Add("| 滚动帧总耗时 p95 ms | $(Range ($reports | ForEach-Object { $_.scroll.total_p95_ms })) |")
      $summary.Add("| 滚动卡顿帧 / 总帧 | $(Range ($reports | ForEach-Object { $_.scroll.janky_frames })) / $(Range ($reports | ForEach-Object { $_.scroll.frames })) |")
      $summary.Add("| 筛选每字到首帧 中位 / 最长 ms | $(Range ($reports | ForEach-Object { $_.filter.first_frame_median_ms })) / $(Range ($reports | ForEach-Object { $_.filter.first_frame_max_ms })) |")
      $summary.Add("| 筛选单帧最长构建 ms | $(Range ($reports | ForEach-Object { $_.filter.max_build_ms })) |")
    }
  }
}
$summary.Add('')
$summary.Add('口径：一台机器、样本书（每本 30 章小文本），只代表这两个场景；不是完整性能验收。')
$summary | Set-Content -LiteralPath (Join-Path $out 'summary.md') -Encoding utf8
Write-Output "基线：$out\summary.md"
