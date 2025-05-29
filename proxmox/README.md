# 📦 LXC ID Renumber Script for Proxmox VE

This script safely renumbers a Proxmox **LXC container ID** while:
- Backing up the original configuration and disk mapping
- Renaming associated volumes across supported storage backends
- Automatically updating the container's config
- Supporting Ceph RBD, ZFS, and LVM-thin storage types

---

## 🚀 Features

- 📁 Full config and volume mapping backup  
- 🧠 Intelligent storage detection  
- 🪄 Automatic volume renaming:
  - ✅ Ceph RBD (`rbd`)
  - ✅ ZFS (`zfs`)
  - ✅ LVM-thin (`lvrename`)
- 🧹 Host path mounts (`/mnt/...`) are safely ignored  
- 🔐 Root-only operation check

---

## 🛠️ Requirements

- Proxmox VE 6.x / 7.x / 8.x  
- Bash  
- `pvesm`, `rbd`, `zfs`, `lvs`, `lvrename`  
- Must be run on a Proxmox node (not inside a container)

---

## 📋 Usage

```bash
sudo ./renumber-lxc.sh <OLD_ID> <NEW_ID>
