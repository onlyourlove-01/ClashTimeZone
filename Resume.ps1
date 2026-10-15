param([string]$StateDirectory='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
if(!$StateDirectory){if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installation.json')){$StateDirectory=Get-CtzStateDirectory}else{$StateDirectory=Join-Path $PSScriptRoot 'preview-data'}}
$flag=Join-Path $StateDirectory 'pause.request'
if(Test-Path -LiteralPath $flag){Remove-Item -LiteralPath $flag -Force}
Write-Output 'Resume requested. Previous confirmations are not reused. Start.ps1 is required if stopped.'
