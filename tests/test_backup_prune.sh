#!/bin/bash
# =============================================================================
# Unit test: cleanup_old_backups retention
# =============================================================================
# Needs no Docker and no server. Each case lays out a backup directory with
# backdated files and asks valheim-backup to prune it.
#
# Guards #4: the BACKUPS_MAX_AGE find combined two -name tests with -o and no
# parentheses, so the age test and the action bound only to the .tar.gz branch.
# The default format is .zip (BACKUPS_ZIP=true), so by default age pruning
# removed nothing and the backup directory grew until the disk filled.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

BACKUP_DIR=""

# Lay out a backup directory: two backups of each format, one stale, one fresh,
# plus a file that does not belong to us.
setup_backups() {
    BACKUP_DIR="${WORK}/backups"
    rm -rf "${BACKUP_DIR}"; mkdir -p "${BACKUP_DIR}"
    touch -d '10 days ago' "${BACKUP_DIR}/valheim_stale.zip"
    touch -d '10 days ago' "${BACKUP_DIR}/valheim_stale.tar.gz"
    touch "${BACKUP_DIR}/valheim_fresh.zip"
    touch "${BACKUP_DIR}/valheim_fresh.tar.gz"
    touch -d '10 days ago' "${BACKUP_DIR}/somebody_elses.zip"
}

# prune <max_age> <max_count>
prune() {
    (
        export BACKUPS_DIRECTORY="${BACKUP_DIR}"
        export VALHEIM_SCRIPTS_PATH="${REPO_ROOT}/scripts"
        export BACKUPS_MAX_AGE="$1"
        export BACKUPS_MAX_COUNT="$2"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/scripts/valheim-backup"
        cleanup_old_backups
    ) > /dev/null 2>&1
}

gone()   { [[ ! -e "${BACKUP_DIR}/$1" ]]; }
kept()   { [[ -e "${BACKUP_DIR}/$1" ]]; }

check() { # check <predicate> <file> <description>
    if "$1" "$2"; then pass "$3"; else fail "$3"; fi
}

# --- age pruning: the bug this test exists for ----------------------------
setup_backups
prune 3 0

check gone valheim_stale.zip    "a stale .zip is removed by age (the default format)"
check gone valheim_stale.tar.gz "a stale .tar.gz is removed by age"
check kept valheim_fresh.zip    "a fresh .zip is kept"
check kept valheim_fresh.tar.gz "a fresh .tar.gz is kept"
check kept somebody_elses.zip   "a stale file that is not one of our backups is left alone"

# --- age pruning disabled -------------------------------------------------
setup_backups
prune 0 0
check kept valheim_stale.zip    "BACKUPS_MAX_AGE=0 disables age pruning"

# --- count pruning still works (regression guard) -------------------------
# Five backups, keep two: the three oldest go, whatever their extension.
BACKUP_DIR="${WORK}/backups"
rm -rf "${BACKUP_DIR}"; mkdir -p "${BACKUP_DIR}"
touch -d '5 hours ago' "${BACKUP_DIR}/valheim_a.zip"
touch -d '4 hours ago' "${BACKUP_DIR}/valheim_b.tar.gz"
touch -d '3 hours ago' "${BACKUP_DIR}/valheim_c.zip"
touch -d '2 hours ago' "${BACKUP_DIR}/valheim_d.zip"
touch -d '1 hour ago'  "${BACKUP_DIR}/valheim_e.zip"
prune 0 2

remaining="$(find "${BACKUP_DIR}" -maxdepth 1 -type f | wc -l)"
if [[ "${remaining}" == "2" ]]; then
    pass "BACKUPS_MAX_COUNT keeps exactly the requested number of backups"
else
    fail "expected 2 backups after count pruning, found ${remaining}"
fi
if kept valheim_e.zip && kept valheim_d.zip; then
    pass "count pruning keeps the newest backups"
else
    fail "count pruning kept the wrong backups: $(ls "${BACKUP_DIR}")"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All backup retention checks passed"
    exit 0
fi
echo "${failures} backup retention check(s) failed"
exit 1
