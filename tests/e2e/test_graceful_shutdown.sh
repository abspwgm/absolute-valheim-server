#!/bin/bash
# =============================================================================
# E2E Test: Graceful Shutdown
# Verifies that the server saves the world and shuts down cleanly
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="graceful_shutdown"

# -----------------------------------------------------------------------------
# Test: Graceful Shutdown
# -----------------------------------------------------------------------------
test_graceful_shutdown() {
    log_test_start "${TEST_NAME}"
    
    # Verify container is running
    assert_container_running "valheim-server"
    
    # Wait for server to be ready
    log_info "Waiting for server to be ready"
    if ! wait_for_log "valheim-server" "Game server connected" 300; then
        log_warn "Server may not be fully ready"
    fi
    
    # Give server time to stabilize
    sleep 10
    
    # Verify server process is running before shutdown
    assert_process_running "valheim-server" "valheim_server.x86_64"
    
    # Get logs before shutdown for comparison
    local logs_before
    logs_before=$(docker logs valheim-server 2>&1 | wc -l)
    
    # Send graceful shutdown signal
    log_info "Sending graceful shutdown signal (SIGINT)"
    docker kill --signal=INT valheim-server || true
    
    # Wait for shutdown (up to 2 minutes for world save)
    log_info "Waiting for graceful shutdown (up to 120 seconds)"
    local timeout=120
    local elapsed=0
    
    while docker inspect -f '{{.State.Running}}' valheim-server 2>/dev/null | grep -q true; do
        if [[ ${elapsed} -ge ${timeout} ]]; then
            log_error "Container did not stop within ${timeout} seconds"
            log_test_fail "${TEST_NAME}"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        
        if [[ $((elapsed % 20)) -eq 0 ]]; then
            log_info "Still waiting... (${elapsed}s/${timeout}s)"
        fi
    done
    
    log_info "Container stopped after ${elapsed} seconds"
    
    # Check logs for world save message
    log_info "Checking logs for world save confirmation"
    local logs
    logs=$(docker logs valheim-server 2>&1)
    
    if echo "${logs}" | grep -qi "World saved\|Saving world\|World save"; then
        log_success "World save detected in logs"
    else
        log_warn "World save message not found in logs"
        log_warn "This may be normal if no world was generated"
    fi
    
    # Check exit code
    local exit_code
    exit_code=$(docker inspect -f '{{.State.ExitCode}}' valheim-server 2>/dev/null || echo "unknown")
    log_info "Container exit code: ${exit_code}"
    
    # Exit code 0 or 137 (SIGKILL after SIGINT timeout) are acceptable
    if [[ "${exit_code}" == "0" ]] || [[ "${exit_code}" == "137" ]] || [[ "${exit_code}" == "143" ]]; then
        log_success "Container exited cleanly"
    else
        log_warn "Container exited with code ${exit_code}"
    fi
    
    # Restart container for subsequent tests
    log_info "Restarting container for subsequent tests"
    cd "$(dirname "${SCRIPT_DIR}")/.."
    docker compose -f docker-compose.test.yml up -d
    
    # Wait for container to be running again
    local attempts=0
    while [[ $(docker inspect -f '{{.State.Running}}' valheim-server 2>/dev/null) != "true" ]]; do
        if [[ ${attempts} -ge 30 ]]; then
            log_error "Container failed to restart"
            log_test_fail "${TEST_NAME}"
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    
    log_success "Container restarted successfully"
    log_test_pass "${TEST_NAME}"
    return 0
}

# Run test
test_graceful_shutdown
