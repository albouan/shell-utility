#!/usr/bin/env bash

# ==============================================================================
# Script Name:     BackupManager.sh
# Description:     Verify the integrity of backup files across multiple disks
# Target OS:       macOS (Sonoma/Sequoia+) / Raspberry Pi OS (Debian Bookworm+)
# Compatibility:   macOS (Darwin) & Linux (ARM/Debian-based)
# Requirements:    Bash 5.0+
# ==============================================================================

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ] || ((${BASH_VERSION%%.*} < 5)); then
	echo "Error: This script requires bash version 5.0 or higher." >&2
	echo "You are using: $BASH_VERSION" >&2
	exit 1
fi

require() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Error: Missing required command: $1" >&2
		exit 1
	}
}

if [[ "$OSTYPE" == linux* ]]; then
	hash_cmd=(sha256sum)
else
	hash_cmd=(shasum -a 256)
fi

for cmd in find diff rsync perl sort awk "${hash_cmd[0]}"; do
	require "$cmd"
done

readonly SCRIPT_NAME="Backup Manager"
readonly SCRIPT_VERSION="2026.07.29"

readonly FIND_FILTER=(
	! -name '.DS_Store'
	! -name '._*'
	! -name 'Thumbs.db'
	! -name '*~'
)

declare -a DISKS
declare -a PATHS

get_mounted_backup_volumes() {
	local -n result_array=$1
	result_array=()
	local temp_list=()

	if [[ "$OSTYPE" == "darwin"* ]]; then
		if [ -d "/Volumes" ]; then
			local boot_volume
			boot_volume=$(df -P / | awk 'NR==2 {print $6}')

			for vol in /Volumes/*; do
				if [ -d "$vol" ] && [ "$vol" != "$boot_volume" ]; then
					if mount | grep -Fq "on $vol "; then
						temp_list+=("$vol")
					fi
				fi
			done
		fi

	elif [[ "$OSTYPE" == "linux"* ]]; then
		local search_paths=("/media/$USER" "/run/media/$USER" "/mnt")

		for base in "${search_paths[@]}"; do
			if [ -d "$base" ]; then
				for vol in "$base"/*; do
					if [ -d "$vol" ]; then
						if mount | grep -Fq "on $vol "; then
							temp_list+=("$vol")
						fi
					fi
				done
			fi
		done
	fi

	if [ ${#temp_list[@]} -gt 0 ]; then
		# shellcheck disable=SC2034
		mapfile -t result_array < <(printf '%s\n' "${temp_list[@]}" | sort)
	fi
}

get_common_top_level_items() {
	local -n _common_result=$1
	shift

	local paths=("$@")
	_common_result=()

	if [ ${#paths[@]} -eq 0 ]; then
		return 0
	fi

	declare -A item_counts
	local valid_paths=0

	for path in "${paths[@]}"; do
		if [ -d "$path" ]; then
			valid_paths=$((valid_paths + 1))
			declare -A path_items=()

			while IFS= read -r -d '' item; do
				local basename="${item##*/}"
				[ -n "$basename" ] && path_items["$basename"]=1
			done < <(find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

			for item in "${!path_items[@]}"; do
				: "${item_counts["$item"]:=0}"
				item_counts["$item"]=$((item_counts["$item"] + 1))
			done
		fi
	done

	if [ "$valid_paths" -eq 0 ]; then
		return 0
	fi

	local -a intersection_items=()
	for item in "${!item_counts[@]}"; do
		if [ "${item_counts["$item"]}" -eq "$valid_paths" ]; then
			intersection_items+=("$item")
		fi
	done

	if [ ${#intersection_items[@]} -gt 0 ]; then
		mapfile -t _common_result < <(
			printf '%s\n' "${intersection_items[@]}" | sort
		)
	fi
}

remove_dot_items_inplace() {
	local -n arr="$1"
	local output=()
	local item
	for item in "${arr[@]}"; do
		[[ "$item" != .* ]] && output+=("$item")
	done
	arr=("${output[@]}")
}

atomic_refresh_storage() {
	local target="$1"
	local tmp="${target}.refreshing"
	local old="${target}.old"

	if [[ ! -e "$target" ]]; then
		echo "Error: '$target' does not exist." >&2
		return 1
	fi

	rm -rf -- "$tmp" "$old" || return 1

	if [[ -d "$target" ]]; then
		mkdir -- "$tmp" || return 1
		rsync -a --no-owner --no-group --whole-file -- "$target/" "$tmp/" || return 1
	else
		rsync -a --no-owner --no-group --whole-file -- "$target" "$tmp" || return 1
	fi

	sync

	mv -- "$target" "$old" || return 1

	mv -- "$tmp" "$target" || {
		mv -- "$old" "$target"
		return 1
	}

	sync

	rm -rf -- "$old"
}

select_backup() {
	local -n _result=$1
	shift
	local items=("$@")

	if [ ${#items[@]} -eq 0 ]; then
		echo "No items available for selection."
		return 1
	fi

	if [ ${#items[@]} -eq 1 ]; then
		_result="${items[0]}"
		return 0
	fi

	select opt in "${items[@]}"; do
		if [ -n "$opt" ]; then
			_result="$opt"
			return 0
		else
			echo "Invalid selection. Please try again."
		fi
	done
}

verify_backup() {
	local path
	select_backup path "${PATHS[@]}"
	if [ -z "${path:-}" ]; then
		echo "No path selected. Exiting verification."
		return 1
	fi

	printf "\n"

	local tree_diffs=""
	verify_backup_tree_impl tree_diffs "$path" || {
		echo "Error: Failed to verify backup tree for $path" >&2
		return 1
	}

	if [ -z "$tree_diffs" ]; then
		printf "\n✓ Backup trees match. Calculating checksums...\n"

		local start_st
		start_st=$(date +%s)

		local -a pids=()
		local -a tmps=()

		for ((i = 0; i < ${#DISKS[@]}; i++)); do
			tmps[i]="$(mktemp)"
		done

		for ((i = 0; i < ${#DISKS[@]}; i++)); do
			local disk="${DISKS[$i]}"
			calculate_hashes_impl "$disk/$path" "${tmps[$i]}" "$disk" &
			pids+=("$!")
		done

		for ((i = 0; i < ${#pids[@]}; i++)); do
			if ! wait "${pids[$i]}"; then
				for pid in "${pids[@]}"; do
					kill "$pid" 2>/dev/null || true
				done

				echo "Error: Checksum calculation failed in one or more disks." >&2

				rm -f -- "${tmps[@]}" || true

				return 1
			fi
		done

		local hash_diffs=""
		for ((i = 1; i < ${#DISKS[@]}; i++)); do
			local current_diff=""
			current_diff="$(diff "${tmps[0]}" "${tmps[$i]}")" || true
			hash_diffs+="$current_diff"
		done

		rm -f -- "${tmps[@]}" || true

		if [ -z "$hash_diffs" ]; then
			printf "\nBackup verification completed successfully in %d minute(s).\n" "$((($(date +%s) - start_st + 30) / 60))"
			printf "\n\033[1;32m✅ VERIFICATION SUCCESSFUL.\033[0m\n"
		else
			local diff_count=0
			diff_count="$(echo "$hash_diffs" | grep -c '^[<>].*' || true)"
			printf "\n%'d file difference(s) found.\n" "$diff_count"
			printf "\n\033[1;31m❌ VERIFICATION FAILED.\033[0m\n"
		fi
	else
		printf "\n\033[1;31m❌ Discrepancies found in tree comparison(s):\033[0m\n%s\n" "$tree_diffs"
	fi

	printf "\n"
}

calculate_hashes_impl() {
	local start_s
	start_s=$(date +%s)
	local target_path="$1"
	find "$target_path" -type f \( "${FIND_FILTER[@]}" \) -exec "${hash_cmd[@]}" {} + | perl -pe "s|^([a-fA-F0-9]+)\s+[\* ]?\Q$target_path\E(.*)$|\2  \1|" | sort >"$2"
	printf "\nCalculating $3 checksums completed in %d minute(s).\n" "$((($(date +%s) - start_s + 30) / 60))"
}

verify_backup_tree() {
	local path
	select_backup path "${PATHS[@]}"
	if [ -z "${path:-}" ]; then
		echo "No path selected. Exiting tree verification."
		return 1
	fi

	printf "\n"

	local tree_diffs=""
	verify_backup_tree_impl tree_diffs "$path" || {
		echo "Error: Failed to verify backup tree for $path" >&2
		return 1
	}

	if [ -z "$tree_diffs" ]; then
		printf "\n\033[1;32m✅ Success: All backup trees match identically across all disks.\033[0m\n"
	else
		printf "\n\033[1;31m❌ Discrepancies found in comparison(s):\033[0m\n%s\n" "$tree_diffs"
	fi

	printf "\n"
}

verify_backup_tree_impl() {
	local -n _result=$1
	local path="$2"

	declare -a tmps=()
	for ((i = 0; i < ${#DISKS[@]}; i++)); do
		tmps[i]="$(mktemp)"
	done

	for ((i = 0; i < ${#DISKS[@]}; i++)); do
		local disk="${DISKS[$i]}"
		local target_dir="$disk/$path"
		find "$target_dir" -type f \( "${FIND_FILTER[@]}" \) | perl -pe "s|^\Q$target_dir\E||" | sort >"${tmps[$i]}"
		local file_count=0
		local dir_count=0
		file_count=$(wc -l <"${tmps[$i]}" | tr -d ' ')
		dir_count=$(find "$target_dir" -type d | tail -n +2 | wc -l | tr -d ' ')
		printf "Disk %d (%s): %'d file(s), %'d folder(s)\n" "$i" "$disk" "$file_count" "$dir_count"
	done

	local file_tree_diffs=""
	for ((i = 1; i < ${#DISKS[@]}; i++)); do
		local current_diff=""
		current_diff="$(diff "${tmps[0]}" "${tmps[$i]}")" || true
		file_tree_diffs+="$current_diff"
	done

	_result="$file_tree_diffs"

	rm -f -- "${tmps[@]}" || true
}

refresh_backup() {
	local path
	select_backup path "${PATHS[@]}"
	if [ -z "${path:-}" ]; then
		echo "No path selected. Exiting storage refresh."
		return 1
	fi

	local start_st
	start_st=$(date +%s)

	local -a pids=()

	for ((i = 0; i < ${#DISKS[@]}; i++)); do
		local disk="${DISKS[$i]}"
		refresh_storage_impl "$disk/$path" &
		pids+=("$!")
	done

	for ((i = 0; i < ${#pids[@]}; i++)); do
		if ! wait "${pids[$i]}"; then
			for pid in "${pids[@]}"; do
				kill "$pid" 2>/dev/null || true
			done

			echo "Error: Storage refresh failed in one or more disks." >&2
			return 1
		fi
	done

	printf "\n\033[1;32m✅ Success: Refreshing storage contents completed successfully in %d minute(s).\033[0m\n" "$((($(date +%s) - start_st + 30) / 60))"

	printf "\n"
}

refresh_storage_impl() {
	local start_s
	start_s=$(date +%s)
	atomic_refresh_storage "$1" || {
		echo "Error: Failed to refresh storage for $1" >&2
		return 1
	}
	printf "\nRefreshing $1 storage contents completed in %d minute(s).\n" "$((($(date +%s) - start_s + 30) / 60))"
}

print_version() {
	local shname=""
	local shver=""
	if [ -n "${BASH_VERSION:-}" ]; then
		shname="bash"
		shver="v${BASH_VERSION%%-*}"
	elif [ -n "${ZSH_VERSION:-}" ]; then
		shname="zsh"
		shver="v${ZSH_VERSION}"
	else
		shname=$(ps -p $$ -o comm= 2>/dev/null | tail -n 1 | sed 's/^-//' | tr -d '\n')
		if [ -z "$shname" ]; then
			shname="sh"
		fi
		shver=$($shname --version 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i ~ /^[0-9]/){print "v"$i; exit}}' || echo "v?")
	fi
	printf '%s v%s\nRunning on %s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$shname" "$shver"
}

print_version
echo ""

get_mounted_backup_volumes DISKS

echo "--- Disks Found (${#DISKS[@]}) ---"
for path in "${DISKS[@]}"; do
	echo "$path"
done
echo ""

if [ "${#DISKS[@]}" -lt 2 ]; then
	echo "Error: At least two mounted backup volumes are required."
	exit 1
fi

get_common_top_level_items PATHS "${DISKS[@]}"

remove_dot_items_inplace PATHS

if [ "${#PATHS[@]}" -eq 0 ]; then
	echo "Error: No common backup folders found."
	exit 1
fi

echo "--- Common Backups (${#PATHS[@]}) ---"
for path in "${PATHS[@]}"; do
	echo "$path"
done
echo ""

PS3="Please select an option: "
options=("Verify" "Verify Tree" "Refresh" "Exit")

select opt in "${options[@]}"; do
	case $opt in
	"Verify")
		verify_backup || true
		;;
	"Verify Tree")
		verify_backup_tree || true
		;;
	"Refresh")
		refresh_backup || true
		;;
	"Exit")
		printf "\nBye.\n"
		exit 0
		;;
	*)
		printf "Invalid option. Please try again.\n"
		;;
	esac
done
