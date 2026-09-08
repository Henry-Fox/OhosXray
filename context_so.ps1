param(
  [string]$Path = "D:\project\OhosXray\entry\libs\arm64-v8a\libxraycore.so"
)
$enc = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
$bytes = [System.IO.File]::ReadAllBytes($Path)
$all = $enc.GetString($bytes)
function Show-Context($needle, $before=160, $after=260) {
  $idx = 0
  $hit = 0
  while ($true) {
    $pos = $all.IndexOf($needle, $idx)
    if ($pos -lt 0) { break }
    $hit++
    $start = [Math]::Max(0, $pos - $before)
    $len = [Math]::Min($before + $needle.Length + $after, $all.Length - $start)
    $seg = $all.Substring($start, $len)
    # replace non-printable with a separator so adjacent strings are visible
    $out = -join ($seg.ToCharArray() | ForEach-Object {
      $c = [int][char]$_
      if ($c -ge 32 -and $c -lt 127) { $_ } else { ' | ' }
    })
    Write-Output "===== [$needle] hit#$hit at offset $pos ====="
    Write-Output $out
    Write-Output ""
    $idx = $pos + $needle.Length
    if ($hit -ge 6) { break }
  }
  if ($hit -eq 0) { Write-Output "##### NOT FOUND: $needle" }
}
Show-Context 'read OpenHarmony Tun Fd'
Show-Context 'tunFd'
Show-Context 'xray.tun.fd'
