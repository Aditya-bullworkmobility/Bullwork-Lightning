#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
LOG_TAG="FLASH"
source "${REPO_ROOT}/jetson_bsp_common.sh"

DEFAULT_BOARD="jetson-orin-nano-devkit-super-nvme"
DEFAULT_DEVICE="nvme0n1"
BOARD=""
BACKUP_DEVICE=""
IMAGES_DIR=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [options] <backup-zip> [restore-options]

Unpacks the provided Jetson backup zip (created by backup_and_zip.sh),
places the images inside Linux_for_Tegra, and invokes the restore flow.

Options:
  --board <name>      Set the Jetson board configuration (overrides env)
  --device <dev>      Set the storage device passed with -e (overrides env)
  -h, --help          Show this help

Environment variables:
  BOARD             Target board name (default: ${DEFAULT_BOARD})
  JETSON_BSP_URL    URL used to download the Jetson BSP if Linux_for_Tegra is
                    not present.
  BACKUP_DEVICE     Block device passed to -e during restore (default: ${DEFAULT_DEVICE})

Additional arguments are forwarded to l4t_backup_restore.sh, e.g.:
  $(basename "$0") backups/jetson-orin-nano-devkit-super-nvme-backup.zip
EOF
}

BOARD_CLI=""
DEVICE_CLI=""
ZIP_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --board)
            if [[ -z "${2:-}" ]]; then
                log "Error: --board requires an argument"
                exit 1
            fi
            BOARD_CLI="$2"
            shift 2
            ;;
        --board=*)
            BOARD_CLI="${1#*=}"
            shift
            ;;
        --device)
            if [[ -z "${2:-}" ]]; then
                log "Error: --device requires an argument"
                exit 1
            fi
            DEVICE_CLI="$2"
            shift 2
            ;;
        --device=*)
            DEVICE_CLI="${1#*=}"
            shift
            ;;
        --)
            shift
            break
            ;;
        -* )
            log "Unknown option: $1"
            usage
            exit 1
            ;;
        * )
            ZIP_PATH="$1"
            shift
            break
            ;;
    esac
done

if [[ -z "${ZIP_PATH}" ]]; then
    usage
    exit 1
fi

RESTORE_ARGS=("$@")

BOARD="${BOARD_CLI:-${DEFAULT_BOARD}}"
BACKUP_DEVICE="${DEVICE_CLI:-${DEFAULT_DEVICE}}"

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
if [[ ${#RESTORE_ARGS[@]} -gt 0 ]]; then
    log "Invoking ./tools/backup_restore/l4t_backup_restore.sh -r -e ${BACKUP_DEVICE} ${BOARD} ${RESTORE_ARGS[*]}"
else
    log "Invoking ./tools/backup_restore/l4t_backup_restore.sh -r -e ${BACKUP_DEVICE} ${BOARD}"
fi
if [[ -n "${SUDO_BIN}" ]]; then
	(
		cd "${L4T_DIR}"
		"${SUDO_BIN}" env LC_ALL=C LANG=C ./tools/backup_restore/l4t_backup_restore.sh -r -e "${BACKUP_DEVICE}" "${RESTORE_ARGS[@]}" "${BOARD}"
	)
else
	(
		cd "${L4T_DIR}"
		LC_ALL=C LANG=C ./tools/backup_restore/l4t_backup_restore.sh -r -e "${BACKUP_DEVICE}" "${RESTORE_ARGS[@]}" "${BOARD}"
	)
fi

log "Restore completed. You can reboot or power-cycle the target."
