# Jetson Image Toolkit

Utilities that wrap NVIDIA’s Linux for Tegra (L4T) backup and restore flow for
a Jetson Orin Nano dev kit (`jetson-orin-nano-devkit-super-nvme` by default).

## Repository Layout

- `Linux_for_Tegra/` – NVIDIA’s BSP. The helper scripts can download it if you
  provide a URL.
- `backup_and_zip.sh` – runs the L4T backup script and zips the resulting
  images.
- `flash_from_zip.sh` – unpacks a backup archive and triggers the restore flow.
- `jetson_bsp_common.sh` – shared helpers (download BSP, logging, sudo helper).
- `backups/` – generated archives and checksums.
- `downloads/` – cached BSP installers.

## Prerequisites

- Ubuntu host with `sudo` access.
- Required tools: `bash`, `zip`, `unzip`, `sha256sum`, `wget`, `tar`, `sshpass`,
  `zstd`, `abootimg`, `nfs-kernel-server`.
- Jetson device in recovery mode connected over USB, or configured for network
  flashing per NVIDIA docs.
- For the Jetson Orin Nano dev kit, short the recovery pads (Force Recovery:
  pinpoint the pads near the 40-pin header, typically `FC REC` and `GND`) while
  powering on to enter recovery mode. The photos below show the wiring:
  ![Jetson recovery wiring overview](images/IMG-20251016-WA0002.jpg)
  ![Jetson recovery wiring close-up](images/IMG-20251016-WA0003.jpg)

  Steps:
  1. Power off the dev kit and disconnect USB-C.
  2. Use a dupont jumper to connect `FC REC` to the adjacent `GND` pin (highlighted above).
  3. While the jumper is in place, reconnect USB-C and tap the power button.
  4. Once the host PC detects the device as `0955:7523`, remove the jumper and proceed with backup/restore.

The helper scripts attempt to install any missing packages automatically using
`apt-get` (sudo is used when necessary). If APT is unavailable, install the
prerequisites manually before running the tools.

If `Linux_for_Tegra/` is missing the scripts will download
`https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Jetson_Linux_r36.4.4_aarch64.tbz2`
by default. Override this by exporting `JETSON_BSP_URL` to a different BSP
package URL if required.

If `Linux_for_Tegra/rootfs/` is empty, the scripts automatically fetch and
extract the sample root filesystem from
`https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Tegra_Linux_Sample-Root-Filesystem_r36.4.4_aarch64.tbz2`.
Set `JETSON_ROOTFS_URL` to override the download source. After the rootfs is in
place the scripts invoke `sudo ./apply_binaries.sh` (or rely on your existing
installation) to stage the proprietary BSP components automatically.

## Backing Up

```bash
sudo ./backup_and_zip.sh
```

Example with a custom archive name:

```bash
sudo ./backup_and_zip.sh --zip-name <image_name>.zip
```

![Backup flow overview](images/backup_flow.png)

The script calls `l4t_backup_restore.sh -b -e <BACKUP_DEVICE>` internally, then
packages `Linux_for_Tegra/tools/backup_restore/images/` into
`backups/<board>-backup-<timestamp>.zip` and emits a matching `.sha256`.

Environment overrides:

- `--board <name>` – select a different Jetson configuration.
- `--zip-name <filename>` – choose a custom archive name (append `.zip` if you
  want a specific extension; otherwise it will be
  added automatically).
- `--device <dev>` – sets the block device passed to
  `-e` (defaults to
  `nvme0n1` if you do not specify one on the command line).
- `L4T_DIR=<path>` – point the scripts at an existing `Linux_for_Tegra`
  directory if it lives outside this repository.
- `JETSON_ROOTFS_URL=<url>` – choose an alternate rootfs tarball to extract.
- `SKIP_APPLY_BINARIES=1` – prevent the helper from running `apply_binaries.sh`
  (useful if you manage the rootfs manually).

## Flashing

```bash
sudo ./flash_from_zip.sh backups/<archive>.zip [extra restore flags]
```

![Flashing flow overview](images/restoring_flow.png)

The script unpacks the archive, replaces the BSP’s `images/` directory with its
contents, and invokes `l4t_backup_restore.sh -r -e <BACKUP_DEVICE>` for the
selected board. Override the defaults via `--board` / `--device` (or the
matching environment variables) if needed. Any additional arguments supplied
after the zip path are forwarded to `l4t_backup_restore.sh` (for example
`--raw-image /path/to/disk.img`).

## Tips

- Verify NFS requirements (`nfs-kernel-server`, firewall rules) before running.
- Keep `Linux_for_Tegra/bootloader` intact; restore relies on its binaries.
- After flashing, power-cycle or reboot the Jetson manually.
