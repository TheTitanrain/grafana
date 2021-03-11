<#
        .SYNOPSIS
        PRTG Veeam Advanced Sensor
  
        .DESCRIPTION
        Advanced Sensor will Report Statistics about Backups during last 24 Hours and Actual Repository usage. It will then convert them into JSON, ready to add into InfluxDB and show it with Grafana
	
        .Notes
        NAME:  veeam-stats.ps1
        ORIGINAL NAME: PRTG-VeeamBRStats.ps1
        LASTEDIT: 22/01/2018
        VERSION: 0.3
        KEYWORDS: Veeam, PRTG
   
        .Link
        http://mycloudrevolution.com/
        Minor Edits and JSON output for Grafana by https://jorgedelacruz.es/
        Minor Edits from JSON to Influx for Grafana by r4yfx
 
 #Requires PS -Version 3.0
 #Requires -Modules VeeamPSSnapIn    
 #>
[cmdletbinding()]
param(
    [Parameter(Position=0, Mandatory=$false)]
        [string] $BRHost = "localhost",
    [Parameter(Position=1, Mandatory=$false)]
        $reportMode = "24", # Weekly, Monthly as String or Hour as Integer
    [Parameter(Position=2, Mandatory=$false)]
        $repoCritical = 10,
    [Parameter(Position=3, Mandatory=$false)]
        $repoWarn = 20
  
)
# You can find the original code for PRTG here, thank you so much Markus Kraus - https://github.com/mycloudrevolution/Advanced-PRTG-Sensors/blob/master/Veeam/PRTG-VeeamBRStats.ps1
# Big thanks to Shawn, creating a awsome Reporting Script:
# http://blog.smasterson.com/2016/02/16/veeam-v9-my-veeam-report-v9-0-1/

#region: Functions
Function Get-vPCRepoInfo {
[CmdletBinding()]
        param (
                [Parameter(Position=0, ValueFromPipeline=$true)]
                [PSObject[]]$Repository
                )
        Begin {
                $outputArray = @()
                Function Build-Object {param($name, $repohost, $path, $free, $total)
                        $repoObj = New-Object -TypeName PSObject -Property @{ 
                                Target = $name
                                RepoHost = $repohost
                                Storepath = $path
                                StorageFree = $free
                                StorageTotal = $total
                                FreePercentage = [Math]::Round(100*$free/$total)
                                }
                        Return $repoObj | Select-Object Target, RepoHost, Storepath, StorageFree, StorageTotal, FreePercentage
                }
        }
        Process {
                Foreach ($r in $Repository) {
                	# Refresh Repository Size Info
                        [Veeam.Backup.Core.CBackupRepositoryEx]::SyncSpaceInfoToDb($r, $true)
                        
                        If ($r.HostId -eq "00000000-0000-0000-0000-000000000000") {
                                $HostName = ""
                        }
                        Else {
                                $HostName = $($r.GetHost()).Name.ToLower()
                        }
                        $outputObj = Build-Object $r.Name $Hostname $r.FriendlyPath $r.GetContainer().CachedFreeSpace.InGigabytes $r.GetContainer().CachedTotalSpace.InGigabytes
                        
                }                        
                $outputArray += $outputObj
        }
        End {
                $outputArray
        }
}
#endregion

#region: Start BRHost Connection
$OpenConnection = (Get-VBRServerSession).Server
if($OpenConnection -eq $BRHost) {
	
} elseif ($null -eq $OpenConnection ) {
	
	Connect-VBRServer -Server $BRHost
} else {
    
    Disconnect-VBRServer
   
    Connect-VBRServer -Server $BRHost
}

$NewConnection = (Get-VBRServerSession).Server
if ($null -eq $NewConnection ) {
	Write-Error "`nError: BRHost Connection Failed"
	Exit
}
#endregion

#region: Convert mode (timeframe) to hours
If ($reportMode -eq "Monthly") {
        $HourstoCheck = 720
} Elseif ($reportMode -eq "Weekly") {
        $HourstoCheck = 168
} Else {
        $HourstoCheck = $reportMode
}
#endregion

#region: Collect and filter Sessions
# $vbrserverobj = Get-VBRLocalhost        # Get VBR Server object
# $viProxyList = Get-VBRViProxy           # Get all Proxies
$repositoryList = Get-VBRBackupRepository     # Get all Repositories
$allSessions = Get-VBRBackupSession         # Get all Sessions
# $allResto = Get-VBRRestoreSession       # Get all Restore Sessions
$sessionListBackup = @($allSessions | Where-Object{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck)) -and $_.JobType -eq "Backup"})                          # Gather all Backup sessions within timeframe

# Gather all BackupCopy sessions within timeframe
#get jobs for immediate backup copy
$job = Get-VBRJob -WarningAction SilentlyContinue | Where-Object {$_.JobType -eq "SimpleBackupCopyPolicy"}
#get child worker jobs
$workers = $job.GetWorkerJobs()
#get session details for each worker job
foreach ($worker in $workers) {
        $sessionListBackupCopy += [Veeam.Backup.Core.CBackupSession]::GetByJob($worker.id)
        }
$sessionListBackupCopy = @($sessionListBackupCopy | Where-Object{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck))})

$sessionListReplication = @($allSessions | Where-Object{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck)) -and $_.JobType -eq "Replica"})                    # Gather all Replication sessions within timeframe
$sessionListNas = @($allSessions | Where-Object{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck)) -and $_.JobType -eq "NasBackup"})                          # Gather all NAS sessions within timeframe
$sessionListNasCopy = @($allSessions | Where-Object{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck)) -and $_.JobType -eq "NasBackupCopy"})                  # Gather all NAS copy sessions within timeframe
$sessionListAgentBackup = @($allSessions | Where-Object{($_.CreationTime -ge (Get-Date).AddHours(-$HourstoCheck)) -and $_.JobType -eq "EpAgentBackup"})              # Gather all NAS copy sessions within timeframe

#endregion

#region: Collect Jobs
# $allJobsBackup = @(Get-VBRJob | Where-Object {$_.JobType -eq "Backup"})                      # Gather Backup jobs
# $Count = $allJobsBackup.Count
# $body="veeam-stats allJobsBackup=$Count"
# Write-Host $body
# $allJobsBackupCopy = @(Get-VBRJob | Where-Object {$_.JobType -eq "SimpleBackupCopyPolicy"})  # Gather BackupCopy jobs
# $Count = $allJobsBackupCopy.Count
# $body="veeam-stats allJobsBackupCopy=$Count"
# Write-Host $body
# $allJobsNasBackup = @(Get-VBRJob | Where-Object {$_.JobType -eq "NasBackup"})                # Gather BackupCopy jobs
# $Count = $allJobsNasBackup.Count
# $body="veeam-stats allJobsNasBackup=$Count"
# Write-Host $body
# $allJobsNASBackupCopy = @(Get-VBRJob | Where-Object {$_.JobType -eq "NasBackupCopy"})        # Gather BackupCopy jobs
# $Count = $allJobsNASBackupCopy.Count
# $body="veeam-stats allJobsNASBackupCopy=$Count"
# Write-Host $body
# $repList = @(Get-VBRJob | Where-Object {$_.IsReplica})                                       # Get Replica jobs
# $Count = $repList.Count
# $body="veeam-stats repList=$Count"
# Write-Host $body
#endregion

#region: Get Backup session informations
$totalTransferedBackup = 0
$totalReadBackup = 0
$sessionListBackup | ForEach-Object{$totalTransferedBackup += $([Math]::Round([Decimal]$_.Progress.TransferedSize/1GB, 0))}
$sessionListBackup | ForEach-Object{$totalReadBackup += $([Math]::Round([Decimal]$_.Progress.ReadSize/1GB, 0))}
#endregion

#region: Preparing Backup Session Reports
$successSessionsBackup = @($sessionListBackup | Where-Object{$_.Result -eq "Success"})
$warningSessionsBackup = @($sessionListBackup | Where-Object{$_.Result -eq "Warning"})
$failsSessionsBackup = @($sessionListBackup | Where-Object{$_.Result -eq "Failed"})
$runningSessionsBackup = @($allSessions | Where-Object{$_.State -eq "Working" -and $_.JobType -eq "Backup"})
$failedSessionsBackup = @($sessionListBackup | Where-Object{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})
#endregion

#region:  Preparing Backup Copy Session Reports
$successSessionsBackupCopy = @($sessionListBackupCopy | Where-Object{$_.Result -eq "Success"})
$warningSessionsBackupCopy = @($sessionListBackupCopy | Where-Object{$_.Result -eq "Warning"})
$failsSessionsBackupCopy = @($sessionListBackupCopy | Where-Object{$_.Result -eq "Failed"})
$runningSessionsBackupCopy = @($allSessions | Where-Object{$_.State -eq "Working" -and $_.JobType -eq "SimpleBackupCopyPolicy"})
$IdleSessionsBackupCopy = @($allSessions | Where-Object{$_.State -eq "Idle" -and $_.JobType -eq "SimpleBackupCopyPolicy"})
$failedSessionsBackupCopy = @($sessionListBackupCopy | Where-Object{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})
#endregion

#region: Preparing Replication Session Reports
$successSessionsRepl = @($sessionListReplication | Where-Object{$_.Result -eq "Success"})
$warningSessionsRepl = @($sessionListReplication | Where-Object{$_.Result -eq "Warning"})
$failsSessionsRepl = @($sessionListReplication | Where-Object{$_.Result -eq "Failed"})
$runningSessionsRepl = @($allSessions | Where-Object{$_.State -eq "Working" -and $_.JobType -eq "Replica"})
$failedSessionsRepl = @($sessionListReplication | Where-Object{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})
#endregion

#region: Preparing NAS Session Reports
$successSessionsNas = @($sessionListNas | Where-Object{$_.Result -eq "Success"})
$warningSessionsNas = @($sessionListNas | Where-Object{$_.Result -eq "Warning"})
$failsSessionsNas = @($sessionListNas | Where-Object{$_.Result -eq "Failed"})
$runningSessionsNas = @($allSessions | Where-Object{$_.State -eq "Working" -and $_.JobType -eq "NasBackup"})
$failedSessionsNas = @($sessionListNas | Where-Object{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})
#endregion

#region: Preparing NAS Copy Session Reports
$successSessionsNasCopy = @($sessionListNasCopy | Where-Object{$_.Result -eq "Success"})
$warningSessionsNasCopy = @($sessionListNasCopy | Where-Object{$_.Result -eq "Warning"})
$failsSessionsNasCopy = @($sessionListNasCopy | Where-Object{$_.Result -eq "Failed"})
$runningSessionsNasCopy = @($allSessions | Where-Object{$_.State -eq "Working" -and $_.JobType -eq "NasBackupCopy"})
$failedSessionsNasCopy = @($sessionListNas | Where-Object{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})
#endregion

#region: Preparing Windows Agent Backup Session Reports
$successSessionsAgentBackup = @($sessionListAgentBackup | Where-Object{$_.Result -eq "Success"})
$warningSessionsAgentBackup = @($sessionListAgentBackup | Where-Object{$_.Result -eq "Warning"})
$failsSessionsAgentBackup = @($sessionListAgentBackup | Where-Object{$_.Result -eq "Failed"})
$runningSessionsAgentBackup = @($allSessions | Where-Object{$_.State -eq "Working" -and $_.JobType -eq "EpAgentBackup"})
$failedSessionsAgentBackup = @($sessionListAgentBackup | Where-Object{($_.Result -eq "Failed") -and ($_.WillBeRetried -ne "True")})
#endregion

#region: Repository Report
$RepoReport = $repositoryList | Get-vPCRepoInfo | Select-Object @{Name="Repository Name"; Expression = {$_.Target}},
                                                                @{Name="Host"; Expression = {$_.RepoHost}},
                                                                @{Name="Path"; Expression = {$_.Storepath}},
                                                                @{Name="Free (GB)"; Expression = {$_.StorageFree}},
                                                                @{Name="Total (GB)"; Expression = {$_.StorageTotal}},
                                                                @{Name="Free (%)"; Expression = {$_.FreePercentage}},
                                                                @{Name="Status"; Expression = {
                                                                If ($_.FreePercentage -lt $repoCritical) {"Critical"} 
                                                                ElseIf ($_.FreePercentage -lt $repoWarn) {"Warning"}
                                                                ElseIf ($_.FreePercentage -eq "Unknown") {"Unknown"}
                                                                Else {"OK"}}} | `
                                                                Sort-Object "Repository Name" 
#endregion

#region: Number of Endpoints
$number_endpoints = 0
foreach ($endpoint in Get-VBREPJob ) {
$number_endpoints++;
}
#endregion


#region: Influxdb Output for Telegraf

$Count = $successSessionsBackup.Count
$body="veeam-stats successfulbackups=$Count"
Write-Host $body

$Count = $warningSessionsBackup.Count
$body="veeam-stats warningbackups=$Count"
Write-Host $body

$Count = $failsSessionsBackup.Count
$body="veeam-stats failesbackups=$Count"
Write-Host $body

$Count = $failedSessionsBackup.Count
$body="veeam-stats failedbackups=$Count"
Write-Host $body

$Count = $runningSessionsBackup.Count
$body="veeam-stats runningbackups=$Count"
Write-Host $body

$Count = $successSessionsBackupCopy.Count
$body="veeam-stats successfulbackupcopys=$Count"
Write-Host $body

$Count = $warningSessionsBackupCopy.Count
$body="veeam-stats warningbackupcopys=$Count"
Write-Host $body

$Count = $failsSessionsBackupCopy.Count
$body="veeam-stats failesbackupcopys=$Count"
Write-Host $body

$Count = $failedSessionsBackupCopy.Count
$body="veeam-stats failedbackupcopys=$Count"
Write-Host $body

$Count = $runningSessionsBackupCopy.Count
$body="veeam-stats runningbackupcopys=$Count"
Write-Host $body

$Count = $IdleSessionsBackupCopy.Count
$body="veeam-stats idlebackupcopys=$Count"
Write-Host $body

$Count = $successSessionsRepl.Count
$body="veeam-stats successfulreplications=$Count"
Write-Host $body

$Count = $warningSessionsRepl.Count
$body="veeam-stats warningreplications=$Count"
Write-Host $body

$Count = $failsSessionsRepl.Count
$body="veeam-stats failesreplications=$Count"
Write-Host $body

$Count = $runningSessionsNas.Count
$body="veeam-stats runningSessionsNas=$Count"
Write-Host $body

$Count = $successSessionsNas.Count
$body="veeam-stats successSessionsNas=$Count"
Write-Host $body

$Count = $warningSessionsNas.Count
$body="veeam-stats warningSessionsNas=$Count"
Write-Host $body

$Count = $failsSessionsNas.Count
$body="veeam-stats failsSessionsNas=$Count"
Write-Host $body

$Count = $failedSessionsNas.Count
$body="veeam-stats failedSessionsNas=$Count"
Write-Host $body

$Count = $failedSessionsNas.Count
$body="veeam-stats failedSessionsNas=$Count"
Write-Host $body


$Count = $runningSessionsNasCopy.Count
$body="veeam-stats runningSessionsNasCopy=$Count"
Write-Host $body

$Count = $successSessionsNasCopy.Count
$body="veeam-stats successSessionsNasCopy=$Count"
Write-Host $body

$Count = $warningSessionsNasCopy.Count
$body="veeam-stats warningSessionsNasCopy=$Count"
Write-Host $body

$Count = $failsSessionsNasCopy.Count
$body="veeam-stats failsSessionsNasCopy=$Count"
Write-Host $body

$Count = $failedSessionsNasCopy.Count
$body="veeam-stats failedSessionsNasCopy=$Count"
Write-Host $body

$Count = $runningSessionsAgentBackup.Count
$body="veeam-stats runningSessionsAgentBackup=$Count"
Write-Host $body

$Count = $successSessionsAgentBackup.Count
$body="veeam-stats successSessionsAgentBackup=$Count"
Write-Host $body

$Count = $warningSessionsAgentBackup.Count
$body="veeam-stats warningSessionsAgentBackup=$Count"
Write-Host $body

$Count = $failsSessionsAgentBackup.Count
$body="veeam-stats failsSessionsAgentBackup=$Count"
Write-Host $body

$Count = $failedSessionsAgentBackup.Count
$body="veeam-stats failedSessionsAgentBackup=$Count"
Write-Host $body

$body="veeam-stats totalbackuptransfer=$totalTransferedBackup"
Write-Host $body

foreach ($Repo in $RepoReport){
$Name = "REPO " + $Repo."Repository Name" -replace '\s','_'
$Free = $Repo."Free (%)"
$body="veeam-stats $Name=$Free"
Write-Host $body
	}
$body="veeam-stats protectedendpoints=$number_endpoints"
Write-Host $body

$body="veeam-stats totalbackupread=$totalReadBackup"
Write-Host $body

$Count = $runningSessionsRepl.Count
$body="veeam-stats runningreplications=$Count"
Write-Host $body

#endregion

#region: Debug
if ($DebugPreference -eq "Inquire") {
	$RepoReport | Format-Table * -Autosize
    
    $SessionObject = [PSCustomObject] @{
                "Successful Backups"  = $successSessionsBackup.Count
                "Warning Backups" = $warningSessionsBackup.Count
                "Failes Backups" = $failsSessionsBackup.Count
                "Failed Backups" = $failedSessionsBackup.Count
                "Running Backups" = $runningSessionsBackup.Count
                "Warning BackupCopys" = $warningSessionsBackupCopy.Count
                "Failes BackupCopys" = $failsSessionsBackupCopy.Count
                "Failed BackupCopys" = $failedSessionsBackupCopy.Count
                "Running BackupCopys" = $runningSessionsBackupCopy.Count
                "Idle BackupCopys" = $IdleSessionsBackupCopy.Count
                "Successful Replications" = $successSessionsRepl.Count
                "Warning Replications" = $warningSessionsRepl.Count
                "Failes Replications" = $failsSessionsRepl.Count
                "Failed Replications" = $failedSessionsRepl.Count
                "Running Replications" = $RunningSessionsRepl.Count
        }
    $SessionResport += $SessionObject
    $SessionResport
}
#endregion
