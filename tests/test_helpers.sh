#!/bin/bash
# =============================================================================
# Test Helpers - Common functions for E2E tests
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Docker exec wrapper to prevent Git Bash path conversion on Windows
# Usage: docker_exec container_name command [args...]
# -----------------------------------------------------------------------------
docker_exec() {
    MSYS_NO_PATHCONV=1 docker exec "$@"
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_test_start() {
    local test_name="$1"
    echo ""
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}Starting test: ${test_name}${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
}

log_test_pass() {
    local test_name="$1"
    echo -e "${GREEN}----------------------------------------${NC}"
    echo -e "${GREEN}Test PASSED: ${test_name}${NC}"
    echo -e "${GREEN}----------------------------------------${NC}"
}

log_test_fail() {
    local test_name="$1"
    echo -e "${RED}----------------------------------------${NC}"
    echo -e "${RED}Test FAILED: ${test_name}${NC}"
    echo -e "${RED}----------------------------------------${NC}"
}

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------
assert_container_running() {
    local container="$1"
    
    if [[ $(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null) != "true" ]]; then
        log_error "Container '${container}' is not running"
        return 1
    fi
    
    log_info "Container '${container}' is running"
    return 0
}

assert_process_running() {
    local container="$1"
    local process="$2"
    local timeout="${3:-30}"
    local elapsed=0

    # Retry loop - process may take time to spawn
    while [[ ${elapsed} -lt ${timeout} ]]; do
        # Use docker_exec helper to prevent Git Bash path conversion on Windows
        if docker_exec "${container}" pgrep -f "${process}" > /dev/null 2>&1; then
            log_info "Process '${process}' is running"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "Process '${process}' is not running in container '${container}' after ${timeout}s"
    return 1
}

assert_file_exists() {
    local container="$1"
    local file="$2"
    
    # Use docker_exec helper to prevent Git Bash path conversion on Windows
    if ! docker_exec "${container}" test -f "${file}"; then
        log_error "File '${file}' does not exist in container '${container}'"
        return 1
    fi
    
    log_info "File '${file}' exists"
    return 0
}

assert_directory_exists() {
    local container="$1"
    local dir="$2"
    
    # Use docker_exec helper to prevent Git Bash path conversion on Windows
    if ! docker_exec "${container}" test -d "${dir}"; then
        log_error "Directory '${dir}' does not exist in container '${container}'"
        return 1
    fi
    
    log_info "Directory '${dir}' exists"
    return 0
}

# -----------------------------------------------------------------------------
# Wait Functions
# -----------------------------------------------------------------------------
wait_for_log() {
    local container="$1"
    local pattern="$2"
    local timeout="${3:-60}"
    local elapsed=0
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        # Check docker logs (supervisor and bootstrap output)
        if docker logs "${container}" 2>&1 | grep -qi "${pattern}"; then
            return 0
        fi
        # Also check the valheim server log file inside container
        if docker_exec "${container}" grep -qi "${pattern}" /var/log/valheim/valheim-server.log 2>/dev/null; then
            return 0
        fi
        # Check supervisor stdout log
        if docker_exec "${container}" grep -qi "${pattern}" /var/log/valheim/server-stdout.log 2>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    return 1
}

wait_for_container_healthy() {
    local container="$1"
    local timeout="${2:-300}"
    local elapsed=0
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        local health
        health=$(docker inspect -f '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "unknown")
        
        if [[ "${health}" == "healthy" ]]; then
            return 0
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    return 1
}

wait_for_port() {
    local host="$1"
    local port="$2"
    local timeout="${3:-60}"
    local elapsed=0
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if nc -z -w 2 "${host}" "${port}" 2>/dev/null; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    return 1
}

# -----------------------------------------------------------------------------
# Container Operations
# -----------------------------------------------------------------------------
get_container_logs() {
    local container="$1"
    local lines="${2:-100}"
    
    docker logs "${container}" 2>&1 | tail -n "${lines}"
}

exec_in_container() {
    local container="$1"
    shift
    MSYS_NO_PATHCONV=1 docker exec "${container}" "$@"
}
