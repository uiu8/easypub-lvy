param([Parameter(Mandatory=$true)][string]$ProjectPath)
$ErrorActionPreference='Stop'
$probe=Get-Content (Join-Path $PSScriptRoot 'probe_r1_accessibility.ps1') -Raw
$start=$probe.IndexOf('$ErrorActionPreference')
Invoke-Expression $probe.Substring($start,$probe.IndexOf('function Read-Msaa')-$start)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CropCapture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint flags);
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
$folder=Join-Path $root 'artifacts/r5-crop-ui'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$null=[CropCapture]::SetProcessDPIAware()
$p=Start-Process -FilePath $exe -ArgumentList @('--project',('"'+$ProjectPath+'"')) -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru
$result=[ordered]@{capture_method="MSAA with observed-coordinate fallback";checked_at=[DateTimeOffset]::Now.ToString('o');pid=$p.Id;passed=$false;visual_approval='pending_user'}
try {
 for($i=0;$i -lt 60;$i++) {
  Start-Sleep -Milliseconds 200
  $hwnd=[EasyPubMsaa]::OwnedWindow($p.Id)
  if($hwnd -ne [IntPtr]::Zero){break}
 }
 if($hwnd -eq [IntPtr]::Zero){throw 'Window missing'}
 $null=[EasyPubMsaa]::ShowWindow($hwnd,9)
 $null=[EasyPubMsaa]::ShowWindow($hwnd,5)
 $null=[CropCapture]::SetForegroundWindow($hwnd)
 $null=[CropCapture]::SetWindowPos($hwnd,[IntPtr](-1),0,0,0,0,3)
 $view=[EasyPubMsaa]::View($hwnd)
 $null=[EasyPubMsaa]::Root($view)
 Start-Sleep -Milliseconds 1500
 foreach($label in @('封面信息','调整封面裁切…')) {
  $button=$null
  for($i=0;$i -lt 16;$i++) {
   $button=Find-Accessible ([EasyPubMsaa]::Root($view)) $label
   if($null -ne $button){break}
   $area=[CropCapture+RECT]::new();$null=[CropCapture]::GetWindowRect($hwnd,[ref]$area)
   $null=[CropCapture]::SetCursorPos($area.Left+[int](($area.Right-$area.Left)*0.83),$area.Top+[int](($area.Bottom-$area.Top)*0.75))
   [CropCapture]::mouse_event(0x0800,0,0,-240,[UIntPtr]::Zero)
   Start-Sleep -Milliseconds 200
  }
  if($null -eq $button -and $label -eq '封面信息') {
   $r=[CropCapture+RECT]::new();$null=[CropCapture]::GetWindowRect($hwnd,[ref]$r)
   if(($r.Right-$r.Left) -eq 1800 -and ($r.Bottom-$r.Top) -eq 1200) {
    $null=[CropCapture]::SetCursorPos($r.Left+1305,$r.Top+580)
    [CropCapture]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[CropCapture]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    continue
   }
  }
  if($null -eq $button -and $label -eq '调整封面裁切…') {
   $r=[CropCapture+RECT]::new();$null=[CropCapture]::GetWindowRect($hwnd,[ref]$r)
   if(($r.Right-$r.Left) -eq 1800 -and ($r.Bottom-$r.Top) -eq 1200) {
    $null=[CropCapture]::SetCursorPos($r.Left+1380,$r.Top+965)
    [CropCapture]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[CropCapture]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    continue
   }
  }
  if($null -eq $button){
   $r=[CropCapture+RECT]::new();$null=[CropCapture]::GetWindowRect($hwnd,[ref]$r)
   $b=[Drawing.Bitmap]::new($r.Right-$r.Left,$r.Bottom-$r.Top);$g=[Drawing.Graphics]::FromImage($b)
   try {$g.CopyFromScreen($r.Left,$r.Top,0,0,$b.Size);$b.Save((Join-Path $folder 'missing-control.png'),[Drawing.Imaging.ImageFormat]::Png)} finally {$g.Dispose();$b.Dispose()}
   throw "Control missing: $label"
  }
  $button.accDoDefaultAction(0)
  Start-Sleep -Milliseconds 700
 }
 $result.controls=@('调整封面裁切','原图','裁切结果','启用裁切','恢复完整原图','预览制作差异') | ForEach-Object {
  [pscustomobject]@{name=$_;present=($null -ne (Find-Accessible ([EasyPubMsaa]::Root($view)) $_))}
 }
 $rect=[CropCapture+RECT]::new();$null=[CropCapture]::GetWindowRect($hwnd,[ref]$rect)
 $bitmap=[Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top)
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 try {
  $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
  $path=Join-Path $folder 'crop-editor.png'
  $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
  $result.screenshot=$path
  $result.sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
 } finally {$graphics.Dispose();$bitmap.Dispose()}
 $result.msaa_controls_found=@($result.controls|Where-Object {-not $_.present}).Count -eq 0
 $result.verification="Screenshot capture only; content reviewed separately, not accessibility acceptance"
 $result.passed=$true
} catch {$result.error=$_.Exception.Message}
finally {
 if(-not $p.HasExited){$null=$p.CloseMainWindow();if(-not $p.WaitForExit(2000)){$p.Kill();$p.WaitForExit()}}
 $result.owned_process_exited=$p.HasExited
 $json=$result|ConvertTo-Json -Depth 8
 [IO.File]::WriteAllText((Join-Path $root 'docs/evidence/r5-crop-desktop.json'),$json,[Text.UTF8Encoding]::new($false))
 $json
}
if(-not $result.passed){exit 1}
