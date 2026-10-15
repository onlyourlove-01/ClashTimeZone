# OFFLINE local-environment injection; it does not change processes or adapters.
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking -PassThru
$config=Get-CtzConfig;$rows=[Collections.Generic.List[object]]::new()
$before=(Get-TimeZone).Id
$names=@('Get-Process','Get-Service','Get-NetAdapter','Get-NetRoute','Get-NetTCPConnection','Get-CtzSystemProxy','Get-CtzController','Invoke-CtzController')
$saved=@{}
foreach($n in $names){$cmd=& $m {param($Name)Get-Command $Name} $n;if($cmd.CommandType -eq 'Function'){$saved[$n]=$cmd.ScriptBlock}}
try {
 & $m {
    $script:LocalScenario='direct'
    function script:Get-Process {if($script:LocalScenario -notin @('direct','foreign','pac','offline')){if($script:LocalScenario -ne 'tray-only'){[pscustomobject]@{ProcessName='clash-verge';Id=20}};[pscustomobject]@{ProcessName='verge-mihomo';Id=21}}}
    function script:Get-Service {return [pscustomobject]@{Status='Running'}}
    function script:Get-NetAdapter {
        if($script:LocalScenario -eq 'offline'){return}
        [pscustomobject]@{Name='WiFi';Status='Up';InterfaceDescription='Physical WLAN';ifIndex=1;LinkSpeed='100 Mbps'}
        if($script:LocalScenario -in @('proxy-tun','tray-only','tun-only')){[pscustomobject]@{Name='Mihomo';Status='Up';InterfaceDescription='Meta Tunnel';ifIndex=2;LinkSpeed='100 Gbps'}}
        if($script:LocalScenario -eq 'foreign'){[pscustomobject]@{Name='Other VPN';Status='Up';InterfaceDescription='WireGuard Tunnel';ifIndex=3;LinkSpeed='1 Gbps'}}
    }
    function script:Get-NetRoute {[pscustomobject]@{DestinationPrefix='0.0.0.0/0';InterfaceIndex=1;NextHop='192.168.1.1';RouteMetric=10}}
    function script:Get-NetTCPConnection {[pscustomobject]@{OwningProcess=21}}
    function script:Get-CtzSystemProxy {return @{Enabled=($script:LocalScenario -in @('proxy','proxy-tun','tray-only','wrong-port','controller-failed'));Server=$(if($script:LocalScenario -eq 'wrong-port'){'127.0.0.1:1234'}else{'127.0.0.1:7897'});Pac=($script:LocalScenario -eq 'pac')}}
    function script:Get-CtzController {if($script:LocalScenario -in @('direct','foreign','pac','offline','controller-failed')){throw 'NoController'};return @{Kind='Pipe';Address='test-fixture';Version='v1.2.3';Secret=$null}}
    function script:Invoke-CtzController($Controller,[string]$Endpoint){if($Endpoint -eq '/configs'){return @{'mixed-port'=7897;port=7899;mode='rule';tun=@{enable=($script:LocalScenario -in @('proxy-tun','tray-only','tun-only'))}}};return [pscustomobject]@{proxies=[pscustomobject]@{GLOBAL=[pscustomobject]@{now='selection'}}}}
 }
 foreach($case in @(@('direct','Direct'),@('proxy','Proxy'),@('proxy-tun','Proxy'),@('tray-only','Proxy'),@('tun-only','TunMatched'),@('wrong-port','Blocked'),@('controller-failed','Blocked'),@('foreign','Blocked'),@('pac','Blocked'),@('offline','Blocked'))){
    $scenario=$case[0];$expected=$case[1]
    & $m {param($Case)$script:LocalScenario=$Case} $scenario
    try{$s=Get-CtzSnapshot $config;$actual=$s.Path;$pass=$actual -eq $expected;$rows.Add([pscustomobject]@{Scenario=$scenario;Expected=$expected;Actual=$actual;Result=$(if($pass){'PASS'}else{'FAIL'})})}
    catch{$rows.Add([pscustomobject]@{Scenario=$scenario;Result='FAIL';Error=$_.Exception.Message})}
 }
}finally{
 & $m {param($Names,$Saved)foreach($n in $Names){if($Saved.ContainsKey($n)){Set-Item -LiteralPath ('Function:script:'+$n) -Value $Saved[$n]}else{Remove-Item -LiteralPath ('Function:script:'+$n) -ErrorAction SilentlyContinue}}} $names $saved
}
$failed=@($rows|Where-Object {$_.Result -eq 'FAIL'})
if((Get-TimeZone).Id -ne $before){throw 'TimeZoneChangedUnexpectedly'}
$report=@{Mode='Offline local environment injection; no real network or time zone writes';Passed=$rows.Count-$failed.Count;Failed=$failed.Count;Tests=$rows.ToArray()}
if($ReportPath){Write-CtzJson $ReportPath $report}
$report|ConvertTo-Json -Depth 5
if($failed.Count){throw 'Local snapshot tests failed'}
