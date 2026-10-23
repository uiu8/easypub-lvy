# 书源下载插件单独打包（V102）：主程序包不再附带，Release 里另放一个插件压缩包。
# 先运行 tools/build_booksource_plugin.ps1 生成 artifacts/plugins/booksource，再运行本脚本。
# 用法：./tools/package_booksource_plugin.ps1 -PackageName easypub-lvy-booksource-v102-20261023-win-x64
param(
  [Parameter(Mandatory = $true)][string]$PackageName,
  [string]$OutputRoot = 'artifacts/release',
  [string]$EvidencePath = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$plugin = Join-Path $root 'artifacts/plugins/booksource'
$manifestPath = Join-Path $plugin 'plugin.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw '缺少书源下载插件：先运行 tools/build_booksource_plugin.ps1' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$exe = Join-Path $plugin $manifest.executable
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $manifest.sha256) { throw 'plugin.json 里的校验值与插件程序不一致，请重新运行 build_booksource_plugin.ps1。' }
$releaseRoot = Join-Path $root $OutputRoot
$staging = Join-Path $releaseRoot $PackageName
$zip = Join-Path $releaseRoot ($PackageName + '.zip')
if ((Test-Path -LiteralPath $staging) -or (Test-Path -LiteralPath $zip)) { throw "目标已存在，为避免覆盖请换 PackageName：$PackageName" }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
# 解压后就是一个可以直接“从文件夹安装”的插件目录。
Copy-Item -LiteralPath $plugin -Destination (Join-Path $staging 'booksource') -Recurse
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $staging 'booksource/LICENSE')
@"
EasyPub 书源下载插件

安装：
1. 完整解压本压缩包。
2. 打开 EasyPub，进入“插件”页，点“从文件夹安装…”，选择解压出来的 booksource 文件夹。
3. 在插件页启用“书源下载”，确认它需要的权限（联网、写入下载目录、网页组件、导入书库）。

说明：
- 插件是独立运行的程序，只在启用后才会运行；停用或卸载不影响主程序。
- 插件版本：$($manifest.version)；程序校验值（SHA-256）：$hash
- 本插件以 MIT 许可证发布，见 LICENSE。
"@ | Set-Content -Encoding utf8 (Join-Path $staging '安装说明.txt')
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
# 解压复核：插件程序与清单校验值一致。
$check = Join-Path $releaseRoot ($PackageName + '-unpacked-check')
if (Test-Path -LiteralPath $check) { throw "复核目录已存在：$check" }
Expand-Archive -LiteralPath $zip -DestinationPath $check
$unpacked = (Get-FileHash -LiteralPath (Join-Path $check "booksource/$($manifest.executable)") -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [ordered]@{
  package_name = $PackageName
  zip = "$OutputRoot/$PackageName.zip"
  zip_bytes = (Get-Item -LiteralPath $zip).Length
  zip_sha256 = $zipHash
  plugin_version = $manifest.version
  plugin_sha256 = $hash
  verified_from_extracted_zip = ($unpacked -eq $hash)
  passed = ($unpacked -eq $hash)
}
if ($EvidencePath) { $result | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $root $EvidencePath) }
$result | ConvertTo-Json
if (-not $result.passed) { throw '解压复核失败：插件程序校验值不一致。' }
