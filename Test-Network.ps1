# OFFLINE fault-injection: substitutes only this module's HTTP function in this
# process, restores it in finally, never sends a request or changes any time zone.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking -PassThru
$config=Get-CtzConfig;$before=(Get-TimeZone).Id
$rows=[Collections.Generic.List[object]]::new()
$saved=& $module {(Get-Command Invoke-CtzHttps).ScriptBlock}
try {
 & $module {
    $script:InjectedScenario='ok';$script:InjectedCalls=0
    function script:Invoke-CtzHttps([string]$Url,[string]$ProxyUrl,[string]$Provider,$Config,[string]$StateDirectory){
        $script:InjectedCalls++
        if($script:InjectedScenario -eq '429'){throw 'RetryAfter:1234'}
        if($script:InjectedScenario -in @('timeout','dns','invalid-json','offline')){throw 'HttpsTimeoutDnsJsonOrHttpFailure'}
        if($Provider -match '^echo'){
            if($script:InjectedScenario -eq 'tun-mismatch' -and !$ProxyUrl){return @{ip='1.1.1.1'}}
            if($Provider -eq 'echo64'){return @{ip='2606:4700:4700::1111'}}
            return @{ip='8.8.8.8'}
        }
        $ip='8.8.8.8';if($Url -match '2606:4700:4700::1111'){$ip='2606:4700:4700::1111'}
        $country='JP';$iana='Asia/Tokyo'
        if(($script:InjectedScenario -eq 'geo-conflict' -and $Provider -eq 'ipapi') -or ($script:InjectedScenario -eq 'v6-conflict' -and $ip -match ':')){$country='US';$iana='America/New_York'}
        if($script:InjectedScenario -eq 'country-conflict'){$country='JP';$iana='America/New_York'}
        if($Provider -eq 'ipwho'){return @{success=$true;ip=$ip;country_code=$country;timezone=@{id=$iana}}}
        return @{ip=$ip;country_code=$country;timezone=$iana}
    }
 }
 foreach($pair in @(@('ok','TwoGeoProvidersAgree'),@('429','RateLimited'),@('timeout','NetworkOrProviderFailure'),@('dns','NetworkOrProviderFailure'),@('invalid-json','NetworkOrProviderFailure'),@('offline','NetworkOrProviderFailure'),@('geo-conflict','GeoProvidersConflict'),@('v6-conflict','Ipv4Ipv6GeoConflict'),@('country-conflict','CountryTimeZoneConflict'),@('tun-mismatch','TunAndSystemProxyExitMismatch'))){
    $scenario=$pair[0];$expected=$pair[1]
    & $module {param($Scenario) $script:InjectedScenario=$Scenario;$script:InjectedCalls=0;$script:GeoCache.Clear()} $scenario
    $snapshot=[pscustomobject]@{Path='Proxy';ProxyUrl='http://127.0.0.1:7897';CompareTun=$true;Signature='offline-snapshot';Reason='OfflineFixture'}
    $o=Get-CtzObservation $snapshot $config 'unused-offline-path'
    $pass=$o.Reason -eq $expected
    if($scenario -eq 'ok'){$pass=$pass -and $o.Valid -and $o.Target -eq 'Tokyo Standard Time'}
    if($scenario -eq '429'){$pass=$pass -and $o.RetrySeconds -eq 1234}
    if($scenario -ne 'ok'){$pass=$pass -and !$o.Valid}
    $rows.Add([pscustomobject]@{Scenario=$scenario;Expected=$expected;Actual=$o.Reason;Result=$(if($pass){'PASS'}else{'FAIL'})})
 }
 & $module {$script:InjectedScenario='ok';$script:InjectedCalls=0;$script:GeoCache.Clear()}
 $snapshot=[pscustomobject]@{Path='Proxy';ProxyUrl='http://127.0.0.1:7897';CompareTun=$false;Signature='offline-snapshot';Reason='OfflineFixture'}
 $a=Get-CtzObservation $snapshot $config 'unused-offline-path';$calls1=& $module {$script:InjectedCalls}
 $b=Get-CtzObservation $snapshot $config 'unused-offline-path';$calls2=& $module {$script:InjectedCalls}
 $pass=$a.Valid -and $b.Valid -and $a.Nonce -ne $b.Nonce -and $calls1 -eq 6 -and $calls2-$calls1 -eq 2
 $rows.Add([pscustomobject]@{Scenario='geo cache still requires fresh IP requests';Actual=('first='+$calls1+',second='+($calls2-$calls1));Result=$(if($pass){'PASS'}else{'FAIL'})})
} finally {& $module {param($Original) Set-Item -LiteralPath 'Function:script:Invoke-CtzHttps' -Value $Original;$script:GeoCache.Clear()} $saved}
$unchanged=(Get-TimeZone).Id -eq $before
$rows.Add([pscustomobject]@{Scenario='real system time zone unchanged';Result=$(if($unchanged){'PASS'}else{'FAIL'})})
$failed=@($rows|Where-Object {$_.Result -eq 'FAIL'})
$report=[pscustomobject]@{Mode='Offline injected HTTP responses; zero real API calls';Passed=$rows.Count-$failed.Count;Failed=$failed.Count;Tests=$rows.ToArray()}
if($ReportPath){Write-CtzJson $ReportPath $report}
$report|ConvertTo-Json -Depth 6
if($failed.Count){throw 'Network fault injection tests failed'}
