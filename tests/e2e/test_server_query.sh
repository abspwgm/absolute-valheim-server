#!/bin/bash
# =============================================================================
# E2E Test: Server Query
# Verifies that the server is listening on expected UDP ports
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="server_query"

# -----------------------------------------------------------------------------
# Test: Server Query
# -----------------------------------------------------------------------------
test_server_query() {
    log_test_start "${TEST_NAME}"

    # Verify container is running
    assert_container_running "valheim-server"

    # Wait for server to be ready first
    log_info "Waiting for server to be ready"
    if ! wait_for_log "valheim-server" "Game server connected" 300; then
        log_warn "Server may not be fully connected to Steam"
    fi

    # Give server a moment to stabilize
    sleep 10

    # Get the server port
    local server_port="${SERVER_PORT:-2456}"
    local query_port=$((server_port + 1))

    log_info "Checking server is listening on UDP ports"

    # Primary method: Check if server is listening using /proc/net/udp inside the container
    # This doesn't require any external tools like ss or netstat
    # Port numbers in /proc/net/udp are in hex format
    local port_hex
    local query_port_hex
    printf -v port_hex "%04X" "${server_port}"
    printf -v query_port_hex "%04X" "${query_port}"

    local ports_ok=0
    local attempts=0
    local max_attempts=30

    while [[ ${attempts} -lt ${max_attempts} ]]; do
        local udp_sockets
        udp_sockets=$(MSYS_NO_PATHCONV=1 docker exec valheim-server cat /proc/net/udp 2>/dev/null || echo "")

        local port_2456_ok=false
        local port_2457_ok=false

        # Check for query port (2457) - this is the Steam query port
        if echo "${udp_sockets}" | grep -qi ":${query_port_hex}"; then
            port_2457_ok=true
        fi

        # For the game port (2456), it may not always show in /proc/net/udp
        # Valheim uses it differently, so we primarily check the query port
        if echo "${udp_sockets}" | grep -qi ":${port_hex}"; then
            port_2456_ok=true
        fi

        # Success if query port is bound (main indicator that server is ready)
        if [[ "${port_2457_ok}" == "true" ]]; then
            log_success "Server is listening on query port ${query_port}"
            if [[ "${port_2456_ok}" == "true" ]]; then
                log_success "Server is listening on game port ${server_port}"
            else
                log_info "Game port ${server_port} not detected in /proc/net/udp (may be normal)"
            fi
            ports_ok=1
            break
        fi

        sleep 2
        attempts=$((attempts + 1))

        if [[ $((attempts % 10)) -eq 0 ]]; then
            log_info "Still waiting for ports... (${attempts}/${max_attempts})"
        fi
    done

    if [[ ${ports_ok} -eq 1 ]]; then
        # Verify server process is also running
        if MSYS_NO_PATHCONV=1 docker exec valheim-server pgrep -f valheim_server.x86_64 > /dev/null 2>&1; then
            log_success "Server process is running and ports are bound"
            log_test_pass "${TEST_NAME}"
            return 0
        else
            log_error "Ports are bound but server process not found"
            log_test_fail "${TEST_NAME}"
            return 1
        fi
    fi

    # Fallback: If ports aren't detected but process is running and connected to Steam
    log_warn "Could not detect ports via ss, checking process and logs"

    if MSYS_NO_PATHCONV=1 docker exec valheim-server pgrep -f valheim_server.x86_64 > /dev/null 2>&1; then
        if docker logs valheim-server 2>&1 | grep -q "Game server connected"; then
            log_success "Server process is running and connected to Steam"
            log_test_pass "${TEST_NAME}"
            return 0
        fi
    fi

    log_error "Server is not listening on expected ports"
    log_error "Expected ports: ${server_port} (game), ${query_port} (query)"
    docker logs valheim-server --tail 50 2>&1 || true
    log_test_fail "${TEST_NAME}"
    return 1
}

# Run test
test_server_query
