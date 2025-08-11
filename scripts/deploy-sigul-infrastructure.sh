#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Infrastructure Deployment Script for GitHub Workflows
#
# This script handles the deployment of Sigul infrastructure components
# for integration testing with improved permission handling and better
# error diagnosis for GitHub Actions environment.
#
# Usage:
#   ./scripts/deploy-sigul-infrastructure.sh [OPTIONS]
#
# Options:
#   --verbose       Enable verbose output
#   --debug         Enable debug mode with detailed diagnostics
#   --help          Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.sigul.yml"

# Default options
VERBOSE_MODE=false
DEBUG_MODE=false
SHOW_HELP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
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

verbose() {
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

debug() {
    if [[ "${DEBUG_MODE}" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

# Function to determine which Docker Compose command to use
get_docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

# Detect GitHub Actions environment and adjust timing accordingly
is_github_actions() {
    [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

# Get timing adjustments for environment
get_timeout_multiplier() {
    if is_github_actions; then
        echo "2"  # GitHub Actions may need more time
    else
        echo "1"  # Local development
    fi
}

# Help function
show_help() {
    cat << EOF
Sigul Infrastructure Deployment Script for GitHub Workflows

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --verbose       Enable verbose output
    --debug         Enable debug mode with detailed diagnostics
    --help          Show this help message

DESCRIPTION:
    This script deploys the Sigul infrastructure for integration testing
    with better permission handling, error diagnosis, and GitHub Actions compatibility.

    The script performs:
    1. Environment analysis and prerequisite checking
    2. Permission-aware PKI infrastructure setup
    3. Pre-generated configuration files with proper ownership
    4. SQLite database setup with health checks
    5. Sigul server and bridge container deployment with diagnostics
    6. Comprehensive health checks and connectivity verification

IMPROVEMENTS:
    - Better permission handling for GitHub Actions environment
    - Pre-generated configuration files to avoid read-only mount conflicts
    - Enhanced error diagnosis and logging
    - Robust health checks with detailed feedback
    - Container startup diagnostics and troubleshooting

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                VERBOSE_MODE=true
                shift
                ;;
            --help)
                SHOW_HELP=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                echo
                show_help
                exit 1
                ;;
        esac
    done
}

# Enhanced environment analysis
analyze_environment() {
    log "Analyzing deployment environment..."

    debug "System information:"
    debug "  OS: $(uname -a)"
    debug "  User: $(whoami) ($(id))"
    debug "  Working directory: $(pwd)"
    debug "  Docker version: $(docker --version 2>/dev/null || echo 'Not available')"
    debug "  Docker Compose: $($(get_docker_compose_cmd) version --short 2>/dev/null || echo 'Not available')"

    debug "GitHub Actions environment:"
    debug "  GITHUB_ACTIONS: ${GITHUB_ACTIONS:-false}"
    debug "  RUNNER_OS: ${RUNNER_OS:-unknown}"
    debug "  RUNNER_ARCH: ${RUNNER_ARCH:-unknown}"
    debug "  CI: ${CI:-false}"
    debug "  Runner platform: ${SIGUL_RUNNER_PLATFORM:-auto-detect}"
    debug "  Docker platform: ${SIGUL_DOCKER_PLATFORM:-auto-detect}"

    # Check disk space
    local available_space
    available_space=$(df -BG . | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ "${available_space:-0}" -lt 2 ]]; then
        warn "Low disk space: ${available_space}GB available"
    else
        debug "Available disk space: ${available_space}GB"
    fi

    success "Environment analysis completed"
}

# Check prerequisites with enhanced validation
check_prerequisites() {
    log "Checking prerequisites with enhanced validation..."

    local missing_tools=()

    # Check for required tools
    for tool in docker openssl nc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        else
            debug "$tool: $(command -v "$tool")"
        fi
    done

    # Check for Docker Compose (either v1 standalone or v2 plugin)
    local compose_cmd
    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        missing_tools+=("docker-compose or docker compose")
    else
        compose_cmd=$(get_docker_compose_cmd)
        debug "Docker Compose: $compose_cmd ($(${compose_cmd} version --short 2>/dev/null || echo 'unknown version'))"
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        error "Please install the missing tools and try again"
        exit 1
    fi

    # Check Docker is running and accessible
    if ! docker info >/dev/null 2>&1; then
        error "Docker is not running or not accessible"
        debug "Docker daemon connection test failed"
        exit 1
    fi

    # Test Docker functionality
    if ! docker run --rm alpine:latest echo "Docker test successful" >/dev/null 2>&1; then
        error "Docker container execution test failed"
        exit 1
    fi

    debug "Docker daemon is running and functional"
    success "Prerequisites check passed"
}

# Setup PKI with proper permissions and validation
setup_pki_infrastructure() {
    log "Setting up PKI infrastructure with enhanced validation..."

    local pki_dir="${PROJECT_ROOT}/pki"

    # Ensure PKI directory exists with proper permissions
    mkdir -p "$pki_dir"
    chmod 755 "$pki_dir"
    debug "PKI directory: $pki_dir ($(ls -ld "$pki_dir"))"

    # Check if existing PKI infrastructure is present and valid
    if [[ -f "${pki_dir}/ca.crt" && -f "${pki_dir}/server.crt" && \
          -f "${pki_dir}/server-key.pem" && -f "${pki_dir}/bridge.crt" && \
          -f "${pki_dir}/bridge-key.pem" ]]; then

        log "Existing PKI infrastructure found, performing comprehensive validation..."

        # Verify certificate chain
        if openssl verify -CAfile "${pki_dir}/ca.crt" "${pki_dir}/server.crt" >/dev/null 2>&1 && \
           openssl verify -CAfile "${pki_dir}/ca.crt" "${pki_dir}/bridge.crt" >/dev/null 2>&1; then

            # Additional certificate validation
            local ca_subject server_subject bridge_subject
            ca_subject=$(openssl x509 -in "${pki_dir}/ca.crt" -noout -subject 2>/dev/null | cut -d= -f2-)
            server_subject=$(openssl x509 -in "${pki_dir}/server.crt" -noout -subject 2>/dev/null | cut -d= -f2-)
            bridge_subject=$(openssl x509 -in "${pki_dir}/bridge.crt" -noout -subject 2>/dev/null | cut -d= -f2-)

            verbose "Certificate validation results:"
            verbose "  CA Subject: ${ca_subject}"
            verbose "  Server Subject: ${server_subject}"
            verbose "  Bridge Subject: ${bridge_subject}"

            # Check certificate expiration
            local ca_expires server_expires bridge_expires
            ca_expires=$(openssl x509 -in "${pki_dir}/ca.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
            server_expires=$(openssl x509 -in "${pki_dir}/server.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
            bridge_expires=$(openssl x509 -in "${pki_dir}/bridge.crt" -noout -enddate 2>/dev/null | cut -d= -f2)

            debug "Certificate expiration dates:"
            debug "  CA: ${ca_expires}"
            debug "  Server: ${server_expires}"
            debug "  Bridge: ${bridge_expires}"

            success "PKI infrastructure validation passed"
            return 0
        else
            warn "PKI infrastructure validation failed, regenerating..."
        fi
    else
        log "PKI infrastructure missing or incomplete, generating new certificates..."
    fi

    # Generate PKI infrastructure using existing script
    if [[ -f "${SCRIPT_DIR}/generate-complete-pki.sh" ]]; then
        verbose "Using comprehensive PKI generation script..."
        chmod +x "${SCRIPT_DIR}/generate-complete-pki.sh"
        if "${SCRIPT_DIR}/generate-complete-pki.sh"; then
            success "PKI generated using comprehensive script"
        else
            error "Comprehensive PKI generation failed"
            exit 1
        fi
    elif [[ -f "${SCRIPT_DIR}/generate-test-pki.sh" ]]; then
        verbose "Using test PKI generation script..."
        chmod +x "${SCRIPT_DIR}/generate-test-pki.sh"
        if "${SCRIPT_DIR}/generate-test-pki.sh"; then
            success "PKI generated using test script"
        else
            error "Test PKI generation failed"
            exit 1
        fi
    else
        error "No PKI generation script found"
        exit 1
    fi

    # Verify generated PKI and set appropriate permissions
    for cert_file in ca.crt server.crt server-key.pem bridge.crt bridge-key.pem; do
        local cert_path="${pki_dir}/${cert_file}"
        if [[ -f "$cert_path" ]]; then
            # Set appropriate permissions (readable by all, writable by owner)
            chmod 644 "$cert_path"
            if [[ "$cert_file" == *"-key.pem" ]]; then
                chmod 600 "$cert_path"  # Private keys should be more restrictive
            fi
            debug "Set permissions for $cert_file: $(ls -l "$cert_path")"
        else
            error "Generated certificate not found: $cert_file"
            exit 1
        fi
    done

    success "PKI infrastructure setup completed successfully"
}

# Generate configurations with proper permissions
generate_configurations() {
    log "Generating Sigul configuration files with proper permissions..."

    local config_dir="${PROJECT_ROOT}/configs"
    mkdir -p "${config_dir}"
    chmod 755 "${config_dir}"
    debug "Config directory: $config_dir ($(ls -ld "$config_dir"))"

    local pki_dir="${PROJECT_ROOT}/pki"

    # Generate server configuration
    log "Creating server configuration..."
    cat > "${config_dir}/server.conf" << 'EOF'
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

[server]
bridge-hostname = sigul-bridge
bridge-port = 44334
server-cert-nickname = sigul-server-cert
max-file-payload-size = 2097152
signing-timeout = 60
idle-timeout = 300

# Database Configuration - SQLite
[database]
database-path = /var/sigul/database/sigul.db

# TLS Configuration using containerized certificates
ca-cert-file = /var/sigul/secrets/certificates/ca.crt
server-cert-file = /var/sigul/secrets/certificates/server.crt
server-key-file = /var/sigul/secrets/certificates/server-key.pem
require-tls = true


[daemon]
uid = sigul
gid = sigul
EOF

    # Generate bridge configuration
    log "Creating bridge configuration..."
    cat > "${config_dir}/bridge.conf" << 'EOF'
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

[bridge]
host = 0.0.0.0
port = 44334
server-hostname = sigul-server
bridge-cert-nickname = sigul-bridge-cert
max-file-payload-size = 2097152
idle-timeout = 300
nss-dir = /var/lib/sigul/nss/bridge

# TLS Configuration using containerized certificates
ca-cert-file = /var/sigul/secrets/certificates/ca.crt
bridge-cert-file = /var/sigul/secrets/certificates/bridge.crt
bridge-key-file = /var/sigul/secrets/certificates/bridge-key.pem
require-tls = true
EOF

    # Client configuration removed from infrastructure deployment
    # (only needed for integration tests, not infrastructure deployment)

    # Set proper permissions for infrastructure configuration files
    for config_file in server.conf bridge.conf; do
        local config_path="${config_dir}/${config_file}"
        if [[ -f "$config_path" ]]; then
            chmod 644 "$config_path"
            debug "Configuration file created: $config_file ($(ls -l "$config_path"))"
        else
            error "Failed to create configuration file: $config_file"
            exit 1
        fi
    done

    success "Configuration files generated with proper permissions"
}

# Load infrastructure images with enhanced validation
load_infrastructure_images() {
    log "Loading pre-built infrastructure images with validation..."

    local platform_id="${SIGUL_RUNNER_PLATFORM:-linux-amd64}"
    local loaded_images=()
    local failed_images=()

    # Debug platform detection
    debug "Platform ID detection:"
    debug "  SIGUL_RUNNER_PLATFORM: '${SIGUL_RUNNER_PLATFORM:-unset}'"
    debug "  RUNNER_ARCH: '${RUNNER_ARCH:-unset}'"
    debug "  Resolved platform_id: '${platform_id}'"
    debug "  Available .tar files in /tmp:"
    for file in /tmp/*.tar; do
        if [[ -f "$file" ]]; then
            debug "    $(basename "$file")"
        fi
    done
    if ! compgen -G "/tmp/*.tar" > /dev/null; then
        debug "    (no .tar files found in /tmp)"
    fi

    # Define image mappings based on build output naming convention
    # - Infrastructure builds create: /tmp/server-${platform_id}.tar, /tmp/bridge-${platform_id}.tar
    # - Client image loading removed from infrastructure deployment (only needed for integration tests)
    declare -A image_mappings=(
        ["server-${platform_id}-image:test"]="/tmp/server-${platform_id}.tar"
        ["bridge-${platform_id}-image:test"]="/tmp/bridge-${platform_id}.tar"
    )

    for target_image in "${!image_mappings[@]}"; do
        local artifact_file="${image_mappings[$target_image]}"

        debug "Processing image: $target_image"
        debug "  Artifact file: $artifact_file"

        if [[ -f "$artifact_file" ]]; then
            # Show current images before loading for debugging
            debug "Images before loading:"
            debug "$(docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}' | head -10)"
            verbose "Loading $target_image from artifact: $artifact_file"

            # Capture the docker load output to identify the actual loaded image
            local load_output
            if load_output=$(docker load --input "$artifact_file" 2>&1); then
                debug "Docker load output: $load_output"

                # Extract the loaded image name from docker load output
                # Format: "Loaded image: <image_name>"
                local loaded_image
                loaded_image=$(echo "$load_output" | grep "^Loaded image:" | head -1 | sed 's/^Loaded image: //')

                if [[ -n "$loaded_image" ]]; then
                    debug "Identified loaded image: $loaded_image"

                    # Tag it with our expected name if different
                    if [[ "$loaded_image" != "$target_image" ]]; then
                        debug "Tagging loaded image '$loaded_image' as '$target_image'"
                        docker tag "$loaded_image" "$target_image"
                    fi
                else
                    warn "Could not identify loaded image from output, checking expected patterns"
                    # Fallback: try common patterns based on target image
                    if [[ "$target_image" == "server-"* ]]; then
                        local base_name="${target_image%-*-image:test}"
                        local platform="${base_name#server-}"
                        loaded_image="server:${platform}"
                    elif [[ "$target_image" == "bridge-"* ]]; then
                        local base_name="${target_image%-*-image:test}"
                        local platform="${base_name#bridge-}"
                        loaded_image="bridge:${platform}"
                    fi

                    if [[ -n "$loaded_image" ]] && docker image inspect "$loaded_image" >/dev/null 2>&1; then
                        debug "Found expected image pattern: $loaded_image"
                        docker tag "$loaded_image" "$target_image"
                    fi
                fi

                # Show current images after loading for debugging
                debug "Images after loading and tagging:"
                debug "$(docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}' | grep -E '(server|bridge|client)' | head -10)"

                # Verify the target image exists
                if docker image inspect "$target_image" >/dev/null 2>&1; then
                    success "✅ Successfully loaded: $target_image"
                    loaded_images+=("$target_image")
                else
                    warn "❌ Image loading verification failed: $target_image"
                    failed_images+=("$target_image")
                fi
            else
                error "❌ Failed to load image from artifact: $artifact_file"
                error "Docker load error: $load_output"
                failed_images+=("$target_image")
            fi
        else
            warn "⚠️  Artifact not found: $artifact_file"

            # Check if image already exists locally
            if docker image inspect "$target_image" >/dev/null 2>&1; then
                success "✅ Image already available locally: $target_image"
                loaded_images+=("$target_image")
            else
                warn "❌ Image not available: $target_image"
                failed_images+=("$target_image")
            fi
        fi
    done

    # Report results
    if [[ ${#loaded_images[@]} -gt 0 ]]; then
        success "Successfully loaded ${#loaded_images[@]} images: ${loaded_images[*]}"
    fi

    if [[ ${#failed_images[@]} -gt 0 ]]; then
        error "Failed to load ${#failed_images[@]} images: ${failed_images[*]}"
        error "Infrastructure deployment may fail due to missing images"
        return 1
    fi

    # Show final image status
    debug "Final image inventory:"
    for image in "${!image_mappings[@]}"; do
        if docker image inspect "$image" >/dev/null 2>&1; then
            local size created
            size=$(docker image inspect "$image" --format '{{.Size}}' 2>/dev/null)
            created=$(docker image inspect "$image" --format '{{.Created}}' 2>/dev/null | cut -d'T' -f1)
            debug "  ✅ $image ($(numfmt --to=iec "${size:-0}" 2>/dev/null || echo 'unknown size'), created: ${created:-unknown})"
        else
            debug "  ❌ $image (not available)"
        fi
    done

    success "Infrastructure image loading completed"
}

# Deploy Sigul services with comprehensive monitoring
deploy_sigul_services() {
    log "Deploying Sigul server and bridge with comprehensive monitoring..."

    local compose_cmd
    compose_cmd=$(get_docker_compose_cmd)

    # Set environment variables for platform-specific images
    local platform_id="${SIGUL_RUNNER_PLATFORM:-linux-amd64}"
    export SIGUL_SERVER_IMAGE="server-${platform_id}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-${platform_id}-image:test"
    # SIGUL_CLIENT_IMAGE removed from infrastructure deployment (only needed for integration tests)

    # Explicitly skip admin user creation to prevent interactive password prompts
    export SIGUL_SKIP_ADMIN_USER="true"

    verbose "Deploying Sigul services for platform: $platform_id"
    verbose "Using server image: ${SIGUL_SERVER_IMAGE}"
    verbose "Using bridge image: ${SIGUL_BRIDGE_IMAGE}"

    # Start Sigul server first
    log "Starting Sigul server..."
    if ${compose_cmd} -f "${COMPOSE_FILE}" up -d sigul-server; then
        success "Sigul server container started"

        # Wait briefly for container to initialize before IP detection
        sleep 2

        # Capture Sigul server container IP (with retry logic)
        local server_ip=""
        local ip_attempts=0
        local max_ip_attempts=10

        while [[ -z "$server_ip" && $ip_attempts -lt $max_ip_attempts ]]; do
            server_ip=$(docker inspect sigul-server --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
            if [[ -n "$server_ip" ]]; then
                export SIGUL_SERVER_IP="$server_ip"
                verbose "Sigul server container IP: $server_ip"
                # Export to GitHub Actions environment if available
                if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
                    echo "server-ip=$server_ip" >> "$GITHUB_OUTPUT"
                fi
                break
            else
                ((ip_attempts++))
                debug "IP detection attempt $ip_attempts/$max_ip_attempts failed, retrying in 1 second..."
                sleep 1
            fi
        done

        if [[ -z "$server_ip" ]]; then
            warn "Could not determine Sigul server container IP after $max_ip_attempts attempts"
            debug "Container may still be initializing - this won't affect functionality"
        fi
    else
        error "Failed to start Sigul server container"
        return 1
    fi

    # Enhanced server readiness check with detailed monitoring
    log "Waiting for Sigul server with detailed monitoring..."
    local timeout_multiplier
    timeout_multiplier=$(get_timeout_multiplier)
    local max_attempts=$((60 * timeout_multiplier))
    local attempt=1
    local startup_errors=0

    if is_github_actions; then
        log "GitHub Actions environment detected - using extended timeouts"
    fi

    while [[ $attempt -le $max_attempts ]]; do
        verbose "Sigul server readiness check (attempt $attempt/$max_attempts)..."

        # Check container status
        local container_status exit_code
        container_status=$(docker container inspect sigul-server --format '{{.State.Status}}' 2>/dev/null || echo "not found")
        exit_code=$(docker container inspect sigul-server --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")

        debug "Server container status: $container_status (exit code: $exit_code)"

        if [[ "$container_status" == "exited" ]]; then
            error "Sigul server container has exited (exit code: $exit_code)"

            # Get detailed logs for diagnosis
            error "Server container logs:"
            docker logs sigul-server 2>&1 | tail -30 | while read -r line; do
                error "  $line"
            done

            # Get additional container information
            debug "Container inspect output:"
            docker container inspect sigul-server --format '{{json .State}}' 2>/dev/null | \
                python3 -m json.tool 2>/dev/null | while read -r line; do
                debug "  $line"
            done

            return 1
        elif [[ "$container_status" != "running" ]]; then
            warn "Server container not running (status: $container_status)"
            ((startup_errors++))

            # If container is stuck restarting for too long, treat as failure
            if [[ "$container_status" == "restarting" && $startup_errors -gt 10 ]]; then
                error "Server container stuck in restart loop (status: $container_status)"
                error "Container has failed to start properly after $startup_errors restart attempts"

                # Get container logs for diagnosis
                error "Recent server container logs:"
                docker logs sigul-server 2>&1 | tail -20 | while read -r line; do
                    error "  $line"
                done

                return 1
            fi
        else
            # Container is running, test both port connectivity and process health
            # (matching Docker health check requirements)
            local port_ok=false
            local process_ok=false

            # Test port connectivity
            # Server connects to bridge, doesn't listen on a port
            # Check for healthy processes instead
            port_ok=true
            debug "✅ Server connectivity check skipped (server connects to bridge)"

            # Test process health (matching Docker health check)
            if docker exec sigul-server pgrep -f server >/dev/null 2>&1; then
                process_ok=true
                debug "✅ Sigul server process is running"
            else
                debug "❌ Sigul processes not found"
            fi

            # Both checks must pass
            if [[ "$port_ok" == "true" && "$process_ok" == "true" ]]; then
                success "✅ Sigul server is running with healthy processes"
                break
            else
                debug "Server not fully ready yet (processes: $process_ok)"
            fi
        fi

        # Show progress and recent logs every 15 attempts
        if [[ $((attempt % 15)) -eq 0 ]]; then
            log "Still waiting for Sigul server... (attempt $attempt/$max_attempts, startup errors: $startup_errors)"
            debug "Recent server logs:"
            docker logs sigul-server 2>&1 | tail -5 | while read -r line; do
                debug "  $line"
            done
        fi

        sleep 3
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        error "Sigul server failed to start within expected time ($max_attempts attempts)"
        error "Cannot proceed with bridge deployment - server is required"
        return 1
    fi

    success "Sigul server deployed and ready (took $((attempt-1)) attempts)"

    # Additional validation to ensure container will pass Docker health checks
    debug "Performing final health validation..."
    local health_check_result
    health_check_result=$(docker exec sigul-server sh -c "echo 'Health check: Looking for server process...' && pgrep -f server && echo 'Health check: PASSED'" 2>&1 || echo "HEALTH_CHECK_FAILED")

    if [[ "$health_check_result" == *"HEALTH_CHECK_FAILED"* ]]; then
        warn "Server passed readiness but may fail Docker health checks"
        debug "Health check output:"
        echo "$health_check_result" | while read -r line; do
            debug "  $line"
        done
    else
        debug "Server passes both readiness and health checks"
    fi

    # Start Sigul bridge
    log "Starting Sigul bridge..."
    if ${compose_cmd} -f "${COMPOSE_FILE}" up -d sigul-bridge; then
        success "Sigul bridge container started"

        # Capture Sigul bridge container IP
        local bridge_ip
        bridge_ip=$(docker inspect sigul-bridge --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
        if [[ -n "$bridge_ip" ]]; then
            export SIGUL_BRIDGE_IP="$bridge_ip"
            verbose "Sigul bridge container IP: $bridge_ip"
            # Export to GitHub Actions environment if available
            if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
                echo "bridge-ip=$bridge_ip" >> "$GITHUB_OUTPUT"
            fi
        else
            warn "Could not determine Sigul bridge container IP"
        fi
    else
        error "Failed to start Sigul bridge container"
        return 1
    fi

    # Enhanced bridge readiness check
    log "Waiting for Sigul bridge with monitoring..."
    attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        verbose "Sigul bridge readiness check (attempt $attempt/$max_attempts)..."

        # Check container status
        local bridge_status bridge_exit_code
        bridge_status=$(docker container inspect sigul-bridge --format '{{.State.Status}}' 2>/dev/null || echo "not found")
        bridge_exit_code=$(docker container inspect sigul-bridge --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")

        debug "Bridge container status: $bridge_status (exit code: $bridge_exit_code)"

        if [[ "$bridge_status" == "exited" ]]; then
            error "Sigul bridge container has exited (exit code: $bridge_exit_code)"

            error "Bridge container logs:"
            docker logs sigul-bridge 2>&1 | tail -20 | while read -r line; do
                error "  $line"
            done

            return 1
        elif [[ "$bridge_status" == "running" ]]; then
            # Test port connectivity
            if nc -z localhost 44334 2>/dev/null; then
                success "✅ Sigul bridge is responsive on port 44334"
                break
            else
                debug "Port 44334 not yet accessible"
            fi
        fi

        # Show progress every 15 attempts
        if [[ $((attempt % 15)) -eq 0 ]]; then
            log "Still waiting for Sigul bridge... (attempt $attempt/$max_attempts)"
        fi

        sleep 3
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        error "Sigul bridge failed to start within expected time ($max_attempts attempts)"
        return 1
    fi

    success "Sigul bridge deployed and ready (took $((attempt-1)) attempts)"
    success "All Sigul services deployed successfully"
}

# Comprehensive infrastructure health verification
verify_infrastructure() {
    log "Performing comprehensive infrastructure health verification..."

    local services=(
        "44334:Sigul Bridge:sigul-bridge"
    )

    local healthy_services=0
    local total_services=${#services[@]}

    for service in "${services[@]}"; do
        local port="${service%%:*}"
        local remaining="${service#*:}"
        local name="${remaining%%:*}"
        local container="${remaining#*:}"

        log "Testing $name (container: $container, port: $port)..."

        # Check container status
        local status health
        status=$(docker container inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "not found")
        health=$(docker container inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no health check")

        debug "Container status: $status, health: $health"

        if [[ "$status" != "running" ]]; then
            error "❌ Container $container is not running (status: $status)"
            continue
        fi

        # Test port connectivity with timeout
        verbose "Testing connectivity to $name on port $port..."
        if timeout 10 bash -c "until nc -z localhost $port; do sleep 1; done" 2>/dev/null; then
            success "✅ $name is accessible on port $port"
            ((healthy_services++))

            # Additional service-specific health checks
            case "$name" in
                "Sigul Bridge")
                    debug "Sigul Bridge port accessibility confirmed"
                    ;;
            esac
        else
            error "❌ $name is not accessible on port $port"
        fi
    done

    # Check server process health separately since it doesn't listen on a port
    log "Testing Sigul Server (process health check)..."
    if docker exec sigul-server pgrep -f server >/dev/null 2>&1; then
        success "✅ Sigul Server process is running"
        ((healthy_services++))
        ((total_services++))
    else
        error "❌ Sigul Server process is not running"
        ((total_services++))
    fi

    # Overall health assessment
    log "Infrastructure health summary: $healthy_services/$total_services services healthy"

    if [[ $healthy_services -eq $total_services ]]; then
        success "✅ All infrastructure services are healthy and accessible"

        # Verify bridge is ready to accept connections with proper retry logic
        log "Verifying bridge readiness for connections..."
        log "Initial wait: allowing bridge application 10 seconds to start listening..."
        sleep 10

        # Retry logic: check if bridge is listening internally
        local bridge_ready=false
        local max_retries=10
        local retry_interval=3
        local attempt=1

        while [[ $attempt -le $max_retries ]]; do
            debug "Bridge readiness check attempt $attempt/$max_retries..."

            if docker exec sigul-bridge ss -tlun | grep -q ":44334" 2>/dev/null; then
                bridge_ready=true
                success "✅ Bridge is listening and ready for connections (attempt $attempt)"
                break
            else
                debug "Bridge not yet listening on port 44334, waiting ${retry_interval} seconds..."
                if [[ $attempt -lt $max_retries ]]; then
                    sleep $retry_interval
                fi
                ((attempt++))
            fi
        done

        if [[ "$bridge_ready" != "true" ]]; then
            error "❌ Bridge is not listening on port 44334 after $max_retries attempts"
            error "Total wait time: $((10 + (max_retries - 1) * retry_interval)) seconds"
            return 1
        fi

        # Give server more time in GitHub Actions environment
        log "Allowing server initialization time before connectivity test..."
        if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
            log "GitHub Actions environment detected - using extended timing"
            sleep 10
        else
            sleep 3
        fi

        # Test actual connectivity: server connecting to bridge with retry logic
        log "Testing inter-service connectivity..."
        local connectivity_ok=false
        # Extended timing for GitHub Actions environment
        if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
            local max_attempts=15
            local sleep_interval=3
            debug "GitHub Actions environment: using 15 attempts with 3-second intervals (45 seconds max)"
        else
            local max_attempts=$((10 * timeout_multiplier))
            local sleep_interval=2
            debug "Local environment: using 10 attempts with 2-second intervals (20 seconds max)"
        fi
        local attempt=1

        while [[ $attempt -le $max_attempts ]]; do
            debug "Connectivity check attempt $attempt/$max_attempts..."

            if docker exec sigul-server ss -tun | grep -q ":44334" 2>/dev/null; then
                connectivity_ok=true
                success "✅ Inter-service network connectivity verified (server connected to bridge)"
                break
            else
                debug "Server not yet connected to bridge, waiting ${sleep_interval} seconds..."
                sleep ${sleep_interval}
                ((attempt++))
            fi
        done

        if [[ "$connectivity_ok" != "true" ]]; then
            local total_wait_time=$((max_attempts * sleep_interval))
            local env_info=""
            if is_github_actions; then
                env_info=" (GitHub Actions environment with extended timeouts)"
            fi
            error "❌ Inter-service connectivity test failed after ${total_wait_time} seconds${env_info} (server not connected to bridge)"
            debug "Environment: $(is_github_actions && echo "GitHub Actions" || echo "Local")"
            debug "Server network connections:"
            docker exec sigul-server ss -tun 2>/dev/null || true
            debug "Bridge network connections:"
            docker exec sigul-bridge ss -tun 2>/dev/null || true
            debug "Testing DNS resolution from server to bridge:"
            docker exec sigul-server nslookup sigul-bridge 2>/dev/null || docker exec sigul-server getent hosts sigul-bridge 2>/dev/null || true
            debug "Server bridge configuration:"
            docker exec sigul-server grep -A 3 -B 3 "bridge-hostname\|bridge-port" /var/sigul/config/server.conf 2>/dev/null || true
            debug "Bridge listening status:"
            docker exec sigul-bridge ss -tlun | grep 44334 2>/dev/null || true
            debug "Testing basic connectivity from server to bridge:"
            if docker exec sigul-server nc -z sigul-bridge 44334 2>/dev/null; then
                debug "✅ Basic TCP connection works"
            else
                debug "❌ Basic TCP connection failed"
            fi
            debug "Container runtime information:"
            docker version --format '{{.Server.Version}}' 2>/dev/null || true
            debug "Network driver information:"
            docker network inspect sigul-sign-docker_sigul-network --format '{{.Driver}}' 2>/dev/null || true
            if is_github_actions; then
                debug "GitHub Actions runner information:"
                echo "Runner OS: ${RUNNER_OS:-unknown}"
                echo "Runner Arch: ${RUNNER_ARCH:-unknown}"
                debug "System resource usage:"
                docker exec sigul-server sh -c "cat /proc/loadavg" 2>/dev/null || true
                debug "Available memory:"
                docker exec sigul-server sh -c "free -h" 2>/dev/null || true
            fi
            return 1
        fi

        return 0
    else
        error "❌ Infrastructure health check failed: only $healthy_services/$total_services services are healthy"

        # Show detailed status of failed services
        log "Detailed container status for debugging:"
        docker ps -a --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | while read -r line; do
            error "  $line"
        done

        return 1
    fi
}

# Main deployment orchestration
deploy_infrastructure() {
    log "Starting comprehensive Sigul infrastructure deployment..."
    local start_time
    start_time=$(date +%s)

    # Enhanced deployment steps with better error handling
    analyze_environment || { error "Environment analysis failed"; return 1; }
    check_prerequisites || { error "Prerequisites check failed"; return 1; }
    setup_pki_infrastructure || { error "PKI infrastructure setup failed"; return 1; }
    generate_configurations || { error "Configuration generation failed"; return 1; }
    load_infrastructure_images || { error "Image loading failed"; return 1; }

    deploy_sigul_services || { error "Sigul services deployment failed"; return 1; }
    verify_infrastructure || { error "Infrastructure verification failed"; return 1; }

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    success "🎉 Sigul infrastructure deployment completed successfully in ${duration} seconds"

    log "Infrastructure components summary:"
    log "  🖥️  Sigul Server: sigul-server (connects to bridge)"
    log "  🌉 Sigul Bridge: sigul-bridge (port 44334)"
    log "  🔐 PKI Certificates: pki/ directory"
    log "  ⚙️  Configuration Files: configs/ directory"
    log "  🕒 Total Deployment Time: ${duration} seconds"

    debug "Final container status:"
    docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | while read -r line; do
        debug "  $line"
    done
}

# Main function
main() {
    parse_args "$@"

    if [[ "${SHOW_HELP}" == "true" ]]; then
        show_help
        exit 0
    fi

    log "=== Sigul Infrastructure Deployment ==="
    log "Verbose mode: ${VERBOSE_MODE}"
    log "Debug mode: ${DEBUG_MODE}"
    log "Project root: ${PROJECT_ROOT}"
    log "Runner platform: ${SIGUL_RUNNER_PLATFORM:-auto-detect}"
    log "Docker platform: ${SIGUL_DOCKER_PLATFORM:-auto-detect}"

    # Ensure we're in the correct directory
    cd "$PROJECT_ROOT"

    # Run deployment with comprehensive error handling
    if deploy_infrastructure; then
        success "=== Deployment Completed Successfully ==="
        exit 0
    else
        error "=== Deployment Failed ==="
        error "Check the logs above for specific error details"
        error "Consider running with --debug flag for more detailed output"
        exit 1
    fi
}

# Execute main function with all arguments
main "$@"
