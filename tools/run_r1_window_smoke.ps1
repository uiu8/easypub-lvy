$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$report = Join-Path $root 'artifacts\r1-3-window.json'
$exe = Join-Path $root 'flutter\build\windows\x64\runner\Release\easypub_desktop.exe'
Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
$process = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(35)
while (!(Test-Path -LiteralPath $report) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
}
$found = Test-Path -LiteralPath $report
if ($process -and !$process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit(5000) | Out-Null
}
Start-Sleep -Milliseconds 250
$left = @(Get-Process -Name easypub_desktop -ErrorAction SilentlyContinue).Count
Write-Output ('REPORT_FOUND=' + $found)
Write-Output ('LEFTOVER_PROCESS=' + $left)
if (!$found) { exit 1 }
Get-Content -Raw -Encoding UTF8 $report
$result = Get-Content -Raw -Encoding UTF8 $report | ConvertFrom-Json
if (!$result.channel_ack -or !$result.duplicate_open_reused -or !$result.child_closed_before_cleanup -or $result.window_count_at_ready -ne 2 -or $left -ne 0) {
    throw 'Window smoke assertions failed'
}
