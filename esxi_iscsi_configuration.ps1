#load Vmware Module
if ((Get-PSSnapin | Where-Object { $_.Name -eq "VMware.VimAutomation.Core" }) -eq $null) { Add-PSSnapin VMware.VimAutomation.Core }

### iSCSI Configuration ###
$Script:hostName = "vmwesx01.london.espares.co.uk" #Read-Host "Enter the name or IP of the ESXi host to configure"
$iscsiSwitchName = "vSwitchiSCSI"
$iscsiIps = @("192.168.130.101", "192.168.131.101")
$iscsiNics = @("vmnic1", "vmnic2")
$mtu = 9000
### End iSCSI Configuration ###

### Global Script Variables ###
$Global:VIServer = $null
$Global:VMHost = $null
### End Global Script Variables ### 

### Functions ###
function Exit-WithError {
	param(
		[string] $ErrorMessage = "An unspecified error occurred."
	)

	Write-Error $ErrorMessage
	Disconnect-VMHost
	exit 1
}

function Disconnect-VMHost {
	if ($VIServer -ne $null) {
		Write-Host "Disconnecting from VIServer: $VIServer"
		Disconnect-VIServer -Server $VIServer -force -confirm:$false
		$Global:VIServer = $null
	}
}

function Connect-VMHost {
	if ($VIServer -eq $null) {
		Write-Host "Connecting to $hostName"
		$Global:VIServer = Connect-VIServer -Server $hostName
		$Global:VMhost = Get-VMHost -Server $VIServer
	}
}

function Set-AdvancedConfigurationValue 
{
	param ([string]$Setting, [int]$Value)
	
	if ((Get-VMHostAdvancedConfiguration -Name $Setting).Item($Setting) -ne $Value) {
		Write-Host -ForegroundColor green "Setting advanced configuration $Setting to $Value"
		$VMhost | Set-VMHostAdvancedConfiguration -Name $Setting -Value $Value
	}
}

# iSCSI port groups are named starting at 1, not 0.
function get-iSCSINameFromIndex
{
	param ([int]$Index)
	"iSCSI" + ($Index + 1)
}
### End Functions ###

Connect-VMHost

Write-Host "Checking advanced Disk configuration"
Set-AdvancedConfigurationValue "Disk.UseDeviceReset" 0
Set-AdvancedConfigurationValue "Disk.UseLunReset" 1
Set-AdvancedConfigurationValue "Disk.MaxLUN" 50

# Get/Create virtual switch
$iscsiVirtualSwitch = Get-VirtualSwitch -VMHost $VMhost | Where-object { $_.Name -eq $iscsiSwitchName }
if ($iscsiVirtualSwitch -eq $null) {
	Write-Host -ForegroundColor green "Creating new virtual switch for iSCSI: $iscsiSwitchName"
	$iscsiVirtualSwitch = New-VirtualSwitch -VMHost $VMhost -Name $iscsiSwitchName
}

# Jumbo Frames
if ($iscsiVirtualSwitch.Mtu -ne $mtu) {
	Write-Host -ForegroundColor green "Enabling Jumbo Frames (MTU:$mtu) on iSCSI switch: $iscsiSwitchName"
	Set-VirtualSwitch -VirtualSwitch $iscsiVirtualSwitch -MTU $mtu -Confirm:$false
}

# NIC binding 
Write-Host "Checking vNIC bindings of vSwitch: $iscsiSwitchName"
$nicsRequireUpdating = $iscsiVirtualSwitch.Nic.Length -ne $iscsiNics.Length
if (!$nicsRequireUpdating) {
	$existingNics = New-Object System.Collections.ArrayList(, $iscsiVirtualSwitch.Nic)
	$iscsiNics | Foreach-object { if (!$existingNics.Contains($_)) { $nicsRequireUpdating = $true } }
}
if ($nicsRequireUpdating)
{
	Write-Host -ForegroundColor green "Binding iSCSI virtual NICs [$iscsiNics] to virtual switch: $iscsiSwitchName"
	Set-VirtualSwitch -VirtualSwitch $iscsiVirtualSwitch -Nic $iscsiNics -Confirm:$false
}


# VMKernel ports
Write-Host "Checking VMKernel ports and IP addresses"
# Load existing IP addresses
$existingIPs = ($VMhost | Get-VMHostNetworkAdapter | Where-object { $_.IP -ne "" } | %{ $_.IP })
if ($existingIPs.GetType().FullName -eq "System.String") {
	$existingIPs = New-Object System.Collections.ArrayList(, @($existingIPs))
} else {
	$existingIPs = New-Object System.Collections.ArrayList(, $existingIPs)
}
# Check desired IP addresses
for ($i = 0; $i -lt $iscsiIps.Length; $i++) {
	$ip = $iscsiIps[$i]
	if (!$existingIPs.Contains($ip)) {
		$iscsiName = get-iSCSINameFromIndex($i) 
		Write-Host -ForegroundColor green "Creating new VMKernel port $iscsiName with address: $ip"
		$VMhost | New-VMHostNetworkAdapter `
			-PortGroup $iscsiName `
			-IP $ip `
			-SubnetMask 255.255.255.0 `
			-Mtu $mtu `
			-ManagementTrafficEnabled $false `
			-VMotionEnabled $false `
			-VirtualSwitch $iscsiVirtualSwitch
	} else {
		Write-Host "Network adaptor with IP address $ip already exists, checking settings"
		$vmnic = $VMhost | Get-VMHostNetworkAdapter | Where-object { $_.IP -eq $ip }
		if ($vmnic.ManagementTrafficEnabled) {
			Write-Warning ([string]::Format("Disabling Management Traffic on {0}", $vmnic.Name))
			$VMhost | Set-VMHostNetworkAdaptor -VirtualNic -ManagementTrafficEnabled $false
		}
		if ($vmnic.VMotionEnabled) {
			Write-Warning ([string]::Format("Disabling VMotion on {0}", $vmnic.Name))
			$VMhost | Set-VMHostNetworkAdaptor -VirtualNic -VMotionEnabled $false
		}
		if ($vmnic.IPv6Enabled) {
			Write-Warning ([string]::Format("Disabling IPv6 on {0}", $vmnic.Name))
			$VMhost | Set-VMHostNetworkAdaptor -VirtualNic -IPv6Enabled $false
		}
		if ($vmnic.Mtu -ne $mtu) {
			Write-Warning ([string]::Format("Setting MTU to $mtu on {0}", $vmnic.Name))
			$VMhost | Set-VMHostNetworkAdaptor -VirtualNic -Mtu $mtu
		}
	}
}


# Nic Teaming Policy
for ($i = 0; $i -lt $iscsiIps.Length; $i++) {
	$iscsiName = get-iSCSINameFromIndex($i) 
	$activeNic = $iscsiNics[$i]
	Write-Host "Checking NIC teaming policy for $iscsiName port group"
	$portGroupTeamingPolicy = $VMhost | Get-VirtualPortGroup -VirtualSwitch $iscsiVirtualSwitch -Name $iscsiName | Get-NicTeamingPolicy
	if (($portGroupTeamingPolicy.ActiveNic.Length -ne 1) -or ($portGroupTeamingPolicy.ActiveNic[0] -ne $activeNic)) {
		Write-Host -ForegroundColor green ([string]::Format("Binding port group {0} to NIC {1}", $iscsiName, $activeNic))
		$unusedNics = @()
		for ($j = 0; $j -lt $iscsiNics.Length; $j++) { if ($j -ne $i) { $unusedNics += $iscsiNics[$j] } }
		Set-NicTeamingPolicy -VirtualPortGroup $portGroupTeamingPolicy -MakeNicUnused $unusedNics -MakeNicActive $iscsiNics[$i]
	}
}

Write-Host "Checking Software iSCSI initiator"
$vmhostStorage = Get-VMHostStorage -VMHost $VMhost
if (!$vmhostStorage.SoftwareIScsiEnabled) {
	Write-Host -ForegroundColor green "Enabling Software iSCSI initiator"
	$vmhostStorage | Set-VMHostStorage -SoftwareIScsiEnabled $true
	#sleep while iSCSI starts up
	Start-Sleep -Seconds 30   
}

# Get Software iSCSI Adaptor HBA number
Write-Host "Checking iSCSI HBA"
$iscsiHba = $VMhost | Get-VMHostHba | Where-object { $_.Type -match "IScsi" } | Where-object { $_.Model -match "iSCSI Software Adapter" }
$iscsiHbaNumber = $iscsiHba | %{$_.Device}
# Get a CLI instance
$esxCli = Get-EsxCli -Server $VIServer

# Check each vmk binding
$iscsiIps | Foreach-object {
	$ip = $_
	$iscsiVmkNumber = $VMhost | Get-VMHostNetworkAdapter | Where-object { $_.IP -match $ip } | %{ $_.Name }
	Write-Host -ForegroundColor green "Binding VMKernel Port $iscsiVmkNumber to $iscsiHbaNumber"
	$esxCli.swiscsi.nic.add($iscsiHbaNumber, $iscsiVmkNumber)
}

Disconnect-VMHost
