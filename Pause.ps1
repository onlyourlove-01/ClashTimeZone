param([string]$StateDirectory='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
if(!$StateDirectory){if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installation.json')){$StateDirectory=Get-CtzStateDirectory}else{$StateDirectory=Join-Path $PSScriptRoot 'preview-data'}}
New-Item -ItemType Directory -Path $StateDirectory -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $StateDirectory 'pause.request'),[DateTime]::UtcNow.ToString('o'))
Write-Output 'Pause requested. The next local poll acknowledges it; no time zone was changed.'
