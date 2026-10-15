[CmdletBinding()]
param([string]$StateDirectory='', [ValidateRange(1,60)][int]$WaitSeconds=20)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
if(!$StateDirectory){if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installation.json')){$StateDirectory=Get-CtzStateDirectory}else{$StateDirectory=Join-Path $PSScriptRoot 'preview-data'}}
if(!(Test-Path -LiteralPath $StateDirectory)){Write-Output 'No monitor state.';return}
[IO.File]::WriteAllText((Join-Path $StateDirectory 'stop.request'),[DateTime]::UtcNow.ToString('o'))
$deadline=[DateTime]::UtcNow.AddSeconds($WaitSeconds)
do {
    $mutex=[Threading.Mutex]::new($false,(Get-CtzMutexName));$taken=$false
    try {try{$taken=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$taken=$true};if($taken){Write-Output 'Monitor is stopped; no unrelated process was terminated.';return}}
    finally{if($taken){$mutex.ReleaseMutex()};$mutex.Dispose()}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
throw 'Stop is pending. No process was force-killed; wait for network timeout and retry Status.ps1.'
