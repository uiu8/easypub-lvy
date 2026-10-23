# 打包书源下载插件（V86）：release 构建插件进程，生成 plugin.json（含 SHA-256）与说明。
# 用法：. ./tools/project_env.ps1; ./tools/build_booksource_plugin.ps1 [-Out artifacts/plugins/booksource]
param([string]$Out = 'artifacts/plugins/booksource')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    & cargo build --locked -p easypub_booksource --bin easypub_plugin_booksource --release
    if ($LASTEXITCODE -ne 0) { throw 'plugin build failed' }
    $dir = Join-Path $root $Out
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $exe = Join-Path $dir 'easypub_plugin_booksource.exe'
    Copy-Item (Join-Path $root 'target/release/easypub_plugin_booksource.exe') $exe
    $hash = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLowerInvariant()
    $version = (Select-String -Path (Join-Path $root 'Cargo.toml') -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value
    $manifest = [ordered]@{
        id = 'booksource'
        name = '书源下载'
        version = $version
        description = '导入常见格式的 JSON、单文件 JS 与 HTML 文字书源，搜索并下载为 TXT。支持网络代理与连接诊断；网页类书源使用系统自带的网页组件。'
        executable = 'easypub_plugin_booksource.exe'
        sha256 = $hash
        protocol = 1
        permissions = @('network', 'write-downloads', 'webview', 'import-library')
    }
    $manifest | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $dir 'plugin.json')
    "插件：$dir  SHA-256 $hash"
} finally { Pop-Location }
