# Azure Disk Encryption Migrate - Linux VM

Migrates an Azure Linux VM with an encrypted (ADE) OS disk to a new unencrypted OS disk.

Two modes:

- **Replace (default)** — Deletes the source VM and recreates it with the same name, NIC, IP, and data disks, but with the unencrypted OS disk.
- **Clone (`-Clone`)** — Creates a separate VM alongside the source. Source VM is not modified.

## Prerequisites

- PowerShell 7+ with the `Az` module (`Az.Compute`, `Az.Network`, `Az.Resources`)
- Azure account with permissions to create/delete VMs and disks
- Source VM must be **running** (the encrypted disk must be unlocked)

## Usage

### Automated (recommended)

Run the orchestrator from your local machine or directly from Azure Cloud Shell:

```powershell
# Replace source VM in-place
./ade-deploy.ps1 -SubscriptionId "xxx" -ResourceGroupName "myRG" -VMName "myVM"

# Clone instead (source VM untouched)
./ade-deploy.ps1 -SubscriptionId "xxx" -ResourceGroupName "myRG" -VMName "myVM" -Clone
```

If you omit parameters, you will be prompted interactively.

The script handles everything: disk creation, migration, OS disk promotion, and VM creation.

### Manual (on-VM only)

If you prefer to run the migration script directly on the VM:

```bash
# Upload
scp ade-migrate.sh user@vm-ip:/tmp/

# Preview
sudo /tmp/ade-migrate.sh --dry-run

# Run
sudo /tmp/ade-migrate.sh --yes
```

After the script completes, detach the data disk and create an OS disk from it manually.

## What happens during migration

1. A blank data disk is created and attached to the source VM
2. The migration script (runs on-VM) copies the OS disk contents to the blank disk:

```
Encrypted OS Disk              Empty Target Disk
┌─────────────────┐            ┌─────────────────┐
│ BIOS boot (4MB) │  ──dd──►   │ BIOS boot (4MB) │
│ EFI     (106MB) │  ─rsync─►  │ EFI     (106MB) │
│ LUKS    (29.7G) │  ─rsync─►  │ ext4    (29.7G) │  ← decrypted!
│ /boot   (256MB) │  ─rsync─►  │ /boot   (256MB) │
└─────────────────┘            └─────────────────┘
```
   - Replicates the partition table (GPT)
   - Copies BIOS boot, EFI, boot, and root partitions
   - Writes root as plain ext4 (no encryption on target)
   - Updates fstab, removes ADE/LUKS artifacts, regenerates initramfs, reinstalls GRUB
3. The data disk is detached and promoted to a bootable OS disk
4. A new VM is created from the OS disk

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-SubscriptionId` | Azure subscription ID |
| `-ResourceGroupName` | Resource group of the source VM |
| `-VMName` | Name of the source VM |
| `-Clone` | Create a copy VM instead of replacing the source |


## Logs

On-VM migration logs are written to `/var/log/azmigrate-<timestamp>.log`.

## License

MIT