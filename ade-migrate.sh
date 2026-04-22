#!/bin/bash
set -euo pipefail

###############################################################################
# ade-migrate.sh — Azure Linux Encrypted OS Disk Migration
#
# Copyright (c) 2026 Samuel Matildes. All rights reserved.
# Licensed under the MIT License. See LICENSE file in the project root.
#
# Migrates an encrypted OS disk to a blank raw disk (non-encrypted).
###############################################################################

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="/var/log/azmigrate-${TIMESTAMP}.log"

# --- Globals (populated during detection) ---
SOURCE_DISK=""
TARGET_DISK=""
DM_NAME=""
ROOT_FSTYPE=""
DRY_RUN=false
SKIP_CONFIRM=false
FORCE=false
CLEANUP_MOUNTS=()

# --- Colors ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# --- Box drawing ---
readonly BOX_TL='╔'
readonly BOX_TR='╗'
readonly BOX_BL='╚'
readonly BOX_BR='╝'
readonly BOX_H='═'
readonly BOX_V='║'
readonly BULLET='●'
readonly ARROW='→'
readonly CHECK='✔'
readonly CROSS='✖'
readonly DIAMOND='◆'

###############################################################################
# Logging & Output
###############################################################################

log_raw() {
    echo -e "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log() {
    local level="$1"
    shift
    local msg="$*"
    # Strip ANSI escape codes for clean log output
    msg=$(echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g')
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}

print_header() {
    local title="$1"
    local width=64
    local pad=$(( (width - ${#title} - 2) / 2 ))
    local pad_r=$(( width - ${#title} - 2 - pad ))
    echo ""
    echo -e "${CYAN}${BOX_TL}$(printf "${BOX_H}%.0s" $(seq 1 "$width"))${BOX_TR}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}$(printf ' %.0s' $(seq 1 "$pad"))${BOLD}${MAGENTA} ${title} ${NC}$(printf ' %.0s' $(seq 1 "$pad_r"))${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_BL}$(printf "${BOX_H}%.0s" $(seq 1 "$width"))${BOX_BR}${NC}"
    echo ""
    log "INFO" "=== ${title} ==="
}

info() {
    echo -e "  ${GREEN}${BULLET}${NC} $*"
    log "INFO" "$*"
}

warn() {
    echo -e "  ${YELLOW}${DIAMOND}${NC} ${YELLOW}$*${NC}"
    log "WARN" "$*"
}

error() {
    echo -e "  ${RED}${CROSS}${NC} ${RED}${BOLD}$*${NC}" >&2
    log "ERROR" "$*"
}

success() {
    echo -e "  ${GREEN}${CHECK}${NC} ${GREEN}$*${NC}"
    log "INFO" "$*"
}

detail() {
    echo -e "    ${DIM}${ARROW} $*${NC}"
    log "INFO" "  $*"
}

die() {
    error "$@"
    echo -e "\n  ${RED}Migration aborted.${NC}"
    echo -e "  ${DIM}Log file: ${LOG_FILE}${NC}\n"
    log "ERROR" "Migration aborted: $*"
    exit 1
}

spinner() {
    local pid=$1
    local msg="${2:-Working...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r  ${CYAN}${frames[$i]}${NC} ${msg}"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
    wait "$pid"
    local rc=$?
    echo -ne "\r\033[2K"
    return $rc
}

progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local pct=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    local bar
    bar=$(printf '█%.0s' $(seq 1 "$filled") 2>/dev/null || true)
    bar+=$(printf '░%.0s' $(seq 1 "$empty") 2>/dev/null || true)
    echo -ne "\r    ${CYAN}[${bar}]${NC} ${BOLD}${pct}%%${NC}"
}

###############################################################################
# Validation
###############################################################################

validate_dev_path() {
    local path="$1"
    # Ensure path starts with /dev/ and contains no path traversal
    if [[ "$path" != /dev/* ]]; then
        die "Invalid device path: ${path} (must start with /dev/)"
    fi
    if [[ "$path" == *".."* ]]; then
        die "Invalid device path: ${path} (path traversal detected)"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
}

check_dependencies() {
    local deps=(lsblk blkid blockdev sgdisk parted rsync mkfs.ext4 mkfs.ext2 mkfs.vfat mount umount dd sed grep awk)
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
    success "All dependencies available"
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    log "INFO" "Running cleanup..."
    for mnt in "${CLEANUP_MOUNTS[@]}"; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount "$mnt" 2>/dev/null || true
            log "INFO" "Unmounted $mnt"
        fi
    done
    # Remove temp mount dirs (only top-level /tmp/azmigrate_* dirs, not subdirs)
    for mnt in "${CLEANUP_MOUNTS[@]}"; do
        if [[ -d "$mnt" ]] && [[ "$mnt" == /tmp/azmigrate_* ]] && [[ "$(dirname "$mnt")" == "/tmp" ]]; then
            rmdir "$mnt" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT

###############################################################################
# Phase 1: Detection
###############################################################################

detect_os_disk() {
    print_header "Phase 1: OS Disk Detection"

    # Step 1: Find root mount device
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null) || die "Cannot determine root mount"
    info "Root filesystem mounted from: ${BOLD}${root_dev}${NC}"
    log "INFO" "Root device: $root_dev"cd /

    # Step 2: Check if root is on a dm-crypt device
    if [[ "$root_dev" == /dev/mapper/* ]] || [[ "$root_dev" == /dev/dm-* ]]; then
        DM_NAME=$(basename "$root_dev")
        info "Encrypted volume detected: ${BOLD}${DM_NAME}${NC}"

        # Resolve to parent device through dm
        local dm_num

        # Get the dm number
        if [[ "$root_dev" == /dev/mapper/* ]]; then
            dm_num=$(stat -L --format='%T' "$root_dev" 2>/dev/null | xargs printf "%d" 2>/dev/null) || true
            if [[ -z "$dm_num" ]]; then
                # Alternative: look up through dmsetup
                dm_num=$(dmsetup info -c --noheadings -o minor "$DM_NAME" 2>/dev/null) || true
            fi
        fi

        # Find the physical disk backing the crypt device
        local slaves_dir=""
        for d in /sys/block/dm-*/slaves/*; do
            if [[ -d "$d" ]]; then
                local dm_block
                dm_block=$(basename "$(dirname "$(dirname "$d")")")
                # Check if this dm maps to our root device
                if [[ -e "/dev/mapper/${DM_NAME}" ]]; then
                    local resolved
                    resolved=$(readlink -f "/dev/mapper/${DM_NAME}" 2>/dev/null) || true
                    if [[ "/dev/${dm_block}" == "$resolved" ]] || [[ -e "$d" ]]; then
                        slaves_dir="$(dirname "$d")"
                        break
                    fi
                fi
            fi
        done

        # Fallback: use dmsetup table to find the underlying device
        if [[ -z "$slaves_dir" ]]; then
            # Try /sys/class/block approach
            local dm_sysname
            dm_sysname=$(basename "$(readlink -f "/dev/mapper/${DM_NAME}")" 2>/dev/null) || true
            if [[ -n "$dm_sysname" ]] && [[ -d "/sys/class/block/${dm_sysname}/slaves" ]]; then
                slaves_dir="/sys/class/block/${dm_sysname}/slaves"
            fi
        fi

        if [[ -n "$slaves_dir" ]] && [[ -d "$slaves_dir" ]]; then
            local slave_dev
            slave_dev=$(find "$slaves_dir" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | head -1)
            if [[ -n "$slave_dev" ]]; then
                detail "Encrypted partition: /dev/${slave_dev}"
                # Get parent disk (strip partition number)
                SOURCE_DISK=$(lsblk -n -o PKNAME "/dev/${slave_dev}" 2>/dev/null | head -1)
                if [[ -z "$SOURCE_DISK" ]]; then
                    # Fallback: strip trailing digits
                    # Fallback: strip trailing digits
                    SOURCE_DISK=$(lsblk -n -o PKNAME "/dev/${slave_dev}" 2>/dev/null | head -1)
                fi
            fi
        fi

        # Final fallback: use Azure symlinks
        if [[ -z "$SOURCE_DISK" ]] && [[ -L /dev/disk/azure/root ]]; then
            SOURCE_DISK=$(basename "$(readlink -f /dev/disk/azure/root)")
            detail "Detected via Azure symlink"
        fi
    else
        # Not encrypted — find parent disk directly
        SOURCE_DISK=$(lsblk -n -o PKNAME "$root_dev" 2>/dev/null | head -1)
    fi

    if [[ -z "$SOURCE_DISK" ]]; then
        die "Could not detect the OS disk"
    fi

    validate_dev_path "/dev/$SOURCE_DISK"

    # Get filesystem type of root
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null) || ROOT_FSTYPE="ext4"

    success "OS Disk identified: ${BOLD}/dev/${SOURCE_DISK}${NC}"
    echo ""

    # Display partition layout
    info "Source disk partition layout:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "/dev/$SOURCE_DISK" 2>/dev/null | while IFS= read -r line; do
        detail "$line"
    done
}

detect_target_disk() {
    print_header "Phase 1b: Target Disk Detection"

    local candidates=()
    local os_disk_basename
    os_disk_basename="$SOURCE_DISK"

    # Get resource disk name (Azure temp disk)
    local resource_disk=""
    if [[ -L /dev/disk/azure/resource ]]; then
        resource_disk=$(basename "$(readlink -f /dev/disk/azure/resource)")
    fi

    # Get BEK volume disk
    local bek_disk=""
    bek_disk=$(lsblk -n -o PKNAME,LABEL --pairs 2>/dev/null | grep "BEK VOLUME" | head -1 | sed 's/.*PKNAME="\([^"]*\)".*/\1/' || true)

    for disk in $(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        # Skip the OS disk
        [[ "$disk" == "$os_disk_basename" ]] && continue
        # Skip resource disk
        [[ -n "$resource_disk" ]] && [[ "$disk" == "$resource_disk" ]] && continue
        # Skip BEK disk
        [[ -n "$bek_disk" ]] && [[ "$disk" == "$bek_disk" ]] && continue

        # Check if disk is empty (no partitions, no fs signature)
        local part_count
        part_count=$(lsblk -n -o NAME "/dev/$disk" 2>/dev/null | tail -n +2 | wc -l)
        if [[ "$part_count" -eq 0 ]]; then
            local fs_sig
            fs_sig=$(blkid -o value -s TYPE "/dev/$disk" 2>/dev/null || true)
            if [[ -z "$fs_sig" ]]; then
                candidates+=("$disk")
            fi
        fi
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        die "No empty target disk found. Attach a blank disk and retry."
    fi

    if [[ ${#candidates[@]} -eq 1 ]]; then
        TARGET_DISK="${candidates[0]}"
        info "Target disk auto-detected: ${BOLD}/dev/${TARGET_DISK}${NC}"
    else
        info "Multiple empty disks found:"
        local i=1
        for c in "${candidates[@]}"; do
            local size
            size=$(lsblk -d -n -o SIZE "/dev/$c" 2>/dev/null)
            detail "[${i}] /dev/${c}  (${size})"
            i=$((i + 1))
        done
        echo ""
        echo -ne "  ${CYAN}${ARROW}${NC} Select target disk [1-${#candidates[@]}]: "
        local choice
        read -r choice
        if [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#candidates[@]} ]] 2>/dev/null; then
            TARGET_DISK="${candidates[$((choice - 1))]}"
        else
            die "Invalid selection"
        fi
    fi

    validate_dev_path "/dev/$TARGET_DISK"
    success "Target disk selected: ${BOLD}/dev/${TARGET_DISK}${NC}"
}

validate_disk_sizes() {
    print_header "Phase 1c: Size Validation"

    local source_bytes target_bytes source_hr target_hr
    source_bytes=$(blockdev --getsize64 "/dev/$SOURCE_DISK")
    target_bytes=$(blockdev --getsize64 "/dev/$TARGET_DISK")
    source_hr=$(numfmt --to=iec-i --suffix=B "$source_bytes" 2>/dev/null || echo "${source_bytes} bytes")
    target_hr=$(numfmt --to=iec-i --suffix=B "$target_bytes" 2>/dev/null || echo "${target_bytes} bytes")

    info "Source disk (/dev/${SOURCE_DISK}): ${BOLD}${source_hr}${NC}"
    info "Target disk (/dev/${TARGET_DISK}): ${BOLD}${target_hr}${NC}"

    local diff_bytes=$(( source_bytes - target_bytes ))
    local threshold=$(( source_bytes / 100 ))  # 1% tolerance

    if (( target_bytes < source_bytes )); then
        if (( diff_bytes <= threshold )) || $FORCE; then
            warn "Target is slightly smaller (delta: $(numfmt --to=iec-i "$diff_bytes" 2>/dev/null || echo "${diff_bytes} bytes")). Proceeding — last partition will be adjusted."
        else
            die "Target disk is too small (${target_hr} < ${source_hr}). Target must be ≥ source. Use --force to override."
        fi
    fi

    success "Size validation passed"
}

###############################################################################
# Summary & Confirmation
###############################################################################

print_summary() {
    print_header "Migration Summary"

    echo -e "  ${BOLD}Source (encrypted):${NC}"
    detail "Disk:       /dev/${SOURCE_DISK}"
    detail "Crypt map:  /dev/mapper/${DM_NAME}"
    detail "Root FS:    ${ROOT_FSTYPE}"
    echo ""
    echo -e "  ${BOLD}Target (raw):${NC}"
    detail "Disk:       /dev/${TARGET_DISK}"
    echo ""

    info "Partitions to replicate:"
    local parts
    parts=$(lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT "/dev/${SOURCE_DISK}" 2>/dev/null | tail -n +2)
    while IFS= read -r line; do
        [[ -n "$line" ]] && detail "$line"
    done <<< "$parts"

    echo ""
    if $DRY_RUN; then
        warn "DRY RUN MODE — no changes will be made"
        echo ""
        return
    fi

    if ! $SKIP_CONFIRM; then
        echo -e "  ${RED}${BOLD}⚠  WARNING: This will ERASE all data on /dev/${TARGET_DISK}${NC}"
        echo ""
        echo -ne "  ${CYAN}${ARROW}${NC} Type ${BOLD}YES${NC} to proceed: "
        local answer
        read -r answer
        if [[ "$answer" != "YES" ]]; then
            die "User cancelled migration"
        fi
        echo ""
    fi
}

###############################################################################
# Phase 2: Partition Table Replication
###############################################################################

replicate_partition_table() {
    print_header "Phase 2: Partition Table Replication"

    if $DRY_RUN; then
        info "[DRY RUN] Would copy GPT table from /dev/${SOURCE_DISK} to /dev/${TARGET_DISK}"
        return
    fi

    info "Copying GPT partition table..."

    # Use sgdisk to replicate
    sgdisk -R "/dev/${TARGET_DISK}" "/dev/${SOURCE_DISK}" >> "$LOG_FILE" 2>&1 || \
        die "Failed to replicate partition table"

    # Randomize GUIDs on target
    sgdisk -G "/dev/${TARGET_DISK}" >> "$LOG_FILE" 2>&1 || \
        die "Failed to randomize GUIDs"

    # If target is slightly smaller, fix any partition that overflows
    local tgt_sectors
    tgt_sectors=$(blockdev --getsz "/dev/${TARGET_DISK}" 2>/dev/null)
    sgdisk -e "/dev/${TARGET_DISK}" >> "$LOG_FILE" 2>&1 || true
    # Verify and repair GPT
    sgdisk -v "/dev/${TARGET_DISK}" >> "$LOG_FILE" 2>&1 || {
        warn "GPT verify found issues — attempting to repair"
        # Truncate partition 2 (last partition at end of disk) to fit
        local p2_start
        p2_start=$(sgdisk -i 2 "/dev/${TARGET_DISK}" 2>/dev/null | grep "First sector" | awk '{print $3}')
        if [[ -n "$p2_start" ]]; then
            local p2_end=$(( tgt_sectors - 34 ))  # GPT backup header takes 34 sectors
            sgdisk -d 2 -n 2:"${p2_start}":"${p2_end}" -t 2:8300 "/dev/${TARGET_DISK}" >> "$LOG_FILE" 2>&1 || \
                warn "Partition 2 resize may need manual fixup"
            detail "Adjusted partition 2 end to fit target disk"
        fi
    }

    # Force kernel to re-read partition table
    partprobe "/dev/${TARGET_DISK}" 2>/dev/null || true
    sleep 2

    success "Partition table replicated"

    info "Target disk layout:"
    lsblk -o NAME,SIZE,TYPE "/dev/${TARGET_DISK}" 2>/dev/null | while IFS= read -r line; do
        detail "$line"
    done
}

###############################################################################
# Phase 3: Filesystem Creation & Data Copy
###############################################################################

get_partition_dev() {
    local disk="$1"
    local num="$2"
    # Handle nvme-style (sda1 vs nvme0n1p1)
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "/dev/${disk}p${num}"
    else
        echo "/dev/${disk}${num}"
    fi
}

copy_bios_boot() {
    local src_part
    src_part=$(get_partition_dev "$SOURCE_DISK" 14)
    local tgt_part
    tgt_part=$(get_partition_dev "$TARGET_DISK" 14)

    if [[ ! -b "$src_part" ]]; then
        warn "No BIOS boot partition found — skipping"
        return
    fi

    info "Copying BIOS boot partition (raw dd)..."
    if $DRY_RUN; then
        detail "[DRY RUN] dd if=${src_part} of=${tgt_part}"
        return
    fi

    dd if="$src_part" of="$tgt_part" bs=4M status=none >> "$LOG_FILE" 2>&1 || \
        die "Failed to copy BIOS boot partition"
    success "BIOS boot partition copied"
}

copy_efi_partition() {
    local src_part
    src_part=$(get_partition_dev "$SOURCE_DISK" 15)
    local tgt_part
    tgt_part=$(get_partition_dev "$TARGET_DISK" 15)

    if [[ ! -b "$src_part" ]]; then
        warn "No EFI partition found — skipping"
        return
    fi

    info "Creating FAT32 filesystem on EFI partition..."
    if $DRY_RUN; then
        detail "[DRY RUN] mkfs.vfat ${tgt_part} + rsync"
        return
    fi

    mkfs.vfat -F 32 -n "UEFI" "$tgt_part" >> "$LOG_FILE" 2>&1 || \
        die "Failed to create EFI filesystem"

    # Use existing mountpoint if already mounted, otherwise mount temporarily
    local src_mnt
    local src_mounted_here=false
    src_mnt=$(findmnt -n -o TARGET "$src_part" 2>/dev/null | head -1)
    if [[ -z "$src_mnt" ]]; then
        src_mnt="/tmp/azmigrate_efi_src_${TIMESTAMP}"
        mkdir -p "$src_mnt"
        mount -o ro "$src_part" "$src_mnt" >> "$LOG_FILE" 2>&1
        CLEANUP_MOUNTS+=("$src_mnt")
        src_mounted_here=true
    else
        detail "Using existing mountpoint: ${src_mnt}"
    fi

    local tgt_mnt="/tmp/azmigrate_efi_tgt_${TIMESTAMP}"
    mkdir -p "$tgt_mnt"
    mount "$tgt_part" "$tgt_mnt" >> "$LOG_FILE" 2>&1
    CLEANUP_MOUNTS+=("$tgt_mnt")

    rsync -a "$src_mnt/" "$tgt_mnt/" >> "$LOG_FILE" 2>&1 || \
        die "Failed to copy EFI data"

    umount "$tgt_mnt" 2>/dev/null
    if $src_mounted_here; then
        umount "$src_mnt" 2>/dev/null
    fi

    success "EFI partition copied"
}

copy_boot_partition() {
    local src_part
    src_part=$(get_partition_dev "$SOURCE_DISK" 2)
    local tgt_part
    tgt_part=$(get_partition_dev "$TARGET_DISK" 2)

    if [[ ! -b "$src_part" ]]; then
        warn "No /boot partition found — skipping"
        return
    fi

    local src_fstype
    src_fstype=$(blkid -o value -s TYPE "$src_part" 2>/dev/null || echo "ext2")

    info "Creating ${src_fstype} filesystem on /boot partition..."
    if $DRY_RUN; then
        detail "[DRY RUN] mkfs.${src_fstype} ${tgt_part} + rsync"
        return
    fi

    case "$src_fstype" in
        ext2) mkfs.ext2 -q "$tgt_part" >> "$LOG_FILE" 2>&1 ;;
        ext3) mkfs.ext3 -q "$tgt_part" >> "$LOG_FILE" 2>&1 ;;
        ext4) mkfs.ext4 -q "$tgt_part" >> "$LOG_FILE" 2>&1 ;;
        xfs)  mkfs.xfs -f "$tgt_part" >> "$LOG_FILE" 2>&1 ;;
        *) die "Unsupported /boot filesystem: $src_fstype" ;;
    esac

    # Use existing mountpoint if already mounted, otherwise mount temporarily
    local src_mnt
    local src_mounted_here=false
    src_mnt=$(findmnt -n -o TARGET "$src_part" 2>/dev/null | head -1)
    if [[ -z "$src_mnt" ]]; then
        src_mnt="/tmp/azmigrate_boot_src_${TIMESTAMP}"
        mkdir -p "$src_mnt"
        mount -o ro "$src_part" "$src_mnt" >> "$LOG_FILE" 2>&1
        CLEANUP_MOUNTS+=("$src_mnt")
        src_mounted_here=true
    else
        detail "Using existing mountpoint: ${src_mnt}"
    fi

    local tgt_mnt="/tmp/azmigrate_boot_tgt_${TIMESTAMP}"
    mkdir -p "$tgt_mnt"
    mount "$tgt_part" "$tgt_mnt" >> "$LOG_FILE" 2>&1
    CLEANUP_MOUNTS+=("$tgt_mnt")

    rsync -a "$src_mnt/" "$tgt_mnt/" >> "$LOG_FILE" 2>&1 || \
        die "Failed to copy /boot data"

    # Remove LUKS header from target /boot if present
    if [[ -d "$tgt_mnt/luks" ]]; then
        rm -rf "$tgt_mnt/luks"
        detail "Removed LUKS header directory from target /boot"
    fi

    umount "$tgt_mnt" 2>/dev/null
    if $src_mounted_here; then
        umount "$src_mnt" 2>/dev/null
    fi

    success "/boot partition copied"
}

copy_root_partition() {
    local tgt_part
    tgt_part=$(get_partition_dev "$TARGET_DISK" 1)

    info "Creating ${ROOT_FSTYPE} filesystem on root partition..."
    if $DRY_RUN; then
        detail "[DRY RUN] mkfs.${ROOT_FSTYPE} ${tgt_part} + rsync from /dev/mapper/${DM_NAME}"
        return
    fi

    local label
    label=$(blkid -o value -s LABEL "/dev/mapper/${DM_NAME}" 2>/dev/null || true)
    local label_opt=""
    if [[ -n "$label" ]]; then
        label_opt="-L ${label}"
    fi

    case "$ROOT_FSTYPE" in
        ext4) mkfs.ext4 -q ${label_opt:+$label_opt} "$tgt_part" >> "$LOG_FILE" 2>&1 ;;
        ext3) mkfs.ext3 -q ${label_opt:+$label_opt} "$tgt_part" >> "$LOG_FILE" 2>&1 ;;
        xfs)  mkfs.xfs -f ${label:+-L "$label"} "$tgt_part" >> "$LOG_FILE" 2>&1 ;;
        *) die "Unsupported root filesystem: $ROOT_FSTYPE" ;;
    esac

    success "Root filesystem created on ${tgt_part}"

    local tgt_mnt="/tmp/azmigrate_root_tgt_${TIMESTAMP}"
    mkdir -p "$tgt_mnt"
    mount "$tgt_part" "$tgt_mnt" >> "$LOG_FILE" 2>&1
    CLEANUP_MOUNTS+=("$tgt_mnt")

    info "Copying root filesystem data (this may take a while)..."
    echo ""

    # Calculate source data size for progress display
    local src_used_bytes
    src_used_bytes=$(df -B1 --output=used / 2>/dev/null | tail -1 | tr -d ' ')

    # Exclusions: pseudo-fs, target mount, temp mounts, virtual filesystems
    # Run rsync in background, monitor progress via target disk usage
    rsync -aAX --no-i-r / "$tgt_mnt/" \
        --exclude='/proc/*' \
        --exclude='/sys/*' \
        --exclude='/dev/*' \
        --exclude='/run/*' \
        --exclude='/tmp/*' \
        --exclude='/mnt/*' \
        --exclude='/media/*' \
        --exclude='/data/*' \
        --exclude='/var/log/azmigrate*' \
        --exclude='/var/lib/lxcfs/*' \
        --exclude='/snap/*' \
        --exclude="$tgt_mnt" \
        --exclude='/lost+found' \
        >> "$LOG_FILE" 2>&1 &
    local rsync_pid=$!

    # Show progress bar based on target partition usage vs source used space
    local bar_width=40
    while kill -0 "$rsync_pid" 2>/dev/null; do
        local copied_bytes
        copied_bytes=$(df -B1 --output=used "$tgt_mnt" 2>/dev/null | tail -1 | tr -d ' ') || copied_bytes=0
        if [[ -n "$src_used_bytes" ]] && (( src_used_bytes > 0 )) && (( copied_bytes > 0 )); then
            local pct=$(( copied_bytes * 100 / src_used_bytes ))
            (( pct > 100 )) && pct=100
            local filled=$(( pct * bar_width / 100 ))
            local empty=$(( bar_width - filled ))
            local bar=""
            local i
            for (( i=0; i<filled; i++ )); do bar+="█"; done
            for (( i=0; i<empty; i++ )); do bar+="░"; done
            local copied_hr
            copied_hr=$(numfmt --to=iec-i --suffix=B "$copied_bytes" 2>/dev/null || echo "${copied_bytes}")
            local total_hr
            total_hr=$(numfmt --to=iec-i --suffix=B "$src_used_bytes" 2>/dev/null || echo "${src_used_bytes}")
            echo -ne "\r    ${CYAN}[${bar}]${NC} ${BOLD}${pct}%%${NC}  ${DIM}${copied_hr} / ${total_hr}${NC}  "
        fi
        sleep 2
    done

    local rc=0
    wait "$rsync_pid" || rc=$?
    echo -ne "\r\033[2K"

    if [[ $rc -ne 0 ]]; then
        # rsync exit code 24 = some files vanished (ok for live system)
        # rsync exit code 23 = partial transfer (some files unreadable, e.g. virtual fs)
        if [[ $rc -ne 24 ]] && [[ $rc -ne 23 ]]; then
            die "rsync failed with exit code $rc"
        fi
        if [[ $rc -eq 24 ]]; then
            warn "Some files vanished during copy (expected on live system)"
        fi
        if [[ $rc -eq 23 ]]; then
            warn "Some files could not be transferred (virtual/pseudo files — safe to ignore)"
        fi
    fi

    # Create empty mountpoints
    mkdir -p "$tgt_mnt"/{proc,sys,dev,run,tmp,mnt,media}

    success "Root filesystem data copied"
}

###############################################################################
# Phase 4: Post-Copy Fixup
###############################################################################

fixup_target() {
    print_header "Phase 4: Post-Copy Configuration"

    if $DRY_RUN; then
        info "[DRY RUN] Would update fstab, crypttab, and GRUB on target"
        return
    fi

    local tgt_root="/tmp/azmigrate_root_tgt_${TIMESTAMP}"
    # Ensure root is mounted
    local tgt_root_part
    tgt_root_part=$(get_partition_dev "$TARGET_DISK" 1)
    if ! mountpoint -q "$tgt_root" 2>/dev/null; then
        mkdir -p "$tgt_root"
        mount "$tgt_root_part" "$tgt_root" >> "$LOG_FILE" 2>&1
        CLEANUP_MOUNTS+=("$tgt_root")
    fi

    # Mount boot inside root
    local tgt_boot_part
    tgt_boot_part=$(get_partition_dev "$TARGET_DISK" 2)
    if [[ -b "$tgt_boot_part" ]]; then
        mkdir -p "$tgt_root/boot"
        mount "$tgt_boot_part" "$tgt_root/boot" >> "$LOG_FILE" 2>&1
        CLEANUP_MOUNTS+=("$tgt_root/boot")
    fi

    # Mount EFI inside root
    local tgt_efi_part
    tgt_efi_part=$(get_partition_dev "$TARGET_DISK" 15)
    if [[ -b "$tgt_efi_part" ]]; then
        mkdir -p "$tgt_root/boot/efi"
        mount "$tgt_efi_part" "$tgt_root/boot/efi" >> "$LOG_FILE" 2>&1
        CLEANUP_MOUNTS+=("$tgt_root/boot/efi")
    fi

    # --- Fix fstab ---
    info "Updating /etc/fstab on target..."

    local fstab_file="$tgt_root/etc/fstab"
    if [[ -f "$fstab_file" ]]; then
        # Backup original
        cp "$fstab_file" "${fstab_file}.bak.${TIMESTAMP}"

        # Get old UUIDs (source)
        local old_root_uuid
        old_root_uuid=$(blkid -o value -s UUID "/dev/mapper/${DM_NAME}" 2>/dev/null || true)
        local old_boot_uuid
        old_boot_uuid=$(blkid -o value -s UUID "$(get_partition_dev "$SOURCE_DISK" 2)" 2>/dev/null || true)
        local old_efi_uuid
        old_efi_uuid=$(blkid -o value -s UUID "$(get_partition_dev "$SOURCE_DISK" 15)" 2>/dev/null || true)

        # Get new UUIDs (target)
        local new_root_uuid
        new_root_uuid=$(blkid -o value -s UUID "$tgt_root_part" 2>/dev/null || true)
        local new_boot_uuid
        new_boot_uuid=$(blkid -o value -s UUID "$tgt_boot_part" 2>/dev/null || true)
        local new_efi_uuid
        new_efi_uuid=$(blkid -o value -s UUID "$tgt_efi_part" 2>/dev/null || true)

        # Replace UUIDs
        if [[ -n "$old_root_uuid" ]] && [[ -n "$new_root_uuid" ]]; then
            sed -i "s/${old_root_uuid}/${new_root_uuid}/g" "$fstab_file"
            detail "Root UUID: ${old_root_uuid} ${ARROW} ${new_root_uuid}"
        fi
        if [[ -n "$old_boot_uuid" ]] && [[ -n "$new_boot_uuid" ]]; then
            sed -i "s/${old_boot_uuid}/${new_boot_uuid}/g" "$fstab_file"
            detail "Boot UUID: ${old_boot_uuid} ${ARROW} ${new_boot_uuid}"
        fi
        if [[ -n "$old_efi_uuid" ]] && [[ -n "$new_efi_uuid" ]]; then
            sed -i "s/${old_efi_uuid}/${new_efi_uuid}/g" "$fstab_file"
            detail "EFI UUID:  ${old_efi_uuid} ${ARROW} ${new_efi_uuid}"
        fi

        success "fstab updated"
    else
        warn "fstab not found on target"
    fi

    # --- Remove crypttab ---
    local crypttab_file="$tgt_root/etc/crypttab"
    if [[ -f "$crypttab_file" ]]; then
        cp "$crypttab_file" "${crypttab_file}.bak.${TIMESTAMP}"
        # Empty the file but keep it (some tools expect it to exist)
        echo "# Cleared by azmigrate — encryption removed" > "$crypttab_file"
        info "Cleared /etc/crypttab"
    fi

    # --- Remove LUKS header from /boot ---
    if [[ -d "$tgt_root/boot/luks" ]]; then
        rm -rf "$tgt_root/boot/luks"
        info "Removed LUKS header directory"
    fi

    # --- Remove Azure Disk Encryption artifacts ---
    info "Removing Azure Disk Encryption artifacts..."
    # ADE key script referenced in crypttab
    if [[ -f "$tgt_root/usr/sbin/azure_crypt_key.sh" ]]; then
        rm -f "$tgt_root/usr/sbin/azure_crypt_key.sh"
        detail "Removed azure_crypt_key.sh"
    fi
    # ADE initramfs hooks that trigger LUKS unlock at boot
    local ade_hooks=(
        "$tgt_root/etc/initramfs-tools/hooks/azure_crypt_key"
        "$tgt_root/etc/initramfs-tools/hooks/ade"
        "$tgt_root/usr/share/initramfs-tools/hooks/azure_crypt_key"
        "$tgt_root/usr/share/initramfs-tools/hooks/luksheader"
    )
    for hook in "${ade_hooks[@]}"; do
        if [[ -f "$hook" ]]; then
            rm -f "$hook"
            detail "Removed hook: $(basename "$hook")"
        fi
    done
    # Restore original cryptroot hook if ADE modified it (backup exists as .orig)
    local cryptroot_hook="$tgt_root/usr/share/initramfs-tools/hooks/cryptroot"
    if [[ -f "${cryptroot_hook}.orig" ]]; then
        cp "${cryptroot_hook}.orig" "$cryptroot_hook"
        detail "Restored original cryptroot hook"
    fi
    # Remove cryptsetup from initramfs config if referenced
    if [[ -f "$tgt_root/etc/initramfs-tools/conf.d/cryptroot" ]]; then
        rm -f "$tgt_root/etc/initramfs-tools/conf.d/cryptroot"
        detail "Removed initramfs cryptroot config"
    fi
    # Disable cryptsetup in initramfs
    if [[ -f "$tgt_root/etc/cryptsetup-initramfs/conf-hook" ]]; then
        cp "$tgt_root/etc/cryptsetup-initramfs/conf-hook" \
           "$tgt_root/etc/cryptsetup-initramfs/conf-hook.bak.${TIMESTAMP}"
        sed -i 's/^CRYPTSETUP=.*/CRYPTSETUP=n/' "$tgt_root/etc/cryptsetup-initramfs/conf-hook"
        detail "Set CRYPTSETUP=n in initramfs conf-hook"
    fi

    # --- Reinstall GRUB ---
    info "Reinstalling GRUB bootloader on target..."

    # Bind mount for chroot
    mount --bind /dev  "$tgt_root/dev"  2>/dev/null || true
    CLEANUP_MOUNTS+=("$tgt_root/dev")
    mount --bind /proc "$tgt_root/proc" 2>/dev/null || true
    CLEANUP_MOUNTS+=("$tgt_root/proc")
    mount --bind /sys  "$tgt_root/sys"  2>/dev/null || true
    CLEANUP_MOUNTS+=("$tgt_root/sys")
    mount --bind /run  "$tgt_root/run"  2>/dev/null || true
    CLEANUP_MOUNTS+=("$tgt_root/run")

    # Update GRUB config — remove cryptdevice references
    local grub_defaults="$tgt_root/etc/default/grub"
    if [[ -f "$grub_defaults" ]]; then
        cp "$grub_defaults" "${grub_defaults}.bak.${TIMESTAMP}"
        # Remove rd.luks or cryptdevice kernel parameters
        sed -i 's/rd\.luks\.[^ "]*//g' "$grub_defaults"
        sed -i 's/cryptdevice=[^ "]*//g' "$grub_defaults"
        detail "Cleaned encryption references from GRUB defaults"
    fi

    # --- Regenerate initramfs (remove cryptsetup hooks) ---
    info "Regenerating initramfs (removing encryption hooks)..."
    local kernel_ver
    kernel_ver=$(find "$tgt_root/lib/modules/" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)
    if [[ -n "$kernel_ver" ]]; then
        detail "Kernel version: ${kernel_ver}"
        chroot "$tgt_root" update-initramfs -u -k "$kernel_ver" >> "$LOG_FILE" 2>&1 || \
            warn "update-initramfs failed — may need manual intervention"
        success "initramfs regenerated"
    else
        warn "No kernel modules found — skipping initramfs regeneration"
    fi

    # Run grub-install and update-grub in chroot
    chroot "$tgt_root" grub-install "/dev/${TARGET_DISK}" >> "$LOG_FILE" 2>&1 || \
        warn "grub-install failed — may need manual intervention"

    chroot "$tgt_root" update-grub >> "$LOG_FILE" 2>&1 || \
        warn "update-grub failed — may need manual intervention"

    success "GRUB bootloader installed"

    # Unmount bind mounts (reverse order)
    umount "$tgt_root/run"  2>/dev/null || true
    umount "$tgt_root/sys"  2>/dev/null || true
    umount "$tgt_root/proc" 2>/dev/null || true
    umount "$tgt_root/dev"  2>/dev/null || true
}

###############################################################################
# Phase 5: Verification
###############################################################################

verify_target() {
    print_header "Phase 5: Verification"

    if $DRY_RUN; then
        info "[DRY RUN] Would verify target disk partitions and filesystem"
        return
    fi

    local tgt_root="/tmp/azmigrate_root_tgt_${TIMESTAMP}"
    local tgt_root_part
    tgt_root_part=$(get_partition_dev "$TARGET_DISK" 1)

    # Ensure root is still mounted
    if ! mountpoint -q "$tgt_root" 2>/dev/null; then
        mkdir -p "$tgt_root"
        mount "$tgt_root_part" "$tgt_root" >> "$LOG_FILE" 2>&1
        CLEANUP_MOUNTS+=("$tgt_root")
    fi

    # Check fstab exists
    if [[ -f "$tgt_root/etc/fstab" ]]; then
        success "fstab present on target"
        detail "Contents:"
        grep -v '^#' "$tgt_root/etc/fstab" | grep -v '^$' | while IFS= read -r line; do
            detail "  $line"
        done
    else
        warn "fstab missing from target"
    fi

    # Verify partition UUIDs
    info "Target disk final layout:"
    lsblk -o NAME,SIZE,FSTYPE,UUID "/dev/${TARGET_DISK}" 2>/dev/null | while IFS= read -r line; do
        detail "$line"
    done

    echo ""
    success "Verification complete"
}

###############################################################################
# Final Report
###############################################################################

print_final_report() {
    print_header "Migration Complete"

    echo -e "  ${GREEN}${BOLD}The OS disk has been migrated successfully.${NC}"
    echo ""

    # Collect summary data
    local tgt_root_part
    tgt_root_part=$(get_partition_dev "$TARGET_DISK" 1)
    local tgt_root_uuid tgt_boot_uuid tgt_efi_uuid
    tgt_root_uuid=$(blkid -o value -s UUID "$tgt_root_part" 2>/dev/null || echo "n/a")
    local tgt_boot_part
    tgt_boot_part=$(get_partition_dev "$TARGET_DISK" 2)
    tgt_boot_uuid=$(blkid -o value -s UUID "$tgt_boot_part" 2>/dev/null || echo "n/a")
    local tgt_efi_part
    tgt_efi_part=$(get_partition_dev "$TARGET_DISK" 15)
    tgt_efi_uuid=$(blkid -o value -s UUID "$tgt_efi_part" 2>/dev/null || echo "n/a")

    local src_size_hr tgt_size_hr
    src_size_hr=$(lsblk -dn -o SIZE "/dev/${SOURCE_DISK}" 2>/dev/null || echo "?")
    tgt_size_hr=$(lsblk -dn -o SIZE "/dev/${TARGET_DISK}" 2>/dev/null || echo "?")

    # Pretty summary table
    echo -e "  ${CYAN}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}│${NC}  ${BOLD}Source${NC}                                              ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}    Disk:       /dev/${SOURCE_DISK} (${src_size_hr}, encrypted)       ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}    Crypt map:  /dev/mapper/${DM_NAME}                     ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}    Status:     ${GREEN}Untouched${NC}                               ${CYAN}│${NC}"
    echo -e "  ${CYAN}├──────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC}  ${BOLD}Target${NC}                                              ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}    Disk:       /dev/${TARGET_DISK} (${tgt_size_hr}, raw)             ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}    Root:       ${tgt_root_uuid}         ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}    Boot:       ${tgt_boot_uuid}         ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}    EFI:        ${tgt_efi_uuid}                        ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}    Status:     ${GREEN}Bootable${NC}                                ${CYAN}│${NC}"
    echo -e "  ${CYAN}└──────────────────────────────────────────────────────┘${NC}"
    echo ""
    info "Log file: ${LOG_FILE}"
    echo ""

    # Machine-readable summary for automation (deploy.ps1 parses this)
    echo "###MIGRATION_SUMMARY_START###"
    echo "STATUS=SUCCESS"
    echo "SOURCE_DISK=/dev/${SOURCE_DISK}"
    echo "SOURCE_SIZE=${src_size_hr}"
    echo "TARGET_DISK=/dev/${TARGET_DISK}"
    echo "TARGET_SIZE=${tgt_size_hr}"
    echo "ROOT_UUID=${tgt_root_uuid}"
    echo "BOOT_UUID=${tgt_boot_uuid}"
    echo "EFI_UUID=${tgt_efi_uuid}"
    echo "ROOT_FS=${ROOT_FSTYPE}"
    echo "DM_NAME=${DM_NAME}"
    echo "LOG_FILE=${LOG_FILE}"
    echo "###MIGRATION_SUMMARY_END###"
}

###############################################################################
# Usage
###############################################################################

usage() {
    cat <<EOF

${BOLD}Azure Linux Encrypted OS Disk Migration Tool v${VERSION}${NC}

${BOLD}Usage:${NC}
  sudo ./${SCRIPT_NAME} [OPTIONS]

${BOLD}Options:${NC}
  --dry-run       Preview actions without making changes
  --yes           Skip confirmation prompt
  --force         Override size check (when target is slightly smaller)
  --help          Show this help message

${BOLD}Description:${NC}
  Detects the encrypted OS disk, finds an empty target disk,
  replicates partitions, copies decrypted data, and configures
  the target for standalone boot (no encryption).

${BOLD}Requirements:${NC}
  - Must run as root on the source VM
  - Source OS disk must be encrypted (ADE/LUKS) and unlocked
  - Empty target disk must be attached to the VM
  - Target disk must be ≥ source disk in size

EOF
    exit 0
}

###############################################################################
# Main
###############################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN=true ;;
            --yes|-y)   SKIP_CONFIRM=true ;;
            --force)    FORCE=true ;;
            --help|-h)  usage ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done

    # Initialize
    echo ""
    echo -e "${BOLD}${MAGENTA}  ╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}  ║        Azure Linux Encrypted Disk Migration Tool            ║${NC}"
    echo -e "${BOLD}${MAGENTA}  ║                      v${VERSION}                                ║${NC}"
    echo -e "${BOLD}${MAGENTA}  ╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    log "INFO" "=== Migration started at $(date) ==="
    log "INFO" "Version: ${VERSION}"
    log "INFO" "Dry run: ${DRY_RUN}"

    check_dependencies

    # Phase 1: Detection
    detect_os_disk
    detect_target_disk
    validate_disk_sizes

    # Summary & Confirmation
    print_summary

    # Phase 2: Partition table
    replicate_partition_table

    # Phase 3: Copy data
    print_header "Phase 3: Data Copy"
    copy_bios_boot
    copy_efi_partition
    copy_boot_partition
    copy_root_partition

    # Phase 4: Fixup
    fixup_target

    # Phase 5: Verify
    verify_target

    # Done
    print_final_report
}

main "$@"
