#Requires -Version 5.1
#Requires -Modules Az.Compute, Az.Network, Az.Resources

#
# az-linux-ade-migrate.ps1 — Azure Linux Encrypted Disk Migration Orchestrator
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
      2. Creates a recovery snapshot of the source OS disk
      3. Creates a blank data disk (OS disk size + 1 GB)
      4. Attaches data disk to source VM
      5. Uploads and runs az-linux-ade-migrate-guest.sh on the VM via Run Command
      6. Detaches the data disk
      7. Creates a bootable OS disk from the data disk
      8. Deletes source VM and recreates with unencrypted disk (or creates copy)
.PARAMETER SubscriptionId
    Azure Subscription ID. Prompted if not provided.
.PARAMETER ResourceGroupName
    Resource Group containing the source VM.
.PARAMETER VMName
    Name of the source VM with encrypted OS disk.
.PARAMETER Clone
    Create a separate clone VM instead of replacing the source VM.
    The source VM is left untouched and a new VM named
    <VMName>-migrated-<timestamp> is created.
.EXAMPLE
    ./az-linux-ade-migrate.ps1 -SubscriptionId "abc-123" -ResourceGroupName "myRG" -VMName "myVM"
    # Replaces source VM in-place with unencrypted OS disk
.EXAMPLE
    ./az-linux-ade-migrate.ps1 -SubscriptionId "abc-123" -ResourceGroupName "myRG" -VMName "myVM" -Clone
    # Creates a separate clone VM, source is untouched
.EXAMPLE
    ./az-linux-ade-migrate.ps1   # Prompts for parameters interactively
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

function Get-ShortHash {
    param([string]$Text)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (-join ($sha1.ComputeHash($bytes)[0..3] | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha1.Dispose()
    }
}

function New-ResourceName {
    param(
        [string]$BaseName,
        [string]$Suffix,
        [int]$MaxLength = 80
    )

    $baseName = $BaseName.Trim('-')
    $fullName = "$baseName-$Suffix"
    if ($fullName.Length -le $MaxLength) {
        return $fullName
    }

    $hash = Get-ShortHash -Text $baseName
    $reservedLength = $Suffix.Length + $hash.Length + 2
    $trimmedLength = $MaxLength - $reservedLength
    if ($trimmedLength -lt 1) {
        throw "Cannot build Azure resource name within max length $MaxLength"
    }

    $trimmedBase = $baseName.Substring(0, [Math]::Min($baseName.Length, $trimmedLength)).TrimEnd('-')
    return "$trimmedBase-$hash-$Suffix"
}

function ConvertTo-JsonObjectSafe {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        try {
            return $text | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return $null
        }
    }

    return $Value
}

function Get-ADEExtensionState {
    param(
        [string]$RG,
        [string]$VM,
        $VMStatus
    )

    $extensions = @(Get-AzVMExtension -ResourceGroupName $RG -VMName $VM -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Publisher -like 'Microsoft.Azure.Security*' -and
            $_.ExtensionType -like 'AzureDiskEncryption*'
        })

    foreach ($ext in $extensions) {
        $publicSettings = ConvertTo-JsonObjectSafe $ext.PublicSettings
        $volumeType = ''
        if ($publicSettings -and ($publicSettings.PSObject.Properties.Name -contains 'VolumeType')) {
            $volumeType = [string]$publicSettings.VolumeType
        }

        $osStatus = ''
        $dataStatus = ''
        $statusExtension = @($VMStatus.Extensions | Where-Object { $_.Name -eq $ext.Name }) | Select-Object -First 1
        if ($statusExtension -and $statusExtension.Substatuses) {
            foreach ($substatus in $statusExtension.Substatuses) {
                $statusMessage = ConvertTo-JsonObjectSafe $substatus.Message
                if (-not $statusMessage) { continue }
                if ($statusMessage.PSObject.Properties.Name -contains 'os') {
                    $osStatus = [string]$statusMessage.os
                }
                if ($statusMessage.PSObject.Properties.Name -contains 'data') {
                    $dataStatus = [string]$statusMessage.data
                }
            }
        }

        [PSCustomObject]@{
            Name         = $ext.Name
            ExtensionType = $ext.ExtensionType
            VolumeType   = $volumeType
            OsStatus     = $osStatus
            DataStatus   = $dataStatus
        }
    }
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

    $rawOutput = if ($result.Value) {
        (($result.Value | ForEach-Object { $_.Message }) -join "`n").Trim()
    } else {
        ""
    }

    $stdout = ""
    $stderr = ""

    if ($rawOutput -match '(?s)\[stdout\]\s*(.*?)\s*\[stderr\]\s*(.*)$') {
        $stdout = $Matches[1].Trim()
        $stderr = $Matches[2].Trim()
    } else {
        $stdout = $rawOutput
    }

    return @{ Stdout = $stdout; Stderr = $stderr; Raw = $rawOutput }
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
    $deploymentSuffix = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    Write-Detail "Run Suffix:     $deploymentSuffix"
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

    $adeStates = @(Get-ADEExtensionState -RG $ResourceGroupName -VM $VMName -VMStatus $vmStatus)
    foreach ($adeState in $adeStates) {
        $volumeDisplay = if ([string]::IsNullOrWhiteSpace($adeState.VolumeType)) { 'Unknown' } else { $adeState.VolumeType }
        $osDisplay = if ([string]::IsNullOrWhiteSpace($adeState.OsStatus)) { 'Unknown' } else { $adeState.OsStatus }
        $dataDisplay = if ([string]::IsNullOrWhiteSpace($adeState.DataStatus)) { 'Unknown' } else { $adeState.DataStatus }
        Write-Detail "ADE Extension:  $($adeState.Name) (VolumeType=$volumeDisplay, OS=$osDisplay, Data=$dataDisplay)"
    }

    $unsupportedAdeState = @($adeStates | Where-Object {
        $_.VolumeType -match '^(All|Data)$' -or $_.DataStatus -eq 'Encrypted'
    }) | Select-Object -First 1
    if ($unsupportedAdeState) {
        Write-Err "Unsupported Azure Disk Encryption scope detected"
        Write-Detail "This tool supports Azure Disk Encryption on the OS disk only."
        Write-Detail "Detected extension: $($unsupportedAdeState.Name)"
        if (-not [string]::IsNullOrWhiteSpace($unsupportedAdeState.VolumeType)) {
            Write-Detail "ADE VolumeType: $($unsupportedAdeState.VolumeType)"
        }
        if (-not [string]::IsNullOrWhiteSpace($unsupportedAdeState.DataStatus)) {
            Write-Detail "ADE Data Status: $($unsupportedAdeState.DataStatus)"
        }
        Write-Detail "Source data disks attached: $($sourceDataDiskRefs.Count)"
        Write-Detail "Unsupported scenario: ADE with encrypted data volumes (OS + Data or Data-only). Please remove data disk encryption first, and re-run the migration tool."
        exit 1
    }

    # Source networking (reuse subnet for new VM)
    $sourceNicId   = $vm.NetworkProfile.NetworkInterfaces[0].Id
    $sourceNicName = ($sourceNicId -split '/')[-1]
    $sourceNicRG   = ($sourceNicId -split '/')[4]
    $sourceNic     = Get-AzNetworkInterface -ResourceGroupName $sourceNicRG -Name $sourceNicName
    $sourceSubnetId = $sourceNic.IpConfigurations[0].Subnet.Id

    Write-OK "Source VM discovered"

    # ── Step 4: Create Recovery Snapshot ─────────────────────────────────────
    Write-Header "Step 4: Create Recovery Snapshot"

    $osSnapshotName = New-ResourceName -BaseName "$VMName-os-snapshot" -Suffix $deploymentSuffix -MaxLength 80
    $snapshotTag = @{
        SourceVm   = $VMName
        SourceDisk = $osDiskName
        RunSuffix  = $deploymentSuffix
        Purpose    = 'PreMigrationRecovery'
    }

    Write-Step "Creating snapshot: $osSnapshotName"

    $snapshotConfig = New-AzSnapshotConfig `
        -Location $location `
        -CreateOption Copy `
        -SourceResourceId $osDisk.Id `
        -SkuName Standard_LRS `
        -Tag $snapshotTag

    $osSnapshot = New-AzSnapshot `
        -ResourceGroupName $ResourceGroupName `
        -SnapshotName $osSnapshotName `
        -Snapshot $snapshotConfig

    [void]$createdResources.Add("Snapshot: $osSnapshotName")

    Write-Detail "Snapshot ID: $($osSnapshot.Id)"
    Write-OK "Recovery snapshot created"

    # ── Step 5: Create Target Data Disk ──────────────────────────────────────
    Write-Header "Step 5: Create Target Data Disk"

    $dataDiskName   = New-ResourceName -BaseName "$VMName-migrated-data" -Suffix $deploymentSuffix -MaxLength 80
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

    # ── Step 6: Attach Data Disk ─────────────────────────────────────────────
    Write-Header "Step 6: Attach Data Disk to Source VM"

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

    # ── Step 7: Run Migration Script ─────────────────────────────────────────
    Write-Header "Step 7: Run Migration Script"

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $migrateScript = Join-Path $scriptDir 'az-linux-ade-migrate-guest.sh'
    $migrateUrl = 'https://raw.githubusercontent.com/samatild/ade-disk-migrate/main/az-linux-ade-migrate-guest.sh'

    if (-not (Test-Path $migrateScript)) {
        Write-Step "az-linux-ade-migrate-guest.sh not found locally, downloading from GitHub..."
        try {
            Invoke-WebRequest -Uri $migrateUrl -OutFile $migrateScript -UseBasicParsing -ErrorAction Stop
            Write-OK "Downloaded az-linux-ade-migrate-guest.sh"
        } catch {
            Write-Err "Failed to download az-linux-ade-migrate-guest.sh from $migrateUrl"
            Write-Err $_.Exception.Message
            exit 1
        }
    }

    # Upload script via base64 to avoid escaping issues
    $scriptBytes = [System.IO.File]::ReadAllBytes($migrateScript)
    $b64 = [Convert]::ToBase64String($scriptBytes)
    $remoteScriptPath = '/root/az-linux-ade-migrate-guest.sh'

    $uploadCmd = "umask 022 && echo '$b64' | base64 -d > $remoteScriptPath && chmod 700 $remoteScriptPath && echo UPLOAD_OK"

    $upload = Invoke-VMScript -RG $ResourceGroupName -VM $VMName `
        -Script $uploadCmd `
        -Description "Uploading az-linux-ade-migrate-guest.sh to VM"

    if ($upload.Stdout -notmatch 'UPLOAD_OK') {
        Write-Err "Script upload failed"
        if ($upload.Stderr) {
            Write-Detail $upload.Stderr
        } elseif ($upload.Raw) {
            Write-Detail $upload.Raw
        }
        exit 1
    }
    Write-OK "az-linux-ade-migrate-guest.sh uploaded"

    # Execute migration
    Write-Step "Running migration (this may take several minutes)..."
    Write-Detail "Run Command timeout: ~90 min. For disks >500 GB, run manually."
    Write-Host ""

    $runCmd = "bash $remoteScriptPath --yes 2>&1; echo `"###MIGRATE_EXIT=`$?###`""

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

    # ── Step 8: Detach Data Disk ─────────────────────────────────────────────
    Write-Header "Step 8: Detach Migrated Disk"

    Write-Step "Detaching data disk from source VM..."
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    Remove-AzVMDataDisk -VM $vm -Name $dataDiskName | Out-Null
    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -ErrorAction Stop | Out-Null
    Write-OK "Data disk detached"

    # ── Step 9: Create OS Disk ───────────────────────────────────────────────
    Write-Header "Step 9: Create Bootable OS Disk"

    $osDiskNewName = New-ResourceName -BaseName "$VMName-migrated-os" -Suffix $deploymentSuffix -MaxLength 80

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

    # ── Step 10: Create VM ─────────────────────────────────────────────────
    if ($Clone) {
        # --- Clone mode: create a new VM alongside the source ---
        Write-Header "Step 10: Create Clone VM"

        $newVMName = New-ResourceName -BaseName "$VMName-migrated" -Suffix $deploymentSuffix -MaxLength 64
        Write-Step "Creating VM: $newVMName (size: $vmSize)"

        # Public IP
        $pipName = New-ResourceName -BaseName $newVMName -Suffix 'pip' -MaxLength 80
        Write-Detail "Creating public IP: $pipName"

        $pip = New-AzPublicIpAddress `
            -ResourceGroupName $ResourceGroupName `
            -Location $location `
            -Name $pipName `
            -AllocationMethod Static `
            -Sku Standard

        [void]$createdResources.Add("PIP: $pipName")

        # NIC in same subnet as source VM
        $nicName = New-ResourceName -BaseName $newVMName -Suffix 'nic' -MaxLength 80
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
            $copyName = New-ResourceName -BaseName "$newVMName-$($dd.Name)" -Suffix "lun$($dd.Lun)" -MaxLength 80
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
        Write-Header "Step 10: Replace Source VM"

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
        Write-Step "Run Suffix:     $deploymentSuffix"
        Write-Step "Source VM:      $VMName [unchanged, still running]"
        Write-Step "Snapshot:       $osSnapshotName [source OS recovery point]"
        Write-Step "Data Disk:      $dataDiskName [migration artifact]"
        Write-Step "OS Disk:        $osDiskNewName [bootable, unencrypted]"

        $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName `
            -Name $pipName -ErrorAction SilentlyContinue
        Write-Step "New VM:         $newVMName"
        if ($pip -and $pip.IpAddress) {
            Write-Step "Public IP:      $($pip.IpAddress)"
            Write-Host ""
            Write-Detail ('SSH: ssh <username>@' + $pip.IpAddress)
        }

        Write-Host ""
        Write-Warn ("Cleanup: delete " + $dataDiskName + " once verified; keep snapshot " + $osSnapshotName + " until you no longer need the recovery point")
    } else {
        Write-Step "Run Suffix:     $deploymentSuffix"
        Write-Step "VM:             $VMName [replaced in-place, unencrypted]"
        Write-Step "Snapshot:       $osSnapshotName [source OS recovery point]"
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
        Write-Warn ("Cleanup: delete " + $dataDiskName + " and " + $osDiskName + " once verified; keep snapshot " + $osSnapshotName + " until you no longer need the recovery point")
    }

    Write-Host ""
    Write-OK "Done!"

    # LVM warning: source VG was renamed during migration and not reverted
    if ($summaryData['USE_LVM'] -eq 'true') {
        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor Yellow
        Write-Host "  │  LVM Notice                                         │" -ForegroundColor Yellow
        Write-Host "  ├──────────────────────────────────────────────────────┤" -ForegroundColor Yellow
        Write-Host "  │  The source VM's VG was renamed during migration    │" -ForegroundColor Yellow
        Write-Host "  │  (e.g. rootvg -> rootvg_mig). If you need to       │" -ForegroundColor Yellow
        Write-Host "  │  reuse the source VM, rename it back manually:      │" -ForegroundColor Yellow
        Write-Host "  │                                                     │" -ForegroundColor Yellow
        Write-Host "  │    sudo vgrename rootvg_mig rootvg                  │" -ForegroundColor Yellow
        Write-Host "  │    sudo reboot                                      │" -ForegroundColor Yellow
        Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor Yellow
    }

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
