#!/bin/bash

set -e

# ------------------------------------------------------------------------------
# Proxmox LXC/VM Renumbering Script
# ------------------------------------------------------------------------------
# This script safely renumbers an LXC container or QEMU/KVM VM in Proxmox.
# It performs:
#   - Detection of container type (LXC vs VM)
#   - Full config backup
#   - Volume renaming (RBD, ZFS, LVM-thin)
#   - Global config reference replacement (even in snapshot blocks)
#   - Optional start of the container or VM
#
# Supports: Proxmox VE 6/7/8
# ------------------------------------------------------------------------------
# Author: unifiedcommsguy
# Version: 1.1.0
# Date: 2025-05-30
# License: MIT
# Repository: https://github.com/unifiedcommsguy/proxmox-tools
# ------------------------------------------------------------------------------

# --- Help Message ---
usage() {
  echo -e "Usage: $0 <OLD_ID> <NEW_ID> [start=yes|no]\n"
  echo "Renames a Proxmox VM or LXC container ID safely with volume renaming and config patching."
  echo
  echo "Arguments:"
  echo "  OLD_ID    Existing VM or LXC ID"
  echo "  NEW_ID    Desired new ID"
  echo "  start     Optional: 'yes' to auto-start after renaming (default: no)"
  exit 1
}

# --- Argument Validation ---
if [[ "$1" == "--help" || $# -lt 2 || $# -gt 3 ]]; then usage; fi

OLD_ID="$1"
NEW_ID="$2"
START_AFTER_RENAME="${3:-no}"

[[ "$OLD_ID" =~ ^[0-9]+$ && "$NEW_ID" =~ ^[0-9]+$ ]] || usage

NOW=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/root/renumber_backup_${OLD_ID}_to_${NEW_ID}_$NOW"
mkdir -p "$BACKUP_DIR"

command -v pvesm >/dev/null || { echo "❌ Must be run on a Proxmox node."; exit 1; }

# --- Detect Container Type ---
if [[ -f "/etc/pve/lxc/${OLD_ID}.conf" ]]; then
  TYPE="lxc"
elif [[ -f "/etc/pve/qemu-server/${OLD_ID}.conf" ]]; then
  TYPE="vm"
else
  echo "❌ ID $OLD_ID is neither an LXC nor a VM."
  exit 1
fi

# --- Volume Rename Handler ---
rename_volume() {
  local storage="$1"
  local old_vol="$2"
  local new_vol="$3"
  local stype

  stype=$(pvesm status --verbose | awk -v store="$storage" '$1 == store {print $2}')

  case "$stype" in
    rbd)
      echo "🔧 rbd -p $storage rename $old_vol $new_vol"
      rbd -p "$storage" rename "$old_vol" "$new_vol"
      ;;
    zfs)
      echo "🔧 zfs rename $old_vol $new_vol"
      zfs rename "$old_vol" "$new_vol"
      ;;
    lvmthin)
      VG=$(lvs --noheadings -o vg_name | awk '{print $1}' | head -n 1)
      echo "🔧 lvrename $VG $old_vol $new_vol"
      lvrename "$VG" "$old_vol" "$new_vol"
      ;;
    *)
      echo "❌ Unsupported storage type: $stype for $storage"
      exit 1
      ;;
  esac
}

# --- LXC Logic ---
renumber_lxc() {
  CONF_OLD="/etc/pve/lxc/${OLD_ID}.conf"
  CONF_NEW="/etc/pve/lxc/${NEW_ID}.conf"
  echo "📦 Renaming LXC $OLD_ID → $NEW_ID"

  pct status "$OLD_ID" | grep -q running && pct stop "$OLD_ID"

  cp "$CONF_OLD" "$BACKUP_DIR/" && cp "$CONF_OLD" "$CONF_NEW"

  grep -E "^(rootfs|mp[0-9]+|volume=)" "$CONF_NEW" | grep "$OLD_ID" | while read -r line; do
    [[ "$line" =~ ^mp[0-9]+:\ (/|\./) ]] && continue
    DISK_REF=$(echo "$line" | sed -E 's/.*[:=]//;s/,.*//')
    if [[ "$DISK_REF" =~ ^([^:]+):(.+)$ ]]; then
      STORAGE="${BASH_REMATCH[1]}"
      VOL="${BASH_REMATCH[2]}"
      NEW_VOL="${VOL//$OLD_ID/$NEW_ID}"
      echo "$STORAGE:$VOL → $NEW_VOL" >> "$BACKUP_DIR/volume_rename_map.txt"
      rename_volume "$STORAGE" "$VOL" "$NEW_VOL"
      sed -i "s|$VOL|$NEW_VOL|g" "$CONF_NEW"
    fi
  done

  [[ -d "/var/lib/lxc/$OLD_ID" ]] && mv "/var/lib/lxc/$OLD_ID" "/var/lib/lxc/$NEW_ID"
  rm "$CONF_OLD"

  [[ "$START_AFTER_RENAME" == "yes" ]] && pct start "$NEW_ID"
}

# --- VM Logic ---
renumber_vm() {
  CONF_OLD="/etc/pve/qemu-server/${OLD_ID}.conf"
  CONF_NEW="/etc/pve/qemu-server/${NEW_ID}.conf"
  echo "📦 Renaming VM $OLD_ID → $NEW_ID"

  qm stop "$OLD_ID" || true
  cp "$CONF_OLD" "$BACKUP_DIR/" && cp "$CONF_OLD" "$CONF_NEW"

  grep -E "^(ide|sata|scsi|virtio|tpmstate|efidisk)[0-9]+:" "$CONF_NEW" | grep "$OLD_ID" | while read -r line; do
    DISK_REF=$(echo "$line" | cut -d: -f2 | cut -d, -f1)
    if [[ "$DISK_REF" =~ ^([^:]+):(.+)$ ]]; then
      STORAGE="${BASH_REMATCH[1]}"
      VOL="${BASH_REMATCH[2]}"
      NEW_VOL="${VOL//$OLD_ID/$NEW_ID}"
      echo "$STORAGE:$VOL → $NEW_VOL" >> "$BACKUP_DIR/volume_rename_map.txt"
      rename_volume "$STORAGE" "$VOL" "$NEW_VOL"
    fi
  done

  echo "📝 Updating all vm-${OLD_ID}-disk-* references in config..."
  sed -i "s/vm-${OLD_ID}-disk-/vm-${NEW_ID}-disk-/g" "$CONF_NEW"

  rm "$CONF_OLD"
  [[ "$START_AFTER_RENAME" == "yes" ]] && qm start "$NEW_ID"
}

# --- Dispatch ---
echo "📁 Backup directory: $BACKUP_DIR"
case "$TYPE" in
  lxc) renumber_lxc ;;
  vm)  renumber_vm  ;;
esac

echo
echo "✅ Successfully renumbered $TYPE: $OLD_ID → $NEW_ID"
echo "🗂️ Backup stored at: $BACKUP_DIR"
echo "🛠️ Use volume_rename_map.txt to reverse disk renames if needed"
echo "🔍 Run 'grep vm-${OLD_ID} /etc/pve/qemu-server/${NEW_ID}.conf' to check for leftovers"
