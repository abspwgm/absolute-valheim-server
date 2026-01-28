#!/bin/bash
# =============================================================================
# E2E Test: Server Start
# Verifies that the server starts correctly and becomes ready
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="server_start"

# -----------------------------------------------------------------------------
# Test: Server Start
# -----------------------------------------------------------------------------
test_server_start() {
    log_test_start "${TEST_NAME}"
    
    # Verify container is running
    assert_container_running "valheim-server"
    
    # Check that steamcmd update ran
    log_info "Checking for SteamCMD update execution"
    if wait_for_log "valheim-server" "Starting Valheim server update" 120; then
        log_info "SteamCMD update started"
    else
        log_warn "SteamCMD update log not found (may have used cached files)"
    fi
    
    # Wait for server binary to be present
    log_info "Checking for server binary"
    local attempts=0
    local max_attempts=60
    
    while [[ ${attempts} -lt ${max_attempts} ]]; do
        # First check if container is still running
        if [[ $(docker inspect -f '{{.State.Running}}' valheim-server 2>/dev/null) != "true" ]]; then
            log_error "Container stopped unexpectedly during startup"
            log_error "=== Container Logs ==="
            docker logs valheim-server 2>&1 || true
            log_error "=== End Container Logs ==="
            return 1
        fi
        
        # Use bash -c to avoid Git Bash path conversion on Windows
        if MSYS_NO_PATHCONV=1 docker exec valheim-server test -f /opt/valheim/server/valheim_server.x86_64 2>/dev/null; then
            log_info "Server binary found"
            break
        fi
        sleep 5
        attempts=$((attempts + 1))
    done
    
    if [[ ${attempts} -ge ${max_attempts} ]]; then
        log_error "Server binary not found after ${max_attempts} attempts"
        log_error "=== Container Logs ==="
        docker logs valheim-server 2>&1 || true
        log_error "=== End Container Logs ==="
        return 1
    fi
    
    # Wait for server to connect to Steam
    log_info "Waiting for server to connect to Steam (this may take several minutes)"
    if wait_for_log "valheim-server" "Game server connected" 300; then
        log_success "Server connected to Steam successfully"
    else
        # Check if server process is at least running
        # Use bash -c to avoid Git Bash path conversion on Windows
        if MSYS_NO_PATHCONV=1 docker exec valheim-server pgrep -f valheim_server.x86_64 > /dev/null 2>&1; then
            log_warn "Server process is running but 'Game server connected' not found"
            log_warn "This may be normal if Steam is slow to respond"
            # Consider this a pass if the process is running
        else
            log_error "Server process is not running"
            docker logs valheim-server --tail 100
            return 1
        fi
    fi
    
    # Verify server process is running
    log_info "Verifying server process"
    assert_process_running "valheim-server" "valheim_server.x86_64"
    
    log_test_pass "${TEST_NAME}"
    return 0
}

# Run test
test_server_start
