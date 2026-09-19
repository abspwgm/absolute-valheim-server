#!/bin/bash
# =============================================================================
# E2E Test: BepInEx Disaster Drill (bepinex variant only)
#
# Simulates the failure mode a Valheim update most often causes for a modded
# server - doorstop no longer injects, so the server comes up vanilla and silent
# - and proves the harness detects it and can recover:
#
#   snapshot -> break injection -> restart -> modcheck=failed, health=unhealthy,
#   hold set -> restore latest -> modcheck=ok, health=healthy -> release
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="bepinex_disaster_drill"
CONTAINER="valheim-server"
MODCHECK_TIMEOUT="${MODCHECK_TIMEOUT:-180}"
DOORSTOP_LIB="/opt/valheim/server/doorstop_libs/libdoorstop_x64.so"

test_bepinex_disaster_drill() {
    log_test_start "${TEST_NAME}"

    assert_container_running "${CONTAINER}"
    [[ "$(docker_exec "${CONTAINER}" printenv VALHEIM_VARIANT)" == "bepinex" ]] || { log_error "not the bepinex variant"; return 1; }
    [[ "$(docker_exec "${CONTAINER}" printenv MOD_FAILURE_POLICY)" == "hold" ]] || { log_error "drill expects MOD_FAILURE_POLICY=hold"; return 1; }

    # Known-good starting point
    log_info "Waiting for a healthy modded start"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120
    wait_for_modcheck_status "${CONTAINER}" "ok" $((MODCHECK_TIMEOUT + 180))
    if [[ "$(dr_status_field "${CONTAINER}" '.update_hold')" == "true" ]]; then
        dr "${CONTAINER}" release
    fi

    log_info "Taking pre-disaster snapshot"
    local snapshot_id
    snapshot_id=$(dr "${CONTAINER}" snapshot drill --reason "disaster drill" | tail -1)
    [[ -n "${snapshot_id}" ]] || { log_error "snapshot failed"; return 1; }
    log_success "Snapshot ${snapshot_id}"

    # --- Disaster: the doorstop preload library is corrupt -------------------
    # A truncated .so is what a half-applied update or a bad mod-manager sync
    # leaves behind: the file exists (so the overlay's missing-file self-repair
    # does not kick in), the dynamic loader refuses to preload it, and the game
    # silently starts vanilla. Exactly the failure modcheck must catch.
    log_info "DISASTER: truncating ${DOORSTOP_LIB} and restarting the server"
    docker_exec "${CONTAINER}" sh -c ": > '${DOORSTOP_LIB}'"
    dr "${CONTAINER}" restart

    sleep 15
    local lib_size
    lib_size=$(docker_exec "${CONTAINER}" stat -c %s "${DOORSTOP_LIB}" 2>/dev/null || echo missing)
    if [[ "${lib_size}" != "0" ]]; then
        log_error "Drill precondition not met: libdoorstop size is '${lib_size}', expected 0 (self-repaired?)"
        return 1
    fi

    log_info "Waiting for modcheck to detect the failure (up to $((MODCHECK_TIMEOUT + 120))s)"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120
    wait_for_modcheck_status "${CONTAINER}" "failed" $((MODCHECK_TIMEOUT + 120))

    local reason action
    reason=$(dr_status_field "${CONTAINER}" '.modcheck.reason')
    action=$(dr_status_field "${CONTAINER}" '.modcheck.action_taken')
    log_info "modcheck reason=${reason} action=${action}"
    [[ "${reason}" == "not_loaded" ]] || { log_error "expected reason=not_loaded, got '${reason}'"; return 1; }
    [[ "${action}" == "hold" ]] || { log_error "expected action=hold, got '${action}'"; return 1; }

    # Server is UP (vanilla) but the container must report unhealthy
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 30
    local hc
    hc=$(healthcheck_exit_code "${CONTAINER}")
    if [[ "${hc}" == "0" ]]; then
        log_error "healthcheck still passes with BepInEx not injected (MODCHECK_STRICT should fail it)"
        return 1
    fi
    log_success "Health check reports UNHEALTHY (exit ${hc}) while server runs without mods"

    if [[ "$(dr_status_field "${CONTAINER}" '.update_hold')" != "true" ]]; then
        log_error "hold policy did not set UPDATE_HOLD"
        return 1
    fi
    log_success "UPDATE_HOLD set by policy"

    # --- Response: roll back to the pre-disaster snapshot --------------------
    log_info "RESPONSE: valheim-dr restore latest"
    dr "${CONTAINER}" restore latest --reason "drill recovery"

    lib_size=$(docker_exec "${CONTAINER}" stat -c %s "${DOORSTOP_LIB}" 2>/dev/null || echo missing)
    if [[ "${lib_size}" == "0" || "${lib_size}" == "missing" ]]; then
        log_error "doorstop library not restored (size '${lib_size}')"
        return 1
    fi
    log_success "doorstop library restored (${lib_size} bytes)"

    log_info "Waiting for a healthy modded start after restore"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120
    wait_for_modcheck_status "${CONTAINER}" "ok" $((MODCHECK_TIMEOUT + 180))

    hc=$(healthcheck_exit_code "${CONTAINER}")
    [[ "${hc}" == "0" ]] || { log_error "healthcheck exit ${hc} after restore"; return 1; }
    log_success "Health check HEALTHY after restore"

    log_info "Releasing hold"
    dr "${CONTAINER}" release
    [[ "$(dr_status_field "${CONTAINER}" '.update_hold')" == "false" ]] || { log_error "hold not released"; return 1; }

    log_test_pass "${TEST_NAME}"
    return 0
}

test_bepinex_disaster_drill
