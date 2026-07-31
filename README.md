# BackupManager.sh

A robust, multi-disk backup verification and maintenance utility designed for **macOS** and **Linux (Debian/Raspberry Pi OS)**. It ensures file integrity across multiple storage volumes by performing fast tree comparisons and deep cryptographic checksum validations.

---

## 🚀 Features

*   **Multi-Disk Integrity Checks:** Automatically detects mounted backup volumes and cross-references files across multiple disks.
*   **Cryptographic Verification:** Uses `sha256sum` (Linux) or `shasum` (macOS) to guarantee data isn't corrupted.
*   **Atomic Storage Refresh:** Safely rewrites or refreshes storage contents using temporary directories and `rsync` to prevent partial-write data corruption if interrupted.
*   **Smart Filtering:** Automatically ignores system noise and temporary metadata files like `.DS_Store`, `._*`, `Thumbs.db`, and backup temp files.
*   **Parallel Processing:** Leverages background jobs for hashing and syncing across separate disks to speed up performance on multi-core systems.

---

## 💡 Interesting Use Cases

*   **(Regular Computers) Peace of Mind via Cryptographic Verification:** Regular file copy confirmations only tell you if a transfer completed, not if the data degraded later. By running deep SHA-256 cross-checks against multiple independent backup disks, you get absolute certainty that your archives are bit-for-bit identical and entirely free of silent corruption.

*   **(Raspberry Pi-Based Systems) Self-Sufficient Backup Management:** Ideal for headless, low-power storage nodes or local backup appliances running on Debian. It lets you manually manage multi-disk integrity and combat bit rot using inexpensive, off-the-shelf USB enclosures and drives without needing complex enterprise software. Note: the script's menus are interactive (`select`-based), so it requires a terminal session and is not currently suited to unattended/cron-driven automation.

---

## ▶️ Usage

```sh
chmod +x BackupManager.sh
./BackupManager.sh
```

The script scans for mounted volumes, finds backup folders common to all of them, then presents a menu:

*   **Verify** — Compares file trees across disks, then computes and cross-checks SHA-256 checksums for every file. Use this for a full integrity audit.
*   **Verify Tree** — Compares file/folder listings across disks only (no checksums). Faster; use this for a quick structural sanity check.
*   **Refresh** — Atomically rewrites the backup contents on all disks (see [Refresh Interruption & Recovery](#-refresh-interruption--recovery)). Prompts for confirmation before making changes. Requires free space equal to the size of the backup, since the new copy is written alongside the original before being swapped in; the operation refuses to start if the volume is too full.
*   **Exit** — Quits the script.

> **Run Verify before Refresh.** Refresh rewrites whatever bits it reads — it does not repair anything. Auditing first means you find any corruption while you still have a known-good copy on another disk to restore from.

---

## 📋 Requirements

*   **Bash:** Version 5.0 or higher
*   **Core Utilities:** `find`, `diff`, `sort`, `awk`, `du`, `df`, `mktemp`, `wc`, `tr`, `grep`, `date`
*   **Additional dependencies (not always preinstalled, especially on minimal/Lite images):**
    *   `rsync` — used for the atomic storage refresh
    *   `perl` — used to normalize file paths during comparison
    *   `shasum` (macOS) or `sha256sum` (Linux) — used for checksum verification

---

### ⚠️ Refresh Interruption & Recovery

The **Refresh** operation rewrites backup contents by rsyncing to a sibling `<path>.refreshing` directory, then swapping it into place via `mv`. If the process is killed or the system loses power during the brief window between the two `mv` calls, `<path>` may momentarily not exist, leaving `<path>.old` (the original) and/or `<path>.refreshing` (the new copy) behind instead.

This is **not silent data loss** — both copies remain on disk — but it does require manual recovery:

1. Check for `<path>.old` and `<path>.refreshing` next to the expected backup path.
2. If `<path>` is missing, restore it from `<path>.old` (the pre-refresh original) with `mv`.
3. Once you've confirmed the recovered path is intact, remove the leftover `.old`/`.refreshing` directory.

Always verify backups with **Verify** or **Verify Tree** after recovering from an interrupted refresh.

---

## ⚠️ Disclaimer

This script performs file and storage operations across multiple disks. It is provided **"as is"** without warranty of any kind. 

You use **BackupManager.sh** entirely at your own risk. Always maintain independent backups of your critical data before running synchronization, refresh, or maintenance routines. The author accepts no liability for any data loss, corruption, or system issues.