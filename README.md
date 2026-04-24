# Azure Disk Encryption Migrate - Linux VM

Migrates an Azure Linux VM from an **ADE-encrypted OS disk** to a new **unencrypted OS disk**.

Two modes:

- **Replace (default)** — recreates the source VM with the new unencrypted OS disk
- **Clone (`-Clone`)** — creates a separate migrated VM and leaves the source VM untouched

## Not supported

- **ADE with encrypted data disks** (`VolumeType=All`, `VolumeType=Data`, or any VM where ADE reports encrypted data volumes)

The PowerShell deployer checks this up front and stops before any migration work starts.

## Prerequisites

- PowerShell 7+ with the `Az` module (`Az.Compute`, `Az.Network`, `Az.Resources`) or,
- Azure Cloud Shell
- Azure permissions to create/delete VMs, disks, snapshots, NICs, and public IPs
- Source VM must be **running** so the encrypted OS is already unlocked

## Quick Start

```powershell
# Download
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/samatild/ade-disk-migrate/main/az-linux-ade-migrate.ps1" -OutFile az-linux-ade-migrate.ps1

# Replace the source VM in-place
./az-linux-ade-migrate.ps1 -SubscriptionId "xxx" -ResourceGroupName "myRG" -VMName "myVM"

# Or create a separate migrated VM
./az-linux-ade-migrate.ps1 -SubscriptionId "xxx" -ResourceGroupName "myRG" -VMName "myVM" -Clone
```

If you omit parameters, the script prompts interactively.

## How it works

`az-linux-ade-migrate.ps1` is the Azure-side orchestrator. `az-linux-ade-migrate-guest.sh` runs inside the VM and performs the in-guest disk migration.

The automated flow is:

1. Validate the VM and fail fast on unsupported ADE scope
2. Create a recovery snapshot of the source OS disk
3. Create and attach a blank target disk
4. Upload and run `az-linux-ade-migrate-guest.sh` through Azure Run Command
5. Inside the VM, copy the boot/EFI/root layout to the target disk, remove ADE/LUKS artifacts, regenerate initramfs/dracut, and rebuild GRUB
6. Detach the migrated disk, create a managed OS disk from it, and either replace the source VM or create a clone

At a high level, the on-VM script turns this:

```text
Encrypted source disk      Blank target disk
┌────────────────────┐     ┌────────────────────┐
│ BIOS / EFI / boot  │ --> │ BIOS / EFI / boot  │
│ encrypted root/LVM │ --> │ plain root/LVM     │
└────────────────────┘     └────────────────────┘
```

## Manual mode

If you want to run only the on-VM script yourself:

```bash
scp az-linux-ade-migrate-guest.sh user@vm-ip:/tmp/
sudo /tmp/az-linux-ade-migrate-guest.sh --dry-run
sudo /tmp/az-linux-ade-migrate-guest.sh --yes
```

After that, you must detach the migrated disk and create the new OS disk / VM yourself.

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-SubscriptionId` | Azure subscription ID |
| `-ResourceGroupName` | Resource group containing the source VM |
| `-VMName` | Source VM name |
| `-Clone` | Create a separate migrated VM instead of replacing the source |

## Troubleshooting

- On Source VM migration log: `/var/log/azmigrate-<timestamp>.log`
- The deployer also prints the created snapshot, migrated disks, and target VM names at the end of a run

## Source Validation tests

- **Gen1 (BIOS)**
    - Ubuntu / Debian, raw layout

- **Gen 2 (EFI)**
    - Ubuntu / Debian, raw layout
    - RHEL, LVM layout


## License

MIT
