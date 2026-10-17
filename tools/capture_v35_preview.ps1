param(
  [string]$ExecutablePath = 'artifacts/ui-preview-20261010-v35/app/easypub_desktop.exe',
  [string]$Output = 'design/review-20261010-v35',
  [string[]]$Pages = @('issues','chapters','rules','library','layout','conversion')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = (Resolve-Path -LiteralPath (Join-Path $root $ExecutablePath)).Path
$outPath = Join-Path $root $Output
New-Item -ItemType Directory -Force -Path $outPath | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class V35Capture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
}
'@
[V35Capture]::SetProcessDPIAware() | Out-Null
$records = @()
foreach($page in $Pages) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $exe
  $psi.WorkingDirectory = Split-Path -Parent $exe
  $psi.UseShellExecute = $false
  $psi.Environment['EASYPUB_WINDOW_STATE'] = 'ignore'
  $psi.Environment['EASYPUB_PREVIEW_PAGE'] = $page
  $psi.Environment['LOCALAPPDATA'] = Join-Path $root 'artifacts/ui-preview-20261010-v35/isolated-data'
  $process = [Diagnostics.Process]::Start($psi)
  try {
    $handle = [IntPtr]::Zero
    for($i = 0; $i -lt 100; $i++) {
      Start-Sleep -Milliseconds 100
      $process.Refresh()
      if($process.HasExited) {throw "Preview exited before capture: $page"}
      $handle = $process.MainWindowHandle
      if($handle -ne [IntPtr]::Zero) {break}
    }
    if($handle -eq [IntPtr]::Zero) {throw 'Preview window was not created'}
    [V35Capture]::SetForegroundWindow($handle) | Out-Null
    [V35Capture]::SetCursorPos(0,0) | Out-Null
    Start-Sleep -Milliseconds 1800
    $rect = [V35Capture+RECT]::new()
    if(-not [V35Capture]::GetWindowRect($handle,[ref]$rect)) {throw 'Cannot read window bounds'}
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $bitmap = [Drawing.Bitmap]::new($width,$height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
      $dc = $graphics.GetHdc()
      try {
        if(-not [V35Capture]::PrintWindow($handle,$dc,2)) {throw 'PrintWindow failed'}
      } finally {$graphics.ReleaseHdc($dc)}
      $file = Join-Path $outPath ($page + '.png')
      $bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Png)
    } finally {
      $graphics.Dispose()
      $bitmap.Dispose()
    }
    $records += [ordered]@{page=$page;file=($page+'.png');width=$width;height=$height;dpi=[V35Capture]::GetDpiForWindow($handle);sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();process_id=$process.Id;source='Windows PrintWindow / Flutter Profile';data='in-memory demonstration fixture';production_backend=$false}
  } finally {
    if(-not $process.HasExited) {
      $process.CloseMainWindow() | Out-Null
      if(-not $process.WaitForExit(2500)) {$process.Kill();$process.WaitForExit()}
    }
    $process.Dispose()
  }
}
$manifest = [ordered]@{schema=1;date='2026-10-10';executable=$ExecutablePath;entrypoint='design_preview/lib/design_review_v35/main.dart';purpose='Real Flutter Windows rendering of the UI proposal; not production implementation acceptance';screens=$records}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outPath 'manifest.json') -Encoding utf8
$records | ForEach-Object {[pscustomobject]@{page=$_.page;width=$_.width;height=$_.height;file=$_.file}}
