param(
  [string]$Path = "D:\project\OhosXray\entry\libs\arm64-v8a\libxraycore.so"
)
# Streaming ASCII-string extractor, constant memory. Prints printable runs
# (len>=4) that contain any keyword, so output stays small on a 34MB binary.
$keywords = @('OpenHarmony','Ohos','OHOS','ohos','xray.tun','TUN_FD','tun.fd',
              'tunFd','TunFd','TunFD','/dev/net/tun','fdbased','stack_gvisor',
              'TunFdKey','protect','Protect','read OpenHarmony','tun_ohos',
              'XRAY_TUN','autoInterface','interface_name')
$fs = [System.IO.File]::OpenRead($Path)
try {
  $buf = New-Object byte[] 1048576   # 1MB chunks
  $sb = New-Object System.Text.StringBuilder
  $found = New-Object System.Collections.Generic.HashSet[string]
  while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
    for ($i = 0; $i -lt $n; $i++) {
      $b = $buf[$i]
      if ($b -ge 32 -and $b -lt 127) {
        [void]$sb.Append([char]$b)
      } else {
        if ($sb.Length -ge 4) {
          $s = $sb.ToString()
          foreach ($k in $keywords) {
            if ($s.Contains($k)) { [void]$found.Add($s); break }
          }
        }
        [void]$sb.Clear()
      }
    }
  }
  $found | Sort-Object | ForEach-Object { $_ }
} finally {
  $fs.Close()
}
