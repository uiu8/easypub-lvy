param(
  [Parameter(Mandatory)][string]$ExecutablePath,
  [string]$RunDirectory = 'artifacts/workspace-native-20261008',
  [string]$SettingsSource = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$run = [IO.Path]::GetFullPath((Join-Path $root $RunDirectory))
if (-not $run.StartsWith(([IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Run directory must be in project artifacts.' }
New-Item -ItemType Directory -Force -Path $run | Out-Null
$localData = Join-Path $run 'user-data'
$settings = Join-Path $localData 'EasyPub-RustFlutter/settings'
if ($SettingsSource) {
  if (Test-Path -LiteralPath $settings) { throw 'Use a fresh run directory when seeding a workspace.' }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settings) | Out-Null
  Copy-Item -LiteralPath (Resolve-Path -LiteralPath $SettingsSource).Path -Destination $settings -Recurse
}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WorkspaceWindowCheck {
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
}
'@
$results = @()
for ($attempt = 1; $attempt -le 2; $attempt++) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = (Resolve-Path -LiteralPath $ExecutablePath).Path
  $start.WorkingDirectory = Split-Path -Parent $start.FileName
  $start.UseShellExecute = $false
  $start.Environment['LOCALAPPDATA'] = $localData
  $start.Environment['EASYPUB_WINDOW_STATE'] = 'ignore'
  $owned = [Diagnostics.Process]::Start($start)
  @{pid=$owned.Id;executable=$start.FileName;started=$owned.StartTime.ToUniversalTime().ToString('o')} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'owned-process.json') -Encoding utf8
  $deadline = (Get-Date).AddSeconds(25)
  do {
    Start-Sleep -Milliseconds 250
    $owned.Refresh()
  } until ($owned.HasExited -or $owned.MainWindowHandle -ne [IntPtr]::Zero -or (Get-Date) -gt $deadline)
  if ($owned.HasExited -or $owned.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Application did not open a window.' }
  Start-Sleep -Milliseconds 3000
  $maximized = [WorkspaceWindowCheck]::IsZoomed($owned.MainWindowHandle)
  if ($maximized) { throw 'Application started maximized.' }
  $closed = $owned.CloseMainWindow()
  if (-not $closed -or -not $owned.WaitForExit(20000)) { throw 'Normal close did not finish; owned process is retained for inspection.' }
  $results += @{attempt=$attempt;started=$true;normal_window=(!$maximized);normal_close=$true;exit_code=$owned.ExitCode}
  if ($owned.ExitCode -ne 0) { throw 'Application returned an error exit code.' }
}
$files = @(Get-ChildItem -LiteralPath $settings -File -Recurse | ForEach-Object {
  @{path=$_.FullName.Substring($settings.Length + 1);bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
@{passed=$true;executable=$start.FileName;settings_source=$SettingsSource;runs=$results;files=$files} |
  ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding utf8
$results | ConvertTo-Json
