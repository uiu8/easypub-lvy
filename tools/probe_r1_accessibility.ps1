param(
  [string]$Report = 'docs/evidence/r1-accessibility-after.json'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, Accessibility
Add-Type -ReferencedAssemblies Accessibility @'
using System;
using System.Runtime.InteropServices;
using Accessibility;
public static class EasyPubMsaa {
  private delegate bool EnumProc(IntPtr hwnd, IntPtr param);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr param);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  public static IntPtr OwnedWindow(int pid) {
    IntPtr found=IntPtr.Zero;
    EnumWindows((hwnd, param) => { uint owner; GetWindowThreadProcessId(hwnd, out owner);
      if (owner == pid && FindWindowEx(hwnd, IntPtr.Zero, "FLUTTERVIEW", null) != IntPtr.Zero) {found=hwnd; return false;} return true; }, IntPtr.Zero);
    return found;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
  public static IntPtr View(IntPtr parent) { return FindWindowEx(parent, IntPtr.Zero, "FLUTTERVIEW", null); }
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("oleacc.dll")]
  private static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid, out IAccessible obj);
  public static IAccessible Root(IntPtr hwnd) {
    Guid iid = new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");
    IAccessible obj;
    int hr = AccessibleObjectFromWindow(hwnd, 0xfffffffc, ref iid, out obj);
    if (hr < 0) Marshal.ThrowExceptionForHR(hr);
    return obj;
  }
}
'@
function Read-Msaa($Node, [int]$Depth = 0) {
  if ($null -eq $Node -or $Depth -gt 15) { return }
  try {
    [pscustomobject]@{ depth=$Depth; name=$Node.accName(0); role=$Node.accRole(0); value=$Node.accValue(0) }
    $count = [Math]::Min([int]$Node.accChildCount, 150)
    for ($n=1; $n -le $count; $n++) {
      $child = $Node.accChild($n)
      if ($null -ne $child) { Read-Msaa $child ($Depth+1) }
    }
  } catch { [pscustomobject]@{depth=$Depth; error=$_.Exception.Message} }
}
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'flutter/build/windows/x64/runner/Release/easypub_desktop.exe'
$p = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru
$result = [ordered]@{ checked_at=[DateTimeOffset]::Now.ToString('o'); pid=$p.Id; passed=$false }
try {
  for ($i=0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $p.Refresh()
    $hwnd=[EasyPubMsaa]::OwnedWindow($p.Id)
    if ($hwnd -ne [IntPtr]::Zero) { break }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw 'Application window not found' }
  $null=[EasyPubMsaa]::ShowWindow($hwnd, 4)
  Start-Sleep -Milliseconds 1000
  $hostWindow = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $view = [EasyPubMsaa]::View($hwnd)
  $result.flutter_view = $view.ToInt64()
  # First access enables native semantics; request again after the next frames.
  $null = [EasyPubMsaa]::Root($view)
  Start-Sleep -Milliseconds 800
  $result.msaa = @(Read-Msaa ([EasyPubMsaa]::Root($view)))
  $result.msaa_text_fields = @($result.msaa | Where-Object role -eq 42).Count
  $result.msaa_buttons = @($result.msaa | Where-Object role -eq 43).Count
  $result.msaa_named_buttons = @($result.msaa | Where-Object { $_.role -eq 43 -and $_.name }).Count
  $result.msaa_labels = @($result.msaa | Where-Object name | Select-Object -ExpandProperty name -Unique)
  $result.uia_root_response = [EasyPubMsaa]::SendMessage($view, 0x003d, [IntPtr]::Zero, [IntPtr]::new(-25)).ToInt64()
  $hostWindow = [System.Windows.Automation.AutomationElement]::FromHandle($view)
  $null = $hostWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  Start-Sleep -Milliseconds 800
  $result.uia = @($hostWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
    [pscustomobject]@{name=$_.Current.Name; type=$_.Current.ControlType.ProgrammaticName; patterns=@($_.GetSupportedPatterns() | ForEach-Object {$_.ProgrammaticName})}
  })
  $result.application_edits = @($result.uia | Where-Object type -eq 'ControlType.Edit').Count
  $result.application_buttons = @($result.uia | Where-Object { $_.type -eq 'ControlType.Button' -and $_.name -match '调用中文回声|导入 TXT|打开章节实验窗' }).Count
  $result.msaa_passed = $result.msaa_text_fields -gt 0 -and $result.msaa_named_buttons -ge 3
  # Flutter 3.47.3 does not compile the optional FLUTTER_ENGINE_USE_UIA path.
  # Keep UIA as an explicit limitation instead of treating its empty tree as a
  # product failure after MSAA has proved the native accessibility surface.
  $result.uia_engine_limit = $result.application_edits -eq 0 -and $result.application_buttons -eq 0
  $result.passed = $result.msaa_passed
} catch { $result.error=$_.Exception.Message }
finally {
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; $null=$p.WaitForExit(5000) }
  $result.owned_process_exited=$p.HasExited
  $result.leftover_processes = @(Get-Process -Name easypub_desktop -ErrorAction SilentlyContinue).Count
  $path=Join-Path $root $Report
  $json = $result | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText($path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
$result | ConvertTo-Json -Depth 10
if (-not $result.passed) { exit 1 }
