param (
        [string] $PackageFilename = (Read-Host "Package filename to deploy"),
        [string] $ADGroupDistinguishedName = (Read-Host "Distinguished Name of Active Directory group to deploy to"),
        [string] $DestinationUNCPath = (Read-Host "UNC path for installation on each computer"),
        [string] $ServiceName = (Read-Host "Name of the service being deployed")
)

# Import Utilities
. (Join-Path -Path (Split-Path -parent $MyInvocation.MyCommand.Definition) -ChildPath ".\7-zip.ps1")

### Check package file exists
Write-Host "Checking package file..." 
if (!(Test-Path $PackageFilename)) {
        Write-Error "Package file [$PackageFilename] could not be found or accessed."
        exit 1
}

### Get Active Directory group
Write-Host "Looking up group in active directory..."
$adRoot = ([ADSI]"").distinguishedName
$ADGroupDistinguishedName = "$ADGroupDistinguishedName,$adRoot"
$adGroup = [ADSI]("LDAP://$ADGroupDistinguishedName")
if ($adGroup -eq $null -or $adGroup.distinguishedName -eq $null) {
        Write-Error "Group was not found in directory: [$ADGroupDistinguishedName]"
        exit 1
}
Write-Host "Active directory group found: [" $adGroup.distinguishedName "]."

### Get computer members of group
Write-Host "Looking up members of group..."
$filter = "(&amp;(objectCategory=computer)(memberOf=" + $adGroup.distinguishedName + "))"
$search = New-Object System.DirectoryServices.DirectorySearcher($filter)
[void]$search.PropertiesToLoad.Add("dNSHostName")
$members = $search.FindAll() 
# Error handling is a bit odd since FindAll() is not executed until comparing the result with $null
try {
        $error.Clear()
        if ($members -eq $null -or $members.Count -eq 0) { Write-Error "No computers found in group." }
        $memberCount = $members.Count
} catch {
        Write-Error $error[0]
        exit 1
}
Write-Host $memberCount "computers found in group."

### Deploy to each member
$deployedCount = 0
foreach ($member in $members) {
        $computerFQDN = $member.Properties.Item("dNSHostName")
        Write-Host "Starting deploy to $computerFQDN..."
        
        ### Test connection to computer
        Write-Host "Testing connection..."
        if (!(Test-Connection $computerFQDN -quiet)) {
                Write-Error "Unable to deploy to $computerFQDN. Computer is not reachable."
                continue
        }
        
        ### Get the remote service
        Write-Host "Getting service: [$ServiceName]"
        $service = Get-Service -DisplayName $ServiceName -ComputerName $computerFQDN -ErrorAction SilentlyContinue
        if ($service -eq $null) {
                Write-Error "Service [$ServiceName] was not found, or there are insufficient permissions to query the service on $computerFQDN."
                continue
        }
        
        ### Stop service
        if ($service.Status -eq "Running") {
                Write-Host "Stopping service..."
                $error.Clear()
                Stop-Service -InputObject $service -ErrorAction SilentlyContinue
                if (!$?) {
                        Write-Error $error[0]
                        continue
                }

                Write-Host "Waiting for service to stop..."
                Sleep 5
        } else {
                Write-Warning "Service [$ServiceName] is already stopped on [$computerFQDN]."
        }

        ### Check service has stopped
        if ($service.Status -ne "Stopped") {
                Write-Error "Service has not responded to stop request, cannot continue deployment to $computerFQDN."
                continue
        }

        ### Unzip and overwrite existing files
        $error.Clear()
        try {
                $destinationPath = "\\" + (Join-Path $computerFQDN $DestinationUNCPath)
                Write-Host "Testing destination path..."
                if (Test-Path $destinationPath) {
                        Write-Host "Unzipping $PackageFilename to $destinationPath..."
                        Unzip-File $PackageFilename $destinationPath
                } else {
                        throw "Could not access destination path [$destinationPath]. Unable to deploy to $computerFQDN."
                }
        } catch {
                Write-Error $error[0]
                continue
        } finally {
                ### Start service
                Write-Host "Starting service..."
                $error.Clear()
                Start-Service -InputObject $service -ErrorAction SilentlyContinue
                if (!$?) {
                        Write-Error $error[0]
                        continue
                }
        }
        
        Write-Host -ForegroundColor green "Deployed successfully to $computerFQDN"
        $deployedCount++
}

### Check final results
if ($deployedCount -eq $memberCount) {
        Write-Host -ForegroundColor green "Successfully deployed to all clients."
        exit 0
} else {
        Write-Warning ([string]::Format("Deployed to {0} of {1} computers.", $deployedCount, $memberCount))
        exit 1
}
