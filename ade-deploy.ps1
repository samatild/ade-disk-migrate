#Requires -Version 5.1
#Requires -Modules Az.Compute, Az.Network, Az.Resources

#
# ade-deploy.ps1 — Azure Linux Encrypted Disk Migration Orchestrator
#
# Copyright (c) 2026 Samuel Matildes. All rights reserved.
# Licensed under the MIT License. See LICENSE file in the project root.
#

<#
.SYNOPSIS
    Azure Linux Encrypted Disk Migration — Deployment Automation
.DESCRIPTION
    Automates migration of an Azure Linux VM with an encrypted (ADE) OS disk
    to a new VM with a raw (unencrypted) OS disk.

    Default mode (replace):
      Migrates the disk, deletes the source VM, then recreates it with the
      same name reusing the original NIC/PIP/NSG and the new unencrypted OS disk.

    Clone mode (-Clone):
      Creates a separate copy VM alongside the source (which is left untouched).

    Steps:
      1. Validates Azure login and parameters
      2. Creates a blank data disk (OS disk size + 1 GB)
      3. Attaches data disk to source VM
      4. Uploads and runs ade-migrate.sh on the VM via Run Command
      5. Detaches the data disk
      6. Creates a bootable OS disk from the data disk
      7. Deletes source VM and recreates with unencrypted disk (or creates copy)
.PARAMETER SubscriptionId
    Azure Subscription ID. Prompted if not provided.
.PARAMETER ResourceGroupName
    Resource Group containing the source VM.
.PARAMETER VMName
    Name of the source VM with encrypted OS disk.
.PARAMETER Clone
    Create a separate clone VM instead of replacing the source VM.
    The source VM is left untouched and a new VM named <VMName>-migrated is created.
.EXAMPLE
    ./ade-deploy.ps1 -SubscriptionId "abc-123" -ResourceGroupName "myRG" -VMName "myVM"
    # Replaces source VM in-place with unencrypted OS disk
.EXAMPLE
    ./ade-deploy.ps1 -SubscriptionId "abc-123" -ResourceGroupName "myRG" -VMName "myVM" -Clone
    # Creates a separate clone VM, source is untouched
.EXAMPLE
    ./ade-deploy.ps1   # Prompts for parameters interactively
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$VMName,
    [switch]$Clone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ─── Output Helpers ────────────────────────────────────────────────────

function Write-Header {
    param([string]$Text)
    $pad = 58 - $Text.Length
    if ($pad -lt 0) { $pad = 0 }
    $left = [math]::Floor($pad / 2)
    $right = [math]::Ceiling($pad / 2)
    $paddedText = (' ' * $left) + $Text + (' ' * $right)
    Write-Host ""
    Write-Host "  ╔$('═' * 60)╗" -ForegroundColor Cyan
    Write-Host "  ║ $paddedText ║" -ForegroundColor Cyan
    Write-Host "  ╚$('═' * 60)╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "  ● $Text" -ForegroundColor White
}

function Write-Detail {
    param([string]$Text)
    Write-Host "    → $Text" -ForegroundColor DarkGray
}

function Write-OK {
    param([string]$Text)
    Write-Host "  ✔ $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  ⚠ $Text" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    Write-Host "  ✘ $Text" -ForegroundColor Red
}

#endregion

#region ─── Helpers ───────────────────────────────────────────────────────────

function Read-Param {
    param([string]$Label, [string]$Current)
    if ([string]::IsNullOrWhiteSpace($Current)) {
        $Current = Read-Host "  ? $Label"
        if ([string]::IsNullOrWhiteSpace($Current)) {
            Write-Err "$Label is required. Exiting."
            exit 1
        }
    }
    return $Current.Trim()
}

function Invoke-VMScript {
    param(
        [string]$RG,
        [string]$VM,
        [string]$Script,
        [string]$Description
    )
    Write-Step "$Description..."
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $RG `
        -VMName $VM `
        -CommandId 'RunShellScript' `
        -ScriptString $Script

    $stdout = if ($result.Value -and $result.Value.Count -gt 0) { $result.Value[0].Message } else { "" }
    $stderr = if ($result.Value -and $result.Value.Count -gt 1) { $result.Value[1].Message } else { "" }
    return @{ Stdout = $stdout; Stderr = $stderr }
}

#endregion

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║    Azure Linux Encrypted Disk Migration — Deployer       ║" -ForegroundColor Cyan
Write-Host "  ║                       v1.0.0                             ║" -ForegroundColor Cyan
Write-Host "  ╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Track created resources for cleanup on failure
$createdResources = [System.Collections.ArrayList]::new()

try {

    # ── Step 1: Azure Authentication ─────────────────────────────────────────
    Write-Header "Step 1: Azure Authentication"

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) {
        Write-Warn "Not logged in to Azure"
        Write-Step "Opening browser for Azure login..."
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext
        if (-not $ctx) {
            Write-Err "Login failed. Exiting."
            exit 1
        }
    }
    Write-OK "Logged in as $($ctx.Account.Id)"

    # ── Step 2: Parameters ───────────────────────────────────────────────────
    Write-Header "Step 2: Parameters"

    $SubscriptionId    = Read-Param -Label "Subscription ID" -Current $SubscriptionId
    $ResourceGroupName = Read-Param -Label "Resource Group"  -Current $ResourceGroupName
    $VMName            = Read-Param -Label "Source VM Name"   -Current $VMName

    if ($ctx.Subscription.Id -ne $SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }

    Write-Detail "Subscription:   $SubscriptionId"
    Write-Detail "Resource Group: $ResourceGroupName"
    Write-Detail "Source VM:      $VMName"
    Write-OK "Parameters set"

    # ── Step 3: Source VM Discovery ──────────────────────────────────────────
    Write-Header "Step 3: Source VM Discovery"

    Write-Step "Fetching VM details..."
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
    $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction Stop

    $location = $vm.Location
    $vmSize   = $vm.HardwareProfile.VmSize
    $zones    = $vm.Zones

    # OS disk info
    $osDiskName   = $vm.StorageProfile.OsDisk.Name
    $osDisk       = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $osDiskName -ErrorAction Stop
    $osDiskSizeGB = $osDisk.DiskSizeGB
    $osDiskSku    = $osDisk.Sku.Name
    $hyperVGen    = if ($osDisk.HyperVGeneration) { $osDisk.HyperVGeneration } else { "V1" }

    # Power state
    $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus

    Write-Detail "Location:       $location"
    Write-Detail "VM Size:        $vmSize"
    Write-Detail "Zone:           $(if ($zones) { $zones -join ',' } else { 'None' })"
    Write-Detail "OS Disk:        $osDiskName ($osDiskSizeGB GB, $osDiskSku)"
    Write-Detail "Hyper-V Gen:    $hyperVGen"
    Write-Detail "Power State:    $powerState"

    if ($powerState -ne 'VM running') {
        Write-Err "Source VM must be running (current: $powerState)"
        exit 1
    }

    # Data disks
    $sourceDataDiskRefs = @()
    foreach ($dd in $vm.StorageProfile.DataDisks) {
        $ddDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dd.Name -ErrorAction SilentlyContinue
        $ddSizeGB = if ($ddDisk) { $ddDisk.DiskSizeGB } else { '?' }
        $ddSku    = if ($ddDisk) { $ddDisk.Sku.Name } else { 'Unknown' }
        Write-Detail "Data Disk:      $($dd.Name) ($ddSizeGB GB, $ddSku, LUN $($dd.Lun))"
        $sourceDataDiskRefs += @{
            Name    = $dd.Name
            Id      = $dd.ManagedDisk.Id
            Lun     = $dd.Lun
            Caching = $dd.Caching
            SizeGB  = $ddSizeGB
            Sku     = $ddSku
        }
    }
    if ($sourceDataDiskRefs.Count -eq 0) {
        Write-Detail "Data Disks:     None"
    }

    # Source networking (reuse subnet for new VM)
    $sourceNicId   = $vm.NetworkProfile.NetworkInterfaces[0].Id
    $sourceNicName = ($sourceNicId -split '/')[-1]
    $sourceNicRG   = ($sourceNicId -split '/')[4]
    $sourceNic     = Get-AzNetworkInterface -ResourceGroupName $sourceNicRG -Name $sourceNicName
    $sourceSubnetId = $sourceNic.IpConfigurations[0].Subnet.Id

    Write-OK "Source VM discovered"

    # ── Step 4: Create Target Data Disk ──────────────────────────────────────
    Write-Header "Step 4: Create Target Data Disk"

    $dataDiskName   = "$VMName-migrated-data"
    $dataDiskSizeGB = $osDiskSizeGB + 1

    # Check if disk already exists
    $existingDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dataDiskName -ErrorAction SilentlyContinue
    if ($existingDisk) {
        Write-Err "Disk '$dataDiskName' already exists. Delete it first or rename."
        exit 1
    }

    Write-Step "Creating: $dataDiskName ($dataDiskSizeGB GB, $osDiskSku)"

    $diskConfig = New-AzDiskConfig `
        -Location $location `
        -DiskSizeGB $dataDiskSizeGB `
        -SkuName $osDiskSku `
        -CreateOption Empty

    if ($zones) { $diskConfig.Zones = $zones }

    $dataDisk = New-AzDisk `
        -ResourceGroupName $ResourceGroupName `
        -DiskName $dataDiskName `
        -Disk $diskConfig

    [void]$createdResources.Add("Disk: $dataDiskName")

    Write-Detail "Disk ID: $($dataDisk.Id)"
    Write-OK "Data disk created"

    # ── Step 5: Attach Data Disk ─────────────────────────────────────────────
    Write-Header "Step 5: Attach Data Disk to Source VM"

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    $usedLuns = @($vm.StorageProfile.DataDisks | ForEach-Object { $_.Lun })
    $lun = 0
    while ($usedLuns -contains $lun) { $lun++ }

    Write-Step "Attaching at LUN $lun..."
    $vm = Add-AzVMDataDisk -VM $vm `
        -Name $dataDiskName `
        -ManagedDiskId $dataDisk.Id `
        -Lun $lun `
        -CreateOption Attach

    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -ErrorAction Stop | Out-Null
    Write-OK "Data disk attached at LUN $lun"

    # ── Step 6: Run Migration Script ─────────────────────────────────────────
    Write-Header "Step 6: Run Migration Script"

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $migrateScript = Join-Path $scriptDir 'ade-migrate.sh'
    if (-not (Test-Path $migrateScript)) {
        Write-Err "ade-migrate.sh not found at: $migrateScript"
        Write-Err "Ensure ade-migrate.sh is in the same directory as ade-deploy.ps1"
        exit 1
    }

    # Upload script via base64 to avoid escaping issues
    $scriptBytes = [System.IO.File]::ReadAllBytes($migrateScript)
    $b64 = [Convert]::ToBase64String($scriptBytes)

    $uploadCmd = "echo '$b64' | base64 -d > /tmp/ade-migrate.sh && chmod +x /tmp/ade-migrate.sh && echo UPLOAD_OK"

    $upload = Invoke-VMScript -RG $ResourceGroupName -VM $VMName `
        -Script $uploadCmd `
        -Description "Uploading ade-migrate.sh to VM"

    if ($upload.Stdout -notmatch 'UPLOAD_OK') {
        Write-Err "Script upload failed"
        if ($upload.Stderr) { Write-Detail $upload.Stderr }
        exit 1
    }
    Write-OK "ade-migrate.sh uploaded"

    # Execute migration
    Write-Step "Running migration (this may take several minutes)..."
    Write-Detail "Run Command timeout: ~90 min. For disks >500 GB, run manually."
    Write-Host ""

    $runCmd = 'bash /tmp/ade-migrate.sh --yes 2>&1; echo "###MIGRATE_EXIT=$?###"'

    $run = Invoke-VMScript -RG $ResourceGroupName -VM $VMName `
        -Script $runCmd `
        -Description "Executing migration"

    # Parse exit code from output
    $exitMatch = [regex]::Match($run.Stdout, '###MIGRATE_EXIT=(\d+)###')
    $migrateExitCode = if ($exitMatch.Success) { [int]$exitMatch.Groups[1].Value } else { -1 }

    if ($migrateExitCode -ne 0) {
        Write-Err "Migration failed (exit code: $migrateExitCode)"
        Write-Host ""

        # Fetch log for diagnostics
        $log = Invoke-VMScript -RG $ResourceGroupName -VM $VMName `
            -Script 'ls -t /var/log/azmigrate-*.log 2>/dev/null | head -1 | xargs tail -30 2>/dev/null' `
            -Description "Fetching migration log"

        $log.Stdout -split "`n" | ForEach-Object { Write-Detail $_ }

        # Cleanup: detach disk
        Write-Host ""
        Write-Warn "Detaching data disk (preserving for inspection)..."
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
        Remove-AzVMDataDisk -VM $vm -Name $dataDiskName | Out-Null
        Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm | Out-Null
        Write-Warn "Data disk '$dataDiskName' preserved in resource group for debugging"
        exit 1
    }

    Write-OK "Migration completed successfully"

    # Parse structured summary from Run Command output
    $summaryData = @{}
    $rawOutput = $run.Stdout -replace '\x1b\[[0-9;]*m', ''
    $inSummary = $false
    foreach ($line in ($rawOutput -split "`n")) {
        if ($line -match 'MIGRATION_SUMMARY_START') { $inSummary = $true; continue }
        if ($line -match 'MIGRATION_SUMMARY_END') { $inSummary = $false; continue }
        if ($inSummary -and $line -match '^([A-Z_]+)=(.*)$') {
            $summaryData[$Matches[1]] = $Matches[2]
        }
    }

    if ($summaryData.Count -gt 0) {
        $srcDisk = $summaryData['SOURCE_DISK']
        $srcSize = $summaryData['SOURCE_SIZE']
        $tgtDisk = $summaryData['TARGET_DISK']
        $tgtSize = $summaryData['TARGET_SIZE']
        $rootFs  = $summaryData['ROOT_FS']
        $rootUuid = $summaryData['ROOT_UUID']
        $bootUuid = $summaryData['BOOT_UUID']
        $efiUuid  = $summaryData['EFI_UUID']
        $logPath  = $summaryData['LOG_FILE']

        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor Cyan
        Write-Host "  │  Migration Results                                  │" -ForegroundColor Cyan
        Write-Host "  ├──────────────────────────────────────────────────────┤" -ForegroundColor Cyan
        Write-Detail "Source:  $srcDisk [$srcSize, encrypted]"
        Write-Detail "Target:  $tgtDisk [$tgtSize, raw]"
        Write-Detail "Root FS: $rootFs  UUID: $rootUuid"
        Write-Detail "Boot:    UUID: $bootUuid"
        Write-Detail "EFI:     UUID: $efiUuid"
        Write-Detail "Log:     $logPath"
        Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor Cyan
        Write-Host ""
    } else {
        # Fallback: show raw log tail
        $log = Invoke-VMScript -RG $ResourceGroupName -VM $VMName `
            -Script 'ls -t /var/log/azmigrate-*.log 2>/dev/null | head -1 | xargs tail -15 2>/dev/null' `
            -Description "Fetching migration summary"
        $cleanLog = $log.Stdout -replace '\x1b\[[0-9;]*m', ''
        $cleanLog -split "`n" | ForEach-Object { Write-Detail $_ }
    }

    # ── Step 7: Detach Data Disk ─────────────────────────────────────────────
    Write-Header "Step 7: Detach Migrated Disk"

    Write-Step "Detaching data disk from source VM..."
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    Remove-AzVMDataDisk -VM $vm -Name $dataDiskName | Out-Null
    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -ErrorAction Stop | Out-Null
    Write-OK "Data disk detached"

    # ── Step 8: Create OS Disk ───────────────────────────────────────────────
    Write-Header "Step 8: Create Bootable OS Disk"

    $osDiskNewName = "$VMName-migrated-os"

    $existingOsDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $osDiskNewName -ErrorAction SilentlyContinue
    if ($existingOsDisk) {
        Write-Err "Disk '$osDiskNewName' already exists. Delete it first or rename."
        exit 1
    }

    Write-Step "Creating OS disk: $osDiskNewName"

    $dataDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dataDiskName

    $osConfig = New-AzDiskConfig `
        -Location $location `
        -CreateOption Copy `
        -SourceResourceId $dataDisk.Id `
        -OsType Linux `
        -SkuName $osDiskSku `
        -HyperVGeneration $hyperVGen

    if ($zones) { $osConfig.Zones = $zones }

    $newOsDisk = New-AzDisk `
        -ResourceGroupName $ResourceGroupName `
        -DiskName $osDiskNewName `
        -Disk $osConfig

    [void]$createdResources.Add("Disk: $osDiskNewName")

    Write-Detail "Disk ID: $($newOsDisk.Id)"
    Write-OK "OS disk created"

    # ── Step 9: Create VM ──────────────────────────────────────────────────
    if ($Clone) {
        # --- Clone mode: create a new VM alongside the source ---
        Write-Header "Step 9: Create Clone VM"

        $newVMName = "$VMName-migrated"
        Write-Step "Creating VM: $newVMName (size: $vmSize)"

        # Public IP
        $pipName = "$newVMName-pip"
        Write-Detail "Creating public IP: $pipName"

        $pip = New-AzPublicIpAddress `
            -ResourceGroupName $ResourceGroupName `
            -Location $location `
            -Name $pipName `
            -AllocationMethod Static `
            -Sku Standard

        [void]$createdResources.Add("PIP: $pipName")

        # NIC in same subnet as source VM
        $nicName = "$newVMName-nic"
        Write-Detail "Creating NIC: $nicName (same subnet as source)"

        $nicParams = @{
            ResourceGroupName = $ResourceGroupName
            Location          = $location
            Name              = $nicName
            SubnetId          = $sourceSubnetId
            PublicIpAddressId = $pip.Id
        }
        if ($sourceNic.NetworkSecurityGroup) {
            $nicParams['NetworkSecurityGroupId'] = $sourceNic.NetworkSecurityGroup.Id
        }

        $nic = New-AzNetworkInterface @nicParams
        [void]$createdResources.Add("NIC: $nicName")

        # Copy data disks for the copy VM
        $copiedDataDisks = @()
        foreach ($dd in $sourceDataDiskRefs) {
            $copyName = "$newVMName-$($dd.Name)"
            Write-Detail "Copying data disk: $($dd.Name) -> $copyName ($($dd.SizeGB) GB)"

            $existingCopy = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $copyName -ErrorAction SilentlyContinue
            if ($existingCopy) {
                Write-Warn "Disk '$copyName' already exists, skipping copy"
                $copiedDataDisks += @{ Name = $copyName; Id = $existingCopy.Id; Lun = $dd.Lun; Caching = $dd.Caching }
                continue
            }

            $ddCopyConfig = New-AzDiskConfig `
                -Location $location `
                -CreateOption Copy `
                -SourceResourceId $dd.Id `
                -SkuName $dd.Sku

            if ($zones) { $ddCopyConfig.Zones = $zones }

            $copiedDisk = New-AzDisk `
                -ResourceGroupName $ResourceGroupName `
                -DiskName $copyName `
                -Disk $ddCopyConfig

            [void]$createdResources.Add("Disk: $copyName")
            $copiedDataDisks += @{ Name = $copyName; Id = $copiedDisk.Id; Lun = $dd.Lun; Caching = $dd.Caching }
            Write-OK "Copied: $copyName"
        }

        # VM config
        $vmConfig = New-AzVMConfig -VMName $newVMName -VMSize $vmSize
        if ($zones) { $vmConfig.Zones = $zones }

        Set-AzVMOSDisk -VM $vmConfig `
            -ManagedDiskId $newOsDisk.Id `
            -CreateOption Attach `
            -Linux | Out-Null

        Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id | Out-Null
        Set-AzVMBootDiagnostic -VM $vmConfig -Disable | Out-Null

        # Attach copied data disks
        foreach ($cd in $copiedDataDisks) {
            Write-Detail "Attaching data disk: $($cd.Name) at LUN $($cd.Lun)"
            Add-AzVMDataDisk -VM $vmConfig `
                -Name $cd.Name `
                -ManagedDiskId $cd.Id `
                -Lun $cd.Lun `
                -Caching $cd.Caching `
                -CreateOption Attach | Out-Null
        }

        Write-Detail "Provisioning VM (this takes 1-2 minutes)..."
        $null = New-AzVM `
            -ResourceGroupName $ResourceGroupName `
            -Location $location `
            -VM $vmConfig `
            -ErrorAction Stop `
            -WarningAction SilentlyContinue

        [void]$createdResources.Add("VM: $newVMName")

        # Refresh PIP to get assigned address
        $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $pipName

        Write-OK "VM created: $newVMName"
        Write-Detail "Public IP: $($pip.IpAddress)"

    } else {
        # --- Default mode: replace source VM in-place ---
        Write-Header "Step 9: Replace Source VM"

        Write-Step "Stopping source VM: $VMName..."
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -ErrorAction Stop | Out-Null
        Write-OK "Source VM stopped"

        Write-Step "Deleting source VM: $VMName (NIC and disks are preserved)..."
        Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -ErrorAction Stop | Out-Null
        Write-OK "Source VM deleted"

        Write-Step "Recreating VM: $VMName with unencrypted OS disk..."

        # Reuse the original NIC
        $vmConfig = New-AzVMConfig -VMName $VMName -VMSize $vmSize
        if ($zones) { $vmConfig.Zones = $zones }

        Set-AzVMOSDisk -VM $vmConfig `
            -ManagedDiskId $newOsDisk.Id `
            -CreateOption Attach `
            -Linux | Out-Null

        Add-AzVMNetworkInterface -VM $vmConfig -Id $sourceNicId | Out-Null
        Set-AzVMBootDiagnostic -VM $vmConfig -Disable | Out-Null

        # Re-attach original data disks (excluding migration artifact)
        foreach ($dd in $sourceDataDiskRefs) {
            if ($dd.Name -eq $dataDiskName) { continue }
            Write-Detail "Re-attaching data disk: $($dd.Name) at LUN $($dd.Lun)"
            Add-AzVMDataDisk -VM $vmConfig `
                -Name $dd.Name `
                -ManagedDiskId $dd.Id `
                -Lun $dd.Lun `
                -Caching $dd.Caching `
                -CreateOption Attach | Out-Null
        }

        Write-Detail "Provisioning VM (this takes 1-2 minutes)..."
        $null = New-AzVM `
            -ResourceGroupName $ResourceGroupName `
            -Location $location `
            -VM $vmConfig `
            -ErrorAction Stop `
            -WarningAction SilentlyContinue

        Write-OK "VM recreated: $VMName"

        # Show IP from original NIC
        $sourceNic = Get-AzNetworkInterface -ResourceGroupName $sourceNicRG -Name $sourceNicName
        $pipRef = $sourceNic.IpConfigurations[0].PublicIpAddress
        if ($pipRef) {
            $pipResource = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName `
                -Name ($pipRef.Id -split '/')[-1] -ErrorAction SilentlyContinue
            if ($pipResource -and $pipResource.IpAddress) {
                Write-Detail "Public IP: $($pipResource.IpAddress) (same as before)"
            }
        }
        $privateIp = $sourceNic.IpConfigurations[0].PrivateIpAddress
        if ($privateIp) {
            Write-Detail "Private IP: $privateIp (same as before)"
        }
    }

    # ── Summary ──────────────────────────────────────────────────────────────
    Write-Header "Deployment Complete"

    if ($Clone) {
        Write-Step "Source VM:      $VMName [unchanged, still running]"
        Write-Step "Data Disk:      $dataDiskName [migration artifact]"
        Write-Step "OS Disk:        $osDiskNewName [bootable, unencrypted]"

        $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName `
            -Name "$newVMName-pip" -ErrorAction SilentlyContinue
        Write-Step "New VM:         $newVMName"
        if ($pip -and $pip.IpAddress) {
            Write-Step "Public IP:      $($pip.IpAddress)"
            Write-Host ""
            Write-Detail ('SSH: ssh <username>@' + $pip.IpAddress)
        }

        Write-Host ""
        Write-Warn ("Cleanup: delete " + $dataDiskName + " once verified -- it is the raw migration copy")
    } else {
        Write-Step "VM:             $VMName [replaced in-place, unencrypted]"
        Write-Step "OS Disk:        $osDiskNewName [bootable, unencrypted]"
        Write-Step "Old OS Disk:    $osDiskName [encrypted, preserved]"
        Write-Step "Data Disk:      $dataDiskName [migration artifact]"

        # Show IP
        $sourceNic = Get-AzNetworkInterface -ResourceGroupName $sourceNicRG -Name $sourceNicName
        $pipRef = $sourceNic.IpConfigurations[0].PublicIpAddress
        if ($pipRef) {
            $pipResource = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName `
                -Name ($pipRef.Id -split '/')[-1] -ErrorAction SilentlyContinue
            if ($pipResource -and $pipResource.IpAddress) {
                Write-Step "Public IP:      $($pipResource.IpAddress) (unchanged)"
                Write-Host ""
                Write-Detail ('SSH: ssh <username>@' + $pipResource.IpAddress)
            }
        }

        Write-Host ""
        Write-Warn ("Cleanup: delete " + $dataDiskName + " and " + $osDiskName + " once verified")
    }

    Write-Host ""
    Write-OK "Done!"
    Write-Host ""

} catch {
    Write-Host ""
    Write-Err "Deployment failed: $($_.Exception.Message)"
    Write-Detail "At: $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"

    if ($createdResources.Count -gt 0) {
        Write-Host ""
        Write-Warn "Resources created before failure:"
        $createdResources | ForEach-Object { Write-Detail $_ }
        Write-Warn "Review and clean up manually if needed."
    }
    Write-Host ""
    exit 1
}
