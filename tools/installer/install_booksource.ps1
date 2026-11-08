param(
  [Parameter(Mandatory = $true)][string]$LocalRoot,
  [string]$PayloadDirectory,
  [string]$ErrorFile,
  [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
try {
  $data = Join-Path $LocalRoot 'EasyPub-RustFlutter'
  $pointer = Join-Path $data 'location.json'
  if (Test-Path -LiteralPath $pointer) {
    $config = Get-Content -LiteralPath $pointer -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.pending) { throw '请先打开软件完成数据目录迁移，再安装书源插件。' }
    if ($null -ne $config.data) {
      if (-not ($config.data -is [string]) -or $config.data -notmatch '^(?:[A-Za-z]:[\\/]|\\\\)') {
        throw '数据目录配置不是有效的绝对路径。'
      }
      $data = [IO.Path]::GetFullPath($config.data)
    }
  }
  $plugins = Join-Path $data 'plugins'
  $target = Join-Path $plugins 'booksource'
  if (Test-Path -LiteralPath $target) { Write-Output '已有书源插件，保留原样。'; exit 0 }
  if ($CheckOnly) { exit 0 }
  $manifest = Get-Content -LiteralPath (Join-Path $PayloadDirectory 'plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $exe = Join-Path $PayloadDirectory 'easypub_plugin_booksource.exe'
  $stream = [IO.File]::OpenRead($exe)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
  finally { $stream.Dispose(); $sha.Dispose() }
  if ($manifest.id -ne 'booksource' -or $hash -ne $manifest.sha256) {
    throw '书源插件校验失败。'
  }
  New-Item -ItemType Directory -Path $plugins -Force | Out-Null
  $stage = Join-Path $plugins ('.booksource-install-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage | Out-Null
  Get-ChildItem -LiteralPath $PayloadDirectory | Copy-Item -Destination $stage -Recurse
  # 原子改名，不覆盖现有插件；不修改 plugins.json 或任何用户数据。
  [IO.Directory]::Move($stage, $target)
  Write-Output '书源插件已安装，请在软件的插件页启用。'
} catch {
  if ($ErrorFile) { [IO.File]::WriteAllText($ErrorFile, $_.Exception.Message) }
  Write-Error -ErrorRecord $_ -ErrorAction Continue
  exit 1
}
