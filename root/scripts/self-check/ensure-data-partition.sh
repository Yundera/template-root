#!/bin/bash

# Idempotent script to create a 1GB resizable partition and mount it on /mnt/data
# with bind mounts to /DATA and /var/lib/docker
# This script must be run as root
# Preserves existing /DATA and /var/lib/docker directory contents

# Exit immediately if a command exits with a non-zero status
set -e

export DEBIAN_FRONTEND=noninteractive

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

echo "→ Starting data partition setup script..."

# Change to root directory to avoid issues if script is run from /DATA
cd /

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Install required packages only if not already present
PACKAGES_TO_INSTALL=""
if ! command -v rsync &> /dev/null; then
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL rsync"
fi
if ! command -v parted &> /dev/null; then
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL parted"
fi
if ! command -v bc &> /dev/null; then
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL bc"
fi

if [ -n "$PACKAGES_TO_INSTALL" ]; then
    echo "→ Installing missing packages:$PACKAGES_TO_INSTALL..."
    [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
    if ! { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y $PACKAGES_TO_INSTALL; } >/dev/null 2>&1; then
        echo "✗ Failed to install packages. Running with verbose output for debugging:"
        [ -x "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh" ] && "$YND_ROOT/scripts/tools/wait-for-apt-lock.sh"
        apt-get update && apt-get install -y $PACKAGES_TO_INSTALL
        exit 1
    fi
fi

# Check if /mnt/data is already mounted and bind mounts are set up
if mountpoint -q /mnt/data 2>/dev/null && mountpoint -q /DATA 2>/dev/null && mountpoint -q /var/lib/docker 2>/dev/null; then
    echo "✓ All mounts are already configured. Nothing to do."
    exit 0
fi

# Check if /DATA exists as a directory (not mounted)
DATA_BACKUP_NEEDED=false
if [ -d "/DATA" ] && ! mountpoint -q /DATA 2>/dev/null; then
    echo "→ Found existing /DATA directory. Will preserve its contents."
    DATA_BACKUP_NEEDED=true

    # Check if DATA.tmp already exists
    if [ -e "/DATA.tmp" ]; then
        echo "WARNING: /DATA.tmp already exists. Removing it..."
        rm -rf "/DATA.tmp"
    fi

    # Rename existing /DATA to /DATA.tmp
    echo "Backing up existing /DATA to /DATA.tmp..."
    mv "/DATA" "/DATA.tmp"
    echo "Existing /DATA directory backed up to /DATA.tmp"
fi

# Check if /var/lib/docker exists as a directory (not mounted)
DOCKER_BACKUP_NEEDED=false
if [ -d "/var/lib/docker" ] && ! mountpoint -q /var/lib/docker 2>/dev/null; then
    echo "→ Found existing /var/lib/docker directory. Will preserve its contents."
    DOCKER_BACKUP_NEEDED=true

    # Check if docker.tmp already exists
    if [ -e "/var/lib/docker.tmp" ]; then
        echo "WARNING: /var/lib/docker.tmp already exists. Removing it..."
        rm -rf "/var/lib/docker.tmp"
    fi

    # Rename existing /var/lib/docker to /var/lib/docker.tmp
    echo "Backing up existing /var/lib/docker to /var/lib/docker.tmp..."
    mv "/var/lib/docker" "/var/lib/docker.tmp"
    echo "Existing /var/lib/docker directory backed up to /var/lib/docker.tmp"
fi

# Check if the volume group already exists
if vgdisplay data_vg >/dev/null 2>&1; then
    echo "Volume group 'data_vg' already exists."

    # Check if logical volume exists
    if lvdisplay /dev/data_vg/data_lv >/dev/null 2>&1; then
        echo "Logical volume 'data_lv' already exists. Attempting to mount..."

        # Create mount point if it doesn't exist
        if [ ! -d "/mnt/data" ]; then
            echo "Creating mount point /mnt/data..."
            mkdir -p /mnt/data
        fi

        # Try to mount the existing volume
        if mount /dev/data_vg/data_lv /mnt/data 2>/dev/null; then
            echo "Successfully mounted existing data partition to /mnt/data"

            # Ensure fstab entry exists
            if ! grep -q "/dev/data_vg/data_lv /mnt/data" /etc/fstab; then
                echo "Adding fstab entry..."
                echo "/dev/data_vg/data_lv /mnt/data ext4 defaults 0 2" >> /etc/fstab
            fi

            # Create subdirectories and restore data
            mkdir -p /mnt/data/user
            mkdir -p /mnt/data/docker

            # Restore backed up data if needed
            if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
                echo "Restoring backed up data to /mnt/data/user..."
                rsync -av "/DATA.tmp/" "/mnt/data/user/"

                # Remove backup after successful restoration
                echo "Removing backup directory /DATA.tmp..."
                rm -rf "/DATA.tmp"
                echo "Data restoration complete."
            fi

            if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
                echo "Restoring backed up docker data to /mnt/data/docker..."
                rsync -av "/var/lib/docker.tmp/" "/mnt/data/docker/"

                # Remove backup after successful restoration
                echo "Removing backup directory /var/lib/docker.tmp..."
                rm -rf "/var/lib/docker.tmp"
                echo "Docker data restoration complete."
            fi

            # Set up bind mounts
            # Create mount points if they don't exist
            mkdir -p /DATA
            mkdir -p /var/lib/docker

            # Set up bind mounts
            if ! mountpoint -q /DATA 2>/dev/null; then
                mount --bind /mnt/data/user /DATA
            fi

            if ! mountpoint -q /var/lib/docker 2>/dev/null; then
                mount --bind /mnt/data/docker /var/lib/docker
            fi

            # Add bind mount entries to fstab
            if ! grep -q "/mnt/data/user /DATA" /etc/fstab; then
                echo "/mnt/data/user /DATA none bind 0 0" >> /etc/fstab
            fi

            if ! grep -q "/mnt/data/docker /var/lib/docker" /etc/fstab; then
                echo "/mnt/data/docker /var/lib/docker none bind 0 0" >> /etc/fstab
            fi

            # Ensure ownership and logging directory
            chown -R pcs:pcs /DATA 2>/dev/null || true
            mkdir -p /DATA/AppData/casaos/apps/yundera
            chown -R pcs:pcs /DATA/AppData/casaos/apps/yundera 2>/dev/null || true

            echo "✓ Setup complete. Existing DATA partition mounted successfully."
            exit 0
        else
            echo "Failed to mount existing logical volume. Will recreate..."
        fi
    fi
fi

echo "→ No existing data partition found. Creating new 1GB partition..."

# Fix the GPT to use all available space
echo "Fixing GPT to use all available space..."
sgdisk --resize-table=128 /dev/sda

# Fix the GPT to recognize the full disk
echo "Ensuring GPT recognizes full disk space..."
sgdisk -e /dev/sda

# Find suitable free space for 1GB partition (need at least 1100MB to be safe)
echo "Checking for available free space..."
FREE_SPACE_INFO=$(parted -s /dev/sda unit MB print free | grep "Free Space" | awk '{print $1, $2, $3}')

# Find a free space block that can accommodate 1GB
SUITABLE_START=""
SUITABLE_END=""
TARGET_SIZE=1024  # 1GB in MB

while read -r START END SIZE; do
    # Extract just the number from the size (remove 'MB')
    SIZE_NUM=$(echo "$SIZE" | sed 's/MB//')

    # Check if this free space can accommodate our 1GB partition
    if (( $(echo "$SIZE_NUM >= 1100" | bc -l) )); then
        SUITABLE_START=$START
        # Calculate end position for 1GB partition
        START_NUM=$(echo "$START" | sed 's/MB//')
        SUITABLE_END="${START_NUM}MB + ${TARGET_SIZE}MB"
        break
    fi
done <<< "$FREE_SPACE_INFO"

if [ -z "$SUITABLE_START" ]; then
    echo "ERROR: No suitable free space found (minimum 1100MB required for 1GB partition)"

    # Restore backed up data if creation failed
    if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
        echo "Restoring original /DATA directory due to partition creation failure..."
        mv "/DATA.tmp" "/DATA"
    fi

    if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
        echo "Restoring original /var/lib/docker directory due to partition creation failure..."
        mv "/var/lib/docker.tmp" "/var/lib/docker"
    fi

    exit 1
fi

echo "Found suitable free space starting at ${SUITABLE_START}. Will create 1GB partition."

# Determine the next partition number
NEXT_PART_NUM=$(sgdisk -p /dev/sda | grep -c "^[ ]*[0-9]")
NEXT_PART_NUM=$((NEXT_PART_NUM + 1))
NEW_PARTITION="/dev/sda${NEXT_PART_NUM}"

echo "Will create partition: $NEW_PARTITION"

# Create a new 1GB partition
echo "Creating new 1GB partition..."
START_NUM=$(echo "$SUITABLE_START" | sed 's/MB//')
END_NUM=$((START_NUM + TARGET_SIZE))
parted -s /dev/sda unit MB mkpart primary ${START_NUM}MB ${END_NUM}MB

# Update kernel to see the new partition
partprobe /dev/sda

# Smart wait for the partition to become available
echo "Waiting for system to recognize new partition..."
TIMEOUT=30
COUNTER=0
while [ ! -b "$NEW_PARTITION" ] && [ $COUNTER -lt $TIMEOUT ]; do
    echo "Waiting for $NEW_PARTITION to appear... ($COUNTER/$TIMEOUT seconds)"
    sleep 1
    COUNTER=$((COUNTER + 1))
    # Force kernel to re-read partition table again
    if [ $((COUNTER % 5)) -eq 0 ]; then
        partprobe /dev/sda
        udevadm trigger
    fi
done

# Make sure the partition exists before continuing
if [ ! -b "$NEW_PARTITION" ]; then
    echo "ERROR: $NEW_PARTITION not found after $TIMEOUT seconds. Aborting."

    # Restore backed up data if partition creation failed
    if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
        echo "Restoring original /DATA directory due to partition creation failure..."
        mv "/DATA.tmp" "/DATA"
    fi

    if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
        echo "Restoring original /var/lib/docker directory due to partition creation failure..."
        mv "/var/lib/docker.tmp" "/var/lib/docker"
    fi

    exit 1
fi

echo "New partition created: $NEW_PARTITION"
echo "Partition size: $(lsblk -no SIZE $NEW_PARTITION 2>/dev/null || echo "Unknown")"

# Create physical volume on the new partition
echo "Creating LVM physical volume..."
if ! pvcreate $NEW_PARTITION; then
    echo "Failed to create physical volume"

    # Restore backed up data if LVM setup failed
    if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
        echo "Restoring original /DATA directory due to LVM setup failure..."
        mv "/DATA.tmp" "/DATA"
    fi

    if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
        echo "Restoring original /var/lib/docker directory due to LVM setup failure..."
        mv "/var/lib/docker.tmp" "/var/lib/docker"
    fi

    exit 1
fi

# Create a new volume group for DATA
echo "Creating volume group data_vg..."
if ! vgcreate data_vg $NEW_PARTITION; then
    echo "Failed to create volume group"

    # Restore backed up data if LVM setup failed
    if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
        echo "Restoring original /DATA directory due to LVM setup failure..."
        mv "/DATA.tmp" "/DATA"
    fi

    if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
        echo "Restoring original /var/lib/docker directory due to LVM setup failure..."
        mv "/var/lib/docker.tmp" "/var/lib/docker"
    fi

    exit 1
fi

# Create a logical volume using 100% of the volume group
echo "Creating logical volume data_lv..."
if ! lvcreate -l 100%FREE -n data_lv data_vg; then
    echo "Failed to create logical volume"

    # Restore backed up data if LVM setup failed
    if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
        echo "Restoring original /DATA directory due to LVM setup failure..."
        mv "/DATA.tmp" "/DATA"
    fi

    if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
        echo "Restoring original /var/lib/docker directory due to LVM setup failure..."
        mv "/var/lib/docker.tmp" "/var/lib/docker"
    fi

    exit 1
fi

# Format the logical volume with ext4
echo "Formatting logical volume with ext4..."
if ! mkfs.ext4 /dev/data_vg/data_lv; then
    echo "Failed to format logical volume"

    # Restore backed up data if formatting failed
    if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
        echo "Restoring original /DATA directory due to formatting failure..."
        mv "/DATA.tmp" "/DATA"
    fi

    if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
        echo "Restoring original /var/lib/docker directory due to formatting failure..."
        mv "/var/lib/docker.tmp" "/var/lib/docker"
    fi

    exit 1
fi

# Create mount point if it doesn't exist
if [ ! -d "/mnt/data" ]; then
    echo "Creating mount point /mnt/data..."
    mkdir -p /mnt/data
fi

# Mount the volume
echo "Mounting volume to /mnt/data..."
if ! mount /dev/data_vg/data_lv /mnt/data; then
    echo "Failed to mount volume"

    # Restore backed up data if mounting failed
    if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
        echo "Restoring original /DATA directory due to mounting failure..."
        rmdir "/mnt/data" 2>/dev/null || true  # Remove empty mount point
        mv "/DATA.tmp" "/DATA"
    fi

    if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
        echo "Restoring original /var/lib/docker directory due to mounting failure..."
        mv "/var/lib/docker.tmp" "/var/lib/docker"
    fi

    exit 1
fi

# Add entry to /etc/fstab for persistent mounting (only if not already present)
if ! grep -q "/dev/data_vg/data_lv /mnt/data" /etc/fstab; then
    echo "Updating /etc/fstab..."
    echo "/dev/data_vg/data_lv /mnt/data ext4 defaults 0 2" >> /etc/fstab
else
    echo "fstab entry already exists, skipping..."
fi

# Create subdirectories
mkdir -p /mnt/data/user
mkdir -p /mnt/data/docker

# Restore backed up data if needed
if [ "$DATA_BACKUP_NEEDED" = true ] && [ -d "/DATA.tmp" ]; then
    echo "Restoring backed up data to /mnt/data/user..."
    rsync -av "/DATA.tmp/" "/mnt/data/user/"

    # Remove backup after successful restoration
    echo "Removing backup directory /DATA.tmp..."
    rm -rf "/DATA.tmp"
    echo "Data restoration complete."
fi

if [ "$DOCKER_BACKUP_NEEDED" = true ] && [ -d "/var/lib/docker.tmp" ]; then
    echo "Restoring backed up docker data to /mnt/data/docker..."
    rsync -av "/var/lib/docker.tmp/" "/mnt/data/docker/"

    # Remove backup after successful restoration
    echo "Removing backup directory /var/lib/docker.tmp..."
    rm -rf "/var/lib/docker.tmp"
    echo "Docker data restoration complete."
fi

# Create mount points for bind mounts
mkdir -p /DATA
mkdir -p /var/lib/docker

# Set up bind mounts
mount --bind /mnt/data/user /DATA
mount --bind /mnt/data/docker /var/lib/docker

# Add bind mount entries to fstab
echo "/mnt/data/user /DATA none bind 0 0" >> /etc/fstab
echo "/mnt/data/docker /var/lib/docker none bind 0 0" >> /etc/fstab

# Create application directory structure
mkdir -p /DATA/AppData/casaos/apps/yundera

# Change ownership of /DATA to pcs user
echo "Changing ownership of /DATA to pcs user..."
if ! chown -R pcs:pcs /DATA; then
    echo "Failed to change ownership to pcs"
    exit 1
fi

# Log successful execution
echo "os-init-data-partition executed successfully" >> "/DATA/AppData/casaos/apps/yundera/log/yundera.log"

# Ensure the log file is also owned by pcs
chown pcs:pcs "/DATA/AppData/casaos/apps/yundera/log/yundera.log"

echo "✓ Setup complete. New 1GB DATA partition created, mounted at /mnt/data with bind mounts to /DATA and /var/lib/docker"
if [ "$DATA_BACKUP_NEEDED" = true ]; then
    echo "Original /DATA contents have been successfully restored."
fi
if [ "$DOCKER_BACKUP_NEEDED" = true ]; then
    echo "Original /var/lib/docker contents have been successfully restored."
fi