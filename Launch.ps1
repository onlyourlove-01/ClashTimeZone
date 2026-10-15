param([ValidateSet('Status','Logs','Start','Stop','Pause','Resume','RestoreChinaPreview','RestoreOriginalPreview','UninstallPreview')][string]$Action='Status')
$ErrorActionPreference='Stop'
switch($Action){
 'Status' {& (Join-Path $PSScriptRoot 'Status.ps1')}
 'Logs' {& (Join-Path $PSScriptRoot 'Status.ps1') -Logs}
 'Start' {& (Join-Path $PSScriptRoot 'Start.ps1') -Apply}
 'Stop' {& (Join-Path $PSScriptRoot 'Stop.ps1')}
 'Pause' {& (Join-Path $PSScriptRoot 'Pause.ps1')}
 'Resume' {& (Join-Path $PSScriptRoot 'Resume.ps1')}
 'RestoreChinaPreview' {& (Join-Path $PSScriptRoot 'Restore-TimeZone.ps1') -China}
 'RestoreOriginalPreview' {& (Join-Path $PSScriptRoot 'Restore-TimeZone.ps1') -Original}
 'UninstallPreview' {& (Join-Path $PSScriptRoot 'Uninstall.ps1')}
}
