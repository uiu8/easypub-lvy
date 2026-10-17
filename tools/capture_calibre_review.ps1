param([string]$Evidence = 'docs/evidence/r4-matrix-mix-kindling.json', [string]$Output = 'artifacts/r5-reader-review', [string]$Location = 'toc:第110章 卷5的旅程110', [switch]$DismissWelcome)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root $Output
if (Test-Path -LiteralPath $run) { throw 'Choose a new output directory' }
New-Item -ItemType Directory -Path $run | Out-Null
$report = Get-Content -LiteralPath (Join-Path $root $Evidence) -Raw | ConvertFrom-Json
$book = Join-Path $run 'review.azw3'
Copy-Item -LiteralPath $report.output -Destination $book
$before = (Get-FileHash -LiteralPath $report.output -Algorithm SHA256).Hash
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ReaderCapture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int s);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int t,bool repaint);
}
'@
[ReaderCapture]::SetProcessDPIAware() | Out-Null
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'C:/Program Files/Calibre2/ebook-viewer.exe'
$psi.UseShellExecute = $false
$psi.Environment['CALIBRE_CONFIG_DIRECTORY'] = Join-Path $run 'config'
$psi.Environment['CALIBRE_CACHE_DIRECTORY'] = Join-Path $run 'cache'
$psi.ArgumentList.Add('--new-instance')
$psi.ArgumentList.Add('--open-at=' + $Location)
$psi.ArgumentList.Add($book)
$process = [Diagnostics.Process]::Start($psi)
try {
 for ($i=0;$i -lt 150;$i++) {
  Start-Sleep -Milliseconds 100
  $process.Refresh()
  if ($process.HasExited) { throw 'Reader exited before capture' }
  if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }
 }
 $handle=$process.MainWindowHandle
 if ($handle -eq [IntPtr]::Zero) { throw 'Reader window missing' }
 [ReaderCapture]::ShowWindow($handle,9) | Out-Null
 [ReaderCapture]::MoveWindow($handle,60,50,1350,950,$true) | Out-Null
 [ReaderCapture]::SetForegroundWindow($handle) | Out-Null
 Start-Sleep -Seconds 7
 if ($DismissWelcome) {
  $shell = New-Object -ComObject WScript.Shell
  $shell.AppActivate($process.Id) | Out-Null
  Start-Sleep -Milliseconds 400
  if ([ReaderCapture]::GetForegroundWindow() -ne $handle) { throw 'Reader is not foreground; no keys sent' }
  [Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 3
 }
 $rect=[ReaderCapture+RECT]::new()
 if (-not [ReaderCapture]::GetWindowRect($handle,[ref]$rect)) { throw 'No window rectangle' }
 $bitmap=[Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top)
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
 $graphics.Dispose()
 $screen=Join-Path $run 'reader.png'
 $bitmap.Save($screen,[Drawing.Imaging.ImageFormat]::Png)
 $bitmap.Dispose()
 [ordered]@{source=$report.output;source_sha256=$before;location=$Location;screen=$screen;window_title=$process.MainWindowTitle;visual_review_pending=$true;mouse_navigation_verified=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'capture.json') -Encoding utf8
} finally {
 if (-not $process.HasExited) {
  $process.CloseMainWindow() | Out-Null
  if (-not $process.WaitForExit(3000)) { $process.Kill($true); $process.WaitForExit() }
 }
 $process.Dispose()
}
if ((Get-FileHash -LiteralPath $report.output -Algorithm SHA256).Hash -ne $before) { throw 'Original artifact changed' }
Write-Output $screen
