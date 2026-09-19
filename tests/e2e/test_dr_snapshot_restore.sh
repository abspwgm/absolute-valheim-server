#!/bin/bash
# =============================================================================
# E2E Test: DR Snapshot / Restore (both variants)
# Verifies the disaster-response primitives every response path relies on:
#   snapshot -> tamper -> restore -> hold set -> release
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="dr_snapshot_restore"
CONTAINER="valheim-server"
CANARY="/opt/valheim/server/.dr_e2e_canary"

test_dr_snapshot_restore() {
    log_test_start "${TEST_NAME}"

    assert_container_running "${CONTAINER}"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120

    # Baseline: nothing held, DR CLI answers
    log_info "Checking DR status"
    local variant build_id
    variant=$(dr_status_field "${CONTAINER}" '.variant')
    build_id=$(dr_status_field "${CONTAINER}" '.build_id')
    log_info "variant=${variant} build_id=${build_id}"
    [[ -n "${variant}" && "${variant}" != "null" ]] || { log_error "status.variant missing"; return 1; }
    [[ "${build_id}" != "0" ]] || { log_error "no installed build to snapshot"; return 1; }

    if [[ "$(dr_status_field "${CONTAINER}" '.update_hold')" == "true" ]]; then
        log_warn "Update hold already set from a previous test; releasing"
        dr "${CONTAINER}" release
    fi

    # Plant a canary in the server directory, snapshot, then destroy it
    log_info "Planting canary file and taking snapshot"
    docker_exec "${CONTAINER}" sh -c "echo e2e > ${CANARY}"
    local snapshot_id
    snapshot_id=$(dr "${CONTAINER}" snapshot e2e --reason "e2e drill" | tail -1)
    log_info "Snapshot id: ${snapshot_id}"
    [[ -n "${snapshot_id}" ]] || { log_error "snapshot returned no id"; return 1; }

    assert_file_exists "${CONTAINER}" "/config/dr/snapshots/${snapshot_id}/manifest.json"
    assert_file_exists "${CONTAINER}" "/config/dr/snapshots/${snapshot_id}/server.tar"

    local listed
    listed=$(dr_status_field "${CONTAINER}" '.snapshots | length')
    [[ "${listed}" -ge 1 ]] || { log_error "status.snapshots is empty"; return 1; }
    log_success "Snapshot recorded (${listed} total)"

    log_info "Destroying canary"
    docker_exec "${CONTAINER}" rm -f "${CANARY}"
    if docker_exec "${CONTAINER}" test -f "${CANARY}"; then
        log_error "Canary still present after rm"
        return 1
    fi

    # Restore: must stop the server, replace files, hold updates, restart
    log_info "Restoring latest snapshot"
    dr "${CONTAINER}" restore latest --server-only --reason "e2e drill"

    assert_file_exists "${CONTAINER}" "${CANARY}"
    log_success "Canary restored from snapshot"

    if [[ "$(dr_status_field "${CONTAINER}" '.update_hold')" != "true" ]]; then
        log_error "UPDATE_HOLD not set after restore"
        return 1
    fi
    log_success "UPDATE_HOLD set by restore"

    if [[ "$(dr_status_field "${CONTAINER}" '.last_restore.id')" != "${snapshot_id}" ]]; then
        log_error "last_restore does not reference ${snapshot_id}"
        return 1
    fi

    # The updater must honour the hold
    log_info "Verifying updater honours the hold"
    local updater_output
    updater_output=$(docker_exec "${CONTAINER}" /opt/valheim/scripts/valheim-updater 2>&1 || true)
    if ! echo "${updater_output}" | grep -q "UPDATE_HOLD is active"; then
        log_error "Updater did not report the hold:"
        echo "${updater_output}" | tail -20
        return 1
    fi
    log_success "Updater skipped while held"

    # Server must come back after the restore
    log_info "Waiting for server process after restore"
    assert_process_running "${CONTAINER}" "valheim_server.x86_64" 120

    log_info "Releasing hold"
    dr "${CONTAINER}" release
    if [[ "$(dr_status_field "${CONTAINER}" '.update_hold')" != "false" ]]; then
        log_error "UPDATE_HOLD still set after release"
        return 1
    fi
    log_success "Hold released"

    docker_exec "${CONTAINER}" rm -f "${CANARY}" || true

    log_test_pass "${TEST_NAME}"
    return 0
}

test_dr_snapshot_restore
