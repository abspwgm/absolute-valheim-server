#!/bin/bash
# =============================================================================
# E2E Test: BepInEx Loaded (bepinex variant only)
# Verifies the modded artifact actually injects BepInEx into the server and that
# the mod-load verifier + health check agree.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="bepinex_loaded"
CONTAINER="valheim-server"
MODCHECK_TIMEOUT="${MODCHECK_TIMEOUT:-180}"

test_bepinex_loaded() {
    log_test_start "${TEST_NAME}"

    assert_container_running "${CONTAINER}"

    # Right image?
    local variant
    variant=$(docker_exec "${CONTAINER}" printenv VALHEIM_VARIANT)
    if [[ "${variant}" != "bepinex" ]]; then
        log_error "Expected VALHEIM_VARIANT=bepinex, got '${variant}'"
        return 1
    fi

    # Overlay installed and persisted
    log_info "Checking BepInEx overlay"
    assert_file_exists "${CONTAINER}" "/opt/valheim/server/BepInEx/core/BepInEx.Preloader.dll"
    assert_file_exists "${CONTAINER}" "/opt/valheim/server/doorstop_libs/libdoorstop_x64.so"
    assert_file_exists "${CONTAINER}" "/opt/valheim/server/.bepinex.env"
    assert_file_exists "${CONTAINER}" "/opt/valheim/server/.bepinex_version"

    local env_dump
    env_dump=$(docker_exec "${CONTAINER}" /opt/valheim/scripts/valheim-bepinex env)
    log_info "Launch env:"
    echo "${env_dump}"
    echo "${env_dump}" | grep -q '^DOORSTOP_' || { log_error "no DOORSTOP_* in launch env"; return 1; }
    echo "${env_dump}" | grep -q '^LD_PRELOAD=.*libdoorstop' || { log_error "LD_PRELOAD missing libdoorstop"; return 1; }

    local plugins_link
    plugins_link=$(docker_exec "${CONTAINER}" readlink /opt/valheim/server/BepInEx/plugins)
    if [[ "${plugins_link}" != "/config/bepinex/plugins" ]]; then
        log_error "BepInEx/plugins is not persisted to /config (readlink: '${plugins_link}')"
        return 1
    fi
    log_success "Plugins persisted at /config/bepinex/plugins"

    # Pinned version matches what the image says it ships
    local pack_version installed_version
    pack_version=$(dr_status_field "${CONTAINER}" '.bepinex.pack_version')
    installed_version=$(dr_status_field "${CONTAINER}" '.bepinex.installed_version')
    if [[ -z "${pack_version}" || "${pack_version}" != "${installed_version}" ]]; then
        log_error "BepInEx version mismatch: pack=${pack_version} installed=${installed_version}"
        return 1
    fi
    log_success "BepInEx ${installed_version} installed"

    # The real proof: doorstop preloaded, chainloader finished
    log_info "Waiting for BepInEx chainloader (up to $((MODCHECK_TIMEOUT + 120))s)"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120
    if ! wait_for_file_pattern "${CONTAINER}" /opt/valheim/server/BepInEx/LogOutput.log "Chainloader startup complete" $((MODCHECK_TIMEOUT + 120)); then
        log_error "Chainloader never completed. BepInEx log:"
        docker_exec "${CONTAINER}" cat /opt/valheim/server/BepInEx/LogOutput.log 2>&1 | tail -50 || echo "(no LogOutput.log - doorstop did not inject)"
        return 1
    fi
    log_success "BepInEx chainloader startup complete"

    docker_exec "${CONTAINER}" head -5 /opt/valheim/server/BepInEx/LogOutput.log || true

    # Verifier agrees, and did not trip the policy
    wait_for_modcheck_status "${CONTAINER}" "ok" 120
    local reason action
    reason=$(dr_status_field "${CONTAINER}" '.modcheck.reason')
    action=$(dr_status_field "${CONTAINER}" '.modcheck.action_taken')
    log_info "modcheck reason=${reason} action=${action}"
    [[ "${action}" == "none" ]] || { log_error "modcheck took action '${action}' on a healthy start"; return 1; }

    # Health check passes in strict mode
    local hc
    hc=$(healthcheck_exit_code "${CONTAINER}")
    if [[ "${hc}" != "0" ]]; then
        log_error "healthcheck exit code ${hc} on a healthy modded server"
        docker_exec "${CONTAINER}" /opt/valheim/scripts/healthcheck || true
        return 1
    fi
    log_success "Health check passes (strict mode)"

    log_test_pass "${TEST_NAME}"
    return 0
}

test_bepinex_loaded
