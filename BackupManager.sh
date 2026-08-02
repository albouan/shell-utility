#!/usr/bin/env bash

# ==============================================================================
# Script Name:     BackupManager.sh
# Description:     Verify the integrity of backup files across multiple disks
# Target OS:       macOS (Sonoma/Sequoia+) / Raspberry Pi OS (Debian Bookworm+)
# Compatibility:   macOS (Darwin) & Linux (ARM/Debian-based)
# Requirements:    Bash 5.0+, GNU rsync
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

for cmd in find diff rsync perl sort awk du df mktemp wc tr grep date "${hash_cmd[0]}"; do
	require "$cmd"
done

rsync_version_output="$(rsync --version 2>&1 || true)"
if ! [[ "$rsync_version_output" =~ ^rsync[[:space:]]+version[[:space:]] ]]; then
	echo "Error: This script requires GNU rsync; openrsync/BSD rsync is not supported." >&2
	echo "Detected: $(printf '%s' "$rsync_version_output" | head -n1)" >&2
	if [[ "$OSTYPE" == "darwin"* ]]; then
		echo "On macOS, install it with: brew install rsync (keep it ahead of /usr/bin/rsync in PATH)." >&2
	fi
	exit 1
fi
unset rsync_version_output

declare -a RSYNC_META=()
RSYNC_META_WARNING=""

rsync_help="$(rsync --help 2>&1 || true)"
if [[ "$rsync_help" == *--xattrs* ]]; then
	RSYNC_META=(--xattrs)
	[[ "$rsync_help" == *--acls* ]] && RSYNC_META+=(--acls)
else
	RSYNC_META_WARNING="Warning: this rsync build supports neither --xattrs nor --acls."$'\n'"Refresh will discard extended attributes, Finder tags, and ACLs."
fi
[[ "$rsync_help" == *--crtimes* ]] && RSYNC_META+=(--crtimes)
[[ "$rsync_help" == *--fileflags* ]] && RSYNC_META+=(--fileflags)
if [[ "$OSTYPE" == "darwin"* && "$rsync_help" != *--crtimes* ]]; then
	[ -n "$RSYNC_META_WARNING" ] && RSYNC_META_WARNING+=$'\n'
	RSYNC_META_WARNING+="Warning: this rsync build lacks --crtimes; refresh will not preserve creation dates."
fi
unset rsync_help

readonly RSYNC_META_WARNING

readonly SCRIPT_NAME="Backup Manager"
readonly SCRIPT_VERSION="26.8"

readonly FIND_FILTER=(
	! -name '.DS_Store'
	! -name '._*'
	! -name 'Thumbs.db'
	! -name '*~'
)

declare -a DISKS
declare -a PATHS
declare -a TEMP_FILES=()
declare -A LEFTOVER_NAMES=()
declare -a RUNNING_PIDS=()
INTERRUPT_NOTE=""

cleanup_temp_files() {
	if [ ${#TEMP_FILES[@]} -gt 0 ]; then
		rm -f -- "${TEMP_FILES[@]}" 2>/dev/null || true
	fi
}

trap cleanup_temp_files EXIT

terminate_jobs() {
	local pid
	for pid in "$@"; do
		kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}

on_interrupt() {
	local sig="$1" signum="$2"

	trap - INT TERM

	printf "\n\033[1;33m⚠ Interrupted (SIG%s); stopping jobs on all disks...\033[0m\n" "$sig" >&2

	if [ ${#RUNNING_PIDS[@]} -gt 0 ]; then
		terminate_jobs "${RUNNING_PIDS[@]}"
		RUNNING_PIDS=()
	fi

	if [ -n "$INTERRUPT_NOTE" ]; then
		printf '%s\n' "$INTERRUPT_NOTE" >&2
	fi

	exit $((128 + signum))
}

arm_interrupt_trap() {
	INTERRUPT_NOTE="${1:-}"
	RUNNING_PIDS=()
	trap 'on_interrupt INT 2' INT
	trap 'on_interrupt TERM 15' TERM
}

disarm_interrupt_trap() {
	trap - INT TERM
	RUNNING_PIDS=()
	INTERRUPT_NOTE=""
}

format_duration() {
	local secs="$1"
	if [ "$secs" -lt 60 ]; then
		printf '%d second(s)' "$secs"
	else
		printf "%'d minute(s)" "$(((secs + 30) / 60))"
	fi
}

strip_prefix_for() {
	local target="$1"
	if [ -d "$target" ]; then
		printf '%s' "$target"
	else
		printf '%s' "${target%/*}"
	fi
}

is_mount_point() {
	local dir="$1" dev parent_dev
	dev=$(df -P "$dir" 2>/dev/null | awk 'NR==2 {print $1}') || return 1
	parent_dev=$(df -P "$dir/.." 2>/dev/null | awk 'NR==2 {print $1}') || return 1
	[ -n "$dev" ] && [ "$dev" != "$parent_dev" ]
}

get_mounted_backup_volumes() {
	local -n _result_array=$1
	_result_array=()
	local temp_list=()

	if [[ "$OSTYPE" == "darwin"* ]]; then
		if [ -d "/Volumes" ]; then
			local boot_volume
			boot_volume=$(df -P / | awk 'NR==2 {print $1}')

			local vol
			for vol in /Volumes/*; do
				if [ -d "$vol" ]; then
					local vol_device
					vol_device=$(df -P "$vol" | awk 'NR==2 {print $1}')
					if [ "$vol_device" != "$boot_volume" ] && is_mount_point "$vol"; then
						temp_list+=("$vol")
					fi
				fi
			done
		fi

	elif [[ "$OSTYPE" == "linux"* ]]; then
		local search_paths=("/media/$USER" "/run/media/$USER" "/mnt")

		local base
		for base in "${search_paths[@]}"; do
			if [ -d "$base" ]; then
				for vol in "$base"/*; do
					if [ -d "$vol" ]; then
						if is_mount_point "$vol"; then
							temp_list+=("$vol")
						fi
					fi
				done
			fi
		done
	fi

	if [ ${#temp_list[@]} -gt 0 ]; then
		mapfile -t _result_array < <(printf '%s\n' "${temp_list[@]}" | sort)
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

	local path
	for path in "${paths[@]}"; do
		if [ -d "$path" ]; then
			valid_paths=$((valid_paths + 1))
			declare -A path_items=()

			while IFS= read -r -d '' item; do
				local basename="${item##*/}"
				[ -n "$basename" ] && path_items["$basename"]=1
			done < <(find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

			local item
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
		mapfile -t _common_result < <(printf '%s\n' "${intersection_items[@]}" | sort)
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

path_state() {
	if [ -e "$1" ]; then printf '%s' "$2"; else printf '%s' "$3"; fi
}

suggest_refresh_recovery() {
	local base="$1"
	local has_old=0 has_new=0

	[ -e "$base.old" ] && has_old=1
	[ -e "$base.refreshing" ] && has_new=1

	if [ -e "$base" ]; then
		if [ "$has_old" -eq 1 ] && [ "$has_new" -eq 1 ]; then
			printf "Ambiguous. Verify '%s' first, then remove whichever leftovers it makes redundant." "$base"
		elif [ "$has_old" -eq 1 ]; then
			printf "Refresh completed; verify '%s', then: rm -rf %q" "$base" "$base.old"
		else
			printf "Refresh died before the swap; '%s' is the untouched original, then: rm -rf %q" "$base" "$base.refreshing"
		fi
	else
		if [ "$has_old" -eq 1 ]; then
			printf "Restore the pre-refresh original: mv %q %q" "$base.old" "$base"
		else
			printf "Only the new copy survives; inspect it, then: mv %q %q" "$base.refreshing" "$base"
		fi
	fi
}

print_refresh_leftover_report() {
	local base
	for base in "$@"; do
		printf "\n  %s\n" "$base"
		printf "    %-14s %s\n" "itself:" "$(path_state "$base" "present" "MISSING")"
		printf "    %-14s %s\n" ".old:" "$(path_state "$base.old" "present" "absent")"
		printf "    %-14s %s\n" ".refreshing:" "$(path_state "$base.refreshing" "present" "absent")"
		printf "    → %s\n" "$(suggest_refresh_recovery "$base")"
	done
}

scan_interrupted_refreshes() {
	local -A bases=()
	local disk item suffix base

	for disk in "${DISKS[@]}"; do
		for item in "$disk"/*.refreshing "$disk"/*.old; do
			[ -e "$item" ] || continue

			case "$item" in
			*.refreshing) suffix=".refreshing" ;;
			*) suffix=".old" ;;
			esac

			base="${item%"$suffix"}"
			bases["$base"]=1
			LEFTOVER_NAMES["${item##*/}"]=1
			LEFTOVER_NAMES["${base##*/}"]=1
		done
	done

	if [ ${#bases[@]} -eq 0 ]; then
		return 0
	fi

	local -a sorted_bases=()
	mapfile -t sorted_bases < <(printf '%s\n' "${!bases[@]}" | sort)

	printf "\033[1;33m⚠ Possible interrupted refresh: %d path(s) with leftover copies.\033[0m\n" "${#sorted_bases[@]}"
	printf "These may be recovery copies from an interrupted refresh, or unrelated paths.\n"
	printf "They are withheld from the backup menu until resolved.\n"

	print_refresh_leftover_report "${sorted_bases[@]}"

	printf "\nInspect before acting. Run Verify or Verify Tree afterwards to confirm the result.\n\n"
}

remove_leftover_items_inplace() {
	local -n _items="$1"
	local output=()
	local item
	for item in "${_items[@]}"; do
		[ -n "${LEFTOVER_NAMES["$item"]:-}" ] || output+=("$item")
	done
	_items=("${output[@]}")
}

atomic_refresh_storage() {
	local target="$1"
	local tmp="${target}.refreshing"
	local old="${target}.old"

	if [[ -e "$tmp" || -e "$old" ]]; then
		echo "Error: Leftover '$tmp' and/or '$old' found next to '$target'." >&2
		echo "This may be a recovery copy from an interrupted refresh, or an unrelated path." >&2
		print_refresh_leftover_report "$target" >&2
		return 1
	fi

	if [[ ! -e "$target" ]]; then
		echo "Error: '$target' does not exist." >&2
		return 1
	fi

	local need_kb avail_kb
	need_kb=$(du -sk -- "$target" 2>/dev/null | awk 'END {print $1}') || need_kb=""
	avail_kb=$(df -Pk -- "${target%/*}" 2>/dev/null | awk 'NR==2 {print $4}') || avail_kb=""
	if [[ -n "$need_kb" && -n "$avail_kb" ]] && ((avail_kb < need_kb)); then
		printf "Error: '%s' needs ~%'d KB free, but only %'d KB is available.\n" "$target" "$need_kb" "$avail_kb" >&2
		return 1
	fi

	if [[ -d "$target" ]]; then
		mkdir -- "$tmp" || return 1
		rsync -a "${RSYNC_META[@]}" --no-owner --no-group --whole-file -- "$target/" "$tmp/" || return 1
	else
		rsync -a "${RSYNC_META[@]}" --no-owner --no-group --whole-file -- "$target" "$tmp" || return 1
	fi

	sync

	trap '' INT TERM

	mv -- "$target" "$old" || {
		trap - INT TERM
		return 1
	}

	mv -- "$tmp" "$target" || {
		mv -- "$old" "$target"
		trap - INT TERM
		return 1
	}

	trap - INT TERM

	sync

	if ! rm -rf -- "$old"; then
		echo "Warning: refresh of '$target' succeeded, but removing old copy '$old' failed; remove it manually." >&2
	fi
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

	local PS3="Please select a backup: "

	select opt in "${items[@]}"; do
		if [ -n "$opt" ]; then
			_result="$opt"
			return 0
		else
			echo "Invalid selection. Please try again."
		fi
	done
}

report_hash_mismatches() {
	local cand_file="$1"
	shift

	awk -v nd="$#" '
		FNR == 1 { fidx++ }
		fidx == 1 { cand[$0] = 1; next }
		{
			hash = $NF
			rel = substr($0, 1, length($0) - length(hash) - 2)
			if (rel in cand) {
				h[rel, fidx - 2] = hash
				seen[rel] = 1
			}
		}
		END {
			for (rel in seen) {
				split("", val)
				split("", cnt)
				for (d = 0; d < nd; d++) {
					val[d] = ((rel SUBSEP d) in h) ? h[rel, d] : "MISSING"
					cnt[val[d]]++
				}

				best = ""; bestn = 0; tie = 0
				for (v in cnt) {
					if (cnt[v] > bestn) { bestn = cnt[v]; best = v; tie = 0 }
					else if (cnt[v] == bestn) { tie = 1 }
				}

				line = rel
				bad = ""
				for (d = 0; d < nd; d++) {
					line = line sprintf("  disk%d=%s", d,
						(val[d] == "MISSING") ? "MISSING" : substr(val[d], 1, 10))
					if (!tie && val[d] != best) {
						bad = bad (bad == "" ? "" : ",") sprintf("disk%d", d)
					}
				}

				if (tie) verdict = "no majority - cannot tell which disk is wrong"
				else verdict = "suspect: " bad

				printf "%s  [%s]\n", line, verdict
			}
		}
	' "$cand_file" "$@" | sort
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

		local -a tmps=()

		local i

		for ((i = 0; i < ${#DISKS[@]}; i++)); do
			tmps[i]="$(mktemp)"
			TEMP_FILES+=("${tmps[i]}")
		done

		arm_interrupt_trap

		set -m
		for ((i = 0; i < ${#DISKS[@]}; i++)); do
			local disk="${DISKS[$i]}"
			calculate_hashes_impl "$disk/$path" "${tmps[$i]}" "$disk" </dev/null &
			RUNNING_PIDS+=("$!")
		done
		set +m

		for ((i = 0; i < ${#RUNNING_PIDS[@]}; i++)); do
			if ! wait "${RUNNING_PIDS[$i]}"; then
				terminate_jobs "${RUNNING_PIDS[@]}"
				disarm_interrupt_trap

				echo "Error: Checksum calculation failed in one or more disks." >&2

				rm -f -- "${tmps[@]}" || true

				return 1
			fi
		done

		disarm_interrupt_trap

		for ((i = 0; i < ${#DISKS[@]}; i++)); do
			if [ ! -s "${tmps[$i]}" ]; then
				echo "Error: Checksum list for ${DISKS[$i]} is empty; refusing to report success." >&2
				rm -f -- "${tmps[@]}" || true
				return 1
			fi
		done

		local hash_diffs=""
		local -A affected_files=()

		for ((i = 1; i < ${#DISKS[@]}; i++)); do
			local current_diff=""
			current_diff="$(diff "${tmps[0]}" "${tmps[$i]}")" || true
			if [ -n "$current_diff" ]; then
				[ -n "$hash_diffs" ] && hash_diffs+=$'\n'
				hash_diffs+="$current_diff"

				local line rel
				while IFS= read -r line; do
					case "$line" in
					'< '* | '> '*) ;;
					*) continue ;;
					esac
					rel="${line:2}"
					rel="${rel%  *}"
					[ -n "$rel" ] || continue
					affected_files["$rel"]=1
				done <<<"$current_diff"
			fi
		done

		if [ -z "$hash_diffs" ]; then
			rm -f -- "${tmps[@]}" || true

			printf "\nBackup verification completed successfully in %s.\n" "$(format_duration "$(($(date +%s) - start_st))")"
			printf "\n\033[1;32m✅ VERIFICATION SUCCESSFUL.\033[0m\n"
		else
			printf "\n\033[1;31m❌ Discrepancies found in checksum comparison(s):\033[0m\n\n"

			if [ ${#affected_files[@]} -gt 0 ]; then
				for ((i = 0; i < ${#DISKS[@]}; i++)); do
					printf "  disk%d = %s\n" "$i" "${DISKS[$i]}"
				done
				printf "\n"

				local cand_file
				cand_file="$(mktemp)"
				TEMP_FILES+=("$cand_file")
				printf '%s\n' "${!affected_files[@]}" >"$cand_file"

				report_hash_mismatches "$cand_file" "${tmps[@]}"

				rm -f -- "$cand_file" || true

				printf "\n%'d file(s) affected by checksum mismatches or missing copies.\n" "${#affected_files[@]}"
			else
				printf '%s\n' "$hash_diffs"
			fi

			rm -f -- "${tmps[@]}" || true

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

	local strip_prefix
	strip_prefix="$(strip_prefix_for "$target_path")"

	if ! find "$target_path" -type f \( "${FIND_FILTER[@]}" \) -exec "${hash_cmd[@]}" {} + |
		BM_TARGET="$strip_prefix" perl -pe 's|^([a-fA-F0-9]+)\s+[\* ]?\Q$ENV{BM_TARGET}\E(.*)$|$2  $1|' |
		sort >"$2"; then
		echo "Error: Failed to calculate checksums for '$target_path'." >&2
		return 1
	fi

	if grep -qv '^/' "$2"; then
		echo "Error: Unexpected checksum line for '$target_path' (filename with an embedded newline?)." >&2
		return 1
	fi

	printf "\nCalculating %s checksums completed in %s.\n" "$3" "$(format_duration "$(($(date +%s) - start_s))")"
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
	declare -a dir_tmps=()

	local i

	for ((i = 0; i < ${#DISKS[@]}; i++)); do
		tmps[i]="$(mktemp)"
		TEMP_FILES+=("${tmps[i]}")
		dir_tmps[i]="$(mktemp)"
		TEMP_FILES+=("${dir_tmps[i]}")
	done

	local total_files=0

	for ((i = 0; i < ${#DISKS[@]}; i++)); do
		local disk="${DISKS[$i]}"
		local target_dir="$disk/$path"

		local strip_prefix
		strip_prefix="$(strip_prefix_for "$target_dir")"

		if ! find "$target_dir" -type f \( "${FIND_FILTER[@]}" \) |
			BM_TARGET="$strip_prefix" perl -pe 's|^\Q$ENV{BM_TARGET}\E||' |
			sort >"${tmps[$i]}"; then
			echo "Error: Failed to list files under '$target_dir'." >&2
			rm -f -- "${tmps[@]}" "${dir_tmps[@]}" || true
			return 1
		fi

		if ! find "$target_dir" -mindepth 1 -type d \( "${FIND_FILTER[@]}" \) |
			BM_TARGET="$strip_prefix" perl -pe 's|^\Q$ENV{BM_TARGET}\E||' |
			sort >"${dir_tmps[$i]}"; then
			echo "Error: Failed to list folders under '$target_dir'." >&2
			rm -f -- "${tmps[@]}" "${dir_tmps[@]}" || true
			return 1
		fi

		if grep -qv '^/' "${tmps[$i]}" || grep -qv '^/' "${dir_tmps[$i]}"; then
			echo "Error: Unexpected entry listing '$target_dir' (filename with an embedded newline?)." >&2
			rm -f -- "${tmps[@]}" "${dir_tmps[@]}" || true
			return 1
		fi

		local file_count=0
		local dir_count=0
		file_count=$(wc -l <"${tmps[$i]}" | tr -d ' ')
		dir_count=$(wc -l <"${dir_tmps[$i]}" | tr -d ' ')

		total_files=$((total_files + file_count))
		printf "Disk %d (%s): %'d file(s), %'d folder(s)\n" "$i" "$disk" "$file_count" "$dir_count"
	done

	if [ "$total_files" -eq 0 ]; then
		echo "Error: No files found under '$path' on any disk; nothing to verify." >&2
		rm -f -- "${tmps[@]}" "${dir_tmps[@]}" || true
		return 1
	fi

	local file_diffs=""
	for ((i = 1; i < ${#DISKS[@]}; i++)); do
		local current_diff=""

		current_diff="$(diff "${tmps[0]}" "${tmps[$i]}")" || true
		if [ -n "$current_diff" ]; then
			[ -n "$file_diffs" ] && file_diffs+=$'\n'
			file_diffs+="Disk 0 vs Disk $i (file(s)):"$'\n'"$current_diff"
		fi

		current_diff="$(diff "${dir_tmps[0]}" "${dir_tmps[$i]}")" || true
		if [ -n "$current_diff" ]; then
			[ -n "$file_diffs" ] && file_diffs+=$'\n'
			file_diffs+="Disk 0 vs Disk $i (folder(s)):"$'\n'"$current_diff"
		fi
	done

	_result="$file_diffs"

	rm -f -- "${tmps[@]}" "${dir_tmps[@]}" || true
}

refresh_backup() {
	local path
	select_backup path "${PATHS[@]}"
	if [ -z "${path:-}" ]; then
		echo "No path selected. Exiting storage refresh."
		return 1
	fi

	if [ -n "$RSYNC_META_WARNING" ]; then
		printf "\n\033[1;33m%s\033[0m\n" "$RSYNC_META_WARNING" >&2
	fi

	local confirm
	read -r -p "This will rewrite backup contents for '$path' on all disks. Continue? [y/N] " confirm
	case "$confirm" in
	[yY] | [yY][eE][sS]) ;;
	*)
		echo "Refresh cancelled."
		return 1
		;;
	esac

	local start_st
	start_st=$(date +%s)

	local i

	arm_interrupt_trap "Refresh stopped part-way. Disks may hold leftover '.refreshing' or '.old' copies; re-run this script for the recovery report."

	set -m
	for ((i = 0; i < ${#DISKS[@]}; i++)); do
		local disk="${DISKS[$i]}"
		refresh_storage_impl "$disk/$path" </dev/null &
		RUNNING_PIDS+=("$!")
	done
	set +m

	for ((i = 0; i < ${#RUNNING_PIDS[@]}; i++)); do
		if ! wait "${RUNNING_PIDS[$i]}"; then
			terminate_jobs "${RUNNING_PIDS[@]}"
			disarm_interrupt_trap

			echo "Error: Storage refresh failed in one or more disks." >&2
			return 1
		fi
	done

	disarm_interrupt_trap

	printf "\n\033[1;32m✅ Success: Refreshing storage contents completed successfully in %s.\033[0m\n" "$(format_duration "$(($(date +%s) - start_st))")"

	printf "\n"
}

refresh_storage_impl() {
	local start_s
	start_s=$(date +%s)
	atomic_refresh_storage "$1" || {
		echo "Error: Failed to refresh storage for $1" >&2
		return 1
	}
	printf "\nRefreshing %s storage contents completed in %s.\n" "$1" "$(format_duration "$(($(date +%s) - start_s))")"
}

printf '%s version %s\nRunning on bash version %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "${BASH_VERSION%%-*}"
printf '\n'

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

scan_interrupted_refreshes

get_common_top_level_items PATHS "${DISKS[@]}"

remove_dot_items_inplace PATHS
remove_leftover_items_inplace PATHS

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
	case "$opt" in
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
