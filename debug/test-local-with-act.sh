#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Local Testing Script with nektos/act
#
# This script tests the Sigul infrastructure locally using nektos/act
# to simulate GitHub Actions environment before pushing to CI.
#
# Usage:
#   ./debug/test-local-with-act.sh [OPTIONS]
#
# Options:
#   --workflow WORKFLOW    Which workflow to run (default: local-debug-test)
#   --architecture ARCH    Architecture to test (amd64|arm64, default: amd64)
#   --duration SECONDS     Test duration (default: 120)
#   --verbose              Enable verbose output
#   --dry-run              Only check syntax, don't run containers
#   --help                 Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default options
WORKFLOW="local-debug-test"
ARCHITECTURE="amd64"
DURATION="120"
VERBOSE_MODE=false
DRY_RUN=false
SHOW_HELP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
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
Local Testing Script with nektos/act

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --workflow WORKFLOW    Which workflow to run (default: local-debug-test)
    --architecture ARCH    Architecture to test (amd64|arm64, default: amd64)
    --duration SECONDS     Test duration in seconds (default: 120)
    --verbose              Enable verbose output
    --dry-run              Only check syntax, don't run containers
    --help                 Show this help message

DESCRIPTION:
    This script uses nektos/act to run GitHub Actions workflows locally,
    allowing you to test changes before pushing to CI. It provides:
    
    1. **Dockerfile Syntax Checking**: Validates all Dockerfiles
    2. **Local Container Testing**: Builds and runs containers locally
    3. **Stability Testing**: Monitors for restart issues
    4. **Quick Feedback**: Faster than waiting for CI

EXAMPLES:
    # Run basic test
    $0
    
    # Test ARM64 architecture
    $0 --architecture arm64
    
    # Run longer stability test
    $0 --duration 300
    
    # Just check syntax without running containers
    $0 --dry-run
    
    # Run with verbose output
    $0 --verbose

REQUIREMENTS:
    - nektos/act installed (https://github.com/nektos/act)
    - Docker running
    - Sufficient disk space for container images

WORKFLOWS AVAILABLE:
    - local-debug-test: Quick local testing (default)
    - debug-bridge-crashes: Full crash diagnostics (slower)
EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --workflow)
                WORKFLOW="$2"
                shift 2
                ;;
            --architecture)
                ARCHITECTURE="$2"
                shift 2
                ;;
            --duration)
                DURATION="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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
    case "$ARCHITECTURE" in
        "amd64"|"arm64") ;;
        *) error "Invalid architecture: $ARCHITECTURE (must be amd64 or arm64)"; exit 1 ;;
    esac

    if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 10 ]]; then
        error "Duration must be a number >= 10 seconds"
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    section "Checking prerequisites"
    
    # Check if act is installed
    if ! command -v act >/dev/null 2>&1; then
        error "nektos/act is not installed"
        log "Install act from: https://github.com/nektos/act"
        log "On macOS: brew install act"
        log "On Linux: see installation instructions at the GitHub repo"
        exit 1
    fi
    
    local act_version
    act_version=$(act --version 2>/dev/null | head -1 || echo "unknown")
    debug "Act version: $act_version"
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        error "Docker is not running"
        log "Please start Docker and try again"
        exit 1
    fi
    
    debug "Docker is running"
    
    # Check if we're in the right directory
    if [[ ! -f "$PROJECT_ROOT/docker-compose.sigul.yml" ]]; then
        error "Not in sigul-sign-docker project root"
        log "Current directory: $(pwd)"
        log "Expected file: $PROJECT_ROOT/docker-compose.sigul.yml"
        exit 1
    fi
    
    # Check if workflow file exists
    local workflow_file="$PROJECT_ROOT/.github/workflows/${WORKFLOW}.yml"
    if [[ ! -f "$workflow_file" ]]; then
        error "Workflow file not found: $workflow_file"
        log "Available workflows:"
        find "$PROJECT_ROOT/.github/workflows" -name "*.yml" -exec basename {} \; 2>/dev/null || echo "No workflows found"
        exit 1
    fi
    
    success "Prerequisites check passed"
}

# Check Dockerfile syntax locally
check_dockerfile_syntax() {
    section "Checking Dockerfile syntax"
    
    local dockerfiles=(
        "Dockerfile.server"
        "Dockerfile.bridge" 
        "Dockerfile.client"
    )
    
    local syntax_errors=0
    
    for dockerfile in "${dockerfiles[@]}"; do
        if [[ -f "$PROJECT_ROOT/$dockerfile" ]]; then
            log "Checking $dockerfile..."
            
            # Simple syntax check by attempting to parse the Dockerfile
            local syntax_output
            syntax_output=$(docker build --file "$dockerfile" --target nonexistent-stage "$PROJECT_ROOT" 2>&1 || true)
            
            # Check if it's a syntax error (not just missing target stage)
            if echo "$syntax_output" | grep -q "dockerfile parse error\|unknown instruction\|invalid reference format"; then
                error "❌ $dockerfile has syntax errors:"
                echo "$syntax_output" | head -10
                ((syntax_errors++))
            else
                success "✅ $dockerfile syntax is valid"
            fi
        else
            warn "Dockerfile not found: $dockerfile"
        fi
    done
    
    if [[ $syntax_errors -gt 0 ]]; then
        error "Found $syntax_errors Dockerfile(s) with syntax errors"
        exit 1
    fi
    
    success "All Dockerfiles have valid syntax"
}

# Run workflow with act
run_workflow_with_act() {
    section "Running workflow '$WORKFLOW' with act"
    
    cd "$PROJECT_ROOT"
    
    # Set up act parameters
    local act_args=(
        "--job" "local-debug-test"  # Specific job name
        "--verbose" 
        "--rm"  # Remove containers after run
    )
    
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        act_args+=("--verbose")
    fi
    
    # Set up input parameters for the workflow
    local workflow_inputs=()
    
    if [[ "$WORKFLOW" == "local-debug-test" ]]; then
        workflow_inputs+=(
            "-s" "GITHUB_TOKEN=dummy"  # Some workflows expect this
            "--input" "test_duration=$DURATION"
            "--input" "architecture=$ARCHITECTURE"
        )
    fi
    
    log "Running act with the following configuration:"
    log "  Workflow: $WORKFLOW"
    log "  Architecture: $ARCHITECTURE" 
    log "  Duration: ${DURATION}s"
    log "  Verbose: $VERBOSE_MODE"
    
    # Run act
    log "Executing: act workflow_dispatch ${act_args[*]} ${workflow_inputs[*]}"
    
    if act workflow_dispatch "${act_args[@]}" "${workflow_inputs[@]}"; then
        success "✅ Workflow completed successfully"
        return 0
    else
        local exit_code=$?
        error "❌ Workflow failed with exit code $exit_code"
        return $exit_code
    fi
}

# Quick local test without act
run_quick_local_test() {
    section "Running quick local test (without act)"
    
    cd "$PROJECT_ROOT"
    
    log "Building images locally..."
    
    # Build images
    local images=(
        "server:Dockerfile.server"
        "bridge:Dockerfile.bridge"
        "client:Dockerfile.client"
    )
    
    for image_def in "${images[@]}"; do
        local image_name="${image_def%%:*}"
        local dockerfile="${image_def##*:}"
        
        log "Building $image_name image..."
        if docker build \
            --file "$dockerfile" \
            --tag "${image_name}-linux-${ARCHITECTURE}-image:test" \
            --build-arg "TARGETARCH=$ARCHITECTURE" \
            . ; then
            success "✅ Built $image_name image"
        else
            error "❌ Failed to build $image_name image"
            return 1
        fi
    done
    
    # Set up environment
    export SIGUL_SERVER_IMAGE="server-linux-${ARCHITECTURE}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-linux-${ARCHITECTURE}-image:test"
    export SIGUL_CLIENT_IMAGE="client-linux-${ARCHITECTURE}-image:test"
    export NSS_PASSWORD="test_password_$(date +%s)"
    export SIGUL_ADMIN_PASSWORD="test_admin_$(date +%s)"
    export DEBUG="true"
    
    log "Starting containers..."
    docker compose -f docker-compose.sigul.yml up -d sigul-server sigul-bridge
    
    # Wait for startup
    sleep 15
    
    # Check status
    local server_status
    server_status=$(docker inspect --format='{{.State.Status}}' sigul-server 2>/dev/null || echo "not_found")
    local bridge_status
    bridge_status=$(docker inspect --format='{{.State.Status}}' sigul-bridge 2>/dev/null || echo "not_found")
    
    log "Container status:"
    log "  Server: $server_status"
    log "  Bridge: $bridge_status"
    
    if [[ "$server_status" == "running" ]] && [[ "$bridge_status" == "running" ]]; then
        success "✅ Containers started successfully"
        
        # Quick stability check
        log "Running ${DURATION}s stability check..."
        local end_time=$(($(date +%s) + DURATION))
        
        while [[ $(date +%s) -lt $end_time ]]; do
            local current_server_status
            current_server_status=$(docker inspect --format='{{.State.Status}}' sigul-server 2>/dev/null || echo "not_found")
            local current_bridge_status
            current_bridge_status=$(docker inspect --format='{{.State.Status}}' sigul-bridge 2>/dev/null || echo "not_found")
            
            if [[ "$current_server_status" != "running" ]] || [[ "$current_bridge_status" != "running" ]]; then
                error "❌ Container(s) stopped running during test"
                log "Server: $current_server_status"
                log "Bridge: $current_bridge_status"
                docker compose -f docker-compose.sigul.yml down --remove-orphans || true
                return 1
            fi
            
            sleep 10
        done
        
        success "✅ Stability test passed"
        
        # Cleanup
        log "Cleaning up..."
        docker compose -f docker-compose.sigul.yml down --remove-orphans || true
        
        return 0
    else
        error "❌ Containers failed to start"
        log "Server logs:"
        docker logs sigul-server --tail 20 || true
        log "Bridge logs:"
        docker logs sigul-bridge --tail 20 || true
        
        # Cleanup
        docker compose -f docker-compose.sigul.yml down --remove-orphans || true
        return 1
    fi
}

# Main function
main() {
    parse_arguments "$@"
    
    section "=== Local Testing with Act ==="
    log "Testing Sigul infrastructure locally before CI"
    log "Workflow: $WORKFLOW"
    log "Architecture: $ARCHITECTURE"
    log "Duration: ${DURATION}s"
    log "Dry run: $DRY_RUN"
    log ""
    
    check_prerequisites
    check_dockerfile_syntax
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        success "✅ Dry run completed - syntax checks passed"
        log "To run full test, remove --dry-run flag"
        exit 0
    fi
    
    # Try to run with act first, fall back to local test if act fails
    local test_result=0
    
    if command -v act >/dev/null 2>&1; then
        log "Using nektos/act to simulate GitHub Actions environment"
        if ! run_workflow_with_act; then
            warn "Act run failed, falling back to quick local test"
            run_quick_local_test || test_result=1
        fi
    else
        log "Act not available, running quick local test"
        run_quick_local_test || test_result=1
    fi
    
    section "=== Local Testing Complete ==="
    if [[ $test_result -eq 0 ]]; then
        success "✅ All local tests passed"
        log "The changes look good to push to CI"
    else
        error "❌ Local tests failed"
        log "Fix the issues before pushing to CI"
    fi
    
    exit $test_result
}

# Execute main function with all arguments
main "$@"