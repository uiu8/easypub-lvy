param(
  [string]$ReportPath = 'docs/evidence/r2-screen-capture.json',
  [string]$Output = 'artifacts/r2-screens',
  [string]$ProjectPath = '',
  [int[]]$ClickPoints = @(),
  [string]$CaptureName = 'real-project',
  [string]$ExecutablePath = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'flutter/build/windows/x64/runner/Release/easypub_desktop.exe'
if ($ExecutablePath) { $exe = (Resolve-Path -LiteralPath $ExecutablePath).Path }
if (-not (Test-Path -LiteralPath $exe)) { throw "Release executable missing: $exe" }
$outputPath = Join-Path $root $Output
$reportPath = Join-Path $root $ReportPath
New-Item -ItemType Directory -Force -Path $outputPath,(Split-Path -Parent $reportPath) | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class R2Native {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
'@
[R2Native]::SetProcessDPIAware() | Out-Null

$scenarios = @(
  @{ id='library'; title='书库：有书稿与批量范围'; scenario='' },
  @{ id='repair-self'; title='自助修复：本地证据'; scenario='self-repair' },
  @{ id='catalog-acquire'; title='目录获取：来源选择'; scenario='catalog-acquire' },
  @{ id='catalog-confirm'; title='目录确认：候选卷章'; scenario='catalog-confirm' },
  @{ id='catalog-repair'; title='目录修复：归位证据'; scenario='catalog-repair' },
  @{ id='repair-preview'; title='修复预览：勾选与差异'; scenario='repair-preview' },
  @{ id='repair-result'; title='修复结果：剩余原因'; scenario='repair-result' },
  @{ id='body-compare'; title='正文对比：两份正文'; scenario='body-compare' },
  @{ id='production-cover'; title='制作：封面信息'; scenario='production-cover' },
  @{ id='production-layout'; title='制作：排版预览'; scenario='production-layout' },
  @{ id='conversion-settings'; title='转换：设置'; scenario='conversion-settings' },
  @{ id='conversion-queue'; title='转换：队列'; scenario='conversion-queue' },
  @{ id='conversion-complete'; title='转换：完成'; scenario='conversion-complete' },
  @{ id='settings'; title='设置：主题与规则'; scenario='settings' }
)
if ($ProjectPath) { $scenarios = @(@{id=$CaptureName; title='真实项目重开'; scenario=''}) }
if ($ClickPoints.Count % 2 -ne 0) { throw 'ClickPoints requires x,y pairs' }
$results = @()
$ownedIds = @()
foreach ($item in $scenarios) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $exe
  $psi.WorkingDirectory = Split-Path -Parent $exe
  $psi.UseShellExecute = $false
  $psi.Environment['EASYPUB_WINDOW_STATE'] = 'ignore'
  $psi.Environment['EASYPUB_R2_SCENARIO'] = $item.scenario
  if ($ProjectPath) { $psi.ArgumentList.Add('--project'); $psi.ArgumentList.Add($ProjectPath) }
  $process = [Diagnostics.Process]::Start($psi)
  $ownedIds += $process.Id
  try {
    $handle = [IntPtr]::Zero
    for ($i = 0; $i -lt 80; $i++) {
      Start-Sleep -Milliseconds 100
      $process.Refresh()
      $handle = $process.MainWindowHandle
      if ($handle -ne [IntPtr]::Zero) { break }
    }
    if ($handle -eq [IntPtr]::Zero) { throw "Main window not found" }
    [R2Native]::ShowWindow($handle, 9) | Out-Null
    [R2Native]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds $(if ($ProjectPath) { 1800 } else { 450 })
    $rect = [R2Native+RECT]::new()
    if (-not [R2Native]::GetWindowRect($handle, [ref]$rect)) { throw 'GetWindowRect failed' }
    for ($j = 0; $j -lt $ClickPoints.Count; $j += 2) {
      [R2Native]::SetCursorPos($rect.Left + $ClickPoints[$j], $rect.Top + $ClickPoints[$j + 1]) | Out-Null
      [R2Native]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
      [R2Native]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
      Start-Sleep -Milliseconds 1000
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { throw "Invalid window size ${width}x${height}" }
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, [Drawing.Size]::new($width, $height))
    $graphics.Dispose()
    $file = Join-Path $outputPath ($item.id + '.png')
    $bitmap.Save($file, [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    $bytes = (Get-Item -LiteralPath $file).Length
    $results += [ordered]@{ id=$item.id; title=$item.title; scenario=$item.scenario; file=$file.Substring($root.Length + 1).Replace('\','/'); width=$width; height=$height; bytes=$bytes; sha256=$hash; captured=$true }
  } catch {
    $results += [ordered]@{ id=$item.id; title=$item.title; scenario=$item.scenario; captured=$false; error=$_.Exception.Message }
  } finally {
    if ($process -and -not $process.HasExited) {
      $process.CloseMainWindow() | Out-Null
      if (-not $process.WaitForExit(1500)) { $process.Kill($true); $process.WaitForExit() }
    }
    $process.Dispose()
  }
}
$remaining = @(Get-Process -Id $ownedIds -ErrorAction SilentlyContinue)
$report = [pscustomobject]@{ captured_at=(Get-Date).ToString('o'); executable=$exe.Substring($root.Length + 1).Replace('\','/'); capture_process_dpi_aware=$true; scenarios=@($results | ForEach-Object { [pscustomobject]$_ }); captured_count=@($results | Where-Object captured).Count; passed=(@($results | Where-Object captured).Count -eq $scenarios.Count -and $remaining.Count -eq 0); leftover_processes=$remaining.Count; visual_approval='pending_user'; note=$(if ($ProjectPath) { '真实项目重开截图；源文件为本地人工测试夹具，待用户视觉确认。' } else { '普通 Release 合成样书截图，待用户视觉确认。' }) }
$json = ConvertTo-Json -InputObject $report -Depth 8
[IO.File]::WriteAllText($reportPath, $json + "`n", [Text.UTF8Encoding]::new($false))
ConvertTo-Json -InputObject $report -Depth 5
if (-not $report.passed) { exit 1 }

