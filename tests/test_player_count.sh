#!/bin/bash
# =============================================================================
# Unit test: get_player_count / is_server_idle
# =============================================================================
# Needs no Docker and no server. Each case writes a fake valheim-server.log and
# asks the shared library how many players are connected.
#
# Guards #6: get_player_count used to read a status.json that nothing in the
# image ever wrote, so it always returned 0, is_server_idle was always true, and
# a scheduled update would restart the server on top of connected players.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

# A real connect line, as the server writes it.
connect()    { echo "Got connection SteamID $1"; }
# A real disconnect line. valheim-logfilter always lets these through.
disconnect() { echo "Closing socket $1"; }

# count_for <<< "<log contents>"  ; sets COUNT and IDLE
count_for() {
    local log_dir="${WORK}/log"
    rm -rf "${log_dir}"; mkdir -p "${log_dir}"
    cat > "${log_dir}/valheim-server.log"
    COUNT="$(
        export LOG_PATH="${log_dir}"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/scripts/common"
        get_player_count
    )"
    if (
        export LOG_PATH="${log_dir}"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/scripts/common"
        is_server_idle
    ); then IDLE=yes; else IDLE=no; fi
}

check() { # check <expected_count> <expected_idle> <description>
    if [[ "${COUNT}" == "$1" && "${IDLE}" == "$2" ]]; then
        pass "$3"
    else
        fail "$3 (expected count=$1 idle=$2, got count=${COUNT} idle=${IDLE})"
    fi
}

# --- nobody connected -----------------------------------------------------
count_for <<< ""
check 0 yes "an empty log means nobody is connected"

# --- the bug this test exists for -----------------------------------------
# One player connected and never disconnected: the server is NOT idle, so a
# scheduled update must not restart it.
count_for < <(connect 76561198000000001)
check 1 no "one connected player is counted, and the server is not idle"

# --- connect then leave ---------------------------------------------------
count_for < <(connect 76561198000000001; disconnect 76561198000000001)
check 0 yes "a player who disconnected is not counted"

# --- several players ------------------------------------------------------
count_for < <(connect 76561198000000001; connect 76561198000000002; connect 76561198000000003)
check 3 no "three connected players are counted"

count_for < <(connect 76561198000000001; connect 76561198000000002; disconnect 76561198000000001)
check 1 no "only the remaining player is counted"

# --- a restart must not leave ghosts -------------------------------------
# The log persists across restarts. Without a reset, a connection that was open
# when the server went down would look live forever, and then updates and
# backups would be skipped for good - the opposite failure.
count_for < <(connect 76561198000000001; echo "Steam game server initialized")
check 0 yes "a server restart clears connections left open in the old log"

count_for < <(connect 76561198000000001; echo "Steam game server initialized"; connect 76561198000000002)
check 1 no "connections after a restart are counted, earlier ones are not"

# --- robustness ----------------------------------------------------------
count_for < <(connect 76561198000000001; connect 76561198000000001)
check 1 no "the same player appearing twice is counted once"

count_for < <(disconnect 76561198000000009)
check 0 yes "a disconnect with no matching connect cannot drive the count negative"

# valheim-logfilter rewrites lines with a [timestamp] prefix before they land
# in the log file, so the parser has to cope with that form too.
count_for < <(echo "[2026-09-20 11:00:00] Got connection SteamID 76561198000000001")
check 1 no "a line carrying valheim-logfilter's timestamp prefix still parses"

# --- no log at all -------------------------------------------------------
COUNT="$(
    export LOG_PATH="${WORK}/nonexistent"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/common"
    get_player_count
)"
if [[ "${COUNT}" == "0" ]]; then
    pass "a missing log reports zero rather than erroring"
else
    fail "expected 0 for a missing log, got ${COUNT}"
fi

# --- an unreadable log while the server is up must fail closed ------------
# We cannot prove nobody is connected, so the guard must not claim "idle".
if (
    export LOG_PATH="${WORK}/nonexistent"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/common"
    # Pretend the server process is up; the log is still missing.
    is_server_running() { return 0; }
    is_server_idle
) > /dev/null 2>&1; then
    fail "an unreadable log while the server is running must not report idle"
else
    pass "an unreadable log while the server is running fails closed (not idle)"
fi

# With the server down, a missing log is simply "nobody connected".
if (
    export LOG_PATH="${WORK}/nonexistent"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/common"
    is_server_running() { return 1; }
    is_server_idle
) > /dev/null 2>&1; then
    pass "with the server down, a missing log reports idle"
else
    fail "with the server down, a missing log should report idle"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All player count checks passed"
    exit 0
fi
echo "${failures} player count check(s) failed"
exit 1
