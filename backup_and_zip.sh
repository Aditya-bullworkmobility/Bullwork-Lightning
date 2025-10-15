#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
LOG_TAG="BACKUP"
source "${REPO_ROOT}/jetson_bsp_common.sh"

BOARD=""
BACKUP_DEVICE=""
ZIP_NAME=""
OUTPUT_DIR="${REPO_ROOT}/backups"
DEFAULT_BOARD="jetson-orin-nano-devkit-super-nvme"
DEFAULT_DEVICE="nvme0n1"
IMAGES_DIR=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Creates a Jetson backup using Linux_for_Tegra/tools/backup_restore and
packages the resulting images into a timestamped zip archive under
${OUTPUT_DIR}.

Options:
  --zip-name <file>   Override the generated archive name (adds .zip if missing)
  --board <name>      Set the Jetson board configuration (overrides env)
  --device <dev>      Set the storage device passed with -e (overrides env)
  -h, --help          Show this help

Environment variables:
  BOARD             Target board name (default: ${DEFAULT_BOARD})
  JETSON_BSP_URL    URL used to download the Jetson BSP if Linux_for_Tegra is
                    not present.
  BACKUP_DEVICE     Block device passed to -e (default: ${DEFAULT_DEVICE})
EOF
}

ZIP_NAME_CLI=""
BOARD_CLI=""
DEVICE_CLI=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		--zip-name)
			if [[ -z "${2:-}" ]]; then
				log "Error: --zip-name requires an argument"
				exit 1
			fi
			ZIP_NAME_CLI="$2"
			shift 2
			;;
		--zip-name=*)
			ZIP_NAME_CLI="${1#*=}"
			shift
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
		*)
			log "Unknown option: $1"
			usage
			exit 1
			;;
	esac
done

ZIP_NAME="${ZIP_NAME_CLI:-}"
BOARD="${BOARD_CLI:-${DEFAULT_BOARD}}"
BACKUP_DEVICE="${DEVICE_CLI:-${DEFAULT_DEVICE}}"

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

log "Starting backup for board ${BOARD}"
log "Invoking ./tools/backup_restore/l4t_backup_restore.sh -b -e ${BACKUP_DEVICE} ${BOARD}"
if [[ -n "${SUDO_BIN}" ]]; then
	(
		cd "${L4T_DIR}"
		"${SUDO_BIN}" env LC_ALL=C LANG=C ./tools/backup_restore/l4t_backup_restore.sh -b -e "${BACKUP_DEVICE}" "${BOARD}"
	)
else
	(
		cd "${L4T_DIR}"
		LC_ALL=C LANG=C ./tools/backup_restore/l4t_backup_restore.sh -b -e "${BACKUP_DEVICE}" "${BOARD}"
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
