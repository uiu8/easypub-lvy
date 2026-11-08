param(
  [ValidateSet('Launch','Capture','Tree','Click','Keys','Scroll','Resize','Stop')][string]$Mode,
  [string]$RunDirectory = 'artifacts/windows86',
  [string]$ExecutablePath = '',
  [string]$Name = 'window',
  [int]$X = 0,
  [int]$Y = 0,
  [int]$Wheel = -3,
  [string]$Keys = '',
  [int]$Width = 1350,
  [int]$Height = 1080
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$run = [IO.Path]::GetFullPath((Join-Path $root $RunDirectory))
if (-not $run.StartsWith(([IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Run directory must be inside project artifacts.' }
New-Item -ItemType Directory -Path $run -Force | Out-Null
$pidFile = Join-Path $run 'owned-process.json'
if ($Mode -eq 'Launch') {
  if (Test-Path -LiteralPath $pidFile) {
    $previous = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
    if (Get-Process -Id $previous.pid -ErrorAction SilentlyContinue) { throw 'Previous process is still live; inspect it first.' }
  }
  if (-not $ExecutablePath) { $ExecutablePath = Join-Path $root 'flutter/build/windows/x64/runner/Release/easypub_desktop.exe' }
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = (Resolve-Path -LiteralPath $ExecutablePath).Path
  $psi.WorkingDirectory = Split-Path -Parent $psi.FileName
  $psi.UseShellExecute = $false
  $psi.Environment['LOCALAPPDATA'] = Join-Path $run 'user-data'
  $psi.Environment['EASYPUB_WINDOW_STATE'] = 'ignore'
  $appProcess = [Diagnostics.Process]::Start($psi)
  @{pid=$appProcess.Id;executable=$psi.FileName;started=$appProcess.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $pidFile -Encoding utf8
  Start-Sleep -Milliseconds 2000
} else {
  $owned = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
  $appProcess = Get-Process -Id $owned.pid -ErrorAction Stop
  if ($appProcess.Path -ne $owned.executable -or $appProcess.StartTime.ToUniversalTime().Ticks -ne ([datetime]$owned.started).ToUniversalTime().Ticks) { throw 'Owned process identity changed.' }
}
if ($Mode -eq 'Stop') {
  $appProcess.CloseMainWindow() | Out-Null
  if (-not $appProcess.WaitForExit(2000)) { throw 'Owned application did not close; inspect pending dialog.' }
  @{stopped=$true;pid=$appProcess.Id} | ConvertTo-Json
  exit
}
Add-Type -AssemblyName System.Drawing,System.Windows.Forms,UIAutomationClient,UIAutomationTypes
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class DesktopProbe {
 [StructLayout(LayoutKind.Sequential)]public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")]public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")]public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr GetLastActivePopup(IntPtr h);
 [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")]public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")]public static extern bool MoveWindow(IntPtr h,int x,int y,int width,int height,bool repaint);
 [DllImport("user32.dll")]public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
}
'@
[DesktopProbe]::SetProcessDPIAware() | Out-Null
$appProcess.Refresh()
$handle = $appProcess.MainWindowHandle
if ($handle -eq [IntPtr]::Zero) { throw 'No application window.' }
if ([DesktopProbe]::IsIconic($handle)) { [DesktopProbe]::ShowWindow($handle,9) | Out-Null }
$activePopup = [DesktopProbe]::GetLastActivePopup($handle)
[DesktopProbe]::SetForegroundWindow($activePopup) | Out-Null
Start-Sleep -Milliseconds 150
$rect = [DesktopProbe+RECT]::new()
if (-not [DesktopProbe]::GetWindowRect($handle,[ref]$rect)) { throw 'Cannot read window rectangle.' }
if ($Mode -eq 'Resize') {
  if ($Width -lt 640 -or $Width -gt 3000 -or $Height -lt 480 -or $Height -gt 2000) { throw 'Unsupported verification window size.' }
  [DesktopProbe]::MoveWindow($handle,$rect.Left,$rect.Top,$Width,$Height,$true) | Out-Null
  Start-Sleep -Milliseconds 500
  [DesktopProbe]::GetWindowRect($handle,[ref]$rect) | Out-Null
}
if ($Mode -ne 'Tree') {
  [uint32]$foregroundPid = 0
  [DesktopProbe]::GetWindowThreadProcessId([DesktopProbe]::GetForegroundWindow(),[ref]$foregroundPid) | Out-Null
  if ($foregroundPid -ne $appProcess.Id) { throw 'Target is not foreground; refusing input.' }
}
if ($Mode -in @('Click','Keys','Scroll')) {
  if ($Mode -in @('Click','Scroll')) {
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge ($rect.Right-$rect.Left) -or $Y -ge ($rect.Bottom-$rect.Top)) { throw 'Click outside app bounds.' }
    [DesktopProbe]::SetCursorPos($rect.Left+$X,$rect.Top+$Y) | Out-Null
    if ($Mode -eq 'Scroll') {
      $delta = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]($Wheel * 120)),0)
      [DesktopProbe]::mouse_event(0x800,0,0,$delta,[UIntPtr]::Zero)
    } else {
      [DesktopProbe]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
      [DesktopProbe]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    }
  } else { [Windows.Forms.SendKeys]::SendWait($Keys) }
  Start-Sleep -Milliseconds 450
}
if ($Mode -eq 'Tree') {
  $element = [Windows.Automation.AutomationElement]::FromHandle($handle)
  $all = $element.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
  @($all | Select-Object -First 350 | ForEach-Object { @{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;id=$_.Current.AutomationId;enabled=$_.Current.IsEnabled} }) | ConvertTo-Json -Depth 4
} else {
  $bitmap = [Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
    $capture = Join-Path $run ($Name+'.png')
    $bitmap.Save($capture,[Drawing.Imaging.ImageFormat]::Png)
    @{pid=$appProcess.Id;path=$capture;width=$bitmap.Width;height=$bitmap.Height} | ConvertTo-Json
  } finally { $graphics.Dispose();$bitmap.Dispose() }
}
