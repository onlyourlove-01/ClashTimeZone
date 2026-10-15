[CmdletBinding()]
param([switch]$ApproveUninstall,[ValidateSet('None','Original','China')][string]$Restore='Original')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
$m=Test-CtzInstallation $PSScriptRoot
$expected=[IO.Path]::GetFullPath($m.InstallDirectory).TrimEnd('\')
if($expected -eq [IO.Path]::GetPathRoot($expected).TrimEnd('\') -or ((Get-Item -LiteralPath $expected).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'UnsafeInstallationRoot'}
if([IO.Path]::GetFullPath($PSScriptRoot) -ne $expected){throw 'UnexpectedInstallationPath'}
if(!$ApproveUninstall){Write-Output ('Dry Run: stop this monitor, remove its login shortcut and allowlisted package files; restore='+$Restore+'; retain Data and unrelated files. Add -ApproveUninstall only after approval.');return}
& (Join-Path $PSScriptRoot 'Stop.ps1')
$target=$null
if($Restore -eq 'Original'){$target=$m.OriginalTimeZone}elseif($Restore -eq 'China'){$target='China Standard Time'}
if($target){$null=Get-TimeZone -Id $target;if((Get-TimeZone).Id -ne $target){Set-TimeZone -Id $target};if((Get-TimeZone).Id -ne $target){throw 'RestoreVerificationFailed'}}
$shortcut=Join-Path ([Environment]::GetFolderPath('Startup')) 'ClashTimeZone.lnk'
if(Test-Path -LiteralPath $shortcut){
    $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($shortcut)
    if($link.Arguments -notlike ('*'+(Join-Path $PSScriptRoot 'Start.ps1')+'*')){throw 'ShortcutOwnershipMismatch: not removed'}
    Remove-Item -LiteralPath $shortcut -Force
}
$known=@('Auto-TimeZone.ps1','ClashTimeZone.psm1','config.json','Install.ps1','Uninstall.ps1','Start.ps1','Stop.ps1','Status.ps1','Pause.ps1','Resume.ps1','Restore-TimeZone.ps1','Test.ps1','Test-Network.ps1','Test-Local.ps1','README.md','Acceptance.md','Launch.ps1','LICENSE','THIRD_PARTY_NOTICES.md','installation.json')
$archive=@{UninstalledUtc=[DateTime]::UtcNow.ToString('o');OriginalTimeZone=$m.OriginalTimeZone;FinalTimeZone=(Get-TimeZone).Id;StartupRemoved=$true}
Write-CtzJson (Join-Path (Get-CtzStateDirectory) 'uninstalled.json') $archive
foreach($name in $known){$path=Join-Path $expected $name;if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force}}
if(@(Get-ChildItem -LiteralPath $expected -Force).Count -eq 0){Remove-Item -LiteralPath $expected -Force}
Write-Output ('Uninstalled. No recursive deletion. Logs and rollback record retained at '+(Get-CtzStateDirectory)+'. Unrelated extra files in the installation directory are retained.')
