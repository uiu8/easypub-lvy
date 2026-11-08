$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$legacy = 'D:\software\DeepSeek-Harness\workspace\easypub-branch\src\EasyPub.Core'
$headingPath = Join-Path $legacy 'HeadingSyntax.cs'
$numericPath = Join-Path $legacy 'NumericHeadingRule.cs'
# Compile the actual legacy HeadingSyntax source in memory; no legacy build output.
$source = "using System;`nusing System.Linq;`n" + (Get-Content -Raw -Encoding UTF8 $headingPath)
Add-Type -TypeDefinition $source
$numericSource = Get-Content -Raw -Encoding UTF8 $numericPath
$pattern = [regex]::Match($numericSource, 'DefaultPattern = @"([^"]+)"').Groups[1].Value
if (!$pattern) { throw 'Missing legacy numeric pattern' }
$numeric = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromMilliseconds(200))
$lines = [System.Collections.Generic.HashSet[string]]::new()
foreach ($prefix in @('', '第', '【第', ' ( 第', '　')) {
  foreach ($number in @('一', '１', '２', '９', '１２３', '-', '1', '9999', '零十', '壹佰', '兩', '')) {
    foreach ($marker in @('章', '回', '卷', '部', '节', '篇', '集')) {
      foreach ($tail in @('', ' 标题', '头看向门口', '正文保留原行。')) {
        [void]$lines.Add($prefix + $number + $marker + $tail)
      }
    }
  }
}
foreach ($special in @('序章','序言','前言','后记','後記','尾声','尾聲','终章','終章','番外','番外篇')) {
  foreach ($tail in @('', ' 标题', '：标题', '不搭后语', '篇', '（标题）')) { [void]$lines.Add($special + $tail) }
}
foreach ($number in @('1','0','9999','10000','000001','1234567','１２','١')) {
  foreach ($separator in @(' ','.','..','.2','.２','．','、',':','_','—','-')) {
    foreach ($title in @('标题','123','😀','𠮷','é','..标题','2标题','')) { [void]$lines.Add($number+$separator+$title) }
  }
}
$syntheticFiles = @()
$sampleRoot = Join-Path (Split-Path (Split-Path $legacy -Parent) -Parent) 'samples'
foreach ($relative in @('六卷690章修复验收\完整原稿.txt','六卷690章修复验收\缺陷样书.txt','六卷缺陷样书\缺陷样书.txt')) {
  $file = Join-Path $sampleRoot $relative
  $sampleLines = @(Get-Content -Encoding UTF8 -LiteralPath $file)
  foreach ($line in $sampleLines) { [void]$lines.Add($line) }
  $syntheticFiles += [ordered]@{path=$relative; lines=$sampleLines.Count; sha256=(Get-FileHash -LiteralPath $file).Hash}
}
$cases = foreach ($line in ($lines | Sort-Object)) {
  $match = $numeric.Match($line)
  $number = 0
  $matched = $match.Success -and [int]::TryParse($match.Groups['number'].Value, [ref]$number) -and $number -ge 1 -and $number -le 9999
  $letters = $false
  foreach ($ch in $match.Groups['title'].Value.ToCharArray()) { if ([char]::IsLetter($ch)) { $letters=$true; break } }
  [ordered]@{line=$line; heading=[EasyPub.Core.HeadingSyntax]::IsHeading($line); numeric=($matched -and $letters)}
}
$report = [ordered]@{runtime=[System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription; heading_sha256=(Get-FileHash $headingPath).Hash; numeric_sha256=(Get-FileHash $numericPath).Hash; numeric_pattern=$pattern; synthetic_files=$syntheticFiles; cases=@($cases)}
$path = Join-Path $root 'fixtures\r1-2\legacy-rule-oracle.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $path
Write-Output "ORACLE_CASES=$($cases.Count)"
