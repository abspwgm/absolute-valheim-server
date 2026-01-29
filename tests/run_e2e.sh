#!/bin/bash
# =============================================================================
# E2E Test Runner - Executes all end-to-end tests
# =============================================================================
# Usage: ./tests/run_e2e.sh [test_name]
#   - No arguments: runs all tests
#   - With argument: runs specific test (e.g., ./tests/run_e2e.sh server_start)
# =============================================================================

# Don't use set -e - we want to capture logs even on failures
# set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
E2E_DIR="${SCRIPT_DIR}/e2e"

# Test configuration
CONTAINER_NAME="valheim-server"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.test.yml"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"  # 10 minutes default
STARTUP_WAIT="${STARTUP_WAIT:-300}"  # 5 minutes for server startup
USE_BIND_MOUNTS="${USE_BIND_MOUNTS:-false}"  # Use local data folder for debugging
LOGS_DIR="${PROJECT_ROOT}/data/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# Create logs directory immediately
mkdir -p "${LOGS_DIR}"

# Master log file for all output
MASTER_LOG="${LOGS_DIR}/e2e_run_$(date +%Y%m%d_%H%M%S).log"

# Error handler - captures state on unexpected errors
on_error() {
    local exit_code=$?
    local line_no=$1
    echo "[ERROR] Script failed at line ${line_no} with exit code ${exit_code}" | tee -a "${MASTER_LOG}"
    echo "[ERROR] Capturing emergency logs..." | tee -a "${MASTER_LOG}"
    
    # Try to capture container logs
    {
        echo "========================================"
        echo "EMERGENCY LOG CAPTURE"
        echo "Failed at line: ${line_no}"
        echo "Exit code: ${exit_code}"
        echo "Timestamp: $(date)"
        echo "========================================"
        echo ""
        echo "=== Docker PS ==="
        docker ps -a 2>&1 || echo "docker ps failed"
        echo ""
        echo "=== Container Logs ==="
        docker logs "${CONTAINER_NAME}" 2>&1 || echo "No container logs available"
        echo ""
        echo "=== Docker Compose Logs ==="
        docker compose -f "${COMPOSE_FILE}" logs 2>&1 || echo "No compose logs available"
    } >> "${LOGS_DIR}/emergency_$(date +%Y%m%d_%H%M%S).log" 2>&1
    
    echo "[ERROR] Emergency logs saved to ${LOGS_DIR}/" | tee -a "${MASTER_LOG}"
}

# Set up error trap
trap 'on_error ${LINENO}' ERR

# -----------------------------------------------------------------------------
# Logging (all output goes to both console and master log)
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${MASTER_LOG}"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*" | tee -a "${MASTER_LOG}"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*" | tee -a "${MASTER_LOG}"
}

log_warn() {
    echo -e "${YELLOW}[SKIP]${NC} $*" | tee -a "${MASTER_LOG}"
}

log_header() {
    echo "" | tee -a "${MASTER_LOG}"
    echo -e "${BLUE}========================================${NC}" | tee -a "${MASTER_LOG}"
    echo -e "${BLUE}$*${NC}" | tee -a "${MASTER_LOG}"
    echo -e "${BLUE}========================================${NC}" | tee -a "${MASTER_LOG}"
}

# -----------------------------------------------------------------------------
# Setup and Teardown
# -----------------------------------------------------------------------------
cleanup_existing() {
    log_info "Cleaning up any existing containers"
    
    cd "${PROJECT_ROOT}"
    
    # Stop and remove any existing containers
    docker compose -f docker-compose.test.yml down -v 2>/dev/null || true
    docker compose down -v 2>/dev/null || true
    docker rm -f valheim-server 2>/dev/null || true
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    
    # Remove any orphaned networks
    docker network prune -f 2>/dev/null || true
    
    # Wait for ports to be released
    sleep 2
}

setup_test_environment() {
    log_header "Setting up test environment"
    
    # First cleanup any existing resources
    cleanup_existing
    
    cd "${PROJECT_ROOT}"

    # Create data directories
    mkdir -p data/config data/server data/logs
    
    # Export USE_BIND_MOUNTS for docker-compose only if it's "true"
    # When unset, docker-compose will use the default named volumes
    if [[ "${USE_BIND_MOUNTS}" == "true" ]]; then
        export USE_BIND_MOUNTS
    else
        unset USE_BIND_MOUNTS
    fi
    
    # Build the container
    log_info "Building Docker image"
    docker compose -f "${COMPOSE_FILE}" build --no-cache
    
    log_success "Test environment ready"
}

cleanup_test_environment() {
    log_header "Cleaning up test environment"
    
    cd "${PROJECT_ROOT}"
    
    # Export logs before cleanup (in case we're exiting unexpectedly)
    if docker inspect "${CONTAINER_NAME}" &>/dev/null; then
        export_logs "cleanup_final"
    fi
    
    # Stop and remove containers
    docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

    # Remove test volumes (only if not using bind mounts)
    if [[ "${USE_BIND_MOUNTS}" != "true" ]]; then
        docker volume rm valheim-test-config valheim-test-server 2>/dev/null || true
    fi
    
    log_success "Cleanup complete"
}

# -----------------------------------------------------------------------------
# Container Management
# -----------------------------------------------------------------------------
start_container() {
    log_info "Starting test container"
    
    cd "${PROJECT_ROOT}"
    
    # Start container with test config
    docker compose -f "${COMPOSE_FILE}" up -d
    
    # Wait for container to be running
    local attempts=0
    while [[ $(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null) != "true" ]]; do
        if [[ ${attempts} -ge 30 ]]; then
            log_error "Container failed to start"
            docker compose -f "${COMPOSE_FILE}" logs
            return 1
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    
    log_success "Container started"
}

stop_container() {
    log_info "Stopping test container"
    
    cd "${PROJECT_ROOT}"
    docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
    
    log_success "Container stopped"
}

get_container_logs() {
    docker logs "${CONTAINER_NAME}" 2>&1
}

export_logs() {
    local test_name="${1:-final}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="${LOGS_DIR}/${timestamp}_${test_name}.log"
    
    log_info "Exporting logs to ${log_file}"
    mkdir -p "${LOGS_DIR}"
    
    {
        echo "========================================"
        echo "Test: ${test_name}"
        echo "Timestamp: $(date)"
        echo "========================================"
        echo ""
        echo "=== Container Logs ==="
        docker logs "${CONTAINER_NAME}" 2>&1 || echo "No container logs available"
        echo ""
        echo "=== Container Inspect ==="
        docker inspect "${CONTAINER_NAME}" 2>&1 || echo "Container not found"
    } > "${log_file}" 2>&1
    
    log_success "Logs exported to ${log_file}"
}

# -----------------------------------------------------------------------------
# Test Execution
# -----------------------------------------------------------------------------
run_test() {
    local test_name="$1"
    local test_script="${E2E_DIR}/test_${test_name}.sh"
    
    if [[ ! -f "${test_script}" ]]; then
        log_warn "Test not found: ${test_name}"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        return 0
    fi
    
    log_header "Running test: ${test_name}"
    
    # Make script executable
    chmod +x "${test_script}"
    
    # Run test with timeout
    local start_time
    start_time=$(date +%s)
    
    if timeout "${TEST_TIMEOUT}" bash "${test_script}"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log_success "Test passed: ${test_name} (${duration}s)"
        
        # Export logs for passed tests too (for debugging)
        export_logs "${test_name}_PASSED"
        
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        local exit_code=$?
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ ${exit_code} -eq 124 ]]; then
            log_error "Test timed out: ${test_name} (${duration}s)"
        else
            log_error "Test failed: ${test_name} (exit code: ${exit_code}, ${duration}s)"
        fi
        
        # Capture container logs on failure
        log_info "=== Container Logs (last 100 lines) ==="
        docker logs "${CONTAINER_NAME}" --tail 100 2>&1 || true
        log_info "=== End Container Logs ==="
        
        # Export full logs to file for debugging
        export_logs "${test_name}_FAILED"
        
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("${test_name}")
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Test Suite
# -----------------------------------------------------------------------------
ALL_TESTS=(
    "server_start"
    "server_query"
    "backup"
    "graceful_shutdown"
    "restart_update"
)

run_all_tests() {
    local specific_test="$1"
    
    # Setup
    setup_test_environment
    
    # Trap cleanup on exit
    trap cleanup_test_environment EXIT
    
    # Start container for tests
    start_container
    
    # Run tests
    if [[ -n "${specific_test}" ]]; then
        run_test "${specific_test}"
    else
        for test in "${ALL_TESTS[@]}"; do
            run_test "${test}" || true  # Continue even if test fails
        done
    fi
    
    # Export final logs
    export_logs "final_summary"
    
    # Print summary
    print_summary
}

print_summary() {
    log_header "Test Summary"
    
    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    
    echo ""
    echo -e "  ${GREEN}Passed:${NC}  ${TESTS_PASSED}"
    echo -e "  ${RED}Failed:${NC}  ${TESTS_FAILED}"
    echo -e "  ${YELLOW}Skipped:${NC} ${TESTS_SKIPPED}"
    echo -e "  Total:   ${total}"
    echo ""
    
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo -e "${RED}Failed tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  - ${test}"
        done
        echo ""
    fi
    
    if [[ ${TESTS_FAILED} -gt 0 ]]; then
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}TESTS FAILED${NC}"
        echo -e "${RED}========================================${NC}"
        return 1
    else
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        echo -e "${GREEN}========================================${NC}"
        return 0
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_header "Absolute Valheim Server - E2E Test Suite"
    log_info "Master log: ${MASTER_LOG}"
    
    # Check dependencies
    if ! command -v docker &> /dev/null; then
        log_error "Docker is required but not installed"
        exit 1
    fi
    
    if ! command -v docker compose &> /dev/null; then
        log_error "Docker Compose is required but not installed"
        exit 1
    fi
    
    # Run tests
    local result=0
    run_all_tests "$1" || result=$?
    
    log_info "Logs saved to: ${LOGS_DIR}/"
    log_info "Master log: ${MASTER_LOG}"
    
    # Keep window open if running interactively
    if [[ -t 0 ]]; then
        echo ""
        echo "Press Enter to close..."
        read -r
    fi
    
    return ${result}
}

# Run main
main "$@"
