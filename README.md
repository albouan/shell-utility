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

*   **(Raspberry Pi-Based Systems) Self-Sufficient Backup Management:** Ideal for headless, low-power storage nodes or local backup appliances running on Debian. It allows you to manually or automatically manage multi-disk integrity and combat bit rot using inexpensive, off-the-shelf USB enclosures and drives without needing complex enterprise software.

---

## 📋 Requirements

*   **Bash:** Version 5.0 or higher
*   **Core Utilities:** `find`, `diff`, `rsync`, `perl`, `sort`, `awk`, and `sha256sum`/`shasum`

---

## ⚠️ Disclaimer

This script performs file and storage operations across multiple disks. It is provided **"as is"** without warranty of any kind. 

You use **BackupManager.sh** entirely at your own risk. Always maintain independent backups of your critical data before running synchronization, refresh, or maintenance routines. The author accepts no liability for any data loss, corruption, or system issues.