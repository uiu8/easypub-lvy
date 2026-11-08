param([ValidateSet('library','overview','chapters','issues','rules','catalog','repairs','metadata','layout','cleanup','resources','conversion','tasks','settings')][string]$Page='issues')
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'artifacts/ui-preview-20261010-v36/app/easypub_desktop.exe'
if(-not (Test-Path -LiteralPath $exe)) {throw 'Preview executable is not built yet.'}
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName=$exe
$psi.WorkingDirectory=Split-Path -Parent $exe
$psi.UseShellExecute=$false
$psi.Environment['EASYPUB_WINDOW_STATE']='ignore'
$psi.Environment['EASYPUB_PREVIEW_PAGE']=$Page
$psi.Environment['LOCALAPPDATA']=Join-Path $root 'artifacts/ui-preview-20261010-v36/isolated-data'
[Diagnostics.Process]::Start($psi) | Out-Null

