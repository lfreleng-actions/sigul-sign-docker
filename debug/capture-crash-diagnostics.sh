#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Comprehensive Crash Diagnostics Capture Script
#
# This script captures detailed diagnostics when the bridge daemon crashes
# or restarts, including all logs, container state, and system information.
# Designed to run in GitHub Actions and upload results as artifacts.
#
# Usage:
#   ./debug/capture-crash-diagnostics.sh [OPTIONS]
#
# Options:
#   --monitor-duration SECONDS    How long to monitor (default: 600)
#   --capture-interval SECONDS    How often to capture state (default: 5)
#   --output-dir DIR              Where to save diagnostics (default: ./crash-diagnostics)
#   --github-actions              Optimize for GitHub Actions environment
#   --verbose                     Enable verbose output
#   --help                        Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default options
MONITOR_DURATION=600  # 10 minutes
CAPTURE_INTERVAL=5    # 5 seconds
OUTPUT_DIR="${PROJECT_ROOT}/crash-diagnostics"
GITHUB_ACTIONS_MODE=false
VERBOSE_MODE=false
SHOW_HELP=false

# Colors for output (disabled in GitHub Actions)
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PURPLE=''
    CYAN=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    NC='\033[0m'
fi

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

debug() {
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

section() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] SECTION:${NC} $*"
}

# Help function
show_help() {
    cat << EOF
Comprehensive Crash Diagnostics Capture Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --monitor-duration SECONDS    How long to monitor for crashes (default: 600)
    --capture-interval SECONDS    How often to capture state (default: 5)
    --output-dir DIR              Where to save diagnostics (default: ./crash-diagnostics)
    --github-actions              Optimize for GitHub Actions environment
    --verbose                     Enable verbose output
    --help                        Show this help message

DESCRIPTION:
    This script provides comprehensive crash diagnostics by:

    1. **Real-time Log Capture**: Streams all container logs to files
    2. **State Monitoring**: Captures container state every few seconds
    3. **Crash Detection**: Detects restarts and crashes immediately
    4. **Deep Diagnostics**: Captures system state, configs, and environment
    5. **GitHub Artifacts**: Optimized for uploading to GitHub Actions

    The script creates a structured output directory with:
    - Continuous log streams from all containers
    - Container inspection data at crash time
    - System diagnostics and resource usage
    - Configuration files and environment variables
    - Network and process information

EXAMPLES:
    # Run in local environment
    $0 --verbose

    # Run in GitHub Actions
    $0 --github-actions --monitor-duration 300

    # Custom output location
    $0 --output-dir /tmp/sigul-crash-diagnostics

GITHUB ACTIONS INTEGRATION:
    Add this to your workflow after the script runs:

    - name: Upload crash diagnostics
      if: always()
      uses: actions/upload-artifact@v4
      with:
        name: sigul-crash-diagnostics
        path: crash-diagnostics/
        retention-days: 7
EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --monitor-duration)
                MONITOR_DURATION="$2"
                shift 2
                ;;
            --capture-interval)
                CAPTURE_INTERVAL="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --github-actions)
                GITHUB_ACTIONS_MODE=true
                shift
                ;;
            --verbose)
                VERBOSE_MODE=true
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

    # Validate arguments
    if ! [[ "$MONITOR_DURATION" =~ ^[0-9]+$ ]] || [[ "$MONITOR_DURATION" -lt 10 ]]; then
        error "Monitor duration must be a number >= 10 seconds"
        exit 1
    fi

    if ! [[ "$CAPTURE_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$CAPTURE_INTERVAL" -lt 1 ]]; then
        error "Capture interval must be a number >= 1 second"
        exit 1
    fi
}

# Setup output directory structure
setup_output_directory() {
    section "Setting up diagnostics output directory"

    # Create main output directory
    mkdir -p "$OUTPUT_DIR"
    chmod 755 "$OUTPUT_DIR"

    # Create subdirectories
    local subdirs=(
        "logs/continuous"
        "logs/snapshots"
        "container-state"
        "system-info"
        "configs"
        "network-info"
        "crash-events"
        "github-actions"
    )

    for subdir in "${subdirs[@]}"; do
        mkdir -p "$OUTPUT_DIR/$subdir"
        debug "Created directory: $OUTPUT_DIR/$subdir"
    done

    # Create metadata file
    cat > "$OUTPUT_DIR/metadata.json" << EOF
{
    "capture_start": "$(date -Iseconds)",
    "script_version": "1.0.0",
    "monitor_duration": $MONITOR_DURATION,
    "capture_interval": $CAPTURE_INTERVAL,
    "github_actions_mode": $GITHUB_ACTIONS_MODE,
    "environment": {
        "hostname": "$(hostname)",
        "user": "$(whoami)",
        "pwd": "$(pwd)",
        "docker_version": "$(docker --version 2>/dev/null || echo 'unknown')",
        "os": "$(uname -a)"
    }
}
EOF

    success "Output directory structure created: $OUTPUT_DIR"
}

# Capture initial system state
capture_initial_state() {
    section "Capturing initial system state"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    # System information
    {
        echo "=== SYSTEM INFORMATION ==="
        echo "Timestamp: $(date -Iseconds)"
        echo "Hostname: $(hostname)"
        echo "Uptime: $(uptime)"
        echo "Load: $(cat /proc/loadavg 2>/dev/null || echo 'unknown')"
        echo "Memory: $(free -h 2>/dev/null || echo 'unknown')"
        echo "Disk: $(df -h . 2>/dev/null || echo 'unknown')"
        echo ""

        echo "=== DOCKER INFORMATION ==="
        echo "Docker version: $(docker --version 2>/dev/null || echo 'unknown')"
        echo "Docker system info:"
        docker system info 2>/dev/null || echo "Docker system info unavailable"
        echo ""

        echo "=== DOCKER IMAGES ==="
        docker images | grep -E "(sigul|bridge|server|client)" || echo "No sigul images found"
        echo ""

        echo "=== DOCKER NETWORKS ==="
        docker network ls --filter "name=sigul" || echo "No sigul networks found"
        echo ""

        echo "=== DOCKER VOLUMES ==="
        docker volume ls --filter "name=sigul" || echo "No sigul volumes found"
        echo ""
    } > "$OUTPUT_DIR/system-info/initial_state_${timestamp}.log"

    # GitHub Actions specific information
    if [[ "${GITHUB_ACTIONS_MODE}" == "true" ]] || [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
        {
            echo "=== GITHUB ACTIONS ENVIRONMENT ==="
            echo "GITHUB_WORKFLOW: ${GITHUB_WORKFLOW:-unknown}"
            echo "GITHUB_RUN_ID: ${GITHUB_RUN_ID:-unknown}"
            echo "GITHUB_RUN_NUMBER: ${GITHUB_RUN_NUMBER:-unknown}"
            echo "GITHUB_JOB: ${GITHUB_JOB:-unknown}"
            echo "GITHUB_ACTION: ${GITHUB_ACTION:-unknown}"
            echo "GITHUB_REPOSITORY: ${GITHUB_REPOSITORY:-unknown}"
            echo "GITHUB_REF: ${GITHUB_REF:-unknown}"
            echo "GITHUB_SHA: ${GITHUB_SHA:-unknown}"
            echo "RUNNER_OS: ${RUNNER_OS:-unknown}"
            echo "RUNNER_ARCH: ${RUNNER_ARCH:-unknown}"
            echo ""

            echo "=== GITHUB ACTIONS RESOURCES ==="
            echo "Available disk space:"
            df -h /tmp /var/tmp "$HOME" . 2>/dev/null || echo "Disk info unavailable"
            echo ""
            echo "Available memory:"
            free -h 2>/dev/null || echo "Memory info unavailable"
            echo ""
            echo "CPU information:"
            nproc 2>/dev/null || echo "CPU count unavailable"
            cat /proc/cpuinfo 2>/dev/null | grep "model name" | head -1 || echo "CPU model unavailable"
            echo ""
        } > "$OUTPUT_DIR/github-actions/environment_${timestamp}.log"
    fi

    debug "Initial system state captured"
}

# Capture container configurations
capture_configurations() {
    section "Capturing container configurations"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    # Docker Compose configuration
    if [[ -f "$PROJECT_ROOT/docker-compose.sigul.yml" ]]; then
        cp "$PROJECT_ROOT/docker-compose.sigul.yml" "$OUTPUT_DIR/configs/docker-compose_${timestamp}.yml"
        debug "Captured Docker Compose configuration"
    fi

    # Container configurations (if running)
    local containers=("sigul-server" "sigul-bridge" "sigul-client-test")
    for container in "${containers[@]}"; do
        if docker ps -a --filter "name=$container" | grep -q "$container"; then
            # Container inspect
            docker inspect "$container" > "$OUTPUT_DIR/configs/${container}_inspect_${timestamp}.json" 2>/dev/null || true

            # Container environment variables
            docker exec "$container" env > "$OUTPUT_DIR/configs/${container}_env_${timestamp}.txt" 2>/dev/null || true

            # Internal configuration files (if accessible)
            if docker exec "$container" test -d /var/sigul/config 2>/dev/null; then
                docker exec "$container" find /var/sigul/config -type f -name "*.conf" -exec cat {} \; > "$OUTPUT_DIR/configs/${container}_internal_configs_${timestamp}.txt" 2>/dev/null || true
            fi

            debug "Captured configuration for $container"
        fi
    done
}

# Start continuous log capture
start_continuous_log_capture() {
    section "Starting continuous log capture"

    local containers=("sigul-server" "sigul-bridge" "sigul-client-test")
    local log_pids=()

    for container in "${containers[@]}"; do
        if docker ps --filter "name=$container" --filter "status=running" | grep -q "$container"; then
            # Start continuous log capture in background with error handling
            {
                echo "[$(date -Iseconds)] Starting continuous log capture for $container"
                timeout 3600 docker logs -f "$container" 2>&1 || echo "[$(date -Iseconds)] Log capture terminated for $container"
            } > "$OUTPUT_DIR/logs/continuous/${container}_continuous.log" 2>&1 &

            local pid=$!
            log_pids+=($pid)
            echo "$pid" > "$OUTPUT_DIR/logs/continuous/${container}_log_pid.txt"

            debug "Started continuous log capture for $container (PID: $pid)"
        fi
    done

    # Save all log PIDs for cleanup
    if [[ ${#log_pids[@]} -gt 0 ]]; then
        printf '%s\n' "${log_pids[@]}" > "$OUTPUT_DIR/logs/continuous/all_log_pids.txt"
    else
        echo "No log capture processes started" > "$OUTPUT_DIR/logs/continuous/all_log_pids.txt"
    fi

    success "Continuous log capture started for all running containers"
}

# Capture container state snapshot
capture_container_snapshot() {
    local snapshot_id="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    local containers=("sigul-server" "sigul-bridge" "sigul-client-test")

    for container in "${containers[@]}"; do
        if docker ps -a --filter "name=$container" | grep -q "$container"; then
            local snapshot_file="$OUTPUT_DIR/container-state/${container}_snapshot_${snapshot_id}_${timestamp}.json"

            # Comprehensive container state
            {
                echo "{"
                echo "  \"timestamp\": \"$(date -Iseconds)\","
                echo "  \"snapshot_id\": \"$snapshot_id\","
                echo "  \"container\": \"$container\","

                # Basic container info
                echo "  \"docker_inspect\": $(docker inspect "$container" 2>/dev/null || echo 'null'),"

                # Container stats (if running)
                if docker ps --filter "name=$container" --filter "status=running" | grep -q "$container"; then
                    echo "  \"stats\": $(docker stats --no-stream --format json "$container" 2>/dev/null || echo 'null'),"

                    # Process information
                    echo "  \"processes\": ["
                    if docker exec "$container" ps aux 2>/dev/null | tail -n +2; then
                        docker exec "$container" ps aux 2>/dev/null | tail -n +2 | while read -r line; do
                            echo "    \"$line\","
                        done | sed '$ s/,$//'
                    fi
                    echo "  ],"

                    # Network information
                    echo "  \"network\": {"
                    echo "    \"netstat\": ["
                    if docker exec "$container" netstat -tlnp 2>/dev/null; then
                        docker exec "$container" netstat -tlnp 2>/dev/null | tail -n +3 | while read -r line; do
                            echo "      \"$line\","
                        done | sed '$ s/,$//'
                    fi
                    echo "    ]"
                    echo "  },"

                    # File system information
                    echo "  \"filesystem\": {"
                    echo "    \"var_sigul_structure\": ["
                    if docker exec "$container" find /var/sigul -type f 2>/dev/null; then
                        docker exec "$container" find /var/sigul -type f 2>/dev/null | while read -r file; do
                            echo "      \"$file\","
                        done | sed '$ s/,$//'
                    fi
                    echo "    ]"
                    echo "  }"
                else
                    echo "  \"stats\": null,"
                    echo "  \"processes\": [],"
                    echo "  \"network\": {},"
                    echo "  \"filesystem\": {}"
                fi

                echo "}"
            } > "$snapshot_file"

            # Capture recent logs snapshot with timeout
            timeout 20 docker logs --tail 50 "$container" > "$OUTPUT_DIR/logs/snapshots/${container}_logs_${snapshot_id}_${timestamp}.log" 2>&1 || {
                echo "WARNING: Failed to capture log snapshot for $container" > "$OUTPUT_DIR/logs/snapshots/${container}_logs_${snapshot_id}_${timestamp}.log"
            }

            debug "Captured snapshot $snapshot_id for $container"
        fi
    done
}

# Detect crash events
detect_crash_event() {
    local previous_state="$1"
    local current_state="$2"
    local crash_detected=false

    # Compare container states to detect crashes/restarts
    local containers=("sigul-server" "sigul-bridge")

    for container in "${containers[@]}"; do
        # Get current restart count
        local current_restarts
        current_restarts=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "unknown")

        # Get previous restart count (if available)
        local previous_restarts="0"
        if [[ -f "$previous_state" ]]; then
            previous_restarts=$(grep "\"$container\".*\"restart_count\"" "$previous_state" | sed 's/.*"restart_count": *"\([^"]*\)".*/\1/' || echo "0")
        fi

        # Check for restart
        if [[ "$current_restarts" != "unknown" ]] && [[ "$previous_restarts" != "unknown" ]] && [[ $current_restarts -gt $previous_restarts ]]; then
            error "CRASH DETECTED: $container restart count increased from $previous_restarts to $current_restarts"
            crash_detected=true

            # Capture detailed crash information
            capture_crash_event "$container" "$current_restarts"
        fi

        # Update current state file
        echo "\"$container\": {\"restart_count\": \"$current_restarts\", \"timestamp\": \"$(date -Iseconds)\"}" >> "$current_state"
    done

    echo "$crash_detected"
}

# Capture detailed crash event information
capture_crash_event() {
    local container="$1"
    local restart_count="$2"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    section "CAPTURING CRASH EVENT for $container"

    local crash_dir="$OUTPUT_DIR/crash-events/crash_${container}_${restart_count}_${timestamp}"
    mkdir -p "$crash_dir"

    # Comprehensive crash information
    {
        echo "=== CRASH EVENT REPORT ==="
        echo "Container: $container"
        echo "Restart Count: $restart_count"
        echo "Crash Time: $(date -Iseconds)"
        echo "Uptime Before Crash: $(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null || echo 'unknown')"
        echo ""

        echo "=== CONTAINER INSPECT AT CRASH ==="
        docker inspect "$container" 2>/dev/null || echo "Container inspect failed"
        echo ""

        echo "=== CONTAINER LOGS (last 200 lines) ==="
        timeout 30 docker logs --tail 200 "$container" 2>&1 || echo "Container logs unavailable (timeout or error)"
        echo ""

        echo "=== SYSTEM STATE AT CRASH ==="
        echo "System load: $(cat /proc/loadavg 2>/dev/null || echo 'unknown')"
        echo "Available memory: $(free -h 2>/dev/null || echo 'unknown')"
        echo "Disk usage: $(df -h . 2>/dev/null || echo 'unknown')"
        echo ""

        echo "=== DOCKER EVENTS (last 50) ==="
        timeout 15 docker events --since "10m" --until "now" --filter "container=$container" 2>/dev/null | tail -50 || echo "Docker events unavailable"
        echo ""

        echo "=== OTHER CONTAINERS STATUS ==="
        timeout 10 docker ps -a --filter "name=sigul" 2>/dev/null || echo "Container status unavailable"
        echo ""

    } > "$crash_dir/crash_report.log"

    # Try to capture core dumps or crash dumps if available
    if timeout 10 docker exec "$container" test -d /var/sigul/logs 2>/dev/null; then
        timeout 30 docker cp "$container:/var/sigul/logs" "$crash_dir/var_sigul_logs" 2>/dev/null || echo "Failed to copy logs directory"
    fi

    # Capture current configuration state
    timeout 10 docker exec "$container" env > "$crash_dir/environment_at_crash.txt" 2>/dev/null || echo "Failed to capture environment variables"

    error "Crash event captured in: $crash_dir"
}

# Monitor containers for crashes
monitor_containers() {
    section "Starting container crash monitoring"
    log "Monitoring for $MONITOR_DURATION seconds with $CAPTURE_INTERVAL second intervals"

    local start_time
    start_time=$(date +%s)
    local end_time=$((start_time + MONITOR_DURATION))
    local snapshot_count=0
    local crash_count=0

    local previous_state_file="$OUTPUT_DIR/container-state/previous_state.json"
    local current_state_file="$OUTPUT_DIR/container-state/current_state.json"

    # Initialize state tracking
    echo "{}" > "$previous_state_file"

    while [[ $(date +%s) -lt $end_time ]]; do
        ((snapshot_count++))

        # Capture current snapshot
        capture_container_snapshot "$snapshot_count"

        # Reset current state file
        echo "{" > "$current_state_file"

        # Detect crashes
        if [[ $(detect_crash_event "$previous_state_file" "$current_state_file") == "true" ]]; then
            ((crash_count++))
            warn "Crash #$crash_count detected at snapshot $snapshot_count"
        fi

        # Close current state file
        echo "}" >> "$current_state_file"

        # Copy current to previous for next iteration
        cp "$current_state_file" "$previous_state_file"

        # Progress indicator
        local elapsed=$(($(date +%s) - start_time))
        local remaining=$((MONITOR_DURATION - elapsed))
        if [[ $((snapshot_count % 12)) -eq 0 ]]; then  # Every minute (assuming 5s intervals)
            log "Monitoring progress: ${elapsed}s elapsed, ${remaining}s remaining (snapshot $snapshot_count)"
        fi

        sleep "$CAPTURE_INTERVAL"
    done

    success "Monitoring completed: $snapshot_count snapshots, $crash_count crashes detected"
}

# Stop continuous log capture
stop_continuous_log_capture() {
    section "Stopping continuous log capture"

    if [[ -f "$OUTPUT_DIR/logs/continuous/all_log_pids.txt" ]]; then
        while read -r pid; do
            if [[ -n "$pid" ]] && [[ "$pid" != "No log capture processes started" ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                debug "Stopped log capture process $pid"
            fi
        done < "$OUTPUT_DIR/logs/continuous/all_log_pids.txt"
    fi

    # Give processes time to terminate cleanly
    sleep 2

    success "Continuous log capture stopped"
}

# Generate final report
generate_final_report() {
    section "Generating final diagnostic report"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local report_file="$OUTPUT_DIR/DIAGNOSTIC_REPORT_${timestamp}.md"

    {
        echo "# Sigul Bridge Crash Diagnostics Report"
        echo ""
        echo "**Generated:** $(date -Iseconds)"
        echo "**Monitor Duration:** ${MONITOR_DURATION} seconds"
        echo "**Capture Interval:** ${CAPTURE_INTERVAL} seconds"
        echo ""

        echo "## Summary"
        echo ""

        # Count crash events
        local crash_events
        crash_events=$(find "$OUTPUT_DIR/crash-events" -name "crash_*" -type d 2>/dev/null | wc -l)
        echo "- **Crash Events Detected:** $crash_events"

        # Count snapshots
        local snapshots
        snapshots=$(find "$OUTPUT_DIR/container-state" -name "*_snapshot_*.json" 2>/dev/null | wc -l)
        echo "- **Container Snapshots Captured:** $snapshots"

        # Log file sizes
        local log_size
        log_size=$(du -sh "$OUTPUT_DIR/logs" 2>/dev/null | cut -f1 || echo "unknown")
        echo "- **Total Log Data:** $log_size"

        echo ""
        echo "## Directory Structure"
        echo ""
        echo "\`\`\`"
        find "$OUTPUT_DIR" -type f | head -50 | sort
        if [[ $(find "$OUTPUT_DIR" -type f | wc -l) -gt 50 ]]; then
            echo "... (truncated, total $(find "$OUTPUT_DIR" -type f | wc -l) files)"
        fi
        echo "\`\`\`"
        echo ""

        if [[ $crash_events -gt 0 ]]; then
            echo "## Crash Events"
            echo ""
            find "$OUTPUT_DIR/crash-events" -name "crash_*" -type d | while read -r crash_dir; do
                echo "### $(basename "$crash_dir")"
                echo ""
                if [[ -f "$crash_dir/crash_report.log" ]]; then
                    echo "Crash report available: \`$(basename "$crash_dir")/crash_report.log\`"
                fi
                echo ""
            done
        fi

        echo "## Key Files"
        echo ""
        echo "- **System Info:** \`system-info/\`"
        echo "- **Container Configs:** \`configs/\`"
        echo "- **Continuous Logs:** \`logs/continuous/\`"
        echo "- **Log Snapshots:** \`logs/snapshots/\`"
        echo "- **Container State:** \`container-state/\`"
        if [[ $crash_events -gt 0 ]]; then
            echo "- **Crash Events:** \`crash-events/\`"
        fi
        echo ""

        echo "## Next Steps"
        echo ""
        if [[ $crash_events -gt 0 ]]; then
            echo "1. Review crash reports in \`crash-events/\` directories"
            echo "2. Analyze container logs around crash times"
            echo "3. Check container configurations for issues"
            echo "4. Compare system resources at crash times"
        else
            echo "1. No crashes detected during monitoring period"
            echo "2. Review continuous logs for warnings or errors"
            echo "3. Check if monitoring duration was sufficient"
            echo "4. Consider extending monitoring or changing conditions"
        fi

    } > "$report_file"

    success "Final diagnostic report generated: $report_file"
}

# GitHub Actions artifact preparation
prepare_github_artifacts() {
    if [[ "${GITHUB_ACTIONS_MODE}" == "true" ]] || [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
        section "Preparing GitHub Actions artifacts"

        # Create a compressed archive for easier downloading
        local archive_name="sigul-crash-diagnostics-$(date +%Y%m%d_%H%M%S).tar.gz"
        tar -czf "$OUTPUT_DIR/$archive_name" -C "$OUTPUT_DIR" . --exclude="$archive_name"

        # Create GitHub Actions summary
        if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
            {
                echo "# 🔍 Sigul Crash Diagnostics Completed"
                echo ""
                echo "**Monitor Duration:** ${MONITOR_DURATION} seconds"
                echo "**Output Directory:** \`$OUTPUT_DIR\`"
                echo "**Archive:** \`$archive_name\`"
                echo ""

                local crash_events
                crash_events=$(find "$OUTPUT_DIR/crash-events" -name "crash_*" -type d 2>/dev/null | wc -l)
                if [[ $crash_events -gt 0 ]]; then
                    echo "⚠️ **$crash_events crash events detected**"
                else
                    echo "✅ **No crashes detected during monitoring**"
                fi
                echo ""
                echo "Download the diagnostics artifact to analyze the results."

            } >> "$GITHUB_STEP_SUMMARY"
        fi

        success "GitHub Actions artifacts prepared"
    fi
}

# Cleanup function
cleanup() {
    debug "Performing cleanup..."
    stop_continuous_log_capture

    # Update metadata with completion info
    if [[ -f "$OUTPUT_DIR/metadata.json" ]]; then
        local temp_metadata
        temp_metadata=$(mktemp)
        jq ". + {\"capture_end\": \"$(date -Iseconds)\", \"completed\": true}" "$OUTPUT_DIR/metadata.json" > "$temp_metadata" 2>/dev/null || true
        mv "$temp_metadata" "$OUTPUT_DIR/metadata.json" 2>/dev/null || true
    fi
}

# Main function
main() {
    parse_arguments "$@"

    section "=== Sigul Bridge Crash Diagnostics Capture ==="
    log "Starting comprehensive crash diagnostics capture"
    log "Monitor duration: ${MONITOR_DURATION}s, Capture interval: ${CAPTURE_INTERVAL}s"
    log "Output directory: $OUTPUT_DIR"
    if [[ "${GITHUB_ACTIONS_MODE}" == "true" ]] || [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
        log "GitHub Actions mode: ENABLED"
    fi
    log ""

    # Set up cleanup trap
    trap cleanup EXIT

    # Main execution flow
    setup_output_directory
    capture_initial_state
    capture_configurations
    start_continuous_log_capture

    # Main monitoring loop
    monitor_containers

    # Finalization
    stop_continuous_log_capture
    generate_final_report
    prepare_github_artifacts

    section "=== Crash Diagnostics Capture Complete ==="
    success "All diagnostics captured in: $OUTPUT_DIR"

    # Final summary
    local crash_events
    crash_events=$(find "$OUTPUT_DIR/crash-events" -name "crash_*" -type d 2>/dev/null | wc -l)
    if [[ $crash_events -gt 0 ]]; then
        error "🚨 $crash_events crash events detected - check crash-events/ directory"
        exit 1
    else
        success "✅ No crashes detected during monitoring period"
        exit 0
    fi
}

# Execute main function with all arguments
main "$@"
