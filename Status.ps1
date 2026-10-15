[CmdletBinding()]
param([switch]$Logs,[int]$Tail=30,[string]$StateDirectory='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
if(!$StateDirectory){if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installation.json')){$StateDirectory=Get-CtzStateDirectory}else{$StateDirectory=Join-Path $PSScriptRoot 'preview-data'}}
$state=Read-CtzJson (Join-Path $StateDirectory 'status.json')
$mutex=[Threading.Mutex]::new($false,(Get-CtzMutexName));$taken=$false
try{try{$taken=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$taken=$true};$running=!$taken}finally{if($taken){$mutex.ReleaseMutex()};$mutex.Dispose()}
$health='Stopped'
if($running){$health='RunningWithoutHeartbeat';if($state -and ([DateTime]::UtcNow-(ConvertTo-CtzUtc $state.HeartbeatUtc)).TotalSeconds -lt 20){$health='Running'}}
[pscustomobject]@{Product='ClashTimeZone';Health=$health;Installed=(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installation.json'));CurrentZone=(Get-TimeZone).Id;StateDirectory=$StateDirectory;State=$state}|ConvertTo-Json -Depth 8
if($Logs){$file=Join-Path $StateDirectory 'monitor.jsonl';if(Test-Path -LiteralPath $file){Get-Content -LiteralPath $file -Tail $Tail}}
