#!/bin/bash
# =============================================================================
# E2E Test: Discoverable (ready ladder rung 3, standard 2.10)
# The server answers a Steam server-browser query (A2S_INFO) the way a player's
# "add server" dialog sees it, and the player count it advertises agrees with
# the count the idle guard reads from the server's own log.
# =============================================================================
# server_query proves the ports are bound. That is "reachable", not
# "discoverable": a bound port that answers nothing, or answers with the wrong
# name, is a server nobody can find.
#
# This is Valheim's highest rung short of recovery. Valheim has no remote-admin
# interface - its console lives in the game client - so there is no
# authenticated session to prove; policy.yml records that as the local
# definition of 2.10. The cross-check below is the most this server can be made
# to say about itself: two independent views of its state, the one it
# advertises and the one it logs, have to agree.
#
# The query goes from the runner, outside the container, to the container's own
# address on the Docker network, with bash's /dev/udp. docker-compose.test.yml
# deliberately publishes no host ports (the shared runner would collide on
# them), so this is the path a machine on the same network would use; nothing
# in it runs inside the container being tested. A2S_INFO has required a
# challenge round trip since 2020; the first reply may be S2C_CHALLENGE (0x41).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="discoverable"
CONTAINER="valheim-server"
# What docker-compose.test.yml configures, and so what the browser must show.
EXPECTED_NAME="E2E Test Server"
EXPECTED_FOLDER="valheim"

A2S_QUERY='\xFF\xFF\xFF\xFFTSource Engine Query\x00'

# a2s_info ; the server's reply as a lowercase hex string, or nothing
a2s_info() {
    local fd reply challenge escaped=""
    exec {fd}<>"/dev/udp/${QUERY_HOST}/${QUERY_PORT}" || return 1
    # One printf per datagram: two writes would be two packets.
    printf '%b' "${A2S_QUERY}" >&"${fd}"
    reply="$(timeout 5 dd bs=1400 count=1 status=none <&"${fd}" | od -An -v -tx1 | tr -d ' \n')" || true
    if [[ "${reply:0:10}" == "ffffffff41" ]]; then
        challenge="${reply:10:8}"
        for (( i = 0; i < 8; i += 2 )); do escaped+="\\x${challenge:i:2}"; done
        printf '%b' "${A2S_QUERY}${escaped}" >&"${fd}"
        reply="$(timeout 5 dd bs=1400 count=1 status=none <&"${fd}" | od -An -v -tx1 | tr -d ' \n')" || true
    fi
    exec {fd}>&-
    printf '%s' "${reply}"
}

# cstring <var> ; reads a NUL-terminated string at POS in HEX into <var>
cstring() {
    local out=""
    while [[ ${POS} -lt ${#HEX} && "${HEX:POS:2}" != "00" ]]; do
        out+="\\x${HEX:POS:2}"
        POS=$(( POS + 2 ))
    done
    POS=$(( POS + 2 ))
    printf -v "$1" '%b' "${out}"
}

# byte <var> ; one unsigned byte at POS. A reply cut short reads as 0 rather
# than aborting the test under set -e; the assertions then say what is wrong.
byte() {
    local h="${HEX:POS:2}"
    printf -v "$1" '%d' "0x${h:-00}"
    POS=$(( POS + 2 ))
}

test_discoverable() {
    log_test_start "${TEST_NAME}"
    assert_container_running "${CONTAINER}"

    if ! wait_for_log "${CONTAINER}" "Game server connected" 300; then
        log_warn "Server may not be fully ready"
    fi

    # The container's address on its Docker network (the first, if several).
    QUERY_PORT=2457
    QUERY_HOST="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${CONTAINER}" 2>/dev/null | awk '{print $1}')"
    if [[ ! "${QUERY_HOST}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        log_error "Could not find the container's address on its Docker network"
        docker inspect -f '{{json .NetworkSettings.Networks}}' "${CONTAINER}" 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_info "Querying ${QUERY_HOST}:${QUERY_PORT}/udp from the runner"

    # The query port can lag the game port for a moment after startup.
    local attempt
    HEX=""
    for attempt in 1 2 3 4 5 6; do
        HEX="$(a2s_info)" || true
        [[ "${HEX:0:10}" == "ffffffff49" ]] && break
        log_info "No A2S_INFO reply yet (attempt ${attempt}); retrying"
        sleep 5
    done

    if [[ "${HEX:0:10}" != "ffffffff49" ]]; then
        log_error "The server did not answer a server-browser query on 2457/udp"
        log_error "Reply (hex): ${HEX:-<none>}"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # Header (4 x FF), type 'I', protocol, then name, map, folder, game,
    # a 16-bit app id, players, max players, bots.
    local protocol name map folder game players max_players bots
    POS=10
    byte protocol
    cstring name
    cstring map
    cstring folder
    cstring game
    POS=$(( POS + 4 ))   # app id
    byte players
    byte max_players
    byte bots
    log_info "Browser sees: name='${name}' map='${map}' folder='${folder}' game='${game}' players=${players}/${max_players}"

    local failed=0
    if [[ "${name}" == "${EXPECTED_NAME}" ]]; then
        log_success "The browser shows the configured name"
    else
        log_error "Expected name '${EXPECTED_NAME}', the browser shows '${name}'"
        failed=1
    fi
    if [[ "${folder}" == "${EXPECTED_FOLDER}" ]]; then
        log_success "It identifies as ${EXPECTED_FOLDER}"
    else
        log_error "Expected game folder '${EXPECTED_FOLDER}', got '${folder}'"
        failed=1
    fi
    if [[ "${max_players}" -gt 0 ]]; then
        log_success "It advertises ${max_players} slots"
    else
        log_error "It advertises no slots at all"
        failed=1
    fi

    # The count the idle guard reads, through the same function it calls,
    # against the count the server advertises. Two views of one fact.
    local logged
    logged="$(docker exec "${CONTAINER}" bash -c 'source /opt/valheim/scripts/common && get_player_count' 2>/dev/null)" || true
    if [[ "${logged}" =~ ^[0-9]+$ ]] && [[ "${logged}" -eq "${players}" ]]; then
        log_success "The advertised player count (${players}) matches the one the idle guard reads from the log"
    else
        log_error "The browser says ${players} players; the idle guard's count from the log says '${logged:-<nothing>}'"
        failed=1
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_test_pass "${TEST_NAME}"
    return 0
}

test_discoverable
