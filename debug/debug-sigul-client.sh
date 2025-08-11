#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Debug script for Sigul client connectivity and authentication issues
#
# This script helps diagnose why sigul client commands are failing
# by providing detailed debugging information and step-by-step validation.

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

debug() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
}

# Function to check if containers are running
check_containers() {
    log "=== Container Status Check ==="

    echo "Running containers:"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
    echo

    # Check specific sigul containers
    local containers=("sigul-server" "sigul-bridge" "sigul-client-integration")
    for container in "${containers[@]}"; do
        if docker ps --filter "name=$container" --filter "status=running" | grep -q "$container"; then
            success "Container $container is running"
        else
            error "Container $container is NOT running"
            # Show recent logs if container exists but isn't running
            if docker ps -a --filter "name=$container" | grep -q "$container"; then
                warn "Recent logs for $container:"
                docker logs "$container" --tail 10 2>/dev/null || true
            fi
        fi
    done
    echo
}

# Function to check network connectivity
check_network() {
    log "=== Network Connectivity Check ==="

    local network_name
    network_name=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1)

    if [[ -n "$network_name" ]]; then
        success "Found Sigul network: $network_name"

        # Show network details
        debug "Network details:"
        docker network inspect "$network_name" --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null || true

        # Test connectivity from client to bridge and server
        local client_container="sigul-client-integration"
        if docker ps --filter "name=$client_container" --filter "status=running" | grep -q "$client_container"; then
            debug "Testing network connectivity from client container..."

            # Test bridge connectivity
            if docker exec "$client_container" ping -c 1 sigul-bridge >/dev/null 2>&1; then
                success "Client can reach sigul-bridge"
            else
                error "Client CANNOT reach sigul-bridge"
            fi

            # Test server connectivity
            if docker exec "$client_container" ping -c 1 sigul-server >/dev/null 2>&1; then
                success "Client can reach sigul-server"
            else
                error "Client CANNOT reach sigul-server"
            fi

            # Test port connectivity
            debug "Testing port connectivity..."
            if docker exec "$client_container" nc -z sigul-bridge 44334 2>/dev/null; then
                success "Client can connect to sigul-bridge:44334"
            else
                error "Client CANNOT connect to sigul-bridge:44334"
            fi
        fi
    else
        error "No Sigul network found"
    fi
    echo
}

# Function to check configuration files
check_configuration() {
    log "=== Configuration Check ==="

    local client_container="sigul-client-integration"
    if ! docker ps --filter "name=$client_container" --filter "status=running" | grep -q "$client_container"; then
        error "Client container is not running"
        return 1
    fi

    # Check client configuration
    debug "Checking client configuration file..."
    if docker exec "$client_container" test -f /etc/sigul/client.conf; then
        success "Client configuration file exists"
        debug "Client configuration content:"
        docker exec "$client_container" cat /etc/sigul/client.conf 2>/dev/null || true
    else
        error "Client configuration file missing"
    fi
    echo

    # Check CA certificate
    debug "Checking CA certificate..."
    if docker exec "$client_container" test -f /opt/sigul/pki/ca.crt; then
        success "CA certificate exists"
        debug "CA certificate info:"
        docker exec "$client_container" openssl x509 -in /opt/sigul/pki/ca.crt -text -noout | head -10 2>/dev/null || true
    else
        error "CA certificate missing"
    fi
    echo

    # Check NSS database
    debug "Checking NSS database..."
    if docker exec "$client_container" test -d /opt/sigul/pki/nssdb; then
        success "NSS database directory exists"
        debug "NSS database contents:"
        docker exec "$client_container" ls -la /opt/sigul/pki/nssdb/ 2>/dev/null || true

        # Try to list certificates in NSS database
        debug "NSS certificates:"
        docker exec "$client_container" certutil -L -d /opt/sigul/pki/nssdb 2>/dev/null || warn "Could not list NSS certificates"
    else
        error "NSS database directory missing"
    fi
    echo
}

# Function to check environment variables and passwords
check_environment() {
    log "=== Environment Check ==="

    local client_container="sigul-client-integration"
    if ! docker ps --filter "name=$client_container" --filter "status=running" | grep -q "$client_container"; then
        error "Client container is not running"
        return 1
    fi

    debug "Environment variables in client container:"
    docker exec "$client_container" env | grep -E "(SIGUL|NSS|DEBUG)" || warn "No relevant environment variables found"
    echo

    # Check if admin password file exists
    local admin_password_file="${PROJECT_ROOT}/test-artifacts/admin-password"
    if [[ -f "$admin_password_file" ]]; then
        success "Admin password file exists"
        debug "Admin password length: $(wc -c < "$admin_password_file") characters"
    else
        error "Admin password file missing: $admin_password_file"
    fi
    echo
}

# Function to test basic sigul commands with detailed output
test_sigul_commands() {
    log "=== Sigul Command Testing ==="

    local client_container="sigul-client-integration"
    if ! docker ps --filter "name=$client_container" --filter "status=running" | grep -q "$client_container"; then
        error "Client container is not running"
        return 1
    fi

    # Load admin password
    local admin_password_file="${PROJECT_ROOT}/test-artifacts/admin-password"
    if [[ ! -f "$admin_password_file" ]]; then
        error "Cannot load admin password for testing"
        return 1
    fi
    local admin_password
    admin_password=$(cat "$admin_password_file")

    # Test 1: Basic sigul help command
    debug "Testing basic sigul help command..."
    if docker exec "$client_container" sigul --help >/dev/null 2>&1; then
        success "Sigul help command works"
    else
        error "Sigul help command failed"
        docker exec "$client_container" sigul --help 2>&1 || true
    fi
    echo

    # Test 2: Test configuration parsing
    debug "Testing sigul configuration parsing..."
    if docker exec "$client_container" sigul -c /etc/sigul/client.conf --help >/dev/null 2>&1; then
        success "Sigul can parse configuration file"
    else
        error "Sigul cannot parse configuration file"
        docker exec "$client_container" sigul -c /etc/sigul/client.conf --help 2>&1 || true
    fi
    echo

    # Test 3: Test list-users command with detailed output
    debug "Testing list-users command with admin credentials..."
    debug "Running: sigul -c /etc/sigul/client.conf list-users --admin-name admin --admin-password [REDACTED]"

    if docker exec "$client_container" sigul -c /etc/sigul/client.conf list-users --admin-name admin --admin-password "$admin_password" 2>&1; then
        success "List-users command succeeded"
    else
        local exit_code=$?
        error "List-users command failed with exit code: $exit_code"

        # Get detailed container logs
        debug "Recent container logs:"
        docker logs "$client_container" --tail 20 2>/dev/null || true

        # Try to get more specific error information
        debug "Attempting command with verbose output..."
        docker exec "$client_container" sigul -v -c /etc/sigul/client.conf list-users --admin-name admin --admin-password "$admin_password" 2>&1 || true
    fi
    echo

    # Test 4: Test simple connection without authentication
    debug "Testing basic connectivity to bridge..."
    if docker exec "$client_container" timeout 5 bash -c "echo 'test' | nc sigul-bridge 44334" 2>/dev/null; then
        success "Can establish TCP connection to bridge"
    else
        error "Cannot establish TCP connection to bridge"
    fi
    echo
}

# Function to check server and bridge status
check_server_bridge_status() {
    log "=== Server and Bridge Status Check ==="

    # Check server logs
    debug "Recent server logs:"
    if docker ps --filter "name=sigul-server" --filter "status=running" | grep -q "sigul-server"; then
        docker logs "sigul-server" --tail 20 2>/dev/null || warn "Could not get server logs"
    else
        warn "Server container not running"
    fi
    echo

    # Check bridge logs
    debug "Recent bridge logs:"
    if docker ps --filter "name=sigul-bridge" --filter "status=running" | grep -q "sigul-bridge"; then
        docker logs "sigul-bridge" --tail 20 2>/dev/null || warn "Could not get bridge logs"
    else
        warn "Bridge container not running"
    fi
    echo
}

# Function to test NSS database functionality
test_nss_database() {
    log "=== NSS Database Testing ==="

    local client_container="sigul-client-integration"
    if ! docker ps --filter "name=$client_container" --filter "status=running" | grep -q "$client_container"; then
        error "Client container is not running"
        return 1
    fi

    # Test NSS database access
    debug "Testing NSS database access..."
    if docker exec "$client_container" certutil -L -d /opt/sigul/pki/nssdb 2>/dev/null; then
        success "Can access NSS database"
    else
        error "Cannot access NSS database"

        # Check if password is needed
        debug "Trying with password..."
        local admin_password_file="${PROJECT_ROOT}/test-artifacts/admin-password"
        if [[ -f "$admin_password_file" ]]; then
            local admin_password
            admin_password=$(cat "$admin_password_file")
            echo "$admin_password" | docker exec -i "$client_container" certutil -L -d /opt/sigul/pki/nssdb 2>/dev/null || warn "NSS database access with password also failed"
        fi
    fi
    echo
}

# Main execution function
main() {
    log "=== Sigul Client Debug Script ==="
    log "Starting comprehensive debugging session..."
    echo

    check_containers
    check_network
    check_configuration
    check_environment
    check_server_bridge_status
    test_nss_database
    test_sigul_commands

    log "=== Debug Session Complete ==="
    log "Review the output above to identify the root cause of sigul client failures."
}

# Execute main function
main "$@"
