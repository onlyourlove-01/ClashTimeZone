[CmdletBinding()]
param([switch]$ApproveInstall,[switch]$EnableAutomaticSwitching,[switch]$RegisterStartup,[switch]$StartNow,[string]$InstallDirectory='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
$base=Join-Path $env:LOCALAPPDATA 'ClashTimeZone'
$destination=Join-Path $base 'App'
if($InstallDirectory){$destination=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')}
$data=Join-Path $base 'Data'
if($destination -eq [IO.Path]::GetPathRoot($destination).TrimEnd('\') -or $destination -eq $data -or $destination.StartsWith($data+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'UnsafeInstallationDirectory'}
$shortcut=Join-Path ([Environment]::GetFolderPath('Startup')) 'ClashTimeZone.lnk'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$plan=[pscustomobject]@{InstallDirectory=$destination;DataDirectory=$data;StartupShortcut=$shortcut;Identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name;RunLevel='Ordinary current user, never SYSTEM';OriginalTimeZone=(Get-TimeZone).Id;EnableAutomaticSwitching=[bool]$EnableAutomaticSwitching;RegisterStartup=[bool]$RegisterStartup;StartNow=[bool]$StartNow;AdminRequiredForInstaller=$false;WindowsAutoZoneConflict=(Test-CtzAutomaticZoneConflict);AutoZoneSettingChangeRequiresSeparateApproval=$true}
if(!$ApproveInstall){$plan|ConvertTo-Json;Write-Output 'PREVIEW ONLY. Explicit approval is required before -ApproveInstall, -EnableAutomaticSwitching, -RegisterStartup, or -StartNow.';return}
if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Use a non-elevated PowerShell. This installer intentionally does not install elevated persistence.'}
if($PSScriptRoot -eq $destination){throw 'Run installer from the source project, not the installed directory.'}
if((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $data)){throw 'InstallationOrDataAlreadyExists: inspect/migrate existing installation; no files overwritten.'}
if(Test-Path -LiteralPath $shortcut){throw 'StartupShortcutAlreadyExists: no existing shortcut overwritten.'}
if($EnableAutomaticSwitching -and (Test-CtzAutomaticZoneConflict)){throw 'WindowsAutomaticTimeZoneEnabled: request separate user approval before changing that setting.'}
$privileges=(& whoami.exe /priv | Out-String)
if($EnableAutomaticSwitching -and $privileges -notmatch 'SeTimeZonePrivilege'){throw 'TimeZonePrivilegeAbsent: a separately approved permission plan is required.'}
& (Join-Path $PSScriptRoot 'Test.ps1')
if(!$?){throw 'OfflineTestsFailed'}
& (Join-Path $PSScriptRoot 'Test-Network.ps1')
if(!$?){throw 'OfflineNetworkTestsFailed'}
& (Join-Path $PSScriptRoot 'Test-Local.ps1')
if(!$?){throw 'OfflineLocalTestsFailed'}
$files=@('Auto-TimeZone.ps1','ClashTimeZone.psm1','config.json','Install.ps1','Uninstall.ps1','Start.ps1','Stop.ps1','Status.ps1','Pause.ps1','Resume.ps1','Restore-TimeZone.ps1','Test.ps1','Test-Network.ps1','Test-Local.ps1','README.md','Acceptance.md','Launch.ps1','LICENSE','THIRD_PARTY_NOTICES.md')
foreach($name in $files){if(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)){throw ('MissingPackageFile:'+$name)}}
New-Item -ItemType Directory -Path $destination -Force|Out-Null
New-Item -ItemType Directory -Path $data -Force|Out-Null
foreach($folder in @($destination,$data)) {
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($identity in @($sid,'S-1-5-18','S-1-5-32-544')) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.SecurityIdentifier]::new($identity),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $folder -AclObject $acl
}
foreach($name in $files){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destination $name) -ErrorAction Stop}
$manifest=@{Product='ClashTimeZone';Version='1.0.0';InstalledUtc=[DateTime]::UtcNow.ToString('o');InstallDirectory=$destination;DataDirectory=$data;UserSid=$sid;OriginalTimeZone=$plan.OriginalTimeZone;AutomaticSwitchingEnabled=[bool]$EnableAutomaticSwitching;StartupShortcut=$shortcut;StartupEnabled=[bool]$RegisterStartup;Files=$files}
Write-CtzJson (Join-Path $destination 'installation.json') $manifest
if($RegisterStartup) {
    $shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut($shortcut)
    $link.TargetPath=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments='-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+(Join-Path $destination 'Start.ps1')+'"'
    if($EnableAutomaticSwitching){$link.Arguments+=' -Apply'}
    $link.WorkingDirectory=$destination;$link.WindowStyle=7;$link.Description='ClashTimeZone ordinary-user background monitor';$link.Save()
    if(!(Test-Path -LiteralPath $shortcut)){throw 'StartupCreationFailed: installation exists but startup is not verified.'}
}
if($StartNow){& (Join-Path $destination 'Start.ps1') -Apply:$EnableAutomaticSwitching}
$plan|ConvertTo-Json
Write-Output 'Installed. Verify Status.ps1; live JP/US/direct acceptance remains separate.'
