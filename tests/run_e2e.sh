#!/bin/bash
# =============================================================================
# E2E Test Runner - Executes all end-to-end tests
# =============================================================================
# Usage: ./tests/run_e2e.sh [test_name]
#   - No arguments: runs all tests
#   - With argument: runs specific test (e.g., ./tests/run_e2e.sh server_start)
# =============================================================================

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
E2E_DIR="${SCRIPT_DIR}/e2e"

# Test configuration
CONTAINER_NAME="valheim-server"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.test.yml"
ENV_FILE="${PROJECT_ROOT}/.env.test"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"  # 10 minutes default
STARTUP_WAIT="${STARTUP_WAIT:-300}"  # 5 minutes for server startup

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
    echo -e "${YELLOW}[SKIP]${NC} $*"
}

log_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# -----------------------------------------------------------------------------
# Setup and Teardown
# -----------------------------------------------------------------------------
cleanup_existing() {
    log_info "Cleaning up any existing containers"
    
    cd "${PROJECT_ROOT}"
    
    # Stop and remove any existing containers
    docker compose -f docker-compose.yml --env-file .env.test down -v 2>/dev/null || true
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
    
    # Create test .env file
    log_info "Creating test configuration"
    cat > .env.test << EOF
SERVER_NAME=E2E Test Server
SERVER_PORT=2456
WORLD_NAME=TestWorld
SERVER_PASS=testpass123
SERVER_PUBLIC=false
CROSSPLAY=false
UPDATE_ON_START=true
UPDATE_TIMEOUT=600
BACKUPS_ENABLED=true
BACKUPS_CRON=* * * * *
PUID=1000
PGID=1000
TZ=Etc/UTC
EOF
    
    # Create data directories
    mkdir -p data/config data/server
    
    # Build the container
    log_info "Building Docker image"
    docker compose -f "${COMPOSE_FILE}" build --no-cache
    
    log_success "Test environment ready"
}

cleanup_test_environment() {
    log_header "Cleaning up test environment"
    
    cd "${PROJECT_ROOT}"
    
    # Stop and remove containers
    docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    
    # Clean up test files
    rm -f "${ENV_FILE}"
    
    # Remove test volumes
    docker volume rm valheim-test-config valheim-test-server 2>/dev/null || true
    
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
    run_all_tests "$1"
}

# Run main
main "$@"
