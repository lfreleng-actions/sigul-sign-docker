#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Test script to verify shared CA certificate approach
#
# This script tests if the shared CA certificate fixes the certificate
# trust issues between Sigul components by:
# 1. Rebuilding containers with shared CA
# 2. Starting infrastructure
# 3. Testing certificate chain validation
# 4. Running basic sigul client commands

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# Function to check if shared CA exists
check_shared_ca() {
    log "Checking for shared CA certificate..."

    if [[ -f "$PROJECT_ROOT/pki/ca.crt" && -f "$PROJECT_ROOT/pki/ca-key.pem" ]]; then
        success "Shared CA certificate found"
        debug "CA certificate details:"
        openssl x509 -in "$PROJECT_ROOT/pki/ca.crt" -subject -issuer -dates -noout | sed 's/^/  /'
        return 0
    else
        error "Shared CA certificate not found"
        error "Run './pki/setup-ca.sh' to generate the shared CA"
        return 1
    fi
}

# Function to rebuild containers with shared CA
rebuild_containers() {
    log "Rebuilding containers with shared CA..."

    # Set platform for consistency
    local platform_id="linux-amd64"

    # Build server
    debug "Building server container..."
    if docker build -f Dockerfile.server -t "server-${platform_id}-image:test" . >/dev/null 2>&1; then
        success "Server container built successfully"
    else
        error "Failed to build server container"
        return 1
    fi

    # Build bridge
    debug "Building bridge container..."
    if docker build -f Dockerfile.bridge -t "bridge-${platform_id}-image:test" . >/dev/null 2>&1; then
        success "Bridge container built successfully"
    else
        error "Failed to build bridge container"
        return 1
    fi

    # Build client
    debug "Building client container..."
    if docker build -f Dockerfile.client -t "client-${platform_id}-image:test" . >/dev/null 2>&1; then
        success "Client container built successfully"
    else
        error "Failed to build client container"
        return 1
    fi

    success "All containers rebuilt with shared CA"
}

# Function to start infrastructure
start_infrastructure() {
    log "Starting Sigul infrastructure..."

    # Set environment variables
    export SIGUL_SERVER_IMAGE="server-linux-amd64-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-linux-amd64-image:test"
    export SIGUL_CLIENT_IMAGE="client-linux-amd64-image:test"
    # Declare and assign separately to avoid masking return values
    NSS_PASSWORD="$(openssl rand -base64 16)"
    export NSS_PASSWORD
    SIGUL_ADMIN_PASSWORD="$(openssl rand -base64 16)"
    export SIGUL_ADMIN_PASSWORD

    # Save admin password for testing
    mkdir -p "$PROJECT_ROOT/test-artifacts"
    echo "$SIGUL_ADMIN_PASSWORD" > "$PROJECT_ROOT/test-artifacts/admin-password"

    # Stop any existing infrastructure
    docker compose -f docker-compose.sigul.yml down >/dev/null 2>&1 || true

    # Start infrastructure
    debug "Starting containers..."
    if docker compose -f docker-compose.sigul.yml up -d >/dev/null 2>&1; then
        success "Infrastructure started"
    else
        error "Failed to start infrastructure"
        return 1
    fi

    # Wait for containers to initialize
    debug "Waiting for containers to initialize..."
    sleep 15

    # Check container status
    local running_containers
    running_containers=$(docker ps --filter "name=sigul" --format "{{.Names}}" | wc -l)
    if [[ $running_containers -ge 2 ]]; then
        success "Infrastructure containers running ($running_containers containers)"
    else
        error "Not all containers are running"
        docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}"
        return 1
    fi
}

# Function to test certificate chain validation
test_certificate_chain() {
    log "Testing certificate chain validation..."

    # Test server certificate
    debug "Testing server certificate against shared CA..."
    if docker exec sigul-server openssl verify -CAfile /workspace/pki/ca.crt /var/sigul/secrets/certificates/server.crt >/dev/null 2>&1; then
        success "✓ Server certificate validates against shared CA"
    else
        error "✗ Server certificate validation failed"
        return 1
    fi

    # Test bridge certificate
    debug "Testing bridge certificate against shared CA..."
    if docker exec sigul-bridge openssl verify -CAfile /workspace/pki/ca.crt /var/sigul/secrets/certificates/bridge.crt >/dev/null 2>&1; then
        success "✓ Bridge certificate validates against shared CA"
    else
        error "✗ Bridge certificate validation failed"
        return 1
    fi

    # Test that all containers have the same CA
    debug "Verifying all containers have the same CA..."
    local server_ca_hash bridge_ca_hash
    server_ca_hash=$(docker exec sigul-server openssl x509 -in /var/sigul/secrets/certificates/ca.crt -noout -fingerprint -sha256)
    bridge_ca_hash=$(docker exec sigul-bridge openssl x509 -in /var/sigul/secrets/certificates/ca.crt -noout -fingerprint -sha256)

    if [[ "$server_ca_hash" == "$bridge_ca_hash" ]]; then
        success "✓ All containers have the same CA certificate"
    else
        error "✗ Containers have different CA certificates"
        return 1
    fi
}

# Function to test network connectivity
test_network_connectivity() {
    log "Testing network connectivity..."

    # Test bridge port
    debug "Testing bridge port connectivity..."
    if docker exec sigul-server nc -z sigul-bridge 44334 2>/dev/null; then
        success "✓ Server can connect to bridge port"
    else
        error "✗ Server cannot connect to bridge port"
        return 1
    fi

    # Test TLS handshake
    debug "Testing TLS handshake..."
    if docker exec sigul-server timeout 5 openssl s_client -connect sigul-bridge:44334 -verify_return_error </dev/null >/dev/null 2>&1; then
        success "✓ TLS handshake successful between server and bridge"
    else
        error "✗ TLS handshake failed"
        debug "TLS connection details:"
        docker exec sigul-server timeout 5 openssl s_client -connect sigul-bridge:44334 </dev/null 2>&1 | head -10 || true
        return 1
    fi
}

# Function to test basic sigul commands
test_sigul_commands() {
    log "Testing basic sigul commands..."

    # Start a test client container
    local client_container="test-sigul-client"
    local network_name
    network_name=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1)

    debug "Starting test client container..."
    docker rm -f "$client_container" 2>/dev/null || true

    if ! docker run -d --name "$client_container" \
        --network "$network_name" \
        --user sigul \
        -e SIGUL_ROLE=client \
        -e SIGUL_BRIDGE_HOSTNAME=sigul-bridge \
        -e SIGUL_BRIDGE_CLIENT_PORT=44334 \
        -e NSS_PASSWORD="$NSS_PASSWORD" \
        -e DEBUG=true \
        "$SIGUL_CLIENT_IMAGE" \
        tail -f /dev/null >/dev/null 2>&1; then
        error "Failed to start test client"
        return 1
    fi

    # Wait for client to start
    sleep 3

    # Initialize client
    debug "Initializing test client..."
    if docker exec "$client_container" /usr/local/bin/sigul-init.sh --role client >/dev/null 2>&1; then
        success "✓ Client initialization successful"
    else
        error "✗ Client initialization failed"
        docker logs "$client_container" --tail 10 || true
        docker rm -f "$client_container" 2>/dev/null || true
        return 1
    fi

    # Test sigul command
    debug "Testing sigul list-users command..."
    local admin_password
    admin_password=$(cat "$PROJECT_ROOT/test-artifacts/admin-password")

    if docker exec "$client_container" sigul -c /var/sigul/config/client.conf list-users --admin-name admin --admin-password "$admin_password" >/dev/null 2>&1; then
        success "✓ Sigul list-users command successful"
    else
        error "✗ Sigul list-users command failed"
        debug "Command output:"
        docker exec "$client_container" sigul -c /var/sigul/config/client.conf list-users --admin-name admin --admin-password "$admin_password" 2>&1 || true
        docker rm -f "$client_container" 2>/dev/null || true
        return 1
    fi

    # Cleanup test client
    docker rm -f "$client_container" 2>/dev/null || true
    success "✓ Basic sigul commands working"
}

# Function to cleanup
cleanup() {
    debug "Cleaning up test infrastructure..."
    docker compose -f docker-compose.sigul.yml down >/dev/null 2>&1 || true
    docker rm -f test-sigul-client 2>/dev/null || true
}

# Main execution
main() {
    log "=== Testing Shared CA Certificate Approach ==="

    # Change to project root
    cd "$PROJECT_ROOT"

    local test_failed=false

    # Run tests step by step
    if ! check_shared_ca; then
        error "Shared CA check failed"
        exit 1
    elif ! rebuild_containers; then
        error "Container rebuild failed"
        test_failed=true
    elif ! start_infrastructure; then
        error "Infrastructure startup failed"
        test_failed=true
    elif ! test_certificate_chain; then
        error "Certificate chain validation failed"
        test_failed=true
    elif ! test_network_connectivity; then
        error "Network connectivity test failed"
        test_failed=true
    elif ! test_sigul_commands; then
        error "Sigul command test failed"
        test_failed=true
    fi

    # Cleanup regardless of test result
    cleanup

    if [[ "$test_failed" == "true" ]]; then
        error "=== Shared CA test FAILED ==="
        exit 1
    else
        success "=== Shared CA test PASSED ==="
        success "The shared CA approach successfully fixes certificate trust issues!"
        exit 0
    fi
}

# Execute main function
main "$@"
