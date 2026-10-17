param([Parameter(Mandatory=$true)][string]$ProjectPath)
$ErrorActionPreference='Stop'
$probe=Get-Content (Join-Path $PSScriptRoot 'probe_r1_accessibility.ps1') -Raw
$start=$probe.IndexOf('$ErrorActionPreference')
Invoke-Expression $probe.Substring($start,$probe.IndexOf('function Read-Msaa')-$start)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class EffectiveCapture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,int data,UIntPtr extra);
}
'@
function Find-Accessible($node,[string]$name,[int]$depth=0) {
 if ($null -eq $node -or $depth -gt 25) {return $null}
 try {
  if ($node.accName(0) -eq $name) { return $node }
  for($i=1;$i -le [Math]::Min(200,[int]$node.accChildCount);$i++) {
   $found=Find-Accessible ($node.accChild($i)) $name ($depth+1)
   if ($null -ne $found) {return $found}
  }
 } catch {}
 return $null
}
$root=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $root 'flutter/build/windows/x64/runner/Release/easypub_desktop.exe'
$folder=Join-Path $root 'artifacts/r4-effective-ui'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$null=[EffectiveCapture]::SetProcessDPIAware()
$p=Start-Process -FilePath $exe -ArgumentList @('--project',('"'+$ProjectPath+'"')) -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru
$result=[ordered]@{checked_at=[DateTimeOffset]::Now.ToString('o');pid=$p.Id;passed=$false;visual_approval='pending_user'}
try {
 for($i=0;$i -lt 60;$i++) {
  Start-Sleep -Milliseconds 200
  $hwnd=[EasyPubMsaa]::OwnedWindow($p.Id)
  if($hwnd -ne [IntPtr]::Zero){break}
 }
 if($hwnd -eq [IntPtr]::Zero){throw 'Window missing'}
 $null=[EasyPubMsaa]::ShowWindow($hwnd,5)
 Start-Sleep -Milliseconds 150
 $null=[EasyPubMsaa]::ShowWindow($hwnd,9)
 $null=[EasyPubMsaa]::ShowWindow($hwnd,5)
 $null=[EffectiveCapture]::SetForegroundWindow($hwnd)
 $view=[EasyPubMsaa]::View($hwnd)
 $null=[EasyPubMsaa]::Root($view)
 for($i=0;$i -lt 30;$i++) {
  Start-Sleep -Milliseconds 200
  if($i -eq 5) {
   $area=[EffectiveCapture+RECT]::new();$null=[EffectiveCapture]::GetWindowRect($hwnd,[ref]$area)
   $x=$area.Left+[int](($area.Right-$area.Left)*0.8)
   $y=$area.Top+[int](($area.Bottom-$area.Top)*0.8)
   $null=[EffectiveCapture]::SetCursorPos($x,$y)
   [EffectiveCapture]::mouse_event(0x0800,0,0,-600,[UIntPtr]::Zero)
  }
  $button=Find-Accessible ([EasyPubMsaa]::Root($view)) '编辑后章节结构' 
  if($null -ne $button){break}
 }
 if($null -eq $button){
  # Fallback point observed in missing-control.png at 1800x1200, after scrolling.
  $r=[EffectiveCapture+RECT]::new();$null=[EffectiveCapture]::GetWindowRect($hwnd,[ref]$r)
  if(($r.Right-$r.Left) -ne 1800 -or ($r.Bottom-$r.Top) -ne 1200){throw 'Unexpected capture geometry'}
  $null=[EffectiveCapture]::SetCursorPos($r.Left+1375,$r.Top+856)
  [EffectiveCapture]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
  [EffectiveCapture]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
  $result.entry_opened_by='observed screenshot position'
 } else {$button.accDoDefaultAction(0);$result.entry_opened_by='MSAA'}
 for($i=0;$i -lt 30;$i++) {
  Start-Sleep -Milliseconds 200
  $rename=Find-Accessible ([EasyPubMsaa]::Root($view)) '改名'
  if($null -ne $rename){break}
 }
 $result.msaa_edit_controls_found=$null -ne $rename
 $result.controls=@('改名','移动','合并到前章','撤销','重做','清空后续编辑','查看变更并另存 TXT') | ForEach-Object {
  [pscustomobject]@{name=$_;present=($null -ne (Find-Accessible ([EasyPubMsaa]::Root($view)) $_))}
 }
 $rect=[EffectiveCapture+RECT]::new()
 $null=[EffectiveCapture]::GetWindowRect($hwnd,[ref]$rect)
 $bitmap=[Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top)
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 try {
  $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
  $path=Join-Path $folder 'effective-editor.png'
  $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
  $result.screenshot=$path
  $result.sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
 } finally {$graphics.Dispose();$bitmap.Dispose()}
 $result.passed=@($result.controls|Where-Object {-not $_.present}).Count -eq 0
} catch {$result.error=$_.Exception.Message}
finally {
 if(-not $p.HasExited){$null=$p.CloseMainWindow();if(-not $p.WaitForExit(2000)){$p.Kill();$p.WaitForExit()}}
 $result.owned_process_exited=$p.HasExited
 $json=$result|ConvertTo-Json -Depth 8
 [IO.File]::WriteAllText((Join-Path $root 'docs/evidence/r4-effective-ui.json'),$json,[Text.UTF8Encoding]::new($false))
 $json
}
if(-not $result.passed){exit 1}
