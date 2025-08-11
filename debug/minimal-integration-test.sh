#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Minimal Sigul Integration Test
#
# This script runs minimal tests to diagnose the core authentication and
# connection issues with the current Sigul setup. It focuses on understanding
# why sigul client commands are failing with exit code 1.
#
# Key approach:
# 1. Use only the unified sigul-init.sh approach (no volume mounts)
# 2. Test step-by-step to isolate the failure point
# 3. Provide detailed debugging output at each step

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Required environment variables
: "${SIGUL_CLIENT_IMAGE?Error: SIGUL_CLIENT_IMAGE environment variable must be set}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
# YELLOW='\033[1;33m'  # Unused, commented out to fix shellcheck warning
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $*"
}

debug() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
}

# Function to get the Sigul network name
get_sigul_network_name() {
    local network_name
    network_name=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1)

    if [[ -n "$network_name" ]]; then
        echo "$network_name"
        return 0
    fi

    # Fallback
    echo "sigul-sign-docker_sigul-network"
}

# Function to load admin password
load_admin_password() {
    local admin_password_file="${PROJECT_ROOT}/test-artifacts/admin-password"

    if [[ -f "$admin_password_file" ]]; then
        ADMIN_PASSWORD=$(cat "$admin_password_file")
        debug "Loaded admin password (length: ${#ADMIN_PASSWORD} chars)"
        return 0
    else
        error "Admin password file not found: $admin_password_file"
        return 1
    fi
}

# Function to start minimal client container
start_minimal_client() {
    local network_name="$1"
    local container_name="sigul-minimal-client"

    log "Starting minimal client container..."

    # Remove any existing container
    docker rm -f "$container_name" 2>/dev/null || true

    # Start client container with minimal setup
    if ! docker run -d --name "$container_name" \
        --network "$network_name" \
        --user sigul \
        -e SIGUL_ROLE=client \
        -e SIGUL_BRIDGE_HOSTNAME=sigul-bridge \
        -e SIGUL_BRIDGE_CLIENT_PORT=44334 \
        -e NSS_PASSWORD="$ADMIN_PASSWORD" \
        -e DEBUG=true \
        "$SIGUL_CLIENT_IMAGE" \
        tail -f /dev/null; then
        error "Failed to start minimal client container"
        return 1
    fi

    # Wait for container to start
    sleep 3

    if ! docker ps --filter "name=$container_name" --filter "status=running" | grep -q "$container_name"; then
        error "Minimal client container failed to start"
        docker logs "$container_name" 2>/dev/null || true
        return 1
    fi

    success "Minimal client container started"
    return 0
}

# Function to initialize client
initialize_client() {
    local container_name="sigul-minimal-client"

    log "Initializing sigul client..."

    debug "Running sigul-init.sh --role client"
    if docker exec "$container_name" /usr/local/bin/sigul-init.sh --role client; then
        success "Client initialization completed"

        # Show what was created
        debug "Files created during initialization:"
        docker exec "$container_name" find /var/sigul -type f 2>/dev/null | head -20 || true

        return 0
    else
        error "Client initialization failed"
        debug "Container logs after failed initialization:"
        docker logs "$container_name" --tail 20 2>/dev/null || true
        return 1
    fi
}

# Function to test basic client setup
test_client_setup() {
    local container_name="sigul-minimal-client"

    log "Testing client setup..."

    # Test 1: Check if client config exists
    debug "Test 1: Client configuration file"
    if docker exec "$container_name" test -f /var/sigul/config/client.conf; then
        success "✓ Client configuration exists"
        debug "Client configuration content:"
        docker exec "$container_name" cat /var/sigul/config/client.conf || true
    else
        error "✗ Client configuration missing"
        return 1
    fi

    # Test 2: Check NSS database
    debug "Test 2: NSS database"
    if docker exec "$container_name" test -d /var/sigul/nss/client; then
        success "✓ NSS database directory exists"
        debug "NSS database files:"
        docker exec "$container_name" ls -la /var/sigul/nss/client/ || true
    else
        error "✗ NSS database missing"
        return 1
    fi

    # Test 3: Check certificates
    debug "Test 3: Certificate files"
    if docker exec "$container_name" test -f /var/sigul/secrets/certificates/ca.crt; then
        success "✓ CA certificate exists"
        debug "CA certificate info:"
        docker exec "$container_name" openssl x509 -in /var/sigul/secrets/certificates/ca.crt -subject -issuer -noout 2>/dev/null || true
    else
        error "✗ CA certificate missing"
        return 1
    fi

    return 0
}

# Function to test sigul command basics
test_sigul_command_basics() {
    local container_name="sigul-minimal-client"

    log "Testing basic sigul command functionality..."

    # Test 1: Sigul help command
    debug "Test 1: sigul --help"
    if docker exec "$container_name" sigul --help >/dev/null 2>&1; then
        success "✓ sigul --help works"
    else
        error "✗ sigul --help failed"
        docker exec "$container_name" sigul --help || true
        return 1
    fi

    # Test 2: Config file parsing
    debug "Test 2: Configuration file parsing"
    if docker exec "$container_name" sigul -c /var/sigul/config/client.conf --help >/dev/null 2>&1; then
        success "✓ Configuration file parsing works"
    else
        error "✗ Configuration file parsing failed"
        docker exec "$container_name" sigul -c /var/sigul/config/client.conf --help || true
        return 1
    fi

    return 0
}

# Function to test network connectivity
test_network_connectivity() {
    local container_name="sigul-minimal-client"

    log "Testing network connectivity..."

    # Test 1: Bridge hostname resolution
    debug "Test 1: Bridge hostname resolution"
    if docker exec "$container_name" nslookup sigul-bridge >/dev/null 2>&1; then
        success "✓ Can resolve sigul-bridge hostname"
        debug "Bridge IP address:"
        docker exec "$container_name" nslookup sigul-bridge | grep "Address:" | tail -1 || true
    else
        error "✗ Cannot resolve sigul-bridge hostname"
        return 1
    fi

    # Test 2: Bridge port connectivity
    debug "Test 2: Bridge port connectivity"
    if docker exec "$container_name" nc -z sigul-bridge 44334 2>/dev/null; then
        success "✓ Can connect to sigul-bridge:44334"
    else
        error "✗ Cannot connect to sigul-bridge:44334"
        debug "Available listening ports on bridge:"
        docker exec sigul-bridge netstat -tuln 2>/dev/null || true
        return 1
    fi

    # Test 3: TLS handshake test
    debug "Test 3: TLS handshake"
    if docker exec "$container_name" timeout 5 openssl s_client -connect sigul-bridge:44334 -verify_return_error </dev/null >/dev/null 2>&1; then
        success "✓ TLS handshake successful"
    else
        error "✗ TLS handshake failed"
        debug "TLS handshake details:"
        docker exec "$container_name" timeout 5 openssl s_client -connect sigul-bridge:44334 -verify_return_error </dev/null 2>&1 | head -20 || true
        return 1
    fi

    return 0
}

# Function to test admin authentication
test_admin_authentication() {
    local container_name="sigul-minimal-client"

    log "Testing admin authentication..."

    debug "Attempting list-users with admin credentials"
    debug "Command: sigul -c /var/sigul/config/client.conf list-users --admin-name admin --admin-password [REDACTED]"

    # Capture both stdout and stderr
    local cmd_output
    local exit_code

    cmd_output=$(docker exec "$container_name" sigul -c /var/sigul/config/client.conf list-users --admin-name admin --admin-password "$ADMIN_PASSWORD" 2>&1) || exit_code=$?

    if [[ ${exit_code:-0} -eq 0 ]]; then
        success "✓ Admin authentication successful"
        debug "Command output:"
        echo "$cmd_output"
        return 0
    else
        error "✗ Admin authentication failed (exit code: ${exit_code:-unknown})"
        debug "Command output:"
        echo "$cmd_output"

        # Try to get more debugging info
        debug "Recent container logs:"
        docker logs "$container_name" --tail 10 || true

        return 1
    fi
}

# Function to show infrastructure status
show_infrastructure_status() {
    log "Infrastructure status check..."

    debug "Running containers:"
    docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true

    debug "Server container logs (last 5 lines):"
    docker logs sigul-server --tail 5 2>/dev/null || echo "  (no server logs available)"

    debug "Bridge container logs (last 5 lines):"
    docker logs sigul-bridge --tail 5 2>/dev/null || echo "  (no bridge logs available)"

    debug "Network information:"
    local network_name
    network_name=$(get_sigul_network_name)
    docker network inspect "$network_name" --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null || echo "  (network info unavailable)"
}

# Function to cleanup
cleanup() {
    local container_name="sigul-minimal-client"
    debug "Cleaning up minimal client container..."
    docker rm -f "$container_name" 2>/dev/null || true
}

# Main test execution
main() {
    log "=== Minimal Sigul Integration Test ==="

    # Load admin password
    if ! load_admin_password; then
        error "Cannot proceed without admin password"
        exit 1
    fi

    # Show current infrastructure status
    show_infrastructure_status

    # Get network name
    local network_name
    network_name=$(get_sigul_network_name)
    debug "Using Docker network: $network_name"

    # Run tests step by step
    local test_failed=false

    if ! start_minimal_client "$network_name"; then
        error "Failed to start client container"
        exit 1
    fi

    if ! initialize_client; then
        error "Failed to initialize client"
        test_failed=true
    elif ! test_client_setup; then
        error "Client setup test failed"
        test_failed=true
    elif ! test_sigul_command_basics; then
        error "Basic sigul command test failed"
        test_failed=true
    elif ! test_network_connectivity; then
        error "Network connectivity test failed"
        test_failed=true
    elif ! test_admin_authentication; then
        error "Admin authentication test failed"
        test_failed=true
    fi

    # Cleanup
    cleanup

    if [[ "$test_failed" == "true" ]]; then
        error "=== Minimal integration test FAILED ==="
        exit 1
    else
        success "=== Minimal integration test PASSED ==="
        exit 0
    fi
}

# Run main function
main "$@"
