#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Corrected Sigul Integration Tests Script
#
# This script fixes the volume mount and authentication issues in the original
# integration test by using the proper paths expected by the unified sigul-init.sh
#
# Key corrections:
# 1. Mount volumes to correct paths (/var/sigul/config, /var/sigul/nss)
# 2. Use admin user for initial setup instead of non-existent integration-tester
# 3. Create integration-tester user first, then test with it
# 4. Use proper certificate paths in client configuration

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default options
VERBOSE_MODE=false

# Configurable image names
: "${SIGUL_CLIENT_IMAGE?Error: SIGUL_CLIENT_IMAGE environment variable must be set}"
: "${SIGUL_SERVER_IMAGE?Error: SIGUL_SERVER_IMAGE environment variable must be set}"
: "${SIGUL_BRIDGE_IMAGE?Error: SIGUL_BRIDGE_IMAGE environment variable must be set}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

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
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

verbose() {
    debug "$@"
}

# Test result functions
test_pass() {
    local test_name="$1"
    ((TESTS_PASSED++))
    success "✅ $test_name: PASSED"
}

test_fail() {
    local test_name="$1"
    local reason="$2"
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$test_name: $reason")
    error "❌ $test_name: FAILED - $reason"
}

# Function to detect platform and set missing environment variables
detect_and_set_environment() {
    local platform_id=""
    local arch
    arch=$(uname -m)

    case $arch in
        x86_64)
            platform_id="linux-amd64"
            ;;
        aarch64|arm64)
            platform_id="linux-arm64"
            ;;
        *)
            error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    verbose "Platform detection completed: ${platform_id}"
}

# Function to load ephemeral passwords generated during deployment
load_ephemeral_passwords() {
    local admin_password_file="${PROJECT_ROOT}/test-artifacts/admin-password"

    # Load admin password
    if [[ -f "$admin_password_file" ]]; then
        EPHEMERAL_ADMIN_PASSWORD=$(cat "$admin_password_file")
        verbose "Loaded ephemeral admin password from deployment"
    else
        error "Ephemeral admin password not found. Deployment may have failed."
        return 1
    fi

    # Generate ephemeral test user password
    EPHEMERAL_TEST_PASSWORD=$(openssl rand -base64 12)
    verbose "Generated ephemeral test user password"

    return 0
}

# Function to detect the Docker network name created by docker-compose
get_sigul_network_name() {
    local network_name

    # Try to find the network created by docker-compose
    network_name=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1)

    if [[ -n "$network_name" ]]; then
        echo "$network_name"
        return 0
    fi

    # Fallback: construct expected network name
    local project_name="sigul-sign-docker"
    echo "${project_name}_sigul-network"
}

# Function to create corrected client configuration
create_corrected_client_config() {
    local config_dir="${PROJECT_ROOT}/test-artifacts/corrected-config"
    mkdir -p "$config_dir"

    # Create client configuration that uses admin user initially
    cat > "$config_dir/client.conf" << 'EOF'
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

[client]
bridge-hostname = sigul-bridge
bridge-port = 44334
server-hostname = sigul-server
max-file-payload-size = 2097152
username = admin

# TLS Configuration using unified certificate paths
ca-cert-file = /var/sigul/secrets/certificates/ca.crt
require-tls = true
verify-server-cert = true
EOF

    verbose "Created corrected client configuration at $config_dir/client.conf"
}

# Function to start corrected client container
start_corrected_client_container() {
    local network_name="$1"
    local client_container_name="sigul-client-corrected"

    log "Starting corrected client container for integration tests..."

    # Remove any existing client container
    docker rm -f "$client_container_name" 2>/dev/null || true

    # Create corrected client configuration
    create_corrected_client_config

    # Start the client container with corrected volume mounts
    if ! docker run -d --name "$client_container_name" \
        --network "$network_name" \
        --user sigul \
        -v "${PROJECT_ROOT}/test-artifacts/corrected-config:/var/sigul/config:ro" \
        -v "${PROJECT_ROOT}:/workspace:rw" \
        -w /workspace \
        -e SIGUL_ROLE=client \
        -e SIGUL_MOCK_MODE=false \
        -e NSS_PASSWORD="${EPHEMERAL_ADMIN_PASSWORD}" \
        -e DEBUG=true \
        "$SIGUL_CLIENT_IMAGE" \
        tail -f /dev/null; then
        error "Failed to start corrected client container"
        return 1
    fi

    # Wait for container to start
    sleep 3

    # Verify container is running
    if ! docker ps --filter "name=$client_container_name" --filter "status=running" | grep -q "$client_container_name"; then
        error "Corrected client container failed to start properly"
        docker logs "$client_container_name" || true
        return 1
    fi

    # Initialize the client in the container
    verbose "Initializing sigul client in corrected container..."
    verbose "Client container logs before init:"
    docker logs "$client_container_name" 2>/dev/null || true

    if docker exec "$client_container_name" /usr/local/bin/sigul-init.sh --role client 2>&1; then
        success "Corrected client container initialized successfully"

        # Verify basic client functionality
        verbose "Testing basic client configuration..."
        if docker exec "$client_container_name" test -f /var/sigul/config/client.conf; then
            verbose "Client configuration file found at correct path"
        else
            warn "Client configuration file not found at expected path"
        fi

        if docker exec "$client_container_name" test -d /var/sigul/nss/client; then
            verbose "Client NSS database found at correct path"
        else
            warn "Client NSS database not found at expected path"
        fi

        return 0
    else
        error "Failed to initialize corrected client container"
        verbose "Client initialization logs:"
        docker logs "$client_container_name" 2>/dev/null || true
        return 1
    fi
}

# Function to stop corrected client container
stop_corrected_client_container() {
    local client_container_name="sigul-client-corrected"
    verbose "Stopping corrected client container..."
    docker rm -f "$client_container_name" 2>/dev/null || true
}

# Function to run sigul commands in corrected client container
run_corrected_sigul_command() {
    local cmd=("$@")
    local client_container_name="sigul-client-corrected"

    verbose "Running corrected sigul client command: ${cmd[*]}"

    # Check if container is still running
    if ! docker ps --filter "name=$client_container_name" --filter "status=running" | grep -q "$client_container_name"; then
        error "Corrected client container is not running"
        return 1
    fi

    # Run the command with better error handling
    if docker exec "$client_container_name" "${cmd[@]}"; then
        return 0
    else
        local exit_code=$?
        verbose "Command failed with exit code: $exit_code"
        verbose "Container logs:"
        docker logs "$client_container_name" --tail 20 2>/dev/null || true
        return $exit_code
    fi
}

# Function to verify infrastructure is running
verify_infrastructure_running() {
    log "Verifying Sigul infrastructure is running..."

    # Check server container
    if docker ps --filter "name=sigul-server" --filter "status=running" | grep -q "sigul-server"; then
        verbose "Server container is running"
    else
        error "Server container is not running"
        return 1
    fi

    # Check bridge container
    if docker ps --filter "name=sigul-bridge" --filter "status=running" | grep -q "sigul-bridge"; then
        verbose "Bridge container is running"
    else
        error "Bridge container is not running"
        return 1
    fi

    success "Infrastructure verification complete"
}

# Function to test admin authentication
test_admin_authentication() {
    log "Testing admin authentication..."

    if run_corrected_sigul_command \
        sigul -c /var/sigul/config/client.conf list-users \
        --admin-name admin --admin-password "$EPHEMERAL_ADMIN_PASSWORD" 2>/dev/null; then
        test_pass "Admin Authentication"
        return 0
    else
        test_fail "Admin Authentication" "admin authentication failed"
        return 1
    fi
}

# Function to test user creation
test_user_creation() {
    log "Testing integration user creation..."

    # Try to create integration-tester user
    if run_corrected_sigul_command \
        sigul -c /var/sigul/config/client.conf new-user \
        --admin-name admin --admin-password "$EPHEMERAL_ADMIN_PASSWORD" \
        integration-tester "$EPHEMERAL_TEST_PASSWORD" 2>/dev/null; then
        verbose "Integration user created successfully"
    else
        verbose "User creation failed (user may already exist)"
    fi

    # Verify user exists
    if run_corrected_sigul_command \
        sigul -c /var/sigul/config/client.conf list-users \
        --admin-name admin --admin-password "$EPHEMERAL_ADMIN_PASSWORD" 2>/dev/null | grep -q "integration-tester"; then
        test_pass "User Creation"
        return 0
    else
        test_fail "User Creation" "could not create or verify integration-tester user"
        return 1
    fi
}

# Function to test key creation
test_key_creation() {
    log "Testing signing key creation..."

    # Try to create test signing key
    if run_corrected_sigul_command \
        sigul -c /var/sigul/config/client.conf new-key \
        --admin-name admin --admin-password "$EPHEMERAL_ADMIN_PASSWORD" \
        --key-admin integration-tester --key-admin-password "$EPHEMERAL_TEST_PASSWORD" \
        test-signing-key 2048 2>/dev/null; then
        verbose "Test signing key created successfully"
    else
        verbose "Key creation failed (key may already exist)"
    fi

    # Verify key exists
    if run_corrected_sigul_command \
        sigul -c /var/sigul/config/client.conf list-keys \
        --admin-name admin --admin-password "$EPHEMERAL_ADMIN_PASSWORD" 2>/dev/null | grep -q "test-signing-key"; then
        test_pass "Key Creation"
        return 0
    else
        test_fail "Key Creation" "could not create or verify test signing key"
        return 1
    fi
}

# Function to update client config to use integration-tester
update_client_config_for_user() {
    log "Updating client configuration to use integration-tester..."

    local config_dir="${PROJECT_ROOT}/test-artifacts/corrected-config"

    # Create client configuration for integration-tester user
    cat > "$config_dir/client.conf" << 'EOF'
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

[client]
bridge-hostname = sigul-bridge
bridge-port = 44334
server-hostname = sigul-server
max-file-payload-size = 2097152
username = integration-tester

# TLS Configuration using unified certificate paths
ca-cert-file = /var/sigul/secrets/certificates/ca.crt
require-tls = true
verify-server-cert = true
EOF

    verbose "Updated client configuration to use integration-tester user"
}

# Function to test basic functionality with integration-tester
test_basic_functionality() {
    log "Testing basic functionality with integration-tester..."

    # Update client config to use integration-tester
    update_client_config_for_user

    # Test list-keys command
    if run_corrected_sigul_command \
        sigul -c /var/sigul/config/client.conf list-keys \
        --password "$EPHEMERAL_TEST_PASSWORD" 2>/dev/null; then
        test_pass "Basic Functionality"
        return 0
    else
        test_fail "Basic Functionality" "list-keys command failed with integration-tester"
        return 1
    fi
}

# Function to create test workspace
setup_test_workspace() {
    local workspace_dir="${PROJECT_ROOT}/test-artifacts/test-workspace"
    mkdir -p "$workspace_dir"

    # Create test files for signing
    echo "This is a test document for signing." > "$workspace_dir/document1.txt"
    echo "Batch test file 1" > "$workspace_dir/batch-test-1.txt"
    echo "Batch test file 2" > "$workspace_dir/batch-test-2.txt"
    echo "Batch test file 3" > "$workspace_dir/batch-test-3.txt"

    # Create a mock RPM file (not a real RPM, just for testing)
    echo "MOCK RPM CONTENT" > "$workspace_dir/test-package.rpm"

    verbose "Test workspace created at $workspace_dir"
}

# Function to test file signing
test_file_signing() {
    log "Testing file signing operations..."

    setup_test_workspace

    local test_file="test-artifacts/test-workspace/document1.txt"

    if run_corrected_sigul_command \
        sigul -c /var/sigul/config/client.conf sign-data \
        --password "$EPHEMERAL_TEST_PASSWORD" \
        test-signing-key "$test_file" 2>/dev/null; then

        # Check if signature file was created
        if [[ -f "${PROJECT_ROOT}/${test_file}.asc" ]]; then
            test_pass "File Signing"
            return 0
        else
            test_fail "File Signing" "signature file not created"
            return 1
        fi
    else
        test_fail "File Signing" "signing command failed"
        return 1
    fi
}

# Function to test key management
test_key_management() {
    log "Testing key management operations..."

    # Test get-public-key command
    if run_corrected_sigul_command \
        sigul -c /var/sigul/config/client.conf get-public-key \
        --password "$EPHEMERAL_TEST_PASSWORD" \
        test-signing-key > "${PROJECT_ROOT}/test-artifacts/public-key.asc" 2>/dev/null; then

        if [[ -f "${PROJECT_ROOT}/test-artifacts/public-key.asc" ]]; then
            test_pass "Key Management"
            return 0
        else
            test_fail "Key Management" "public key file not created"
            return 1
        fi
    else
        test_fail "Key Management" "get-public-key command failed"
        return 1
    fi
}

# Function to cleanup containers
cleanup_containers() {
    log "Cleaning up corrected integration test containers..."
    stop_corrected_client_container
    success "Container cleanup completed"
}

# Function to generate test report
generate_test_report() {
    log "Generating corrected test report..."

    local report_file="${PROJECT_ROOT}/test-artifacts/corrected-test-report.txt"
    local total_tests=$((TESTS_PASSED + TESTS_FAILED))
    local success_rate=0

    if [[ $total_tests -gt 0 ]]; then
        success_rate=$(( (TESTS_PASSED * 100) / total_tests ))
    fi

    {
        echo "=== CORRECTED INTEGRATION TEST REPORT ==="
        echo "Total Tests: $total_tests"
        echo "Passed: $TESTS_PASSED"
        echo "Failed: $TESTS_FAILED"
        echo "Success Rate: ${success_rate}%"
        echo
        if [[ $TESTS_FAILED -gt 0 ]]; then
            echo "Failed Tests:"
            for failed_test in "${FAILED_TESTS[@]}"; do
                echo "  - $failed_test"
            done
        fi
    } > "$report_file"

    log "Corrected test report generated: $report_file"
}

# Function to run corrected integration tests
run_corrected_integration_tests() {
    log "Starting corrected Sigul infrastructure integration tests..."
    local start_time
    start_time=$(date +%s)

    # Setup and preparation
    verify_infrastructure_running

    # Start corrected client container
    local network_name
    network_name=$(get_sigul_network_name)
    verbose "Using Docker network: $network_name"

    if ! start_corrected_client_container "$network_name"; then
        error "Failed to start corrected client container"
        return 1
    fi

    # Run tests in correct order
    test_admin_authentication
    test_user_creation
    test_key_creation
    test_basic_functionality
    test_file_signing
    test_key_management

    # Cleanup and reporting
    cleanup_containers
    generate_test_report

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $TESTS_FAILED -eq 0 ]]; then
        success "All corrected integration tests passed! (${duration}s)"
        return 0
    else
        error "Corrected integration tests completed with failures (${duration}s)"
        return 1
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show help message
show_help() {
    cat << EOF
Corrected Sigul Integration Tests Script

This script runs corrected integration tests against Sigul infrastructure,
fixing volume mount and authentication issues from the original test.

Usage:
  $0 [OPTIONS]

Options:
  --verbose       Enable verbose output
  --help          Show this help message

Environment Variables:
  SIGUL_CLIENT_IMAGE    Client container image (required)
  SIGUL_SERVER_IMAGE    Server container image (required)
  SIGUL_BRIDGE_IMAGE    Bridge container image (required)

Key Improvements:
  - Correct volume mounts to /var/sigul paths
  - Proper certificate paths in configuration
  - Use admin user for initial setup
  - Create integration-tester user before testing

EOF
}

# Main execution function
main() {
    parse_args "$@"

    log "=== Corrected Sigul Integration Tests ==="
    log "Verbose mode: ${VERBOSE_MODE}"
    log "Project root: ${PROJECT_ROOT}"

    # Ensure all required environment variables are set
    detect_and_set_environment

    # Load ephemeral passwords generated during deployment
    if ! load_ephemeral_passwords; then
        error "Failed to load ephemeral passwords"
        exit 1
    fi

    # Ensure test artifacts directory exists
    mkdir -p "${PROJECT_ROOT}/test-artifacts"

    if run_corrected_integration_tests; then
        success "=== Corrected Real Infrastructure Integration Tests Complete ==="
        exit 0
    else
        error "=== Corrected Real Infrastructure Integration Tests Failed ==="
        exit 1
    fi
}

# Execute main function with all arguments
main "$@"
