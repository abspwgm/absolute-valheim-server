#!/bin/bash
# =============================================================================
# E2E Test: BepInEx Safe Mode (bepinex variant only)
# The "keep players online while mods are broken" response: the modded image
# must be able to run vanilla on demand and come back modded afterwards.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="bepinex_safe_mode"
CONTAINER="valheim-server"
MODCHECK_TIMEOUT="${MODCHECK_TIMEOUT:-180}"

test_bepinex_safe_mode() {
    log_test_start "${TEST_NAME}"

    assert_container_running "${CONTAINER}"
    [[ "$(docker_exec "${CONTAINER}" printenv VALHEIM_VARIANT)" == "bepinex" ]] || { log_error "not the bepinex variant"; return 1; }

    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120
    wait_for_modcheck_status "${CONTAINER}" "ok" $((MODCHECK_TIMEOUT + 180))
    local snapshots_before
    snapshots_before=$(dr_status_field "${CONTAINER}" '.snapshots | length')

    # --- on --------------------------------------------------------------------
    log_info "Engaging safe mode"
    dr "${CONTAINER}" safe-mode on --reason "e2e"

    [[ "$(dr_status_field "${CONTAINER}" '.bepinex.safe_mode')" == "true" ]] || { log_error "safe_mode flag not set"; return 1; }
    [[ "$(dr_status_field "${CONTAINER}" '.bepinex.enabled')" == "false" ]] || { log_error "bepinex still reported enabled"; return 1; }

    local snapshots_after
    snapshots_after=$(dr_status_field "${CONTAINER}" '.snapshots | length')
    [[ "${snapshots_after}" -gt "${snapshots_before}" ]] || { log_error "safe-mode on did not snapshot first"; return 1; }
    log_success "Snapshot taken before disabling mods"

    log_info "Waiting for vanilla restart"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120
    wait_for_modcheck_status "${CONTAINER}" "disabled" 120
    [[ "$(dr_status_field "${CONTAINER}" '.modcheck.reason')" == "safe_mode" ]] || { log_error "modcheck reason is not safe_mode"; return 1; }

    # Server is serving; health must be OK (players can join a vanilla server)
    sleep 10
    if docker_exec "${CONTAINER}" test -f /opt/valheim/server/BepInEx/LogOutput.log; then
        log_error "BepInEx wrote a log in safe mode - doorstop was injected"
        return 1
    fi
    local hc
    hc=$(healthcheck_exit_code "${CONTAINER}")
    [[ "${hc}" == "0" ]] || { log_error "healthcheck exit ${hc} in safe mode"; return 1; }
    log_success "Server runs vanilla in safe mode, health OK"

    # Startup banner should say so
    if ! wait_for_log "${CONTAINER}" "SAFE_MODE engaged" 30; then
        log_warn "SAFE_MODE banner not found in logs (non-fatal)"
    fi

    # --- off -------------------------------------------------------------------
    log_info "Disengaging safe mode"
    dr "${CONTAINER}" safe-mode off
    [[ "$(dr_status_field "${CONTAINER}" '.bepinex.safe_mode')" == "false" ]] || { log_error "safe_mode flag still set"; return 1; }

    log_info "Waiting for modded restart"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120
    wait_for_modcheck_status "${CONTAINER}" "ok" $((MODCHECK_TIMEOUT + 180))
    log_success "BepInEx back after safe mode"

    # safe-mode on also set a hold; clear it for later tests
    if [[ "$(dr_status_field "${CONTAINER}" '.update_hold')" == "true" ]]; then
        dr "${CONTAINER}" release
    fi

    log_test_pass "${TEST_NAME}"
    return 0
}

test_bepinex_safe_mode
