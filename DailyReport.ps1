## --------------------------------------------------- ##
# Master 	PowerShell Reporting 						#
# Author: 	Tom Ralph									#
# Revision: 0.3											#
# Date: 	01/10/2019									#
## --------------------------------------------------- ##

## Define Inputs
Param (
	[String] $VCUsername , #vCenter Username
	[String] $CloudUserName , #vCloud Director Username
	[String] $Password , #Password to login
	[String] $To #Who is the report going to
	)
## User Definable Variables
$SMTPserver = ""
# additional Clouds (vCloud Director Instances) can be added
$Clouds += ""
# additional vCenters can be added
$VCs += ""
# Who is the report coming from?
$From = "email address"


## Define Variables
$Clouds = @()
$VCs = @()
$Records = @()
$VMHosts = @()
$Errors = $Null
$HostsDisabledFirewall = @()
$VMHostSSHEnabled = @()
$VMHostNoVTEPIP = @()
$HostInMaintenanceMode = @()
$VCCount = 0
$HostCount = 0
$VMsOff = 0
$VMsOn = 0
$VMs = @()
$VSANVMs = 0
$AvaliableStorage = 0
$SumNFSDataStore = 0
$SumVSANDataStore = 0
$SumVMFSDataStore = 0
$AvaliableVSANStorage = 0
$AvaliableNFSStorage = 0
$AvaliableISCSIStorage = 0
$PvdcAllocatedRam = @()
$PvdcRPDisabledReport = @()
$DisabledHosts = @()
$StrandedItemsTotal = @()
$TaskArray= @()
$vCenterDSAlarms = @()

$Header = @"
<style>
table
    {
		Margin: 0px 0px 0px 4px;
        Border: 1px solid rgb(190, 190, 190);
        Font-Family: Tahoma;
        Font-Size: 8pt;
        Background-Color: rgb(252, 252, 252);
    }
tr:hover td
    {
        Background-Color: rgb(150, 150, 220);
        Color: rgb(255, 255, 255);
    }
tr:nth-child(even)
    {
        Background-Color: rgb(242, 242, 242);
    }
th
    {
        Text-Align: Left;
        Color: rgb(150, 150, 220);
        Padding: 1px 4px 1px 4px;
    }
td
    {
        Vertical-Align: Top;
        Padding: 1px 4px 1px 4px;
    }
H2
	{
		Font-Family: Tahoma;
	{
H3
	{
		Font-Family: Tahoma;
	}
</style>
<title>
SI-Team Report >Report generated: $(Get-Date)
</title>
"@
## End - Define Variables

## Load Snap-ins
Add-PSSnapin *.Core
Add-PSSnapin *.Cloud
Import-Module VMware.VimAutomation.Cloud
## End - Load Snap-ins

## Collect vCenters from vCloud
ForEach ( $Cloud in $Clouds ) {
	
	Connect-CIServer -Username $CloudUserName -Password $Password -Server $Cloud -ErrorVariable $Errors
	$PVDCs += Get-ProviderVDC | Get-CIView
	$VCs += $PVDCs.vimserver.Name

	$VCs = $VCs | Select -Unique
	$VCs = $VCs | Sort

	# Collect PVDC Sizing
	ForEach ($Provider in Get-ProviderVdc) {
		$Allocated = {} | Select PVDCName, PVDCAllocated
		$AllocatedRam = $Provider.MemoryAllocatedGB / $Provider.MemoryTotalGB * 100
		$Allocated.PVDCAllocated = [Math]::round($AllocatedRam,2)
		$Allocated.PVDCName += $Provider.Name
		$PvdcAllocatedRam += $Allocated
		$PvdcAllocatedRam = @($PvdcAllocatedRam)
	}	
	
	# Collect PVDC Status's
	$PvdcRPDisabledArray = {} | Select ResourcePool
	$PvdcRPDisabled = @()
	$PvdcsRPDisabled = Search-Cloud -QueryType ProviderVdcResourcePoolRelation  -Filter ('IsEnabled==False')
	
	ForEach ( $PvdcRPDisabled in $PvdcsRPDisabled ) {
		$PvdcRPDisabledArray.ResourcePool = $PvdcRPDisabled.Name
		$PvdcRPDisabledReport += $PvdcRPDisabledArray
		$PvdcRPDisabledReport = @($PvdcRPDisabledReport)
	}
	
	# Collect Stranded Item counts from vCloud
	$Stranded = Search-Cloud -QueryType StrandedItem
	$StrandedItems = {} | Select CloudName,ItemCount
	$StrandedItems.CloudName = $Cloud
	$StrandedItems.ItemCount = $Stranded.Count
	$StrandedItemsTotal += $StrandedItems
	$StrandedItemsTotal = @($StrandedItemsTotal)
	
	# Collect Disabled Hosts in vCloud Director
	$DisabledHost = Search-Cloud -QueryType Host -Filter ('IsEnabled==False')
	$DisHost = {} | Select Hostname
	
	ForEach( $DH in $DisabledHost ) {
		$DisHost.Hostname += $DH.Name
		$DisabledHosts += $DisHost
		$DisabledHosts = @($DisabledHosts)
	}
	
	# Disconnect from vCloud
	Disconnect-CIServer * -Confirm:$False

}

## Collect Information from vCenters
ForEach ( $VC in $VCs ) {

	Write-Host "Connecting to "$VC
	$Connected = Connect-VIServer -Username $VCUsername -password $Password -Server $VC -ErrorVariable $Errors

	# Get all the hosts
	$VMHosts = Get-VMHost 
	
	#Increment Counters
	$HostCount += $VMhosts.Count
	$VCCount++
	$VMs = Get-VM 
	$VMsOn += ($VMs | Where-Object { $_.PowerState -eq "PoweredOn" }).Count
	$VMsOff += ($VMs | Where-Object { $_.PowerState -ne "PoweredOn" }).Count
	
	$SumNFSDataStore = Get-Datastore | Where {$_.Type -eq "NFS"} | Measure-Object -Property CapacityGB -Sum
	$AvaliableNFSStorage += [Math]::Round( $SumNFSDataStore.Sum, 2 )
	
	$SumVSANDataStore = Get-Datastore | Where {$_.Type -eq "vsan"} | Measure-Object -Property CapacityGB -Sum
	$AvaliableVSANStorage += [Math]::Round( $SumVSANDataStore.Sum, 2 )
	
	$SumiSCSIDataStore = Get-Datastore | Where {$_.Type -eq "VMFS"} | Measure-Object -Property CapacityGB -Sum
	$AvaliableiSCSIStorage += [Math]::Round( $SumiSCSIDataStore.Sum, 2 )
	
	# Collect VTEP Addresses
	$VMHostNoVTEPIP += Get-VMHostNetworkAdapter -DistributedSwitch *vcdpool* -VMKernel -ErrorAction SilentlyContinue | Where-Object { $_.IP -like "169*" -or $_.IP -eq "0.0.0.0" -or $_.IP -eq $Null }
	
	ForEach ( $VMHost in $VMHosts ) {
	
		# Collect Syslog Firewall Information
		$HostsDisabledFirewall += Get-VMHostFirewallException -VMHost $VMHost -Name syslog -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $false } | Select VMhost, Name, Enabled 
		
		# Collect SSH Status
		$VMHostSSHEnabled += $VMHost | Get-VMHostService | Where-Object {$_.Key -eq "TSM-SSH" -and $_.Running -eq $true} | Select VMHost, Key, Policy, Running
		
		# Collect vCenter Alarms
		foreach($triggered in $VMHost.ExtensionData.TriggeredAlarmState){
			$arrayline={} | Select HostName, AlarmType, AlarmInformations
			$alarmDefinition = Get-View -Id $triggered.Alarm
			$arrayline.HostName = $VMHost.name
			$arrayline.AlarmType = $triggered.OverallStatus
			$arrayline.AlarmInformations = $alarmDefinition.Info.Name
			$vCenterAlarms += $arrayline
			$vCenterAlarms = @($vCenterAlarms)
		}
		
		# Collect Host RAM Usage
		$RamUsage = ""
		$RamUsage = $VMHost.MemoryUsageGB / $VMHost.MemoryTotalGB * 100
		$RamUsage = [Math]::round($RamUsage,1)
		
		If ( $RamUsage -ge "90" ) {
			$RamLine = {} | Select HostName, RamUsage
			$RamLine.Hostname = $VMhost.Name
			$RamLine.RamUsage = $RamUsage
			$RAMRedHosts += $RamLine
			$RAMRedHosts = @($RAMRedHosts)
		} 
		
		# Collect Maintenance Mode Status
		If ( $VMHost.ConnectionState -ne "Connected" ) {
			$MMArrayLine = {} | Select HostName, ConnectionState, BootTime
			$MMArrayLine.HostName = $VMHost.Name
			$MMArrayLine.BootTime = $VMHost.ExtensionData.Runtime.BootTime
			$MMArrayLine.ConnectionState = $VMHost.ConnectionState
			#$MMArrayLine.MMTime = 
			$HostInMaintenanceMode += $MMArrayLine
			$HostInMaintenanceMode = @($HostInMaintenanceMode)
		}
	}
	
	# Collect Datastore Alarms
	ForEach ($Datastore in (Get-DataStore)) {
		ForEach($Triggered in $Datastore.ExtensionData.TriggeredAlarmState){
			$DSarrayline={} | Select DatastoreName, AlarmType, AlarmInformations
			$alarmDefinition = Get-View -Id $triggered.Alarm
			$DSarrayline.DatastoreName = $Datastore.name
			$DSarrayline.AlarmType = $triggered.OverallStatus
			$DSarrayline.AlarmInformations = $alarmDefinition.Info.Name
			$vCenterDSAlarms += $DSarrayline
			$vCenterDSAlarms = @($vCenterDSAlarms)
		}
	}
	
	#Collect Task Information
	$Date = (Get-Date).AddDays(-1)
	$Tasks = Get-Task | Where-Object { $_.State -eq "Running" -and $_.StartTime -le $Date }
	
	ForEach ( $Task in $Tasks ) {
		$LongTask = {} | Select StartTime, Description, Percent, VcHost, ObjectId
		$LongTask.StartTime = $Task.StartTime
		$LongTask.Description = $Task.Description
		$LongTask.Percent = $Task.PercentComplete
		$LongTask.VcHost = $VC
		$LongTask.ObjectId = $Task.ObjectId
		$TaskArray += $LongTask
		$TaskArray = @($TaskArray)
	}
	
	ForEach ( $VSANCluster in ( Get-Cluster | Where { $_.VSANEnabled -eq "true" } )) {
		$VSANClusterCount ++
		$VSANClusterView = $VSANCluster | Get-View
		$VSANHost += $VSANClusterView.Host.Count
		
		$VSANDatastoreView = Get-Datastore | Where {$_.Type -eq "vsan"} | Get-View
		$VSANVMs += $VSANDatastoreView.VM.Count 
	}
	
	# Disconnect from vCenter
	Disconnect-VIServer * -Confirm:$False

}

$VCCount = "{0:N0}" -f $VCCount
$HostCount = "{0:N0}" -f $HostCount
$VMsOn = "{0:N0}" -f $VMsOn
$VMsOff = "{0:N0}" -f $VMsOff
$VSANClusterCount = "{0:N0}" -f $VSANClusterCount
$VSANHost = "{0:N0}" -f $VSANHost
$VSANVMs = "{0:N0}" -f $VSANVMs
$AvaliableVSANStorage = "{0:N0}" -f $AvaliableVSANStorage
$AvaliableiSCSIStorage = "{0:N0}" -f $AvaliableiSCSIStorage
$AvaliableNFSStorage = "{0:N0}" -f $AvaliableNFSStorage

# Format the Report
$HTMLReport = ConvertTo-Html -Title "Daily SI OneCloud Report." -Head $Header
$HTMLReport += ConvertTo-HTML -PreContent "Checked $VCCount Virtual Center's and $HostCount ESX Hosts. <br /><H3>VM Information:</H3>     Powered On:     $VMsOn <br />     Powered Off: $VMsOff <br /><H3>VSAN Data:</H3>     VSAN Clusters: $VSANClusterCount <br />     VSAN Hosts: $VSANHost <br />     VSAN VMs: $VSANVMs <br />     VSAN Storage: $AvaliableVSANStorage GB <br /><H3>Datastore Information:</H3>     VMFS (iSCSI): $AvaliableiSCSIStorage GB <br />     NFS: $AvaliableNFSStorage GB <br />" 

## Critical Alerts
$HTMLReport += ConvertTo-HTML -PreContent "<H1> Critical Alerts </H1>"
If ($HostsDisabledFirewall.Count -gt 0) {
	$HTMLReport += $HostsDisabledFirewall | ConvertTo-Html -Fragment -PreContent "<H2>vSphere Hosts with Syslog blocked</H2>"
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>vSphere Hosts with Syslog blocked</H2> <H3>No hosts found, in violation. All Clear</H3>"
	}
	
If ($VMHostNoVTEPIP.Count -gt 0) {
	$HTMLReport += $VMHostNoVTEPIP | ConvertTo-Html -Fragment -PreContent "<H2>vSphere Hosts missing valid IP on VTEP Interface</H2>"
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>vSphere Hosts missing valid IP on VTEP Interface</H2> <H3>No hosts found, in violation. All Clear</H3>"
	}
	If ($HostInMaintenanceMode.Count -gt 0) {
	$HTMLReport += $($HostInMaintenanceMode | Select HostName, ConnectionState, BootTime | ConvertTo-Html -Fragment -PreContent "<H2>vSphere Hosts in Maintenance Mode</H2>")
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>vSphere Hosts in Maintenance Mode</H2> <H3>No hosts found, in violation. All Clear</H3>"
	}
If ($PvdcRPDisabledReport.Count -gt 0) {
	$HTMLReport += $($PvdcRPDisabledReport | Select ResourcePool | ConvertTo-Html -Fragment -PreContent "<H2>PVDC Resource Pools Disabled</H2>")
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>PVDC Resource Pools Disabled</H2> <H3>No PVDC's found, in violation. All Clear</H3>"
	}
If ($DisabledHosts.Count -gt 0) {
	$HTMLReport += $($DisabledHosts | Select HostName | ConvertTo-Html -Fragment -PreContent "<H2>Hosts Disabled</H2>")
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>Hosts Disabled</H2> <H3>No disabled hosts found. All Clear</H3>"
	}	
If ($TaskArray.Count -gt 0) {
	$HTMLReport += $($TaskArray | Select VcHost, StartTime, Description, Percent, ObjectId | ConvertTo-Html -Fragment -PreContent "<H2>Long Running Tasks</H2>")
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>Long Running Tasks</H2> <H3>No long running Tasks found. All Clear</H3>"
	}		
## Informational Alerts
$HTMLReport += ConvertTo-HTML -PreContent "<H1> Informational Alerts </H1>"

If ($vCenterAlarms.Count -gt 0) {
	$HTMLReport += $($vCenterAlarms | Select HostName, AlarmType, AlarmInformations | ConvertTo-Html -Fragment -PreContent "<H2>Active vCenter Alarms</H2>")
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>Active vCenter Alarms</H2> <H3>No hosts alarms found. All Clear</H3>"
	}
	
If ($vCenterDSAlarms.Count -gt 0) {
	$HTMLReport += $($vCenterDSAlarms | Select DatastoreName, AlarmType, AlarmInformations | ConvertTo-Html -Fragment -PreContent "<H2>Active Datastore Alarms</H2>")
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>Active Datastore Alarms</H2> <H3>No Datastore alarms found. All Clear</H3>"
	}
	
If ($RAMRedHosts.Count -gt 0) {
	$HTMLReport += $RAMRedHosts | ConvertTo-Html -Fragment -PreContent "<H2>vSphere Hosts using more than 85% RAM</H2>"
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>vSphere Hosts using more than 90% RAM</H2> <H3>No hosts found, in violation. All Clear</H3>"
	}
	
If ($StrandedItemsTotal.Count -gt 0) {
	$HTMLReport += $($StrandedItemsTotal | Select CloudName,ItemCount | ConvertTo-Html -Fragment -PreContent "<H2>vCloud Stranded Items</H2>")
	}
Else {
	$HTMLReport += ConvertTo-HTML -PreContent "<H2>vCloud Stranded Items</H2> <H3>No Stranded Item's found, in violation. All Clear</H3>"
	}
	
$HTMLReport += $($PvdcAllocatedRam | Select PVDCName, PVDCAllocated | ConvertTo-Html -Fragment -PreContent "<H2>Provider VDC Over-Allocation</H2>")

# Email the Report
$Subject = "Daily vCenter Status Email"
$EmailBody = $HTMLReport

$Mailer = New-Object Net.Mail.SMTPclient($SMTPserver)
$Msg = New-Object Net.Mail.MailMessage($from, $to, $subject, $emailbody)
$Msg.IsBodyHTML = $true
$Mailer.send($Msg)
