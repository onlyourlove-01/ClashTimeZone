[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Once,
    [ValidateRange(0,86400)][int]$DurationSeconds=0,
    [string]$StateDirectory=''
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ClashTimeZone.psm1') -Force -DisableNameChecking
$config=Get-CtzConfig
if(!$StateDirectory) {
    if($Apply -or (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installation.json'))){$StateDirectory=Get-CtzStateDirectory}
    else{$StateDirectory=Join-Path $PSScriptRoot 'preview-data'}
}
if($Apply) {
    $installation=Test-CtzInstallation $PSScriptRoot -RequireEnabled
    if([IO.Path]::GetFullPath($StateDirectory) -ne [IO.Path]::GetFullPath((Get-CtzStateDirectory))){throw 'InstalledStateDirectoryRequired'}
    if(Test-CtzAutomaticZoneConflict){throw 'WindowsAutomaticTimeZoneEnabled'}
}
if(!(Test-Path -LiteralPath $StateDirectory)){New-Item -ItemType Directory -Path $StateDirectory -Force|Out-Null}
$mutex=[Threading.Mutex]::new($false,(Get-CtzMutexName));$lock=$false
$clock=[Diagnostics.Stopwatch]::StartNew();$decisionState=New-CtzDecisionState
$runspace=$null;$worker=$null;$pending=$null;$probeSnapshot=$null
$statusPath=Join-Path $StateDirectory 'status.json'
$nextProbe=0.0;$lastProbe=-10000.0;$hardBackoffUntil=0.0;$failures=0;$lastSignature=''
$lastEvent='';$lastObservation=$null;$lastAction='Starting';$lastReason='';$lastPollMs=0
try {
    try{$lock=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$lock=$true}
    if(!$lock){throw 'AnotherClashTimeZoneInstanceIsRunning'}
    # Stop is cooperative; deleting our own stale signal does not terminate other processes.
    $stopPath=Join-Path $StateDirectory 'stop.request'
    if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}
    $runspace=[RunspaceFactory]::CreateRunspace();$runspace.Open()
    $worker=[PowerShell]::Create();$worker.Runspace=$runspace
    [void]$worker.AddCommand('Import-Module').AddParameter('Name',(Join-Path $PSScriptRoot 'ClashTimeZone.psm1')).AddParameter('DisableNameChecking',$true)
    [void]$worker.Invoke();if($worker.HadErrors){throw 'ProbeRunspaceInitializationFailed'};$worker.Commands.Clear()
    Write-CtzLog $StateDirectory 'Started' @{Apply=[bool]$Apply;Pid=$PID;OriginalZone=(Get-TimeZone).Id;Identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name} $config
    do {
        $tick=[Diagnostics.Stopwatch]::StartNew()
        if(Test-Path -LiteralPath $stopPath){$lastAction='Stopped';$lastReason='StopRequested';break}
        if($DurationSeconds -gt 0 -and $clock.Elapsed.TotalSeconds -ge $DurationSeconds){$lastAction='Stopped';$lastReason='PreviewDurationReached';break}
        $paused=Test-Path -LiteralPath (Join-Path $StateDirectory 'pause.request')
        $autoConflict=$false
        if($Apply){$autoConflict=Test-CtzAutomaticZoneConflict}
        try{$snapshot=Get-CtzSnapshot $config}
        catch{$snapshot=[pscustomobject]@{Signature='unavailable';Path='Blocked';Reason='LocalDetectionFailed';ControllerKind='Unavailable';CoreVersion='';Mode='Unknown';TunEnabled=$false;CoreCount=0;GuiCount=0;ServiceRunning=$false;SelectionCount=0}}
        $now=$clock.Elapsed.TotalSeconds
        if($snapshot.Signature -ne $lastSignature) {
            $decisionState.Candidate=$null;$nextProbe=$now;$lastSignature=$snapshot.Signature
            Write-CtzLog $StateDirectory 'LocalChange' @{Path=$snapshot.Path;Reason=$snapshot.Reason;Controller=$snapshot.ControllerKind;Mode=$snapshot.Mode;Tun=$snapshot.TunEnabled;CoreCount=$snapshot.CoreCount;GuiCount=$snapshot.GuiCount} $config
        }
        if($paused -or $autoConflict) {
            $decisionState.Candidate=$null;$lastAction='Keep';$lastReason=$(if($paused){'Paused'}else{'WindowsAutomaticTimeZoneEnabled'})
            if($pending){$worker.Stop();$pending=$null;$worker.Commands.Clear()}
            $nextProbe=$now
        } elseif($pending -and $pending.IsCompleted) {
            try {
                $items=@($worker.EndInvoke($pending))
                # HadErrors also becomes true for exceptions handled inside the
                # probe. Preserve its structured failure / Retry-After result.
                if($worker.Streams.Error.Count -gt 0 -or $items.Count -ne 1 -or $null -eq $items[0].PSObject.Properties['Valid']){throw 'ProbeFailed'}
                $o=$items[0]
            } catch {
                # Types and source line numbers only; do not persist exceptions
                # that might contain an IP-bearing URL or authorization header.
                Write-CtzLog $StateDirectory 'ProbeWorkerDiagnostic' @{ExceptionType=$_.Exception.GetType().Name;Line=$_.InvocationInfo.ScriptLineNumber;OutputCount=$(if($null -ne $items){$items.Count}else{-1});WorkerErrorTypes=@($worker.Streams.Error|ForEach-Object {$_.Exception.GetType().Name})} $config
                $o=[pscustomobject]@{Valid=$false;Reason='ProbeWorkerFailure';Signature=$probeSnapshot.Signature;ProbeMs=0;RetrySeconds=0}
            }
            finally {$pending=$null;$worker.Commands.Clear();$worker.Streams.Error.Clear()}
            $now=$clock.Elapsed.TotalSeconds
            $lastObservation=$o
            # A changed route, node, process, or proxy invalidates an in-flight result.
            if($o.Signature -ne $snapshot.Signature) {
                $decisionState.Candidate=$null;$lastAction='Keep';$lastReason='LocalStateChangedDuringProbe';$nextProbe=$now
            } else {
                $d=Get-CtzDecision $decisionState $o $now (Get-TimeZone).Id $config
                $lastAction=$d.Action;$lastReason=$d.Reason
                if(!$o.Valid) {
                    $failures++;$delay=Get-CtzBackoff $failures $config
                    if($o.Reason -eq 'DailyBudgetExhausted'){$delay=86400}
                    if($o.RetrySeconds -gt 0){$delay=[Math]::Max($delay,$o.RetrySeconds)}
                    $hardBackoffUntil=$now+$delay;$nextProbe=$hardBackoffUntil
                } else {
                    $failures=0
                    switch($d.Action) {
                        'Confirm' {$nextProbe=$now+$config.ConfirmationSeconds}
                        'Cooldown' {$nextProbe=[Math]::Max($now+$config.ConfirmationSeconds,$decisionState.LastChangeAt+$config.MinimumChangeIntervalSeconds)}
                        'Change' {
                            # Refresh local state immediately before a possible system write.
                            $before=Get-CtzSnapshot $config
                            if($before.Signature -ne $o.Signature -or (Test-Path -LiteralPath $stopPath) -or (Test-Path -LiteralPath (Join-Path $StateDirectory 'pause.request'))) {
                                $lastAction='Keep';$lastReason='StateChangedBeforeCommit';$nextProbe=$now
                            } elseif($Apply -and (Test-CtzAutomaticZoneConflict)) {
                                $lastAction='Keep';$lastReason='WindowsAutomaticTimeZoneEnabled';$nextProbe=$now+$config.FailureBackoffSeconds
                            } else {
                                if($Apply) {
                                    Set-CtzVerifiedZone $d.Target
                                    $decisionState.LastChangeAt=$clock.Elapsed.TotalSeconds
                                    $lastAction='Changed'
                                } else {$lastAction='WouldChange'}
                                $nextProbe=$clock.Elapsed.TotalSeconds+$config.StableRecheckSeconds
                                Write-CtzLog $StateDirectory $lastAction @{Target=$d.Target;Country=$o.Country;Iana=$o.Iana;Ip=$o.IpMasked;ProbeMs=$o.ProbeMs;ConfirmedAfterSeconds=[Math]::Round($now-$decisionState.Candidate.FirstAt,2)} $config
                            }
                            $decisionState.Candidate=$null
                        }
                        default {$nextProbe=$now+$config.StableRecheckSeconds}
                    }
                }
                $event=$lastAction+':'+$lastReason
                if($event -ne $lastEvent){Write-CtzLog $StateDirectory 'Decision' @{Action=$lastAction;Reason=$lastReason;ProbeMs=$o.ProbeMs;Target=(Get-CtzField $o 'Target' '');Ip=(Get-CtzField $o 'IpMasked' '')} $config;$lastEvent=$event}
            }
            Write-Output ([pscustomobject]@{Action=$lastAction;Reason=$lastReason;Target=(Get-CtzField $o 'Target' '');Country=(Get-CtzField $o 'Country' '');Iana=(Get-CtzField $o 'Iana' '');Ip=(Get-CtzField $o 'IpMasked' '');ProbeMs=$o.ProbeMs;Apply=[bool]$Apply})
        }
        if(!$paused -and !$autoConflict -and !$pending -and $now -ge $nextProbe -and $now -ge $hardBackoffUntil -and $now-$lastProbe -ge $config.PollSeconds) {
            $probeSnapshot=$snapshot;$lastProbe=$now
            [void]$worker.AddCommand('Get-CtzObservation').AddParameter('Snapshot',$snapshot).AddParameter('Config',$config).AddParameter('StateDirectory',$StateDirectory)
            $pending=$worker.BeginInvoke()
        }
        $status=@{Product='ClashTimeZone';Pid=$PID;StartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');HeartbeatUtc=[DateTime]::UtcNow.ToString('o');Apply=[bool]$Apply;Paused=$paused;CurrentZone=(Get-TimeZone).Id;LastAction=$lastAction;Reason=$lastReason;Path=$snapshot.Path;Controller=$snapshot.ControllerKind;CoreVersion=$snapshot.CoreVersion;Mode=$snapshot.Mode;Tun=$snapshot.TunEnabled;LastPollMs=$lastPollMs;ProbePending=[bool]$pending;NextProbeAfterSeconds=[Math]::Round([Math]::Max(0,[Math]::Max($nextProbe,$hardBackoffUntil)-$now),1)}
        Write-CtzJson $statusPath $status
        if($Once -and !$pending -and $lastReason -ne ''){break}
        $lastPollMs=$tick.ElapsedMilliseconds
        $sleep=[int][Math]::Max(20,($config.PollSeconds*1000-$tick.ElapsedMilliseconds))
        if($pending -and $Once){$sleep=[Math]::Min(1000,$sleep)}
        Start-Sleep -Milliseconds $sleep
    } while($true)
} catch {
    $lastAction='Faulted';$lastReason='MonitorStoppedSafely'
    if($lock){Write-CtzLog $StateDirectory 'Faulted' @{Reason=$lastReason;ErrorType=$_.Exception.GetType().Name} $config}
    throw
} finally {
    if($pending -and $worker){$worker.Stop()}
    if($worker){$worker.Dispose()};if($runspace){$runspace.Dispose()}
    if($lock){
        $old=Read-CtzJson $statusPath
        if($old -and $old.Pid -eq $PID){$old.LastAction=$lastAction;$old.Reason=$lastReason;$old.ProbePending=$false;$old.HeartbeatUtc=[DateTime]::UtcNow.ToString('o');Write-CtzJson $statusPath $old}
        Write-CtzLog $StateDirectory 'Stopped' @{Action=$lastAction;Reason=$lastReason} $config
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
