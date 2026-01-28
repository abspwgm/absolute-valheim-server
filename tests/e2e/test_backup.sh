#!/bin/bash
# =============================================================================
# E2E Test: Backup
# Verifies that the backup system creates valid backups
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="backup"

# -----------------------------------------------------------------------------
# Test: Backup
# -----------------------------------------------------------------------------
test_backup() {
    log_test_start "${TEST_NAME}"
    
    # Verify container is running
    assert_container_running "valheim-server"
    
    # Wait for server to be ready and world to be generated
    log_info "Waiting for server to generate world files"
    if ! wait_for_log "valheim-server" "Game server connected" 300; then
        log_warn "Server may not be fully ready"
    fi
    
    # Give server time to generate world
    log_info "Waiting for world generation (30 seconds)"
    sleep 30
    
    # Check if world files exist
    log_info "Checking for world files"
    local world_name="${WORLD_NAME:-TestWorld}"
    
    # Use MSYS_NO_PATHCONV=1 to avoid Git Bash path conversion on Windows
    if MSYS_NO_PATHCONV=1 docker exec valheim-server test -f "/config/worlds_local/${world_name}.fwl" || \
       MSYS_NO_PATHCONV=1 docker exec valheim-server test -f "/config/worlds_local/${world_name}.db"; then
        log_info "World files found"
    else
        log_warn "World files not yet created, listing worlds_local directory"
        MSYS_NO_PATHCONV=1 docker exec valheim-server ls -la /config/worlds_local/ 2>/dev/null || true
        
        # World might not be created until first player joins
        # Create a dummy world file for testing backup functionality
        log_info "Creating test world files for backup verification"
        MSYS_NO_PATHCONV=1 docker exec valheim-server mkdir -p /config/worlds_local
        MSYS_NO_PATHCONV=1 docker exec valheim-server touch "/config/worlds_local/${world_name}.fwl"
        MSYS_NO_PATHCONV=1 docker exec valheim-server sh -c "echo 'test' > '/config/worlds_local/${world_name}.db'"
    fi
    
    # Trigger manual backup
    log_info "Triggering manual backup"
    # Use MSYS_NO_PATHCONV=1 to prevent Git Bash from converting paths on Windows
    MSYS_NO_PATHCONV=1 docker exec valheim-server /opt/valheim/scripts/valheim-backup --force
    
    # Wait for backup to complete
    sleep 5
    
    # Check if backup was created
    log_info "Checking for backup files"
    local backup_dir="/config/backups"
    
    local backup_count
    backup_count=$(MSYS_NO_PATHCONV=1 docker exec valheim-server find "${backup_dir}" -name 'valheim_*.zip' -o -name 'valheim_*.tar.gz' 2>/dev/null | wc -l)
    
    if [[ ${backup_count} -gt 0 ]]; then
        log_success "Backup created successfully (${backup_count} backup(s) found)"
        
        # List backups
        log_info "Backup files:"
        MSYS_NO_PATHCONV=1 docker exec valheim-server ls -lh "${backup_dir}/" 2>/dev/null || true
        
        # Verify backup contains expected files
        log_info "Verifying backup contents"
        local latest_backup
        latest_backup=$(MSYS_NO_PATHCONV=1 docker exec valheim-server sh -c "ls -t '${backup_dir}'/valheim_*.zip 2>/dev/null | head -1")
        
        if [[ -n "${latest_backup}" ]]; then
            local backup_contents
            backup_contents=$(MSYS_NO_PATHCONV=1 docker exec valheim-server unzip -l "${latest_backup}" 2>/dev/null || true)
            
            if echo "${backup_contents}" | grep -qE "\.(db|fwl)"; then
                log_success "Backup contains world files"
            else
                log_warn "Backup may not contain world files"
                echo "${backup_contents}"
            fi
        fi
        
        log_test_pass "${TEST_NAME}"
        return 0
    else
        log_error "No backup files found"
        MSYS_NO_PATHCONV=1 docker exec valheim-server ls -la "${backup_dir}/" 2>/dev/null || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
}

# Run test
test_backup
