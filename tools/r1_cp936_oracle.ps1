$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Collections.Generic;
public static class Cp936Oracle {
  public static void Write(string path) {
    Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    var codec = Encoding.GetEncoding(936, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
    var decoded = new List<string>();
    for (int index = 0; index < 65792; index++) {
      byte[] bytes = index < 256 ? new byte[]{(byte)index} : new byte[]{(byte)((index-256)>>8), (byte)(index-256)};
      try { decoded.Add(codec.GetString(bytes)); } catch (DecoderFallbackException) { decoded.Add(null); }
    }
    var encoded = new List<string>();
    for (int scalar = 0; scalar < 65536; scalar++) {
      try { encoded.Add(Convert.ToHexString(codec.GetBytes(new string((char)scalar,1)))); }
      catch (EncoderFallbackException) { encoded.Add(null); }
    }
    File.WriteAllText(path, JsonSerializer.Serialize(new {runtime=System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription, codepage=936, decoded, encoded}), new UTF8Encoding(false));
  }
}
'@
[Cp936Oracle]::Write((Join-Path $root 'fixtures\r1-2\cp936-oracle.json'))
Write-Output 'CP936 oracle: 65792 decode cases, 65536 encode cases'
