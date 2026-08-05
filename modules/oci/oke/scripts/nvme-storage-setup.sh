#!/bin/bash

# OKE Node NVMe Storage Configuration
# Creates an LVM volume group from all available NVMe disks with striping
# Excludes only root/boot devices to prevent system damage

# Setup logging
LOGFILE="/var/log/nvme-storage-setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

# Configuration - Support both template variables and environment variables
declare -r node_type="${node_type:-${NODE_TYPE:-generic}}"
declare -r cluster_name="${cluster_name:-${CLUSTER_NAME:-oke-cluster}}"
declare -r vg_name="nvme-vg"
declare -r lv_name="lv-storage"

# Logging function
log() {
    echo "$(date '+%H:%M:%S') - $1"
}

log "Starting NVMe setup for $node_type ($cluster_name)"

# Check if volume group already exists
if vgs "$vg_name" &>/dev/null; then
    log "Volume group exists - skipping"
    exit 0
fi

# Install required packages
yum install -y lvm2 nvme-cli &>/dev/null 2>&1 || log "WARNING: Package installation incomplete"

# Function to identify root disk and boot-related devices
get_root_and_boot_devices() {
    declare -a root_devices=()
    
    # Find root filesystem device
    local root_device=$(findmnt -n -o SOURCE / 2>/dev/null)
    if [[ -n "$root_device" ]]; then
        local base_device=$(echo "$root_device" | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')
        root_devices+=("$base_device")
    fi
    
    # Find boot filesystem device
    local boot_device=$(findmnt -n -o SOURCE /boot 2>/dev/null)
    if [[ -n "$boot_device" ]]; then
        local base_device=$(echo "$boot_device" | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')
        root_devices+=("$base_device")
    fi
    
    # Find EFI system partition
    local efi_device=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null)
    if [[ -n "$efi_device" ]]; then
        local base_device=$(echo "$efi_device" | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')
        root_devices+=("$base_device")
    fi
    
    # Remove duplicates and return
    printf '%s\n' "${root_devices[@]}" | sort -u
}

# Function to check if device is a root/boot device
is_root_or_boot_device() {
    local device="$1"
    local root_devices=("${@:2}")
    
    for root_dev in "${root_devices[@]}"; do
        if [[ "$device" == "$root_dev" ]]; then
            return 0
        fi
    done
    return 1
}

# Identify root and boot devices first
declare -a root_boot_devices=()
while IFS= read -r device; do
    root_boot_devices+=("$device")
done < <(get_root_and_boot_devices)

# Discover all available NVMe devices (excluding only root/boot devices)
declare -a disks=()

# Check all NVMe devices
for device in /dev/nvme*n1; do
    if [[ -b "$device" ]]; then
        # Skip if this is a root or boot device
        if is_root_or_boot_device "$device" "${root_boot_devices[@]}"; then
            continue
        fi
        # Add all other NVMe devices to the list
        disks+=("$device")
    fi
done

log "Found ${#disks[@]} NVMe device(s) for LVM"

if [ "${#disks[@]}" -eq 0 ]; then
    log "No NVMe devices available - expected for non-DenseIO instances"
    exit 0
fi

# Prepare disks for LVM
log "Preparing ${#disks[@]} disk(s) for LVM..."
for disk in "${disks[@]}"; do
    # Remove any existing LVM signatures
    pvremove -ff -y "$disk" &>/dev/null || true
    
    # Clear the beginning of the disk
    dd if=/dev/zero of="$disk" bs=1M count=10 &>/dev/null || true
    
    # Remove all signatures
    wipefs -a -f "$disk" &>/dev/null || true
    
    # Update kernel partition table
    partprobe "$disk" &>/dev/null || true
done

# Create physical volumes
for disk in "${disks[@]}"; do
    if ! pvcreate -ff -y "$disk" &>/dev/null; then
        log "ERROR: Failed to create PV on $disk"
        exit 1
    fi
done
log "Physical volumes created"

# Create volume group from all PVs
if ! vgcreate -ff -y "$vg_name" "${disks[@]}" &>/dev/null; then
    log "ERROR: Failed to create volume group"
    exit 1
fi
log "Volume group '$vg_name' created"

# Create logical volume with striping for performance
num_disks=${#disks[@]}

if [ $num_disks -gt 1 ]; then
    # Create striped LV for multiple disks (64KB stripe size)
    if ! lvcreate -Zn -i "$num_disks" -I 64 -l 95%FREE -n "$lv_name" "$vg_name" &>/dev/null; then
        log "ERROR: Failed to create striped logical volume"
        exit 1
    fi
    log "Striped LV created across $num_disks disks"
else
    # Create standard LV for single disk
    if ! lvcreate -Zn -l 95%FREE -n "$lv_name" "$vg_name" &>/dev/null; then
        log "ERROR: Failed to create logical volume"
        exit 1
    fi
    log "Logical volume created"
fi

# Final summary
log "NVMe setup complete: VG=$vg_name, LV=/dev/$vg_name/$lv_name"

exit 0