#!/bin/bash

set -e

# --- Help Message ---
usage() {
  echo -e "Usage: $0 <OLD_ID> <NEW_ID>\n"
  echo "Safely renames a Proxmox LXC container ID with full backup and correct volume renaming."
  echo
  echo "Arguments:"
  echo "  OLD_ID    Existing container ID (e.g. 218)"
  echo "  NEW_ID    New desired container ID (e.g. 9218)"
  echo
  echo "Example:"
  echo "  $0 218 9218"
  exit 1
}

# --- Argument Parsing ---
if [[ "$1" == "--help" || "$#" -ne 2 ]]; then
  usage
fi

LXC_ID_OLD="$1"
LXC_ID_NEW="$2"

if ! [[ "$LXC_ID_OLD" =~ ^[0-9]+$ && "$LXC_ID_NEW" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: Both OLD_ID and NEW_ID must be numeric."
  usage
fi

CONF_OLD="/etc/pve/lxc/${LXC_ID_OLD}.conf"
CONF_NEW="/etc/pve/lxc/${LXC_ID_NEW}.conf"

if [[ ! -f "$CONF_OLD" ]]; then
  echo "❌ Error: Container config $CONF_OLD does not exist."
  exit 1
fi

if [[ -f "$CONF_NEW" ]]; then
  echo "❌ Error: Config for new container ID $LXC_ID_NEW already exists."
  exit 1
fi

# --- Setup ---
NOW=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/root/lxc_renumber_backup_${LXC_ID_OLD}_to_${LXC_ID_NEW}_$NOW"
ROOTFS_OLD="/var/lib/lxc/${LXC_ID_OLD}"
ROOTFS_NEW="/var/lib/lxc/${LXC_ID_NEW}"

echo "🚧 Renumbering LXC container: $LXC_ID_OLD → $LXC_ID_NEW"
echo "📦 Backup location: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# --- Safety Check ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ This script must be run as root."
  exit 1
fi

command -v pvesm >/dev/null || { echo "❌ pvesm not found. This must be run on a Proxmox node."; exit 1; }

# --- Volume Rename Handler ---
rename_volume() {
  local storage="$1"
  local old_vol="$2"
  local new_vol="$3"

  local stype
  stype=$(pvesm status --verbose | awk -v store="$storage" '$1 == store {print $2}')

  if [[ -z "$stype" ]]; then
    echo "❌ Could not detect storage type for '$storage'"
    exit 1
  fi

  case "$stype" in
    rbd)
      echo "🔧 [rbd] Renaming using: rbd -p $storage rename $old_vol $new_vol"
      rbd -p "$storage" rename "$old_vol" "$new_vol"
      ;;
    zfs)
      echo "🔧 [zfs] Renaming using: zfs rename $old_vol $new_vol"
      zfs rename "$old_vol" "$new_vol"
      ;;
    lvmthin)
      VG=$(lvs --noheadings -o vg_name | awk '{print $1}' | head -n 1)
      echo "🔧 [lvmthin] Renaming using: lvrename $VG $old_vol $new_vol"
      lvrename "$VG" "$old_vol" "$new_vol"
      ;;
    *)
      echo "❌ Unsupported storage type '$stype' for $storage. Please rename manually."
      exit 1
      ;;
  esac
}

# --- Step 1: Stop container if running ---
echo "🛑 Checking if container $LXC_ID_OLD is running..."
if pct status "$LXC_ID_OLD" | grep -q "status: running"; then
  echo "⚙️ Container is running — stopping it..."
  pct stop "$LXC_ID_OLD" || {
    echo "❌ Failed to stop container $LXC_ID_OLD"
    exit 1
  }
else
  echo "ℹ️ Container is already stopped — continuing..."
fi

# --- Step 2: Backup and copy config ---
echo "📄 Backing up config..."
cp "$CONF_OLD" "$BACKUP_DIR/"
cp "$CONF_OLD" "$CONF_NEW"

# --- Step 3: Detect and rename storage volumes ---
echo "🔍 Scanning for attached volumes in config..."

DISK_LINES=$(grep -E "^(rootfs|mp[0-9]+|volume=)" "$CONF_NEW" | grep "$LXC_ID_OLD" || true)

for line in $DISK_LINES; do
  # Skip host path mount points
  if [[ "$line" =~ ^mp[0-9]+:\ (/|\.\/) ]]; then
    echo "ℹ️ Skipping host bind mount: $line"
    continue
  fi

  DISK_REF=$(echo "$line" | sed -E 's/.*[:=]//;s/,.*//')

  if [[ "$DISK_REF" =~ ^([^:]+):(.+)$ ]]; then
    STORAGE="${BASH_REMATCH[1]}"
    VOL="${BASH_REMATCH[2]}"
    NEW_VOL="${VOL//$LXC_ID_OLD/$LXC_ID_NEW}"

    echo "🔄 Renaming volume: $STORAGE:$VOL → $NEW_VOL"
    echo "$STORAGE:$VOL → $NEW_VOL" >> "$BACKUP_DIR/volume_rename_map.txt"

    rename_volume "$STORAGE" "$VOL" "$NEW_VOL"

    sed -i "s|$VOL|$NEW_VOL|g" "$CONF_NEW"
  else
    echo "⚠️ Could not parse volume from line: $line"
  fi
done

# --- Step 4: Move rootfs directory if needed ---
if [[ -d "$ROOTFS_OLD" ]]; then
  echo "📁 Moving rootfs directory: $ROOTFS_OLD → $ROOTFS_NEW"
  echo "$ROOTFS_OLD" >> "$BACKUP_DIR/rootfs_path.txt"
  mv "$ROOTFS_OLD" "$ROOTFS_NEW"
fi

# --- Step 5: Remove old config ---
echo "🧹 Removing old config (already backed up)..."
rm "$CONF_OLD"

# --- Step 6: Start new container ---
echo "🚀 Starting container $LXC_ID_NEW..."
pct start "$LXC_ID_NEW"

# --- Summary ---
echo
echo "✅ Successfully renumbered container $LXC_ID_OLD → $LXC_ID_NEW"
echo "🗂️ Backup stored at: $BACKUP_DIR"
echo "🛠️ Manual restore (if needed):"
echo "   cp ${BACKUP_DIR}/${LXC_ID_OLD}.conf /etc/pve/lxc/"
echo "   Use volume_rename_map.txt for reverse volume renames"
[[ -f "$BACKUP_DIR/rootfs_path.txt" ]] && echo "   mv $ROOTFS_NEW $ROOTFS_OLD"
