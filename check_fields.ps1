$Path = "D:\project\OhosXray\entry\libs\arm64-v8a\libxraycore.so"
$enc = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
$all = $enc.GetString([System.IO.File]::ReadAllBytes($Path))
$cands = @('tunFd','tun_fd','TunFd','tunFD','TunFD','fileDescriptor','deviceFd',
           'ohosTunFd','fdNum','handle','includeUIDs','excludeUIDs',
           'endpointIndependentNat','tcpModerateReceiveBuffer','multiqueue',
           'gVisor','gvisor','system','mixed','device','name','mtu','stack',
           'autoInterface','interfaceName','isIPv6','inet4Address','inet6Address')
foreach ($c in $cands) {
  $count = 0
  $idx = 0
  while (($p = $all.IndexOf($c, $idx)) -ge 0) { $count++; $idx = $p + $c.Length; if ($count -ge 5) { break } }
  Write-Output ("{0,-32} {1}" -f $c, $(if ($count -gt 0) { "PRESENT x$count" } else { "-" }))
}
