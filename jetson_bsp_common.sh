#!/usr/bin/env bash

# Internal helper library shared by Jetson backup/restore utility scripts.
# Requires the caller to define REPO_ROOT before sourcing.

if [[ -z "${REPO_ROOT:-}" ]]; then
	echo "REPO_ROOT must be set before sourcing jetson_bsp_common.sh" >&2
	exit 1
fi

if [[ -n "${_JETSON_BSP_COMMON_SOURCED:-}" ]]; then
	return
fi
readonly _JETSON_BSP_COMMON_SOURCED=1

LOG_TAG="${LOG_TAG:-JETSON}"
L4T_DIR="${L4T_DIR:-${REPO_ROOT}/Linux_for_Tegra}"
L4T_BACKUP_SCRIPT="${L4T_DIR}/tools/backup_restore/l4t_backup_restore.sh"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-${REPO_ROOT}/downloads}"
DEFAULT_JETSON_BSP_URL="https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Jetson_Linux_r36.4.4_aarch64.tbz2"
DEFAULT_JETSON_ROOTFS_URL="https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Tegra_Linux_Sample-Root-Filesystem_r36.4.4_aarch64.tbz2"
APT_UPDATED=0
APPLY_BINARIES_MARKER=".binaries_applied"

declare -A COMMAND_PACKAGE_MAP=(
	[zip]=zip
	[unzip]=unzip
	[sha256sum]=coreutils
	[wget]=wget
	[tar]=tar
	[sshpass]=sshpass
	[zstd]=zstd
	[abootimg]=abootimg
	[exportfs]=nfs-kernel-server
	[rpcbind]=nfs-common
)

log() {
	local ts
	ts="$(date +%H:%M:%S)"
	printf '[%s][%s] %s\n' "${ts}" "${LOG_TAG}" "$*" >&2
}

require_command() {
	local cmd="$1"
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		log "Missing required command: ${cmd}"
		exit 1
	fi
}

ensure_packages() {
	local missing=()
	for cmd in "$@"; do
		if ! command -v "${cmd}" >/dev/null 2>&1; then
			missing+=("${cmd}")
		fi
	done

	if [[ "${#missing[@]}" -eq 0 ]]; then
		return
	fi

	if ! command -v apt-get >/dev/null 2>&1; then
		log "Missing commands: ${missing[*]}. Please install the appropriate packages manually (apt-get not available)."
		exit 1
	fi

	local packages=()
	local seen=""
	for cmd in "${missing[@]}"; do
		local pkg="${COMMAND_PACKAGE_MAP[$cmd]:-$cmd}"
		if [[ " ${seen} " != *" ${pkg} "* ]]; then
			seen+=" ${pkg}"
			packages+=("${pkg}")
		fi
		log "Installing package '${pkg}' to provide '${cmd}'"
	done

	local sudo_bin
	sudo_bin="$(needsudo)"
	if [[ "${APT_UPDATED}" -eq 0 ]]; then
		if [[ -n "${sudo_bin}" ]]; then
			${sudo_bin} apt-get update
		else
			apt-get update
		fi
		APT_UPDATED=1
	fi
	if [[ -n "${sudo_bin}" ]]; then
		${sudo_bin} apt-get install -y --no-install-recommends "${packages[@]}"
	else
		apt-get install -y --no-install-recommends "${packages[@]}"
	fi
}

ensure_host_dependencies() {
	ensure_packages zip unzip sha256sum wget tar sshpass zstd abootimg exportfs rpcbind
}

resolve_l4t_dir() {
	if [[ -x "${L4T_BACKUP_SCRIPT}" ]]; then
		return
	fi

	local candidates=(
		"${L4T_DIR}"
		"${REPO_ROOT}"
		"${REPO_ROOT}/Linux_for_Tegra"
		"${REPO_ROOT}/../Linux_for_Tegra"
	)

	for candidate in "${candidates[@]}"; do
		if [[ -x "${candidate}/tools/backup_restore/l4t_backup_restore.sh" ]]; then
			L4T_DIR="${candidate}"
			L4T_BACKUP_SCRIPT="${candidate}/tools/backup_restore/l4t_backup_restore.sh"
			return
		fi
	done
}

needsudo() {
	if [[ "$(id -u)" -ne 0 ]]; then
		echo "sudo"
	else
		echo ""
	fi
}

download_rootfs() {
	local url="${JETSON_ROOTFS_URL:-${DEFAULT_JETSON_ROOTFS_URL}}"
	if [[ -z "${JETSON_ROOTFS_URL:-}" ]]; then
		log "JETSON_ROOTFS_URL not set; defaulting to ${DEFAULT_JETSON_ROOTFS_URL}"
	fi

	mkdir -p "${DOWNLOADS_DIR}"
	local filename="${DOWNLOADS_DIR}/${url##*/}"

	require_command wget
	require_command tar

	if [[ ! -f "${filename}" ]]; then
		log "Downloading Jetson sample root filesystem from ${url}"
		wget --progress=dot:giga -O "${filename}" "${url}"
	else
		log "Reusing downloaded rootfs archive ${filename}"
	fi

	local sudo_bin
	sudo_bin="$(needsudo)"
	mkdir -p "${L4T_DIR}/rootfs"

	if [[ -n "${sudo_bin}" ]]; then
		log "Extracting rootfs to ${L4T_DIR}/rootfs (requires sudo)"
		${sudo_bin} tar --same-owner --xattrs --numeric-owner -xpf "${filename}" -C "${L4T_DIR}/rootfs"
	else
		log "Extracting rootfs to ${L4T_DIR}/rootfs"
		tar --same-owner --xattrs --numeric-owner -xpf "${filename}" -C "${L4T_DIR}/rootfs"
	fi
}

ensure_rootfs() {
	if [[ -d "${L4T_DIR}/rootfs/bin" ]]; then
		return
	fi
	log "Linux_for_Tegra/rootfs missing or incomplete; downloading sample root filesystem."
	download_rootfs
}

apply_bsp_binaries() {
	if [[ "${SKIP_APPLY_BINARIES:-0}" == "1" ]]; then
		log "Skipping apply_binaries.sh because SKIP_APPLY_BINARIES=1"
		return
	fi

	if [[ ! -x "${L4T_DIR}/apply_binaries.sh" ]]; then
		log "apply_binaries.sh not found in ${L4T_DIR}; cannot apply BSP binaries."
		return
	fi

	local marker="${L4T_DIR}/${APPLY_BINARIES_MARKER}"
	if [[ -f "${marker}" ]]; then
		return
	fi
	if [[ -f "${L4T_DIR}/rootfs/etc/nv_tegra_release" ]]; then
		log "apply_binaries.sh appears to have been run already (nv_tegra_release present)."
		touch "${marker}"
		return
	fi

	log "Running apply_binaries.sh to populate rootfs with BSP binaries."
	local sudo_bin
	sudo_bin="$(needsudo)"
	local rc=0
	if [[ -n "${sudo_bin}" ]]; then
		(
			cd "${L4T_DIR}" && \
			${sudo_bin} ./apply_binaries.sh
		)
		rc=$?
	else
		(
			cd "${L4T_DIR}" && \
			./apply_binaries.sh
		)
		rc=$?
	fi

	if [[ ${rc} -ne 0 ]]; then
		log "apply_binaries.sh failed; check logs above."
		exit 1
	fi

	touch "${marker}"
}

download_bsp() {
	local url="${JETSON_BSP_URL:-${DEFAULT_JETSON_BSP_URL}}"
	if [[ -z "${JETSON_BSP_URL:-}" ]]; then
		log "JETSON_BSP_URL not set; defaulting to ${DEFAULT_JETSON_BSP_URL}"
	fi

	mkdir -p "${DOWNLOADS_DIR}"
	local filename="${DOWNLOADS_DIR}/${url##*/}"

	require_command wget
	require_command tar

	if [[ ! -f "${filename}" ]]; then
		log "Downloading Jetson BSP from ${url}"
		wget --progress=dot:giga -O "${filename}" "${url}"
	else
		log "Reusing downloaded BSP archive ${filename}"
	fi

	pushd "${REPO_ROOT}" >/dev/null
	case "${filename}" in
		*.tbz2|*.tar.bz2)
			log "Extracting ${filename}"
			tar -xjf "${filename}"
			;;
		*.tar.gz|*.tgz)
			log "Extracting ${filename}"
			tar -xzf "${filename}"
			;;
		*.run)
			log "Extracting ${filename}"
			chmod +x "${filename}"
			local target_dir="${DOWNLOADS_DIR}/bsp_extract"
			mkdir -p "${target_dir}"
			"${filename}" --noexec --target "${target_dir}"
			if [[ -f "${target_dir}/Linux_for_Tegra.tbz2" ]]; then
				tar -xjf "${target_dir}/Linux_for_Tegra.tbz2"
			else
				log "Unable to locate Linux_for_Tegra.tbz2 inside extracted runfile"
				exit 1
			fi
			;;
		*)
			log "Unsupported BSP package format: ${filename}"
			exit 1
			;;
	esac
	popd >/dev/null
}

ensure_l4t() {
	resolve_l4t_dir
	if [[ -x "${L4T_BACKUP_SCRIPT}" ]]; then
		ensure_rootfs
		apply_bsp_binaries
		return
	fi

	log "Linux_for_Tegra not found locally; attempting to download BSP."
	download_bsp

	resolve_l4t_dir
	if [[ ! -x "${L4T_BACKUP_SCRIPT}" ]]; then
		log "Linux_for_Tegra still missing after download attempt."
		exit 1
	fi
	ensure_rootfs
	apply_bsp_binaries
}
