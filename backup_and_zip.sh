#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
LOG_TAG="BACKUP"
source "${REPO_ROOT}/jetson_bsp_common.sh"

BOARD="${BOARD:-jetson-orin-nano-devkit-super-nvme}"
OUTPUT_DIR="${REPO_ROOT}/backups"
ZIP_NAME="${ZIP_NAME:-}"
BACKUP_DEVICE="${BACKUP_DEVICE:-nvme0n1}"
IMAGES_DIR=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [backup-options]

Creates a Jetson backup using Linux_for_Tegra/tools/backup_restore and
packages the resulting images into a timestamped zip archive under
${OUTPUT_DIR}.

Environment variables:
  BOARD             Target board name (default: ${BOARD})
  JETSON_BSP_URL    URL used to download the Jetson BSP if Linux_for_Tegra is
                    not present.
  BACKUP_DEVICE     Block device passed to -e (default: ${BACKUP_DEVICE})
  ZIP_NAME          Override the generated archive name (default timestamped)

Any additional arguments are forwarded to l4t_backup_restore.sh, for example:
  $(basename "$0") -e nvme0n1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

ensure_host_dependencies
require_command zip
require_command sha256sum

ensure_l4t
IMAGES_DIR="${L4T_DIR}/tools/backup_restore/images"

if [[ ! -x "${L4T_BACKUP_SCRIPT}" ]]; then
	log "Backup script ${L4T_BACKUP_SCRIPT} is missing or not executable."
	exit 1
fi

SUDO_BIN="$(needsudo)"

args=("$@")
if [[ -n "${BACKUP_DEVICE}" ]]; then
	has_device_flag=0
	for arg in "${args[@]}"; do
		if [[ "${arg}" == "-e" ]]; then
			has_device_flag=1
			break
		fi
	done
	if [[ "${has_device_flag}" -eq 0 ]]; then
		args+=("-e" "${BACKUP_DEVICE}")
	fi
fi

log "Starting backup for board ${BOARD}"
if [[ -n "${SUDO_BIN}" ]]; then
	(
		cd "${L4T_DIR}"
		"${SUDO_BIN}" env LC_ALL=C LANG=C ./tools/backup_restore/l4t_backup_restore.sh -b "${args[@]}" "${BOARD}"
	)
else
	(
		cd "${L4T_DIR}"
		LC_ALL=C LANG=C ./tools/backup_restore/l4t_backup_restore.sh -b "${args[@]}" "${BOARD}"
	)
fi

if [[ ! -d "${IMAGES_DIR}" ]]; then
	log "Expected images directory ${IMAGES_DIR} was not created."
	exit 1
fi

if [[ -z "$(ls -A "${IMAGES_DIR}")" ]]; then
	log "Images directory ${IMAGES_DIR} is empty; nothing to archive."
	exit 1
fi

mkdir -p "${OUTPUT_DIR}"
timestamp="$(date +%Y%m%d-%H%M%S)"
default_name="${BOARD}-backup-${timestamp}.zip"
archive_name="${ZIP_NAME:-${default_name}}"
[[ "${archive_name}" == *.zip ]] || archive_name="${archive_name}.zip"
archive_path="${OUTPUT_DIR}/${archive_name}"
temp_dir="$(mktemp -d "${OUTPUT_DIR}/tmp.${timestamp}.XXXX")"
trap 'rm -rf "${temp_dir}"' EXIT

mkdir -p "${temp_dir}/images"
cp -a "${IMAGES_DIR}/." "${temp_dir}/images/"

(
	cd "${temp_dir}"
	log "Creating archive ${archive_path}"
	zip -rq "${archive_path}" images
)

sha_file="${archive_path}.sha256"
sha256sum "${archive_path}" > "${sha_file}"
log "Backup archive ready: ${archive_path}"
log "SHA256 checksum saved to ${sha_file}"
