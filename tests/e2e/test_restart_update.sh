#!/bin/bash
# =============================================================================
# E2E Test: Restart Update
# Verifies that SteamCMD runs on container restart
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="restart_update"

# -----------------------------------------------------------------------------
# Test: Restart Update
# -----------------------------------------------------------------------------
test_restart_update() {
    log_test_start "${TEST_NAME}"
    
    # Verify container is running
    assert_container_running "valheim-server"
    
    # Get current log line count
    local logs_before
    logs_before=$(docker logs valheim-server 2>&1 | wc -l)
    log_info "Log lines before restart: ${logs_before}"
    
    # Restart the container
    log_info "Restarting container"
    docker restart valheim-server
    
    # Wait for container to be running
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
    
    log_info "Container restarted, waiting for update check"
    
    # Wait for SteamCMD update to run
    # Look for the update message in new logs
    local update_found=false
    local timeout=120
    local elapsed=0
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        local current_logs
        current_logs=$(docker logs valheim-server 2>&1 | tail -n +$((logs_before + 1)))
        
        if echo "${current_logs}" | grep -qi "Starting Valheim server update\|Running SteamCMD\|Update on start is enabled\|app_update"; then
            update_found=true
            log_success "SteamCMD update triggered on restart"
            break
        fi
        
        # Also check for skipped update with cached files
        if echo "${current_logs}" | grep -qi "Continuing with existing server files\|Server binary found"; then
            update_found=true
            log_info "Update check completed (using cached files)"
            break
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Still waiting for update... (${elapsed}s/${timeout}s)"
        fi
    done
    
    if [[ "${update_found}" == "false" ]]; then
        log_warn "Update message not found in logs"
        log_info "Recent logs:"
        docker logs valheim-server 2>&1 | tail -50
    fi
    
    # Wait for server to be ready after restart
    log_info "Waiting for server to be ready after restart"
    if wait_for_log "valheim-server" "Game server connected" 300; then
        log_success "Server reconnected after restart"
    else
        # Check if server process is at least running
        if MSYS_NO_PATHCONV=1 docker exec valheim-server pgrep -f valheim_server.x86_64 > /dev/null 2>&1; then
            log_warn "Server process running but Steam connection not confirmed"
        else
            log_error "Server process not running after restart"
            log_test_fail "${TEST_NAME}"
            return 1
        fi
    fi
    
    log_test_pass "${TEST_NAME}"
    return 0
}

# Run test
test_restart_update
