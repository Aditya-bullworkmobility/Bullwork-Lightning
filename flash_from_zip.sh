#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
LOG_TAG="FLASH"
source "${REPO_ROOT}/jetson_bsp_common.sh"

BOARD="${BOARD:-jetson-orin-nano-devkit-super-nvme}"
IMAGES_DIR=""

usage() {
	cat <<EOF
Usage: $(basename "$0") <backup-zip> [restore-options]

Unpacks the provided Jetson backup zip (created by backup_and_zip.sh),
places the images inside Linux_for_Tegra, and invokes the restore flow.

Environment variables:
  BOARD             Target board name (default: ${BOARD})
  JETSON_BSP_URL    URL used to download the Jetson BSP if Linux_for_Tegra is
                    not present.

Additional arguments are forwarded to l4t_backup_restore.sh, e.g.:
  $(basename "$0") backups/jetson-orin-nano-devkit-super-nvme-backup.zip
EOF
}

if [[ $# -lt 1 || "${1}" == "-h" || "${1}" == "--help" ]]; then
	usage
	exit $(( $# == 0 ? 1 : 0 ))
fi

ZIP_PATH="$1"
shift

if [[ ! -f "${ZIP_PATH}" ]]; then
	log "Backup archive ${ZIP_PATH} not found."
	exit 1
fi

ensure_host_dependencies
require_command unzip

ensure_l4t
IMAGES_DIR="${L4T_DIR}/tools/backup_restore/images"

if [[ ! -x "${L4T_BACKUP_SCRIPT}" ]]; then
	log "Backup script ${L4T_BACKUP_SCRIPT} is missing or not executable."
	exit 1
fi

mkdir -p "${REPO_ROOT}/backups"
temp_dir="$(mktemp -d "${REPO_ROOT}/backups/tmp.flash.XXXX")"
trap 'rm -rf "${temp_dir}"' EXIT

log "Extracting ${ZIP_PATH}"
unzip -q "${ZIP_PATH}" -d "${temp_dir}"

if [[ ! -d "${temp_dir}/images" ]]; then
	log "Archive ${ZIP_PATH} does not contain an images/ directory."
	exit 1
fi

mkdir -p "$(dirname "${IMAGES_DIR}")"

if [[ -d "${IMAGES_DIR}" ]]; then
	backup_dir="${IMAGES_DIR}_$(date +%Y%m%d-%H%M%S)_prev"
	mv "${IMAGES_DIR}" "${backup_dir}"
	log "Existing images moved to ${backup_dir}"
fi

mv "${temp_dir}/images" "${IMAGES_DIR}"
log "Restoring board ${BOARD} using images from ${ZIP_PATH}"

SUDO_BIN="$(needsudo)"
if [[ -n "${SUDO_BIN}" ]]; then
	(
		cd "${L4T_DIR}"
		"${SUDO_BIN}" env LC_ALL=C LANG=C ./tools/backup_restore/l4t_backup_restore.sh -r "$@" "${BOARD}"
	)
else
	(
		cd "${L4T_DIR}"
		LC_ALL=C LANG=C ./tools/backup_restore/l4t_backup_restore.sh -r "$@" "${BOARD}"
	)
fi

log "Restore completed. You can reboot or power-cycle the target."
