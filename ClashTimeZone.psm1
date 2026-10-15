Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:GeoCache = @{}
$script:ConfigDirectory = ''
$script:ZoneMap = @{
    'Asia/Tokyo'='Tokyo Standard Time'; 'Asia/Shanghai'='China Standard Time'
    'America/Los_Angeles'='Pacific Standard Time'; 'US/Pacific'='Pacific Standard Time'
    'America/Denver'='Mountain Standard Time'; 'US/Mountain'='Mountain Standard Time'
    'America/Boise'='Mountain Standard Time'
    'America/Phoenix'='US Mountain Standard Time'; 'US/Arizona'='US Mountain Standard Time'
    'America/Chicago'='Central Standard Time'; 'US/Central'='Central Standard Time'
    'America/Menominee'='Central Standard Time'
    'America/Indiana/Knox'='Central Standard Time'; 'America/Indiana/Tell_City'='Central Standard Time'
    'America/North_Dakota/Center'='Central Standard Time'
    'America/North_Dakota/New_Salem'='Central Standard Time'
    'America/North_Dakota/Beulah'='Central Standard Time'
    'America/New_York'='Eastern Standard Time'; 'US/Eastern'='Eastern Standard Time'
    'America/Detroit'='Eastern Standard Time'
    'America/Kentucky/Louisville'='Eastern Standard Time'
    'America/Kentucky/Monticello'='Eastern Standard Time'
    'America/Indiana/Indianapolis'='US Eastern Standard Time'
    'America/Indiana/Marengo'='US Eastern Standard Time'
    'America/Indiana/Petersburg'='US Eastern Standard Time'
    'America/Indiana/Vevay'='US Eastern Standard Time'
    'America/Indiana/Vincennes'='US Eastern Standard Time'
    'America/Indiana/Winamac'='US Eastern Standard Time'
    'America/Anchorage'='Alaskan Standard Time'; 'US/Alaska'='Alaskan Standard Time'
    'America/Juneau'='Alaskan Standard Time'; 'America/Nome'='Alaskan Standard Time'
    'America/Sitka'='Alaskan Standard Time'; 'America/Yakutat'='Alaskan Standard Time'
    'America/Metlakatla'='Alaskan Standard Time'
    'America/Adak'='Aleutian Standard Time'; 'US/Aleutian'='Aleutian Standard Time'
    'Pacific/Honolulu'='Hawaiian Standard Time'; 'US/Hawaii'='Hawaiian Standard Time'
}
function Get-CtzField($Object, [string]$Name, $Default=$null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-CtzHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Write-CtzJson([string]$Path, $Value) {
    $parent=Split-Path -Parent $Path
    if (!(Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($tmp,($Value | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) {
            $backup=$tmp+'.previous'
            try { [IO.File]::Replace($tmp,$Path,$backup) }
            finally { if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force} }
        }
        else { [IO.File]::Move($tmp,$Path) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}
function Read-CtzJson([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return $null }
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}
function ConvertTo-CtzUtc($Value) {
    # PowerShell 7.5+ may deserialize ISO dates to DateTime automatically,
    # while Windows PowerShell returns strings. Do not stringify a UTC DateTime
    # and parse it as local time (which silently shifts it by eight hours).
    if([string]$Value -match '^0001-01-01'){return [DateTime]::SpecifyKind([DateTime]::MinValue,[DateTimeKind]::Utc)}
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime}
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}
function Get-CtzConfig([string]$Path=(Join-Path $PSScriptRoot 'config.json')) {
    $c=Read-CtzJson $Path
    if ($null -eq $c) { throw 'ConfigurationMissing' }
    foreach($name in @('PollSeconds','ConfirmationSeconds','ConfirmationMaxAgeSeconds','StableRecheckSeconds','MinimumChangeIntervalSeconds','RequestTimeoutSeconds','FailureBackoffSeconds','MaxBackoffSeconds','GeoCacheSeconds','EchoDailyLimit','GeoDailyLimit','LogMaxBytes','LogArchives')) {
        $value=Get-CtzField $c $name
        if ($null -eq $value -or $value -isnot [ValueType] -or [double]$value -le 0) { throw "InvalidConfiguration:$name" }
    }
    if ($c.PollSeconds -lt 5 -or $c.ConfirmationSeconds -lt 3 -or $c.ConfirmationSeconds -gt 10 -or $c.RequestTimeoutSeconds -gt 15 -or $c.StableRecheckSeconds -lt 300 -or $c.StableRecheckSeconds -gt 900 -or !$c.RequireTwoGeoProviders -or $c.ConfirmationMaxAgeSeconds -lt $c.ConfirmationSeconds) { throw 'UnsafeConfiguration' }
    return $c
}
function Get-CtzStateDirectory {
    return (Join-Path $env:LOCALAPPDATA 'ClashTimeZone\Data')
}
function Get-CtzMutexName { return ('Local\ClashTimeZone-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
function Write-CtzLog([string]$Directory,[string]$Event,$Data,$Config) {
    if (!(Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $path=Join-Path $Directory 'monitor.jsonl'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge $Config.LogMaxBytes) {
        $last=Join-Path $Directory ('monitor.jsonl.'+$Config.LogArchives)
        if (Test-Path -LiteralPath $last) { Remove-Item -LiteralPath $last -Force }
        for($i=$Config.LogArchives-1;$i -ge 1;$i--) {
            $old=Join-Path $Directory ('monitor.jsonl.'+$i)
            if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination (Join-Path $Directory ('monitor.jsonl.'+($i+1))) }
        }
        Move-Item -LiteralPath $path -Destination ($path+'.1')
    }
    $entry=@{Utc=[DateTime]::UtcNow.ToString('o');Event=$Event;Data=$Data}
    [IO.File]::AppendAllText($path,($entry|ConvertTo-Json -Compress -Depth 5)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}
function Invoke-CtzPipeGet([string]$Pipe,[string]$Endpoint,[int]$TimeoutMs=1500) {
    if ($Endpoint -notin @('/version','/configs','/proxies')) { throw 'ControllerEndpointDenied' }
    $stream=[IO.Pipes.NamedPipeClientStream]::new('.',$Pipe,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
    $reader=$null
    try {
        $stream.Connect($TimeoutMs)
        $request=[Text.Encoding]::ASCII.GetBytes("GET $Endpoint HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n")
        $write=$stream.WriteAsync($request,0,$request.Length)
        if (!$write.Wait($TimeoutMs)) { throw 'ControllerWriteTimeout' }
        # HTTP chunk sizes are bytes; Latin-1 preserves a 1:1 byte representation
        # until framing is removed, including proxy group names in UTF-8.
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::GetEncoding(28591),$false,4096,$true)
        $read=$reader.ReadToEndAsync()
        if (!$read.Wait($TimeoutMs)) { throw 'ControllerReadTimeout' }
        $raw=$read.Result
        if ($raw.Length -gt 2097152) { throw 'ControllerResponseTooLarge' }
        $parts=$raw -split "`r`n`r`n",2
        if ($parts.Count -ne 2 -or $parts[0] -notmatch '^HTTP/1\.[01] 200\b') { throw 'ControllerHttpFailure' }
        $body=$parts[1]
        if ($parts[0] -match '(?im)^Transfer-Encoding:\s*chunked') {
            $rest=$body; $result=[Text.StringBuilder]::new()
            while($true) {
                $end=$rest.IndexOf("`r`n")
                if($end -lt 0) { throw 'InvalidChunkedResponse' }
                $size=[Convert]::ToInt32(($rest.Substring(0,$end) -split ';')[0],16)
                if($size -eq 0) { break }
                $rest=$rest.Substring($end+2)
                if($rest.Length -lt $size+2) { throw 'InvalidChunkedResponse' }
                [void]$result.Append($rest.Substring(0,$size)); $rest=$rest.Substring($size+2)
            }
            $body=$result.ToString()
        }
        $body=[Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes($body))
        return ($body | ConvertFrom-Json)
    } finally { if ($reader) { $reader.Dispose() }; $stream.Dispose() }
}
function Get-CtzController {
    $pipes=@([IO.Directory]::GetFiles('\\.\pipe\') | ForEach-Object { ($_ -split '\\')[-1] } | Where-Object { $_ -match '^(verge-mihomo|mihomo|clash)(-|$)' -and $_ -notmatch 'service' })
    $valid=@()
    foreach($pipe in $pipes) {
        try {
            $v=Invoke-CtzPipeGet $pipe '/version'
            if ((Get-CtzField $v 'version' '') -match '^v?\d+\.') { $valid+=@{Kind='Pipe';Address=$pipe;Version=$v.version;Secret=$null} }
        } catch { }
    }
    if ($valid.Count -gt 1) { throw 'AmbiguousControllers' }
    if ($valid.Count -eq 1) { return $valid[0] }
    # No guessed TCP ports, no config changes, and no subscription/profile reads.
    $dir=Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
    if ($script:ConfigDirectory) { $dir=$script:ConfigDirectory }
    $file=Join-Path $dir 'clash-verge.yaml'
    if (!(Test-Path -LiteralPath $file)) { throw 'ControllerUnavailable' }
    $address=$null; $secret=$null
    foreach($line in [IO.File]::ReadLines($file)) {
        if ($line -match '^external-controller:\s*(.*?)\s*$') { $address=$Matches[1].Trim("'",'"') }
        elseif ($line -match '^secret:\s*(.*?)\s*$') { $secret=$Matches[1].Trim("'",'"') }
    }
    if ($address -notmatch '^(127\.0\.0\.1|\[::1\]):\d{1,5}$') { throw 'ControllerUnavailable' }
    $controller=@{Kind='Tcp';Address=$address;Version='';Secret=$secret}
    $v=Invoke-CtzController $controller '/version'
    if ((Get-CtzField $v 'version' '') -notmatch '^v?\d+\.') { throw 'ControllerUnavailable' }
    $controller.Version=$v.version
    return $controller
}
function Invoke-CtzController($Controller,[string]$Endpoint) {
    if ($Endpoint -notin @('/version','/configs','/proxies')) { throw 'ControllerEndpointDenied' }
    if ($Controller.Kind -eq 'Pipe') { return (Invoke-CtzPipeGet $Controller.Address $Endpoint) }
    $request=[Net.HttpWebRequest]::Create(('http://'+$Controller.Address+$Endpoint))
    $request.Proxy=$null; $request.Timeout=1500; $request.ReadWriteTimeout=1500
    if ($Controller.Secret) { $request.Headers['Authorization']='Bearer '+$Controller.Secret }
    $response=$null; $reader=$null
    try {
        $response=$request.GetResponse(); $reader=[IO.StreamReader]::new($response.GetResponseStream())
        return ($reader.ReadToEnd()|ConvertFrom-Json)
    } finally { if ($reader) {$reader.Dispose()}; if ($response) {$response.Dispose()} }
}
function Get-CtzSystemProxy {
    $r=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $connection=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -ErrorAction SilentlyContinue
    $bytes=Get-CtzField $connection 'DefaultConnectionSettings'
    $pacFlag=$false
    if ($bytes -and $bytes.Length -gt 8) { $pacFlag=([int]$bytes[8] -band 12) -ne 0 }
    return @{Enabled=(1 -eq (Get-CtzField $r 'ProxyEnable' 0));Server=[string](Get-CtzField $r 'ProxyServer' '');Pac=([bool](Get-CtzField $r 'AutoConfigURL' '') -or $pacFlag)}
}
function Resolve-CtzProxy([string]$Server) {
    $selected=$Server
    if ($Server -match '=') {
        $items=@{}; foreach($part in ($Server -split ';')) { $pair=$part -split '=',2; if($pair.Count -eq 2){$items[$pair[0].Trim()]=$pair[1].Trim()} }
        if (!$items.Contains('https')) { return $null }; $selected=$items['https']
    }
    if ($selected -notmatch '^(?:http://)?(127\.0\.0\.1|localhost|\[::1\]):(\d{1,5})$') { return $null }
    $port=[int]$Matches[2]
    if($port -lt 1 -or $port -gt 65535) { return $null }
    return @{Url=('http://127.0.0.1:'+$port);Port=$port}
}
function Resolve-CtzSelectedChain($Proxies,[string]$Start,[string[]]$Seen=@()) {
    if($Start -in $Seen -or $Seen.Count -ge 32){throw 'ProxySelectionCycle'}
    $node=Get-CtzField $Proxies $Start
    if(!$node){throw 'ProxySelectionMissing'}
    $next=Get-CtzField $node 'now'
    if(!$next){return $Start}
    return (@($Start)+@(Resolve-CtzSelectedChain $Proxies ([string]$next) (@($Seen)+$Start)))
}
function Get-CtzSnapshot($Config) {
    $script:ConfigDirectory=$Config.ClashConfigDirectory
    $processes=@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(clash-verge|verge-mihomo(-alpha)?|mihomo|clash)$' })
    $gui=@($processes|Where-Object {$_.ProcessName -eq 'clash-verge'})
    $cores=@($processes|Where-Object {$_.ProcessName -ne 'clash-verge'})
    $service=Get-Service -Name 'clash_verge_service' -ErrorAction SilentlyContinue
    $proxy=Get-CtzSystemProxy
    $adapters=@(Get-NetAdapter -ErrorAction Stop | Where-Object {$_.Status -eq 'Up'})
    $tunnels=@($adapters|Where-Object {$_.InterfaceDescription -match 'Tunnel|TAP|TUN|WireGuard|Wintun|VPN' -or $_.Name -match 'Mihomo|Clash|VPN'})
    $mihomoTunnels=@($tunnels|Where-Object {$_.Name -match 'Mihomo|Clash' -or $_.InterfaceDescription -eq 'Meta Tunnel'})
    $foreignTunnels=@($tunnels|Where-Object {$_ -notin $mihomoTunnels})
    $controller=$null; $cc=$null; $selections=@(); $controllerError=$null; $chainDepth=0
    try {
        $controller=Get-CtzController
        $cc=Invoke-CtzController $controller '/configs'
        $all=Get-CtzField (Invoke-CtzController $controller '/proxies') 'proxies'
        if($null -eq $all) { throw 'ProxiesMissing' }
        foreach($property in $all.PSObject.Properties) {
            $now=Get-CtzField $property.Value 'now'
            if($null -ne $now) { $selections+=($property.Name+'='+$now) }
        }
        if((Get-CtzField $cc 'mode' '') -eq 'global' -and (Get-CtzField $all 'GLOBAL')) {
            $chain=@(Resolve-CtzSelectedChain $all 'GLOBAL');$chainDepth=$chain.Count
            $selections+=('ResolvedGlobalChain='+($chain -join '>'))
        }
    } catch { $controller=$null; $controllerError='ControllerUnavailableOrAmbiguous' }
    $tun=[bool](Get-CtzField (Get-CtzField $cc 'tun') 'enable' $false)
    $mixed=[int](Get-CtzField $cc 'mixed-port' 0); $http=[int](Get-CtzField $cc 'port' 0)
    $ownedPorts=@()
    if($cores.Count -gt 0) {
        foreach($port in @($mixed,$http)|Select-Object -Unique) {
            if($port -gt 0) {
                $listen=@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
                if(@($listen|Where-Object {$_.OwningProcess -in $cores.Id}).Count -gt 0) {$ownedPorts+=$port}
            }
        }
    }
    $path='Blocked'; $reason='UncertainEffectivePath'; $url=$null; $compareTun=$false
    if($foreignTunnels.Count -gt 0) { $reason='OtherActiveTunnel' }
    elseif($proxy.Pac) { $reason='PACorAutoDetectEnabled' }
    elseif($proxy.Enabled) {
        $resolved=Resolve-CtzProxy $proxy.Server
        if($controller -and $cores.Count -gt 0 -and $resolved -and $resolved.Port -in $ownedPorts) {
            $path='Proxy'; $reason='VerifiedSystemHttpProxy'; $url=$resolved.Url
            $compareTun=$tun -or $mihomoTunnels.Count -gt 0
            if($compareTun -and (!$tun -or $mihomoTunnels.Count -eq 0)) {$path='Blocked';$reason='TunStateMismatch'}
        } else {$reason='SystemProxyNotVerifiedAsMihomo'}
    } elseif($tun -and $mihomoTunnels.Count -gt 0 -and $controller -and $cores.Count -gt 0 -and $ownedPorts.Count -gt 0) {
        $path='TunMatched';$reason='TunNeedsExitComparison';$url='http://127.0.0.1:'+$ownedPorts[0];$compareTun=$true
    } elseif($gui.Count -eq 0 -and $cores.Count -eq 0 -and !$controller -and $tunnels.Count -eq 0 -and $adapters.Count -gt 0) {
        # An idle Verge service is only a supervisor, not evidence of an active proxy.
        $path='Direct';$reason='ClashExitedAndNoProxyOrTunnel'
    }
    $network=@($adapters|Sort-Object ifIndex|ForEach-Object {$_.Name+':'+$_.ifIndex+':'+$_.LinkSpeed})
    $routes=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Where-Object {$_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1')} | Sort-Object InterfaceIndex,DestinationPrefix | ForEach-Object {$_.DestinationPrefix+':'+$_.InterfaceIndex+':'+$_.NextHop+':'+$_.RouteMetric})
    $signature=Get-CtzHash ([ordered]@{Pids=@($processes|ForEach-Object {$_.Id}|Sort-Object);Proxy=[ordered]@{Enabled=$proxy.Enabled;Server=$proxy.Server;Pac=$proxy.Pac};Tun=$tun;Network=$network;Routes=$routes;Selection=@($selections|Sort-Object);Mode=(Get-CtzField $cc 'mode' '');Path=$path;Url=$url;Ports=@($ownedPorts|Sort-Object)}|ConvertTo-Json -Compress -Depth 6)
    return [pscustomobject]@{Signature=$signature;Path=$path;Reason=$reason;ProxyUrl=$url;CompareTun=$compareTun;GuiCount=$gui.Count;CoreCount=$cores.Count;ServiceRunning=($service -and $service.Status -eq 'Running');ControllerKind=$(if($controller){$controller.Kind}else{'Unavailable'});CoreVersion=$(if($controller){$controller.Version}else{''});Mode=(Get-CtzField $cc 'mode' 'Unknown');TunEnabled=$tun;ActiveTunnelCount=$tunnels.Count;SelectionCount=$selections.Count;GlobalChainDepth=$chainDepth;ObservedUtc=[DateTime]::UtcNow.ToString('o')}
}
function Test-CtzPublicIp([string]$Value) {
    $ip=$null
    if (![Net.IPAddress]::TryParse($Value,[ref]$ip)) { return $false }
    if([Net.IPAddress]::IsLoopback($ip)) {return $false}
    $b=$ip.GetAddressBytes()
    if($b.Length -eq 4) {
        if($b[0] -in @(0,10,127) -or $b[0] -ge 224 -or ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or ($b[0] -eq 198 -and $b[1] -in @(18,19)) -or ($Value -match '^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)')) { return $false }
    } else {
        if($ip.IsIPv6LinkLocal -or $ip.IsIPv6Multicast -or $ip.IsIPv6SiteLocal -or $ip.Equals([Net.IPAddress]::IPv6Any) -or ($b[0] -band 254) -eq 252 -or ($b[0] -eq 32 -and $b[1] -eq 1 -and $b[2] -eq 13 -and $b[3] -eq 184) -or $ip.IsIPv4MappedToIPv6) {return $false}
    }
    return $true
}
function Convert-CtzGeo([string]$Provider,$Json,[string]$ExpectedIp) {
    if($Provider -eq 'ipwho') {
        if((Get-CtzField $Json 'success' $false) -ne $true) {throw 'GeoProviderRejected'}
        $ip=[string](Get-CtzField $Json 'ip' '');$country=[string](Get-CtzField $Json 'country_code' '');$iana=[string](Get-CtzField (Get-CtzField $Json 'timezone') 'id' '')
    } elseif($Provider -eq 'ipapi') {
        if(Get-CtzField $Json 'error' $false) {throw 'GeoProviderRejected'}
        $ip=[string](Get-CtzField $Json 'ip' '');$country=[string](Get-CtzField $Json 'country_code' '');$iana=[string](Get-CtzField $Json 'timezone' '')
    } else {throw 'UnknownProvider'}
    if(!(Test-CtzPublicIp $ip) -or !([Net.IPAddress]::Parse($ip).Equals([Net.IPAddress]::Parse($ExpectedIp)))) {throw 'GeoIpMismatch'}
    $target=Resolve-CtzZone $country $iana
    return @{Country=$country;Iana=$iana;Target=$target}
}
function Resolve-CtzZone([string]$Country,[string]$Iana) {
    if(!$script:ZoneMap.ContainsKey($Iana)) {throw 'UnsupportedTimeZone'}
    if(($Country -eq 'JP' -and $Iana -eq 'Asia/Tokyo') -or ($Country -eq 'CN' -and $Iana -eq 'Asia/Shanghai') -or ($Country -eq 'US' -and $Iana -notmatch '^Asia/')) {
        $id=$script:ZoneMap[$Iana]
        if($null -eq (Get-TimeZone -Id $id -ErrorAction SilentlyContinue)) {throw 'WindowsZoneUnavailable'}
        return $id
    }
    throw 'CountryTimeZoneConflict'
}
function Get-CtzBackoff([int]$Failures,$Config) {
    return [int][Math]::Min($Config.MaxBackoffSeconds,$Config.FailureBackoffSeconds*[Math]::Pow(2,[Math]::Min(10,[Math]::Max(0,$Failures-1))))
}
function Invoke-CtzHttps([string]$Url,[string]$ProxyUrl,[string]$Provider,$Config,[string]$StateDirectory) {
    if($Url -notmatch '^https://(api\.ipify\.org|api64\.ipify\.org|ipwho\.is|ipapi\.co)/') {throw 'ExternalEndpointDenied'}
    $budgetFile=Join-Path $StateDirectory 'budget.json'
    $old=Read-CtzJson $budgetFile
    $today=[DateTime]::UtcNow.ToString('yyyy-MM-dd')
    $counts=@{}; $notBefore=[DateTime]::SpecifyKind([datetime]'1970-01-01',[DateTimeKind]::Utc)
    if($old) {
        $n=Get-CtzField $old 'NotBeforeUtc'
        if($n) {$notBefore=ConvertTo-CtzUtc $n}
        if($old.Day -eq $today) {foreach($p in $old.Counts.PSObject.Properties){$counts[$p.Name]=[int]$p.Value}}
    }
    if([DateTime]::UtcNow -lt $notBefore) {throw ('RetryAfter:'+ [int][Math]::Ceiling(($notBefore-[DateTime]::UtcNow).TotalSeconds))}
    $limit=$Config.GeoDailyLimit
    if($Provider -match '^echo') {$limit=$Config.EchoDailyLimit}
    $count=0;if($counts.ContainsKey($Provider)){$count=$counts[$Provider]}
    if($count -ge $limit) {throw 'DailyBudgetExhausted'}
    $counts[$Provider]=$count+1
    $budget=@{Day=$today;Counts=$counts;NotBeforeUtc=$notBefore.ToString('o')}
    Write-CtzJson $budgetFile $budget
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r=[Net.HttpWebRequest]::Create($Url)
    $r.Timeout=$Config.RequestTimeoutSeconds*1000;$r.ReadWriteTimeout=$r.Timeout
    $r.AllowAutoRedirect=$false;$r.UserAgent='ClashTimeZone/1.0';$r.KeepAlive=$false
    $r.CachePolicy=[Net.Cache.RequestCachePolicy]::new([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    $r.Headers['Cache-Control']='no-cache, no-store';$r.Headers['Pragma']='no-cache'
    if($ProxyUrl){$r.Proxy=[Net.WebProxy]::new($ProxyUrl,$false)}else{$r.Proxy=$null}
    $response=$null;$reader=$null
    try {
        $response=$r.GetResponse()
        if([int]$response.StatusCode -ne 200){throw 'HttpFailure'}
        $reader=[IO.StreamReader]::new($response.GetResponseStream());$text=$reader.ReadToEnd()
        if($text.Length -gt 65536){throw 'ResponseTooLarge'}
        return ($text|ConvertFrom-Json)
    } catch {
        $errResponse=Get-CtzField $_.Exception 'Response'
        if($errResponse -and [int]$errResponse.StatusCode -eq 429) {
            $seconds=900;$rawRetry=$errResponse.Headers['Retry-After'];$number=0;$retryDate=[DateTime]::MinValue
            if([int]::TryParse($rawRetry,[ref]$number)){$seconds=[Math]::Max(30,$number)}
            elseif([DateTime]::TryParse($rawRetry,[ref]$retryDate)){$seconds=[Math]::Max(30,[int]($retryDate.ToUniversalTime()-[DateTime]::UtcNow).TotalSeconds)}
            $budget.NotBeforeUtc=[DateTime]::UtcNow.AddSeconds($seconds).ToString('o');Write-CtzJson $budgetFile $budget
            throw ('RetryAfter:'+$seconds)
        }
        # Never log Exception.Message: it may contain an IP-bearing URL or header.
        throw 'HttpsTimeoutDnsJsonOrHttpFailure'
    } finally {if($reader){$reader.Dispose()};if($response){$response.Dispose()}}
}
function Get-CtzEcho([string]$ProxyUrl,$Config,[string]$StateDirectory) {
    $nonce=[guid]::NewGuid().ToString('N')
    $a=Invoke-CtzHttps ('https://api.ipify.org/?format=json&ctz='+$nonce) $ProxyUrl 'echo4' $Config $StateDirectory
    $b=Invoke-CtzHttps ('https://api64.ipify.org/?format=json&ctz='+$nonce) $ProxyUrl 'echo64' $Config $StateDirectory
    $ip=[string](Get-CtzField $a 'ip' '');$other=[string](Get-CtzField $b 'ip' '')
    return (Convert-CtzExitPair $ip $other)
}
function Convert-CtzExitPair([string]$Ipv4,[string]$DualStack) {
    if(!(Test-CtzPublicIp $Ipv4) -or !(Test-CtzPublicIp $DualStack)) {throw 'InvalidPublicIp'}
    $a=[Net.IPAddress]::Parse($Ipv4);$b=[Net.IPAddress]::Parse($DualStack)
    if($a.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Ipv4EndpointFamilyMismatch'}
    if($b.AddressFamily -eq $a.AddressFamily -and !$a.Equals($b)){throw 'SameFamilyDomainExitMismatch'}
    # A stable IPv4/IPv6 pair is accepted only after both families independently
    # pass two-provider geography, and the whole pair matches on confirmation.
    $ips=@(@($a.ToString(),$b.ToString())|Sort-Object -Unique)
    return @{Ips=$ips;Key=($ips -join '|');HasIpv6=($b.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6)}
}
function Get-CtzObservation($Snapshot,$Config,[string]$StateDirectory) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $result=@{Valid=$false;Reason=$Snapshot.Reason;Signature=$Snapshot.Signature;Nonce=[guid]::NewGuid().ToString('N');Path=$Snapshot.Path;Target='';Country='';Iana='';IpHash='';IpMasked='';RetrySeconds=0;ProbeMs=0;CompletedUtc=''}
    try {
        if($Snapshot.Path -eq 'Blocked') {return [pscustomobject]$result}
        $exit=Get-CtzEcho $Snapshot.ProxyUrl $Config $StateDirectory
        if($Snapshot.CompareTun) {
            $osExit=Get-CtzEcho '' $Config $StateDirectory
            if($osExit.Key -ne $exit.Key) {throw 'TunAndSystemProxyExitMismatch'}
        }
        $geos=@()
        foreach($ip in $exit.Ips) {
            $cached=Get-CtzField $script:GeoCache $ip
            if(!$cached -or ([DateTime]::UtcNow-$cached.Utc).TotalSeconds -gt $Config.GeoCacheSeconds) {
                $g1=Convert-CtzGeo 'ipwho' (Invoke-CtzHttps ('https://ipwho.is/'+$ip) $Snapshot.ProxyUrl 'ipwho' $Config $StateDirectory) $ip
                $g2=Convert-CtzGeo 'ipapi' (Invoke-CtzHttps ('https://ipapi.co/'+$ip+'/json/') $Snapshot.ProxyUrl 'ipapi' $Config $StateDirectory) $ip
                if($g1.Country -ne $g2.Country -or $g1.Target -ne $g2.Target){throw 'GeoProvidersConflict'}
                $cached=@{Utc=[DateTime]::UtcNow;Country=$g1.Country;Target=$g1.Target;Iana=$g1.Iana}
                if($script:GeoCache.Count -ge 256){$script:GeoCache.Clear()}
                $script:GeoCache[$ip]=$cached
            }
            $geos+=,$cached
        }
        $cache=$geos[0]
        foreach($g in $geos){if($g.Country -ne $cache.Country -or $g.Target -ne $cache.Target){throw 'Ipv4Ipv6GeoConflict'}}
        if($Snapshot.Path -eq 'Direct' -and $cache.Country -ne 'CN'){throw 'DirectExitNotMainlandChina'}
        if($Snapshot.Path -ne 'Direct' -and $cache.Country -notin @('JP','US')){throw 'ProxyExitNotSupportedJapanOrUS'}
        $result.Valid=$true;$result.Reason='TwoGeoProvidersAgree';$result.Target=$cache.Target;$result.Country=$cache.Country;$result.Iana=$cache.Iana
        $result.IpHash=Get-CtzHash ('ClashTimeZone:'+$exit.Key)
        $masked=@(foreach($ip in $exit.Ips){if($ip -match ':'){(($ip -split ':')[0..1]-join ':')+':***'}else{(($ip -split '\.')[0..1]-join '.')+'.*.*'}})
        $result.IpMasked=$masked -join ' / '
    } catch {
        $code=$_.Exception.Message
        $allowed=@('InvalidPublicIp','Ipv4EndpointFamilyMismatch','SameFamilyDomainExitMismatch','Ipv4Ipv6GeoConflict','TunAndSystemProxyExitMismatch','GeoProvidersConflict','DirectExitNotMainlandChina','ProxyExitNotSupportedJapanOrUS','GeoProviderRejected','GeoIpMismatch','UnsupportedTimeZone','WindowsZoneUnavailable','CountryTimeZoneConflict','DailyBudgetExhausted')
        if($code -match '^RetryAfter:(\d+)$'){$result.Reason='RateLimited';$result.RetrySeconds=[int]$Matches[1]}
        elseif($code -in $allowed){$result.Reason=$code}
        else{$result.Reason='NetworkOrProviderFailure'}
    } finally {$result.ProbeMs=$watch.ElapsedMilliseconds;$result.CompletedUtc=[DateTime]::UtcNow.ToString('o')}
    return [pscustomobject]$result
}
function New-CtzDecisionState { return @{Candidate=$null;LastChangeAt=-1.0e12} }
function Get-CtzDecision($State,$Observation,[double]$Now,[string]$CurrentZone,$Config,[bool]$Paused=$false) {
    if($Paused -or !$Observation.Valid) {$State.Candidate=$null;return @{Action='Keep';Reason=$(if($Paused){'Paused'}else{$Observation.Reason})}}
    if($Observation.Target -eq $CurrentZone){$State.Candidate=$null;return @{Action='Keep';Reason='AlreadyCorrect'}}
    if($Observation.Path -notin @('Proxy','TunMatched','Direct') -or ($Observation.Path -eq 'Direct' -and $Observation.Country -ne 'CN') -or ($Observation.Path -ne 'Direct' -and $Observation.Country -notin @('JP','US'))) {$State.Candidate=$null;return @{Action='Keep';Reason='UntrustedPath'}}
    try {$expected=Resolve-CtzZone $Observation.Country $Observation.Iana;if($expected -ne $Observation.Target){throw 'TargetMismatch'}}catch{$State.Candidate=$null;return @{Action='Keep';Reason='InvalidCountryZone'}}
    $key=$Observation.Signature+':'+$Observation.IpHash+':'+$Observation.Country+':'+$Observation.Target
    $candidate=$State.Candidate
    if(!$candidate -or $candidate.Key -ne $key -or $Now-$candidate.FirstAt -gt $Config.ConfirmationMaxAgeSeconds) {
        $State.Candidate=@{Key=$key;FirstAt=$Now;Nonce=$Observation.Nonce}
        return @{Action='Confirm';Reason='FirstFreshObservation'}
    }
    if($candidate.Nonce -eq $Observation.Nonce){return @{Action='Confirm';Reason='DuplicateObservationRejected'}}
    if($Now-$candidate.FirstAt -lt $Config.ConfirmationSeconds){return @{Action='Confirm';Reason='ConfirmationIntervalNotReached'}}
    if($Now-$State.LastChangeAt -lt $Config.MinimumChangeIntervalSeconds){return @{Action='Cooldown';Reason='MinimumChangeInterval'}}
    return @{Action='Change';Reason='TwoFreshConsistentObservations';Target=$Observation.Target}
}
function Set-CtzVerifiedZone([string]$Target) {
    if($Target -notin @($script:ZoneMap.Values|Select-Object -Unique)){throw 'TargetNotWhitelisted'}
    if((Get-TimeZone).Id -eq $Target){return}
    Set-TimeZone -Id $Target -ErrorAction Stop
    if((Get-TimeZone).Id -ne $Target){throw 'TimeZoneWriteVerificationFailed'}
}
function Test-CtzAutomaticZoneConflict {
    $r=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate'
    $svc=Get-Service tzautoupdate
    # Microsoft documents Start=3 as enabled, even while the trigger-start
    # service is stopped. Only Start=4 is confirmed disabled; fail closed.
    return ([int]$r.Start -ne 4 -or $svc.Status -eq 'Running')
}
function Test-CtzInstallation([string]$Root,[switch]$RequireEnabled) {
    $m=Read-CtzJson (Join-Path $Root 'installation.json')
    if(!$m -or $m.Product -ne 'ClashTimeZone' -or [IO.Path]::GetFullPath($m.InstallDirectory) -ne [IO.Path]::GetFullPath($Root) -or $m.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'ValidInstallationRequired'}
    if($RequireEnabled -and !$m.AutomaticSwitchingEnabled){throw 'AutomaticSwitchingNotAuthorized'}
    return $m
}
Export-ModuleMember -Function *-Ctz*
