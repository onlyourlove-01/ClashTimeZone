[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
$config=Get-CtzConfig;$initialZone=(Get-TimeZone).Id
$results=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add([pscustomobject]@{Name=$Name;Result='PASS'})}
    catch{$results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Error=$_.Exception.Message})}
}
function Equal($Actual,$Expected){if($Actual -ne $Expected){throw ('Expected='+$Expected+'; Actual='+$Actual)}}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};if(!$rejected){throw 'Expected rejection'}}
function Observation([string]$Country='JP',[string]$Iana='Asia/Tokyo',[string]$Path='Proxy',[string]$IpHash='ip-a',[string]$Signature='route-a'){
    return [pscustomobject]@{Valid=$true;Reason='TwoGeoProvidersAgree';Country=$Country;Iana=$Iana;Path=$Path;IpHash=$IpHash;Signature=$Signature;Target=(Resolve-CtzZone $Country $Iana);Nonce=[guid]::NewGuid().ToString('N')}
}
foreach($pair in @(
 @('JP','Asia/Tokyo','Tokyo Standard Time'),@('US','America/Los_Angeles','Pacific Standard Time'),
 @('US','America/New_York','Eastern Standard Time'),@('US','America/Phoenix','US Mountain Standard Time'),
 @('US','America/Denver','Mountain Standard Time'),@('US','America/Chicago','Central Standard Time'),
 @('US','America/Anchorage','Alaskan Standard Time'),@('US','Pacific/Honolulu','Hawaiian Standard Time'),
 @('US','America/Adak','Aleutian Standard Time'),@('CN','Asia/Shanghai','China Standard Time')
)){
    $country=$pair[0];$iana=$pair[1];$target=$pair[2]
    Check ('Map '+$country+' '+$iana) {Equal (Resolve-CtzZone $country $iana) $target}
}
Check 'Japan requires two spaced live observations' {
 $s=New-CtzDecisionState;Equal (Get-CtzDecision $s (Observation) 0 'China Standard Time' $config).Action 'Confirm'
 Equal (Get-CtzDecision $s (Observation) 5 'China Standard Time' $config).Action 'Change'
}
Check 'Los Angeles confirmation' {$s=New-CtzDecisionState;$a=Observation 'US' 'America/Los_Angeles';$null=Get-CtzDecision $s $a 0 'China Standard Time' $config;Equal (Get-CtzDecision $s (Observation 'US' 'America/Los_Angeles') 5 'China Standard Time' $config).Target 'Pacific Standard Time'}
Check 'Exited Clash plus verified mainland direct restores China' {$s=New-CtzDecisionState;$null=Get-CtzDecision $s (Observation 'CN' 'Asia/Shanghai' 'Direct') 0 'Tokyo Standard Time' $config;Equal (Get-CtzDecision $s (Observation 'CN' 'Asia/Shanghai' 'Direct') 5 'Tokyo Standard Time' $config).Target 'China Standard Time'}
Check 'Boot without Clash follows same verified direct policy' {$s=New-CtzDecisionState;Equal (Get-CtzDecision $s (Observation 'CN' 'Asia/Shanghai' 'Direct') 0 'Eastern Standard Time' $config).Action 'Confirm'}
Check 'Closing GUI alone cannot force China' {$s=New-CtzDecisionState;Equal (Get-CtzDecision $s (Observation 'JP' 'Asia/Tokyo' 'TunMatched') 0 'Tokyo Standard Time' $config).Reason 'AlreadyCorrect'}
Check 'Duplicate cached observation cannot confirm' {$s=New-CtzDecisionState;$a=Observation;$null=Get-CtzDecision $s $a 0 'China Standard Time' $config;Equal (Get-CtzDecision $s $a 5 'China Standard Time' $config).Reason 'DuplicateObservationRejected'}
Check 'Insufficient confirmation interval' {$s=New-CtzDecisionState;$null=Get-CtzDecision $s (Observation) 0 'China Standard Time' $config;Equal (Get-CtzDecision $s (Observation) 2 'China Standard Time' $config).Action 'Confirm'}
Check 'Expired confirmation starts over' {$s=New-CtzDecisionState;$null=Get-CtzDecision $s (Observation) 0 'China Standard Time' $config;Equal (Get-CtzDecision $s (Observation) 61 'China Standard Time' $config).Reason 'FirstFreshObservation'}
Check 'Node change invalidates confirmation' {$s=New-CtzDecisionState;$null=Get-CtzDecision $s (Observation) 0 'China Standard Time' $config;Equal (Get-CtzDecision $s (Observation 'JP' 'Asia/Tokyo' 'Proxy' 'ip-a' 'route-b') 5 'China Standard Time' $config).Action 'Confirm'}
Check 'Exit IP change invalidates confirmation' {$s=New-CtzDecisionState;$null=Get-CtzDecision $s (Observation) 0 'China Standard Time' $config;Equal (Get-CtzDecision $s (Observation 'JP' 'Asia/Tokyo' 'Proxy' 'ip-b') 5 'China Standard Time' $config).Action 'Confirm'}
Check 'Minimum change cooldown' {$s=New-CtzDecisionState;$s.LastChangeAt=0;$null=Get-CtzDecision $s (Observation) 10 'China Standard Time' $config;Equal (Get-CtzDecision $s (Observation) 15 'China Standard Time' $config).Action 'Cooldown'}
Check 'Correct current time zone never writes' {$s=New-CtzDecisionState;Equal (Get-CtzDecision $s (Observation) 5 'Tokyo Standard Time' $config).Reason 'AlreadyCorrect'}
foreach($reason in @('RateLimited','NetworkOrProviderFailure','InvalidJson','DnsFailure','Offline','GeoProvidersConflict','TunAndSystemProxyExitMismatch','Ipv4Ipv6OrDomainExitMismatch','UncertainEffectivePath')){
 Check ('Fault keeps current zone: '+$reason) {$s=New-CtzDecisionState;$null=Get-CtzDecision $s (Observation) 0 'China Standard Time' $config;$bad=[pscustomobject]@{Valid=$false;Reason=$reason};Equal (Get-CtzDecision $s $bad 5 'China Standard Time' $config).Action 'Keep';Equal ($null -eq $s.Candidate) $true}
}
Check 'Country/time zone contradictions rejected' {Reject {Resolve-CtzZone 'JP' 'America/New_York'};Reject {Resolve-CtzZone 'CN' 'Asia/Tokyo'}}
Check 'HK MO TW are never mainland China' {foreach($c in @('HK','MO','TW')){Reject {Resolve-CtzZone $c 'Asia/Shanghai'}}}
Check 'Unsupported direct overseas exit does not restore China' {$a=Observation;$a.Path='Direct';$s=New-CtzDecisionState;Equal (Get-CtzDecision $s $a 0 'Eastern Standard Time' $config).Action 'Keep'}
Check 'China through active proxy cannot force fallback' {$a=Observation 'CN' 'Asia/Shanghai' 'Proxy';$s=New-CtzDecisionState;Equal (Get-CtzDecision $s $a 0 'Tokyo Standard Time' $config).Action 'Keep'}
Check 'Pause clears candidate' {$s=New-CtzDecisionState;$null=Get-CtzDecision $s (Observation) 0 'China Standard Time' $config;Equal (Get-CtzDecision $s (Observation) 5 'China Standard Time' $config $true).Reason 'Paused';Equal ($null -eq $s.Candidate) $true}
Check 'Resume needs new confirmations' {$s=New-CtzDecisionState;Equal (Get-CtzDecision $s (Observation) 100 'China Standard Time' $config).Action 'Confirm'}
Check 'Restart discards old confirmation' {$s=New-CtzDecisionState;$null=Get-CtzDecision $s (Observation) 0 'China Standard Time' $config;$s=New-CtzDecisionState;Equal (Get-CtzDecision $s (Observation) 5 'China Standard Time' $config).Action 'Confirm'}
Check 'Backoff grows and is capped' {Equal (Get-CtzBackoff 1 $config) 30;Equal (Get-CtzBackoff 2 $config) 60;Equal (Get-CtzBackoff 20 $config) 900}
Check 'Reject private, loopback, CGNAT, fake-IP and invalid answers' {foreach($ip in @('10.0.0.1','127.0.0.1','100.64.0.1','198.18.0.1','192.168.0.1','::1','fc00::1','fe80::1','2001:db8::1','203.0.113.1','not-an-ip')){Equal (Test-CtzPublicIp $ip) $false};Equal (Test-CtzPublicIp '8.8.8.8') $true;Equal (Test-CtzPublicIp '2606:4700:4700::1111') $true}
Check 'Provider schema ipwho and ipapi are distinct' {$g=Convert-CtzGeo 'ipwho' ([pscustomobject]@{success=$true;ip='8.8.8.8';country_code='US';timezone=@{id='America/Los_Angeles'}}) '8.8.8.8';Equal $g.Target 'Pacific Standard Time';$g=Convert-CtzGeo 'ipapi' ([pscustomobject]@{ip='8.8.8.8';country_code='US';timezone='America/Los_Angeles'}) '8.8.8.8';Equal $g.Target 'Pacific Standard Time'}
Check 'Provider wrong IP rejected' {Reject {Convert-CtzGeo 'ipapi' ([pscustomobject]@{ip='1.1.1.1';country_code='US';timezone='America/Los_Angeles'}) '8.8.8.8'}}
Check 'Provider success false rejected' {Reject {Convert-CtzGeo 'ipwho' ([pscustomobject]@{success=$false}) '8.8.8.8'}}
Check 'Provider missing fields rejected' {Reject {Convert-CtzGeo 'ipapi' ([pscustomobject]@{}) '8.8.8.8'}}
Check 'Only loopback system HTTPS proxy accepted' {Equal (Resolve-CtzProxy '127.0.0.1:7897').Port 7897;Equal ($null -eq (Resolve-CtzProxy '192.168.1.1:7897')) $true;Equal (Resolve-CtzProxy 'http=127.0.0.1:7899;https=127.0.0.1:7897').Port 7897}
Check 'Phoenix and Hawaii do not have DST; New York does' {Equal (Get-TimeZone -Id 'US Mountain Standard Time').SupportsDaylightSavingTime $false;Equal (Get-TimeZone -Id 'Hawaiian Standard Time').SupportsDaylightSavingTime $false;Equal (Get-TimeZone -Id 'Eastern Standard Time').SupportsDaylightSavingTime $true}
Check 'Winter/summer actual UTC offsets use Windows DST rules' {$winter=[datetime]::SpecifyKind([datetime]'2026-01-15T12:00:00',[DateTimeKind]::Utc);$summer=[datetime]::SpecifyKind([datetime]'2026-07-15T12:00:00',[DateTimeKind]::Utc);$pacific=[TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time');Equal $pacific.GetUtcOffset($winter).TotalHours -8;Equal $pacific.GetUtcOffset($summer).TotalHours -7;$phoenix=[TimeZoneInfo]::FindSystemTimeZoneById('US Mountain Standard Time');Equal $phoenix.GetUtcOffset($winter).TotalHours -7;Equal $phoenix.GetUtcOffset($summer).TotalHours -7}
Check 'Controller mutation endpoints denied before connecting' {Reject {Invoke-CtzPipeGet 'unused' '/configs/geo'};Reject {Invoke-CtzController @{Kind='Tcp';Address='127.0.0.1:1';Secret=$null} '/restart'}}
Check 'Apply denied from uninstalled directory' {Reject {Test-CtzInstallation (Join-Path $PSScriptRoot 'not-an-installation') -RequireEnabled}}
Check 'Dual-stack pair may differ by family but not within IPv4' {$p=Convert-CtzExitPair '8.8.8.8' '2606:4700:4700::1111';Equal $p.Ips.Count 2;Equal $p.HasIpv6 $true;Reject {Convert-CtzExitPair '8.8.8.8' '1.1.1.1'}}
Check 'Nested selected groups resolve and cycles reject' {$p=[pscustomobject]@{GLOBAL=@{now='group'};group=@{now='leaf'};leaf=@{type='ss'}};$chain=@(Resolve-CtzSelectedChain $p 'GLOBAL');Equal ($chain -join '>') 'GLOBAL>group>leaf';$cycle=[pscustomobject]@{a=@{now='b'};b=@{now='a'}};Reject {Resolve-CtzSelectedChain $cycle 'a'}}
Check 'UTC JSON values work as strings and DateTime objects' {$utc=[datetime]::SpecifyKind([datetime]'2026-10-15T12:00:00',[DateTimeKind]::Utc);Equal (ConvertTo-CtzUtc $utc).Ticks $utc.Ticks;Equal (ConvertTo-CtzUtc '2026-10-15T12:00:00Z').Ticks $utc.Ticks}
Check 'Legacy no-backoff sentinel cannot underflow in UTC+8' {Equal (ConvertTo-CtzUtc '0001-01-01T00:00:00.0000000').Ticks 0}
Check 'Atomic status JSON updates leave readable last value' {$dir=Join-Path $PSScriptRoot ('test-scratch-'+[guid]::NewGuid().ToString('N'));$path=Join-Path $dir 'state.json';try{Write-CtzJson $path @{Value=1};Write-CtzJson $path @{Value=2};Equal (Read-CtzJson $path).Value 2;Equal @(Get-ChildItem -LiteralPath $dir -File).Count 1}finally{if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force};if(Test-Path -LiteralPath $dir){Remove-Item -LiteralPath $dir -Force}}}
Check 'Real time zone unchanged by all offline simulations' {Equal (Get-TimeZone).Id $initialZone}
$failed=@($results|Where-Object {$_.Result -ne 'PASS'})
$summary=[pscustomobject]@{Mode='Offline simulation; no API calls and no Set-TimeZone';Utc=[DateTime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();Passed=$results.Count-$failed.Count;Failed=$failed.Count;RealTimeZoneBefore=$initialZone;RealTimeZoneAfter=(Get-TimeZone).Id;Tests=$results.ToArray()}
if($ReportPath){Write-CtzJson $ReportPath $summary}
$summary|ConvertTo-Json -Depth 8
if($failed.Count -gt 0){throw ('Offline tests failed: '+$failed.Count)}
