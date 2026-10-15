[CmdletBinding()]
param([switch]$Apply,[switch]$Foreground)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
if($Apply){$null=Test-CtzInstallation $PSScriptRoot -RequireEnabled}
$mutex=[Threading.Mutex]::new($false,(Get-CtzMutexName));$taken=$false
try {try{$taken=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$taken=$true};if(!$taken){Write-Output 'Monitor is already running.';return}}finally{if($taken){$mutex.ReleaseMutex()};$mutex.Dispose()}
if($Foreground){& (Join-Path $PSScriptRoot 'Auto-TimeZone.ps1') -Apply:$Apply;return}
$script=Join-Path $PSScriptRoot 'Auto-TimeZone.ps1'
$args='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$script+'"'
if($Apply){$args+=' -Apply'}
$p=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -WindowStyle Hidden -PassThru
Write-Output ('Worker launched (not yet health-verified), PID='+$p.Id+'. Run Status.ps1 to verify.')
