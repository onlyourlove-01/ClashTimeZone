[CmdletBinding(DefaultParameterSetName='Original')]
param([Parameter(ParameterSetName='China',Mandatory=$true)][switch]$China,[Parameter(ParameterSetName='Original')][switch]$Original,[switch]$Apply)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
$m=Test-CtzInstallation $PSScriptRoot
$target=$m.OriginalTimeZone;if($China){$target='China Standard Time'}
if(!$Apply){Write-Output ('Dry Run: would pause monitoring and restore '+$target+'. Add -Apply only after approval.');return}
& (Join-Path $PSScriptRoot 'Stop.ps1')
# Original time zone may be outside the automatic whitelist, but must be in the
# installation manifest captured before installation and in the Windows catalog.
$null=Get-TimeZone -Id $target -ErrorAction Stop
if((Get-TimeZone).Id -ne $target){Set-TimeZone -Id $target -ErrorAction Stop}
if((Get-TimeZone).Id -ne $target){throw 'RestoreVerificationFailed'}
[IO.File]::WriteAllText((Join-Path (Get-CtzStateDirectory) 'pause.request'),'ManualRestore')
Write-Output ('Restored and verified: '+$target+'. Monitoring is stopped and paused; Resume.ps1 then Start.ps1 -Apply to re-enable.')
