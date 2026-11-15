# windows-vrcft-bridge.ps1 — run this on the Windows PC next to VRCFaceTracking.
#
# VRCFT keeps its default OSC output (127.0.0.1:9000); this script listens there, forwards the packets
# to the Mac, and advertises an OSCQuery service so VRCFT can resolve the avatar. When the avatar
# changes, it feeds /avatar/change to VRCFT so VRCFT reloads that avatar's parameter set.
#
#   powershell -ExecutionPolicy Bypass -File .\windows-vrcft-bridge.ps1 -MacIP 192.168.68.65
#
# No install, no admin rights, no firewall changes: everything is loopback + outbound UDP plus one
# mDNS advertisement on the local network.

param(
    [Parameter(Mandatory = $true)][string]$MacIP,
    [int]$OscPort = 9000,
    [int]$QueryPort = 19090,
    [string]$AdvertisedName = 'fxsteam-vrchat-bridge.local'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(4)
$udp = New-Object System.Net.Sockets.UdpClient
$sender = New-Object System.Net.Sockets.UdpClient
$mdns = New-Object System.Net.Sockets.UdpClient

function NameBytes([string]$name) {
    foreach ($label in $name.Split('.')) {
        [byte]$label.Length
        [Text.Encoding]::ASCII.GetBytes($label)
    }
    [byte]0
}
function U16([int]$n) { [byte](($n -shr 8) -band 255); [byte]($n -band 255) }
function RecordBytes([string]$name, [int]$kind, [byte[]]$data) {
    NameBytes $name
    U16 $kind
    U16 1
    [byte[]]@(0, 0, 0, 15)
    U16 $data.Length
    $data
}
function OscString([string]$s) {
    $b = [Text.Encoding]::UTF8.GetBytes($s)
    $b
    for ($i = 0; $i -lt (4 - ($b.Length % 4)); $i++) { [byte]0 }
}

try {
    $udp.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Loopback, $OscPort)))
    Write-Host "VRCFT OSC: 127.0.0.1:$OscPort -> ${MacIP}:$OscPort"

    # mDNS so VRCFT's OSCQuery discovery finds the proxy on the Mac
    $local = (Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
              Select-Object -First 1).IPAddress
    if ($local) {
        $mdns.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket,
                                     [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $mdns.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($local), 5353)))
        $mdns.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP,
                                     [Net.Sockets.SocketOptionName]::MulticastInterface,
                                     [Net.IPAddress]::Parse($local).GetAddressBytes())
        $mdns.MulticastLoopback = $true
    }

    $service = 'VRChat-Client-FXSteamBridge._oscjson._tcp.local'
    [byte[]]$srv = @(U16 0; U16 0; U16 $QueryPort; NameBytes $AdvertisedName)
    [byte[]]$advert = @(
        0, 0, 132, 0, 0, 0, 0, 1, 0, 0, 0, 3
        RecordBytes '_oscjson._tcp.local' 12 ([byte[]]@(NameBytes $service))
        RecordBytes $service 33 $srv
        RecordBytes $AdvertisedName 1 ([Net.IPAddress]::Parse($MacIP).GetAddressBytes())
        RecordBytes $service 16 ([byte[]]@(9, 116, 120, 116, 118, 101, 114, 115, 61, 49))
    )

    $null = $http.GetStringAsync("http://${MacIP}:$QueryPort/?HOST_INFO").GetAwaiter().GetResult()
    Write-Host "OSCQuery proxy reachable at http://${MacIP}:$QueryPort/ - bridge ready."
    Write-Host 'Keep this window open. Restart VRCFT if it does not pick the avatar up.'

    $pending = $udp.ReceiveAsync()
    $nextCheck = [DateTime]::MinValue
    $lastAvatar = ''
    $lastPids = ''
    $count = 0
    while ($true) {
        if ($pending.Wait(20)) {
            $packet = $pending.GetAwaiter().GetResult()
            $null = $sender.Send($packet.Buffer, $packet.Buffer.Length, $MacIP, $OscPort)
            $count++
            if ($count -eq 1 -or ($count % 10000) -eq 0) { Write-Host "Forwarded OSC packets: $count" }
            $pending = $udp.ReceiveAsync()
        }
        if ([DateTime]::UtcNow -ge $nextCheck) {
            $nextCheck = [DateTime]::UtcNow.AddSeconds(3)
            if ($local) { $null = $mdns.Send($advert, $advert.Length, '224.0.0.251', 5353) }
            try {
                $avatar = ($http.GetStringAsync("http://${MacIP}:$QueryPort/avatar/change").GetAwaiter().GetResult() |
                           ConvertFrom-Json).VALUE[0]
                $vrcPids = @(Get-Process -Name 'VRCFaceTracking*' -ErrorAction SilentlyContinue |
                             Select-Object -ExpandProperty Id)
                $pidKey = $vrcPids -join ','
                if ($avatar -and (($avatar -ne $lastAvatar) -or ($pidKey -ne $lastPids))) {
                    [byte[]]$message = @(OscString '/avatar/change'; OscString ',s'; OscString $avatar)
                    $ports = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                               Where-Object { $_.OwningProcess -in $vrcPids -and
                                              $_.LocalAddress -eq '127.0.0.1' -and
                                              $_.LocalPort -ne 5353 } |
                               Select-Object -ExpandProperty LocalPort -Unique)
                    foreach ($port in $ports) {
                        $null = $sender.Send($message, $message.Length, '127.0.0.1', $port)
                    }
                    if ($ports.Count -gt 0) {
                        $lastAvatar = $avatar
                        $lastPids = $pidKey
                        Write-Host "Avatar synchronised: $avatar"
                    }
                }
            } catch { Write-Warning $_.Exception.Message }
        }
    }
} finally {
    $udp.Dispose(); $sender.Dispose(); $mdns.Dispose(); $http.Dispose()
}
