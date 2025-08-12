#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Fix Log Permissions Script
#
# This script fixes the root cause of the bridge daemon restart issue:
# Permission denied when trying to write to /var/log/sigul_*.log
#
# The issue: Sigul daemons try to write to /var/log/ but the sigul user
# (UID 1000) doesn't have write permissions to that directory.
#
# Solutions implemented:
# 1. Create /var/log with proper permissions in Dockerfiles
# 2. Modify sigul daemon startup to use correct log directories
# 3. Add runtime fixes for existing containers
#
# Usage:
#   ./debug/fix-log-permissions.sh [OPTIONS]
#
# Options:
#   --dockerfile-fix    Generate Dockerfile patches
#   --runtime-fix       Fix running containers
#   --test             Test the fix
#   --help             Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default options
DOCKERFILE_FIX=false
RUNTIME_FIX=false
TEST_FIX=false
SHOW_HELP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $*"
}

section() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] SECTION:${NC} $*"
}

# Help function
show_help() {
    cat << EOF
Fix Log Permissions Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --dockerfile-fix    Generate Dockerfile patches to fix log permissions
    --runtime-fix       Fix permissions in currently running containers
    --test             Test the fix by starting containers
    --help             Show this help message

DESCRIPTION:
    This script fixes the root cause of the Sigul bridge daemon restart issue:

    **Root Cause**: Sigul daemons try to write to /var/log/sigul_*.log and
    /var/run/sigul_*.pid but the sigul user (UID 1000) doesn't have write
    permissions to these directories.

    **Errors**:
    - PermissionError: [Errno 13] Permission denied: '/var/log/sigul_bridge.log'
    - PermissionError: [Errno 13] Permission denied: '/var/run/sigul_bridge.pid'

    **Solutions**:
    1. Create /var/log and /var/run with proper permissions in Dockerfiles
    2. Ensure sigul user can write to log and PID directories
    3. Provide runtime fixes for existing containers

EXAMPLES:
    # Generate and apply Dockerfile fixes
    $0 --dockerfile-fix

    # Fix running containers
    $0 --runtime-fix

    # Test the fix
    $0 --test

    # Apply all fixes
    $0 --dockerfile-fix --test

BACKGROUND:
    The issue was discovered when containers would start successfully, complete
    all initialization (certificates, configs, NSS setup), but then crash
    immediately when the daemon tried to setup logging to /var/log/*.log files.

    This caused Docker to restart the containers in an endless loop.
EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dockerfile-fix)
                DOCKERFILE_FIX=true
                shift
                ;;
            --runtime-fix)
                RUNTIME_FIX=true
                shift
                ;;
            --test)
                TEST_FIX=true
                shift
                ;;
            --help)
                SHOW_HELP=true
                shift
                ;;
            *)
                error "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ "${SHOW_HELP}" == "true" ]]; then
        show_help
        exit 0
    fi

    # Default action if no options specified
    if [[ "${DOCKERFILE_FIX}" == "false" && "${RUNTIME_FIX}" == "false" && "${TEST_FIX}" == "false" ]]; then
        log "No specific action requested. Use --help for options."
        log "Defaulting to --dockerfile-fix --test"
        DOCKERFILE_FIX=true
        TEST_FIX=true
    fi
}

# Generate Dockerfile fixes
generate_dockerfile_fixes() {
    section "Generating Dockerfile fixes for log permissions"

    local dockerfiles=("Dockerfile.server" "Dockerfile.bridge")
    local backup_dir="${PROJECT_ROOT}/debug/dockerfile-backups"

    # Create backup directory
    mkdir -p "$backup_dir"

    for dockerfile in "${dockerfiles[@]}"; do
        local dockerfile_path="${PROJECT_ROOT}/$dockerfile"

        if [[ ! -f "$dockerfile_path" ]]; then
            warn "Dockerfile not found: $dockerfile"
            continue
        fi

        log "Processing $dockerfile..."

        # Create backup
        local backup_file="${backup_dir}/${dockerfile}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$dockerfile_path" "$backup_file"
        log "Backup created: $backup_file"

        # Check if fix is already applied
        if grep -q "RUN mkdir -p /var/log" "$dockerfile_path"; then
            success "Log and PID directory fix already applied to $dockerfile"
            continue
        fi

        # Apply the fix by adding log and PID directory setup before USER command
        local temp_file
        temp_file=$(mktemp)

        # Find the USER sigul line and add directory setup before it
        awk '
        /^USER sigul/ {
            print "# Fix log and PID file permissions - create directories with proper ownership"
            print "RUN mkdir -p /var/log /var/run && \\"
            print "    chown sigul:sigul /var/log /var/run && \\"
            print "    chmod 755 /var/log /var/run"
            print ""
        }
        { print }
        ' "$dockerfile_path" > "$temp_file"

        # Verify the change was made
        if grep -q "RUN mkdir -p /var/log /var/run" "$temp_file"; then
            mv "$temp_file" "$dockerfile_path"
            success "✅ Applied log and PID directory fix to $dockerfile"

            # Show the changes
            log "Changes made to $dockerfile:"
            echo "  + RUN mkdir -p /var/log /var/run && \\"
            echo "  +     chown sigul:sigul /var/log /var/run && \\"
            echo "  +     chmod 755 /var/log /var/run"
        else
            error "Failed to apply fix to $dockerfile"
            rm -f "$temp_file"
        fi
    done

    success "Dockerfile fixes generated"
}

# Fix runtime permissions in running containers
fix_runtime_permissions() {
    section "Fixing log permissions in running containers"

    local containers=("sigul-server" "sigul-bridge")
    local fixes_applied=0

    for container in "${containers[@]}"; do
        if docker ps --filter "name=$container" --filter "status=running" | grep -q "$container"; then
            log "Fixing permissions in running container: $container"

            # Create /var/log and /var/run with proper permissions
            if docker exec "$container" bash -c "
                mkdir -p /var/log /var/run &&
                chown sigul:sigul /var/log /var/run &&
                chmod 755 /var/log /var/run &&
                echo 'Log and PID directory permissions fixed'
            " 2>/dev/null; then
                success "✅ Fixed log and PID permissions in $container"
                ((fixes_applied++))
            else
                error "Failed to fix permissions in $container"
            fi

            # Restart the container to apply the fix
            log "Restarting $container to apply permission fix..."
            if docker restart "$container" >/dev/null 2>&1; then
                log "Container $container restarted"
            else
                warn "Failed to restart $container"
            fi
        else
            warn "Container $container is not running"
        fi
    done

    if [[ $fixes_applied -gt 0 ]]; then
        success "Applied runtime fixes to $fixes_applied container(s)"
        log "Waiting 10 seconds for containers to restart..."
        sleep 10

        # Check status after restart
        for container in "${containers[@]}"; do
            local status
            status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
            log "$container status after restart: $status"
        done
    else
        warn "No runtime fixes were applied"
    fi
}

# Test the fix
test_fix() {
    section "Testing the log permissions fix"

    # Clean up any existing containers
    log "Cleaning up existing containers..."
    docker compose -f "${PROJECT_ROOT}/docker-compose.sigul.yml" down --remove-orphans 2>/dev/null || true

    # Set up environment variables
    export SIGUL_SERVER_IMAGE="server-linux-amd64-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-linux-amd64-image:test"
    export NSS_PASSWORD="test_fix_$(date +%s)"
    export SIGUL_ADMIN_PASSWORD="test_fix_admin_$(date +%s)"
    export DEBUG="true"

    log "Building test images with fix..."

    # Build server image
    if docker build --file "${PROJECT_ROOT}/Dockerfile.server" --tag "$SIGUL_SERVER_IMAGE" "${PROJECT_ROOT}"; then
        success "✅ Built server image with fix"
    else
        error "❌ Failed to build server image"
        return 1
    fi

    # Build bridge image
    if docker build --file "${PROJECT_ROOT}/Dockerfile.bridge" --tag "$SIGUL_BRIDGE_IMAGE" "${PROJECT_ROOT}"; then
        success "✅ Built bridge image with fix"
    else
        error "❌ Failed to build bridge image"
        return 1
    fi

    log "Starting containers with fixed images..."
    cd "${PROJECT_ROOT}"
    docker compose -f docker-compose.sigul.yml up -d sigul-server sigul-bridge

    # Monitor for 60 seconds to see if restart issue is resolved
    log "Monitoring containers for 60 seconds to verify fix..."
    local start_time
    start_time=$(date +%s)
    local end_time=$((start_time + 60))

    while [[ $(date +%s) -lt $end_time ]]; do
        local server_status
        server_status=$(docker inspect --format='{{.State.Status}}' sigul-server 2>/dev/null || echo "not_found")
        local bridge_status
        bridge_status=$(docker inspect --format='{{.State.Status}}' sigul-bridge 2>/dev/null || echo "not_found")

        local server_restarts
        server_restarts=$(docker inspect --format='{{.RestartCount}}' sigul-server 2>/dev/null || echo "0")
        local bridge_restarts
        bridge_restarts=$(docker inspect --format='{{.RestartCount}}' sigul-bridge 2>/dev/null || echo "0")

        if [[ "$server_status" == "running" && "$bridge_status" == "running" && "$server_restarts" == "0" && "$bridge_restarts" == "0" ]]; then
            local elapsed=$(($(date +%s) - start_time))
            if [[ $elapsed -ge 30 ]]; then  # Must be stable for at least 30 seconds
                success "🎉 FIX SUCCESSFUL! Containers have been running stable for ${elapsed} seconds"
                success "✅ Server: $server_status (restarts: $server_restarts)"
                success "✅ Bridge: $bridge_status (restarts: $bridge_restarts)"

                # Test connectivity
                if nc -z localhost 44334 2>/dev/null; then
                    success "✅ Bridge port 44334 is accessible"
                else
                    warn "Bridge port 44334 is not accessible (may still be starting)"
                fi

                # Show recent logs to confirm no permission errors
                log "Recent logs (should show no permission errors):"
                echo "=== SERVER LOGS ==="
                docker logs sigul-server --tail 10
                echo "=== BRIDGE LOGS ==="
                docker logs sigul-bridge --tail 10

                # Cleanup
                log "Cleaning up test containers..."
                docker compose -f docker-compose.sigul.yml down --remove-orphans

                success "🎯 ROOT CAUSE FIXED: Log permission issue resolved!"
                return 0
            fi
        else
            # Check if restart loop is still happening
            if [[ "$server_restarts" -gt "0" || "$bridge_restarts" -gt "0" ]]; then
                error "❌ Restart loop still occurring after fix attempt"
                error "Server: $server_status (restarts: $server_restarts)"
                error "Bridge: $bridge_status (restarts: $bridge_restarts)"

                log "Checking logs for remaining issues:"
                echo "=== SERVER LOGS ==="
                docker logs sigul-server --tail 20
                echo "=== BRIDGE LOGS ==="
                docker logs sigul-bridge --tail 20

                docker compose -f docker-compose.sigul.yml down --remove-orphans
                return 1
            fi
        fi

        sleep 5
    done

    error "❌ Test timeout - containers did not stabilize within 60 seconds"

    # Show final status
    local server_status
    server_status=$(docker inspect --format='{{.State.Status}}' sigul-server 2>/dev/null || echo "not_found")
    local bridge_status
    bridge_status=$(docker inspect --format='{{.State.Status}}' sigul-bridge 2>/dev/null || echo "not_found")

    log "Final status:"
    log "Server: $server_status"
    log "Bridge: $bridge_status"

    docker compose -f docker-compose.sigul.yml down --remove-orphans
    return 1
}

# Show current status
show_current_status() {
    section "Current Status"

    log "=== Dockerfile Status ==="
    local dockerfiles=("Dockerfile.server" "Dockerfile.bridge")
    for dockerfile in "${dockerfiles[@]}"; do
        if [[ -f "${PROJECT_ROOT}/$dockerfile" ]]; then
            if grep -q "RUN mkdir -p /var/log" "${PROJECT_ROOT}/$dockerfile"; then
                success "✅ $dockerfile: Log and PID fix APPLIED"
            else
                warn "⚠️  $dockerfile: Log and PID fix NOT applied"
            fi
        else
            error "❌ $dockerfile: File not found"
        fi
    done

    log ""
    log "=== Running Containers ==="
    if docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -q sigul; then
        docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

        # Check restart counts
        local containers=("sigul-server" "sigul-bridge")
        for container in "${containers[@]}"; do
            if docker ps --filter "name=$container" | grep -q "$container"; then
                local restarts
                restarts=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "unknown")
                if [[ "$restarts" == "0" ]]; then
                    success "$container: 0 restarts ✅"
                else
                    error "$container: $restarts restarts ❌"
                fi
            fi
        done
    else
        log "No sigul containers currently running"
    fi
}

# Main function
main() {
    parse_arguments "$@"

    section "=== Sigul Log Permissions Fix ==="
    log "Fixing the root cause of bridge daemon restart issues"
    log ""

    show_current_status

    if [[ "${DOCKERFILE_FIX}" == "true" ]]; then
        generate_dockerfile_fixes
    fi

    if [[ "${RUNTIME_FIX}" == "true" ]]; then
        fix_runtime_permissions
    fi

    if [[ "${TEST_FIX}" == "true" ]]; then
        test_fix
        local test_result=$?

        if [[ $test_result -eq 0 ]]; then
            success "🎉 SUCCESS: The log permissions fix has resolved the restart issue!"
            log ""
            log "Summary of what was fixed:"
            log "• Root cause: Permission denied writing to /var/log/sigul_*.log and /var/run/sigul_*.pid"
            log "• Solution: Created /var/log and /var/run with proper sigul user permissions"
            log "• Result: Containers now start and remain stable"
        else
            error "❌ Test failed - additional investigation needed"
        fi

        return $test_result
    fi

    section "=== Fix Complete ==="
    success "Log permissions fix has been applied"
    log ""
    log "Next steps:"
    log "1. Test with: $0 --test"
    log "2. Commit the Dockerfile changes"
    log "3. Run containers to verify fix"
}

# Execute main function with all arguments
main "$@"
