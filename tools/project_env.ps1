# Dot-source this script for project-local tools. Never changes user/machine PATH.
$ErrorActionPreference = 'Stop'
$env:RUSTUP_HOME = 'D:\software\EasyPub-Toolchains\rustup'
$env:CARGO_HOME = 'D:\software\EasyPub-Toolchains\cargo'
$env:PUB_CACHE = 'D:\software\EasyPub-Toolchains\pub-cache'
$env:CI = 'true'
$env:PATH = 'D:\software\EasyPub-Toolchains\flutter-3.47.3\bin;D:\software\EasyPub-Toolchains\frb-2.13.0;D:\software\EasyPub-Toolchains\cargo-tools\bin;' + (Join-Path $env:USERPROFILE '.cargo\bin') + ';' + $env:PATH

