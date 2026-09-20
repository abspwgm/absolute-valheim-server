#!/bin/bash
# =============================================================================
# E2E Test: Idle guard (UPDATE_IF_IDLE)
# Verifies that the shared library counts connected players inside the real
# image, and that valheim-updater refuses to update while someone is connected.
# =============================================================================
# The unit tier (tests/test_player_count.sh) covers the parsing. This asserts
# the wiring end to end: real image, real paths, real updater. CI has no Valheim
# client, so a session is simulated by appending the exact lines the server
# writes on connect and disconnect to the log the library reads.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="idle_guard"
CONTAINER="valheim-server"
SERVER_LOG="/var/log/valheim/valheim-server.log"
FAKE_STEAM_ID="76561198000000001"

# Ask the library, inside the container, how many players it sees.
container_player_count() {
    docker exec "${CONTAINER}" bash -c \
        'source /opt/valheim/scripts/common && get_player_count' 2>/dev/null | tr -d '\r'
}

append_to_server_log() {
    docker exec "${CONTAINER}" bash -c "printf '%s\n' \"$1\" >> ${SERVER_LOG}"
}

test_idle_guard() {
    log_test_start "${TEST_NAME}"

    assert_container_running "${CONTAINER}"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64"

    # --- idle: nobody has connected in this CI run -------------------------
    local count
    count="$(container_player_count)"
    if [[ "${count}" != "0" ]]; then
        log_error "Expected 0 players on an untouched server, got '${count}'"
        docker exec "${CONTAINER}" tail -20 "${SERVER_LOG}" 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "An untouched server reports 0 connected players"

    # --- busy: simulate a player connecting --------------------------------
    append_to_server_log "Got connection SteamID ${FAKE_STEAM_ID}"

    count="$(container_player_count)"
    if [[ "${count}" != "1" ]]; then
        log_error "Expected 1 player after a connect line, got '${count}'"
        docker exec "${CONTAINER}" tail -20 "${SERVER_LOG}" 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "A connected player is counted"

    # The guard must now refuse the update. This is the behaviour the README
    # promises and the reason #6 mattered: the updater used to restart the
    # server on top of a live session.
    local updater_output
    updater_output="$(docker exec "${CONTAINER}" valheim-updater 2>&1 || true)"
    if echo "${updater_output}" | grep -q "Players are connected, skipping update"; then
        log_success "valheim-updater skipped the update while a player was connected"
    else
        log_error "valheim-updater did not skip the update while a player was connected"
        log_error "=== updater output ==="
        echo "${updater_output}"
        log_error "=== end updater output ==="
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # --- back to idle: the player leaves -----------------------------------
    append_to_server_log "Closing socket ${FAKE_STEAM_ID}"

    count="$(container_player_count)"
    if [[ "${count}" != "0" ]]; then
        log_error "Expected 0 players after a disconnect line, got '${count}'"
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "A disconnected player is no longer counted"

    log_test_pass "${TEST_NAME}"
    return 0
}

test_idle_guard
