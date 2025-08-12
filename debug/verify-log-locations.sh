#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Log Location Verification Script
#
# This script verifies where the bridge daemon actually writes its logs
# and whether the expected log file location is correct.
#
# Usage:
#   ./debug/verify-log-locations.sh

set -euo pipefail

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
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $*"
}

section() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] SECTION:${NC} $*"
}

# Check if containers are running
check_containers() {
    local containers=("sigul-bridge" "sigul-server")
    local running_containers=()

    for container in "${containers[@]}"; do
        if docker ps --filter "name=$container" --filter "status=running" | grep -q "$container"; then
            running_containers+=("$container")
        fi
    done

    if [[ ${#running_containers[@]} -eq 0 ]]; then
        error "No sigul containers are running"
        log "Available containers:"
        docker ps -a --filter "name=sigul"
        return 1
    fi

    success "Found running containers: ${running_containers[*]}"
    echo "${running_containers[@]}"
}

# Verify log locations for a container
verify_container_logs() {
    local container="$1"

    section "Verifying log locations for $container"

    # Check if container is running
    if ! docker ps --filter "name=$container" --filter "status=running" | grep -q "$container"; then
        error "Container $container is not running"
        return 1
    fi

    # Expected log locations based on configuration
    local expected_log_dir="/var/sigul/logs/${container#sigul-}"
    local expected_log_file="${expected_log_dir}/daemon.log"
    local expected_sigul_log="${expected_log_dir}/sigul_${container#sigul-}.log"

    log "Expected log directory: $expected_log_dir"
    log "Expected daemon log: $expected_log_file"
    log "Expected sigul log: $expected_sigul_log"

    echo ""
    log "=== Checking log directory structure ==="

    # Check if log directory exists
    if docker exec "$container" test -d "$expected_log_dir" 2>/dev/null; then
        success "Log directory exists: $expected_log_dir"

        # List contents
        log "Directory contents:"
        docker exec "$container" ls -la "$expected_log_dir" 2>/dev/null || warn "Cannot list directory contents"

        # Check file sizes
        log "File sizes:"
        docker exec "$container" find "$expected_log_dir" -type f -exec ls -lh {} \; 2>/dev/null || warn "Cannot check file sizes"

    else
        error "Log directory does not exist: $expected_log_dir"
    fi

    echo ""
    log "=== Checking specific log files ==="

    # Check expected daemon log
    if docker exec "$container" test -f "$expected_log_file" 2>/dev/null; then
        local file_size
        file_size=$(docker exec "$container" stat -c%s "$expected_log_file" 2>/dev/null || echo "unknown")

        if [[ "$file_size" == "0" ]]; then
            warn "Daemon log file exists but is empty: $expected_log_file"
        else
            success "Daemon log file exists and has content: $expected_log_file (${file_size} bytes)"

            log "Last 10 lines of daemon log:"
            docker exec "$container" tail -10 "$expected_log_file" 2>/dev/null || warn "Cannot read daemon log"
        fi
    else
        error "Expected daemon log file does not exist: $expected_log_file"
    fi

    # Check expected sigul log
    if docker exec "$container" test -f "$expected_sigul_log" 2>/dev/null; then
        local file_size
        file_size=$(docker exec "$container" stat -c%s "$expected_sigul_log" 2>/dev/null || echo "unknown")

        if [[ "$file_size" == "0" ]]; then
            warn "Sigul log file exists but is empty: $expected_sigul_log"
        else
            success "Sigul log file exists and has content: $expected_sigul_log (${file_size} bytes)"

            log "Last 10 lines of sigul log:"
            docker exec "$container" tail -10 "$expected_sigul_log" 2>/dev/null || warn "Cannot read sigul log"
        fi
    else
        error "Expected sigul log file does not exist: $expected_sigul_log"
    fi

    echo ""
    log "=== Searching for actual log files ==="

    # Search for any log files in the container
    log "Searching for *.log files in /var/sigul:"
    docker exec "$container" find /var/sigul -name "*.log" -type f 2>/dev/null | while read -r logfile; do
        local size
        size=$(docker exec "$container" stat -c%s "$logfile" 2>/dev/null || echo "unknown")
        log "Found: $logfile (${size} bytes)"

        # Show content if small enough
        if [[ "$size" != "unknown" ]] && [[ $size -gt 0 ]] && [[ $size -lt 1000 ]]; then
            log "Content of $logfile:"
            docker exec "$container" cat "$logfile" 2>/dev/null | sed 's/^/  /' || true
        fi
    done

    # Search for daemon processes and their output
    log "Searching for running daemon processes:"
    docker exec "$container" ps aux | grep -E "(sigul|bridge|server)" | grep -v grep || warn "No sigul processes found"

    echo ""
    log "=== Checking where daemon might be logging ==="

    # Check common log locations
    local common_locations=(
        "/var/log"
        "/tmp"
        "/var/sigul"
        "/var/sigul/logs"
        "/var/sigul/tmp"
    )

    for location in "${common_locations[@]}"; do
        if docker exec "$container" test -d "$location" 2>/dev/null; then
            log "Checking $location for recent files:"
            docker exec "$container" find "$location" -name "*sigul*" -o -name "*bridge*" -o -name "*daemon*" 2>/dev/null | head -10 || true

            # Check for recent files (modified in last hour)
            log "Recent files in $location (last hour):"
            docker exec "$container" find "$location" -type f -mmin -60 2>/dev/null | head -10 || true
        fi
    done

    echo ""
    log "=== Checking daemon command line and file descriptors ==="

    # Find the daemon process
    local daemon_pid
    daemon_pid=$(docker exec "$container" pgrep -f "sigul.*${container#sigul-}" 2>/dev/null || echo "")

    if [[ -n "$daemon_pid" ]]; then
        success "Found daemon process PID: $daemon_pid"

        # Check command line
        log "Daemon command line:"
        docker exec "$container" cat "/proc/$daemon_pid/cmdline" 2>/dev/null | tr '\0' ' ' || warn "Cannot read command line"
        echo ""

        # Check file descriptors
        log "Daemon file descriptors:"
        docker exec "$container" ls -la "/proc/$daemon_pid/fd/" 2>/dev/null || warn "Cannot read file descriptors"

        # Check working directory
        log "Daemon working directory:"
        docker exec "$container" readlink "/proc/$daemon_pid/cwd" 2>/dev/null || warn "Cannot read working directory"

    else
        error "Cannot find daemon process for $container"
    fi

    echo ""
    log "=== Checking container stdout/stderr logs ==="

    # Check Docker logs (what we see in docker logs)
    log "Recent Docker logs (last 20 lines):"
    docker logs --tail 20 "$container" 2>&1 | sed 's/^/  /'

    echo ""
    log "=== Configuration analysis ==="

    # Check daemon configuration
    local config_file="/var/sigul/config/${container#sigul-}.conf"
    if docker exec "$container" test -f "$config_file" 2>/dev/null; then
        log "Checking configuration file: $config_file"
        log "Log-related configuration:"
        docker exec "$container" grep -i -E "(log|debug|verbose)" "$config_file" 2>/dev/null || warn "No log configuration found"
    else
        warn "Configuration file not found: $config_file"
    fi
}

# Check if daemon is actually writing logs where expected
check_log_write_behavior() {
    section "Testing live log writing behavior"

    local container="sigul-bridge"

    if ! docker ps --filter "name=$container" --filter "status=running" | grep -q "$container"; then
        error "Bridge container is not running - cannot test log writing"
        return 1
    fi

    local expected_log_dir="/var/sigul/logs/bridge"
    local expected_daemon_log="$expected_log_dir/daemon.log"

    log "Monitoring $expected_daemon_log for new writes..."

    # Get initial file size
    local initial_size
    if docker exec "$container" test -f "$expected_daemon_log" 2>/dev/null; then
        initial_size=$(docker exec "$container" stat -c%s "$expected_daemon_log" 2>/dev/null || echo "0")
    else
        initial_size="0"
        warn "Expected log file does not exist: $expected_daemon_log"
    fi

    log "Initial log file size: $initial_size bytes"

    # Monitor for 30 seconds
    log "Monitoring for 30 seconds to see if log file grows..."
    sleep 30

    # Check final size
    local final_size
    if docker exec "$container" test -f "$expected_daemon_log" 2>/dev/null; then
        final_size=$(docker exec "$container" stat -c%s "$expected_daemon_log" 2>/dev/null || echo "0")
    else
        final_size="0"
    fi

    log "Final log file size: $final_size bytes"

    if [[ $final_size -gt $initial_size ]]; then
        success "Log file is actively being written to! (grew by $((final_size - initial_size)) bytes)"

        # Show new content
        if [[ $((final_size - initial_size)) -lt 1000 ]]; then
            log "New content:"
            docker exec "$container" tail -c "+$((initial_size + 1))" "$expected_daemon_log" 2>/dev/null | sed 's/^/  /' || true
        fi
    elif [[ $final_size -eq $initial_size ]] && [[ $initial_size -gt 0 ]]; then
        warn "Log file exists but is not growing (daemon may not be actively logging)"
    else
        error "Log file is not being written to or does not exist"

        # Check if the daemon is writing elsewhere
        log "Checking if daemon is writing to other locations..."

        # Monitor all files in /var/sigul for changes
        log "Files modified in /var/sigul in the last 5 minutes:"
        docker exec "$container" find /var/sigul -type f -mmin -5 2>/dev/null || warn "Cannot check recent files"
    fi
}

# Main function
main() {
    section "=== Sigul Log Location Verification ==="
    log "Verifying where bridge and server daemons actually write their logs"
    log ""

    # Check which containers are running
    local running_containers
    if ! running_containers=($(check_containers)); then
        exit 1
    fi

    echo ""

    # Verify logs for each running container
    for container in "${running_containers[@]}"; do
        verify_container_logs "$container"
        echo ""
    done

    # Test live log writing behavior
    check_log_write_behavior

    section "=== Log Location Verification Complete ==="

    log ""
    log "SUMMARY:"
    log "1. Check the output above to see where logs are actually being written"
    log "2. If expected log files are empty, the daemon may be logging elsewhere"
    log "3. Docker logs (stdout/stderr) always show container output"
    log "4. The daemon might be configured to log to syslog or other destinations"
    log ""
    log "TROUBLESHOOTING:"
    log "- If no log files are found, the daemon may log only to stdout/stderr"
    log "- If log files exist but are empty, check daemon configuration"
    log "- If daemon crashes immediately, logs may not have time to be written"
    log "- Check crash diagnostics to capture the exact moment of failure"
}

# Execute main function
main "$@"
