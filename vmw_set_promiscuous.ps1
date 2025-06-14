# VMware vSwitch Promiscuous Mode Configuration Script
# This script connects to vCenter and sets Promiscuous mode to "Accept" on all standard vSwitches
# across all ESXi hosts in the environment

param(
    [Parameter(Mandatory=$true)]
    [string]$vCenterServer,
    
    [Parameter(Mandatory=$false)]
    [string]$Username,
    
    [Parameter(Mandatory=$false)]
    [string]$Password,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf = $false
)

# Import VMware PowerCLI module
try {
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Write-Host "VMware PowerCLI module loaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to import VMware PowerCLI module. Please ensure it's installed."
    Write-Host "Install with: Install-Module -Name VMware.PowerCLI -Force" -ForegroundColor Yellow
    exit 1
}

# Disable certificate warnings (optional - remove in production environments)
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session

# Function to get credentials if not provided
function Get-vCenterCredentials {
    if (-not $Username) {
        $Username = Read-Host "Enter vCenter username"
    }
    if (-not $Password) {
        $SecurePassword = Read-Host "Enter vCenter password" -AsSecureString
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword))
    }
    return @{Username = $Username; Password = $Password}
}

# Function to configure promiscuous mode on a vSwitch
function Set-vSwitchPromiscuousMode {
    param(
        [Parameter(Mandatory=$true)]
        $VMHost,
        [Parameter(Mandatory=$true)]
        $vSwitch,
        [Parameter(Mandatory=$false)]
        [bool]$WhatIfMode = $false
    )
    
    try {
        $securityPolicy = Get-SecurityPolicy -VirtualSwitch $vSwitch
        $currentSetting = $securityPolicy.AllowPromiscuous
        
        if ($currentSetting -eq $true) {
            Write-Host "  └─ vSwitch '$($vSwitch.Name)' already has Promiscuous mode set to Accept" -ForegroundColor Gray
            return $false
        }
        
        if ($WhatIfMode) {
            Write-Host "  └─ WHAT-IF: Would change vSwitch '$($vSwitch.Name)' Promiscuous mode from $currentSetting to Accept" -ForegroundColor Yellow
            return $true
        } else {
            $securityPolicy | Set-SecurityPolicy -AllowPromiscuous $true | Out-Null
            Write-Host "  └─ Successfully changed vSwitch '$($vSwitch.Name)' Promiscuous mode to Accept" -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Warning "  └─ Failed to configure vSwitch '$($vSwitch.Name)': $($_.Exception.Message)"
        return $false
    }
}

# Main script execution
try {
    Write-Host "=== VMware vSwitch Promiscuous Mode Configuration ===" -ForegroundColor Cyan
    Write-Host "Target vCenter: $vCenterServer" -ForegroundColor White
    
    if ($WhatIf) {
        Write-Host "Running in WHAT-IF mode - no changes will be made" -ForegroundColor Yellow
        Write-Host ""
    }
    
    # Get credentials if not provided
    if (-not $Username -or -not $Password) {
        $creds = Get-vCenterCredentials
        $Username = $creds.Username
        $Password = $creds.Password
    }
    
    # Connect to vCenter
    Write-Host "Connecting to vCenter Server..." -ForegroundColor Yellow
    $connection = Connect-VIServer -Server $vCenterServer -User $Username -Password $Password -ErrorAction Stop
    Write-Host "Successfully connected to $($connection.Name) ($($connection.Version))" -ForegroundColor Green
    Write-Host ""
    
    # Initialize counters
    $totalHosts = 0
    $totalvSwitches = 0
    $changedvSwitches = 0
    $errorCount = 0
    
    # Get all datacenters
    $datacenters = Get-Datacenter
    Write-Host "Found $($datacenters.Count) datacenter(s)" -ForegroundColor White
    
    foreach ($datacenter in $datacenters) {
        Write-Host "Processing Datacenter: $($datacenter.Name)" -ForegroundColor Cyan
        
        # Get all hosts in this datacenter (including those in clusters)
        $vmhosts = Get-VMHost -Location $datacenter
        $totalHosts += $vmhosts.Count
        
        Write-Host "  Found $($vmhosts.Count) ESXi host(s)" -ForegroundColor White
        
        foreach ($vmhost in $vmhosts) {
            Write-Host "  Processing Host: $($vmhost.Name) ($($vmhost.ConnectionState))" -ForegroundColor White
            
            # Skip if host is not connected
            if ($vmhost.ConnectionState -ne "Connected") {
                Write-Warning "    Host is not connected - skipping"
                continue
            }
            
            # Get all standard vSwitches for this host
            try {
                $vSwitches = Get-VirtualSwitch -VMHost $vmhost -Standard
                $totalvSwitches += $vSwitches.Count
                
                if ($vSwitches.Count -eq 0) {
                    Write-Host "    No standard vSwitches found" -ForegroundColor Gray
                    continue
                }
                
                Write-Host "    Found $($vSwitches.Count) standard vSwitch(es)" -ForegroundColor White
                
                foreach ($vSwitch in $vSwitches) {
                    $result = Set-vSwitchPromiscuousMode -VMHost $vmhost -vSwitch $vSwitch -WhatIfMode $WhatIf
                    if ($result) {
                        $changedvSwitches++
                    }
                }
            } catch {
                Write-Warning "    Failed to process host $($vmhost.Name): $($_.Exception.Message)"
                $errorCount++
            }
        }
        Write-Host ""
    }
    
    # Summary
    Write-Host "=== Summary ===" -ForegroundColor Cyan
    Write-Host "Total ESXi Hosts processed: $totalHosts" -ForegroundColor White
    Write-Host "Total standard vSwitches found: $totalvSwitches" -ForegroundColor White
    
    if ($WhatIf) {
        Write-Host "vSwitches that would be changed: $changedvSwitches" -ForegroundColor Yellow
    } else {
        Write-Host "vSwitches successfully configured: $changedvSwitches" -ForegroundColor Green
    }
    
    if ($errorCount -gt 0) {
        Write-Host "Errors encountered: $errorCount" -ForegroundColor Red
    }
    
} catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    exit 1
} finally {
    # Disconnect from vCenter
    if ($connection) {
        Write-Host ""
        Write-Host "Disconnecting from vCenter..." -ForegroundColor Yellow
        Disconnect-VIServer -Server $vCenterServer -Confirm:$false
        Write-Host "Disconnected successfully" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Script execution completed!" -ForegroundColor Green
