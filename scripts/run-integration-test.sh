#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# NSS-Based Sigul Integration Test Script
#
# This script runs a comprehensive integration test of the NSS-based
# Sigul infrastructure to validate the complete PKI workflow.
#
# Usage:
#   ./run-integration-test.sh [--cleanup] [--debug]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
COMPOSE_FILE="docker-compose.sigul.yml"
TEST_TIMEOUT=300
CLEANUP_ON_EXIT=false
DEBUG_MODE=false
TEST_WORKSPACE="test-workspace"

# Test tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INTEGRATION-TEST:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] INTEGRATION-TEST WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] INTEGRATION-TEST ERROR:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] INTEGRATION-TEST SUCCESS:${NC} $*"
}

# Test result tracking
test_result() {
    local test_name="$1"
    local result="$2"
    local details="${3:-}"

    ((TOTAL_TESTS++))

    if [[ "$result" == "PASS" ]]; then
        ((PASSED_TESTS++))
        success "✓ $test_name"
        [[ -n "$details" ]] && log "  $details"
    else
        ((FAILED_TESTS++))
        error "✗ $test_name"
        [[ -n "$details" ]] && error "  $details"
    fi
}

# Function to show usage
show_usage() {
    cat << EOF
NSS-Based Sigul Integration Test Script

This script runs a comprehensive integration test of the NSS-based
Sigul infrastructure to validate the complete PKI workflow.

Usage:
  $0 [OPTIONS]

Options:
  --cleanup         Clean up containers and volumes after test
  --debug          Enable debug mode with verbose output
  --help           Show this help message

Test Phases:
  1. Environment Setup
  2. Service Startup (Bridge → Server → Client)
  3. Certificate Validation
  4. Communication Testing
  5. End-to-End Workflow

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cleanup)
                CLEANUP_ON_EXIT=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Cleanup function
cleanup() {
    if [[ "$CLEANUP_ON_EXIT" == "true" ]]; then
        log "Cleaning up test environment..."
        docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
        if [[ -d "$TEST_WORKSPACE" ]]; then
            rm -rf "$TEST_WORKSPACE"
        fi
        success "Cleanup completed"
    fi
}

# Set cleanup trap
trap cleanup EXIT

# Phase 1: Environment Setup
test_environment_setup() {
    log "=== Phase 1: Environment Setup ==="

    # Test 1: Docker Compose file exists
    if [[ -f "$COMPOSE_FILE" ]]; then
        test_result "Docker Compose file exists" "PASS"
    else
        test_result "Docker Compose file exists" "FAIL" "File not found: $COMPOSE_FILE"
        return 1
    fi

    # Test 2: Clean up any existing containers
    log "Cleaning up any existing containers..."
    docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
    test_result "Environment cleanup" "PASS"

    # Test 3: Create test workspace
    mkdir -p "$TEST_WORKSPACE"
    if [[ -d "$TEST_WORKSPACE" ]]; then
        test_result "Test workspace created" "PASS"
    else
        test_result "Test workspace created" "FAIL"
        return 1
    fi

    # Test 4: Docker daemon accessible
    if docker version >/dev/null 2>&1; then
        test_result "Docker daemon accessible" "PASS"
    else
        test_result "Docker daemon accessible" "FAIL"
        return 1
    fi

    return 0
}

# Phase 2: Service Startup
test_service_startup() {
    log "=== Phase 2: Service Startup ==="

    # Test 1: Start bridge service first
    log "Starting bridge service..."
    if docker compose -f "$COMPOSE_FILE" up -d sigul-bridge >/dev/null 2>&1; then
        test_result "Bridge service startup" "PASS"
    else
        test_result "Bridge service startup" "FAIL"
        return 1
    fi

    # Test 2: Wait for bridge CA certificate to be created
    log "Waiting for bridge CA certificate to be created..."
    local timeout=120
    local count=0
    while [[ $count -lt $timeout ]]; do
        # Check if bridge CA certificate exists in NSS database
        if docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca >/dev/null 2>&1; then
            test_result "Bridge CA creation" "PASS" "Bridge CA ready after ${count}s"
            break
        fi

        if [[ $count -eq $((timeout-1)) ]]; then
            test_result "Bridge CA creation" "FAIL" "Timeout after ${timeout}s"
            if [[ "$DEBUG_MODE" == "true" ]]; then
                log "Bridge container logs:"
                docker logs sigul-bridge --tail 20 2>&1 | sed 's/^/  /'
            fi
            return 1
        fi

        sleep 1
        ((count++))
    done

    # Test 3: Start server service
    log "Starting server service..."
    if docker compose -f "$COMPOSE_FILE" up -d sigul-server >/dev/null 2>&1; then
        test_result "Server service startup" "PASS"
    else
        test_result "Server service startup" "FAIL"
        return 1
    fi

    # Test 4: Wait for server to be ready
    log "Waiting for server to be ready..."
    timeout=60
    count=0
    while [[ $count -lt $timeout ]]; do
        if docker exec sigul-server pgrep -f "sigul_server" >/dev/null 2>&1; then
            test_result "Server process check" "PASS" "Server ready after ${count}s"
            break
        fi

        if [[ $count -eq $timeout ]]; then
            test_result "Server process check" "FAIL" "Timeout after ${timeout}s"
            return 1
        fi

        sleep 1
        ((count++))
    done

    # Test 5: Start client for testing
    log "Starting client service..."
    if docker compose -f "$COMPOSE_FILE" up -d sigul-client-test >/dev/null 2>&1; then
        test_result "Client service startup" "PASS"
    else
        test_result "Client service startup" "FAIL"
        return 1
    fi

    return 0
}

# Phase 3: Certificate Validation
test_certificate_validation() {
    log "=== Phase 3: Certificate Validation ==="

    # Test 1: Bridge certificate validation
    if docker exec sigul-bridge /usr/local/bin/validate-nss-certificates.sh bridge >/dev/null 2>&1; then
        test_result "Bridge certificate validation" "PASS"
    else
        test_result "Bridge certificate validation" "FAIL"
        if [[ "$DEBUG_MODE" == "true" ]]; then
            log "Bridge validation output:"
            docker exec sigul-bridge /usr/local/bin/validate-nss-certificates.sh bridge 2>&1 | sed 's/^/  /'
        fi
    fi

    # Test 2: Server certificate validation
    if docker exec sigul-server /usr/local/bin/validate-nss-certificates.sh server >/dev/null 2>&1; then
        test_result "Server certificate validation" "PASS"
    else
        test_result "Server certificate validation" "FAIL"
        if [[ "$DEBUG_MODE" == "true" ]]; then
            log "Server validation output:"
            docker exec sigul-server /usr/local/bin/validate-nss-certificates.sh server 2>&1 | sed 's/^/  /'
        fi
    fi

    # Test 3: Client certificate validation
    if docker exec sigul-client-test /usr/local/bin/validate-nss-certificates.sh client >/dev/null 2>&1; then
        test_result "Client certificate validation" "PASS"
    else
        test_result "Client certificate validation" "FAIL"
        if [[ "$DEBUG_MODE" == "true" ]]; then
            log "Client validation output:"
            docker exec sigul-client-test /usr/local/bin/validate-nss-certificates.sh client 2>&1 | sed 's/^/  /'
        fi
    fi

    # Test 4: Cross-component certificate consistency
    if docker exec sigul-bridge /usr/local/bin/validate-nss-certificates.sh all >/dev/null 2>&1; then
        test_result "Certificate consistency check" "PASS"
    else
        test_result "Certificate consistency check" "FAIL"
    fi

    return 0
}

# Phase 4: Communication Testing
test_communication() {
    log "=== Phase 4: Communication Testing ==="

    # Test 1: Bridge port accessibility
    if docker exec sigul-client-test nc -z sigul-bridge 44334 >/dev/null 2>&1; then
        test_result "Bridge port 44334 accessible" "PASS"
    else
        test_result "Bridge port 44334 accessible" "FAIL"
    fi

    # Test 2: Bridge-Server communication
    # Check if server can connect to bridge on port 44333
    if docker exec sigul-server nc -z sigul-bridge 44333 >/dev/null 2>&1; then
        test_result "Bridge-Server communication" "PASS"
    else
        test_result "Bridge-Server communication" "FAIL"
    fi

    # Test 3: NSS certificate validation
    # Check if NSS certificates exist and are properly configured
    if docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca >/dev/null 2>&1 && \
       docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-bridge-cert >/dev/null 2>&1; then
        test_result "NSS certificate validation" "PASS"
    else
        test_result "NSS certificate validation" "FAIL"
    fi

    return 0
}

# Phase 5: Configuration Validation
test_configuration() {
    log "=== Phase 5: Configuration Validation ==="

    # Test 1: Bridge configuration file exists
    if docker exec sigul-bridge test -f /var/sigul/config/bridge.conf; then
        test_result "Bridge configuration file exists" "PASS"
    else
        test_result "Bridge configuration file exists" "FAIL"
    fi

    # Test 2: Server configuration file exists
    if docker exec sigul-server test -f /var/sigul/config/server.conf; then
        test_result "Server configuration file exists" "PASS"
    else
        test_result "Server configuration file exists" "FAIL"
    fi

    # Test 3: Client configuration file exists
    if docker exec sigul-client-test test -f /var/sigul/config/client.conf; then
        test_result "Client configuration file exists" "PASS"
    else
        test_result "Client configuration file exists" "FAIL"
    fi

    # Test 4: NSS password file exists
    if docker exec sigul-bridge test -f /var/sigul/secrets/nss-password; then
        test_result "NSS password file exists" "PASS"
    else
        test_result "NSS password file exists" "FAIL"
    fi

    return 0
}

# Generate final report
generate_report() {
    echo
    log "=== Integration Test Report ==="
    echo
    echo "Test Summary:"
    echo "  Total Tests: $TOTAL_TESTS"
    echo "  Passed: $PASSED_TESTS"
    echo "  Failed: $FAILED_TESTS"

    if [[ $TOTAL_TESTS -gt 0 ]]; then
        echo "  Success Rate: $(( PASSED_TESTS * 100 / TOTAL_TESTS ))%"
    fi

    echo

    if [[ $FAILED_TESTS -eq 0 ]]; then
        success "🎉 All integration tests passed! NSS-based Sigul infrastructure is working correctly."
        echo
        echo "Next steps:"
        echo "  1. The infrastructure is ready for signing operations"
        echo "  2. You can connect clients using the established certificates"
        echo "  3. Consider running production-specific security hardening"
        return 0
    else
        error "❌ $FAILED_TESTS test(s) failed. Infrastructure needs attention."
        echo
        echo "Debug information:"
        echo "  - Check container logs: docker compose -f $COMPOSE_FILE logs"
        echo "  - Validate certificates: docker exec <container> /usr/local/bin/validate-nss-certificates.sh"
        echo "  - Check service status: docker compose -f $COMPOSE_FILE ps"
        return 1
    fi
}

# Show container status for debugging
show_container_status() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        log "Container status:"
        docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | sed 's/^/  /' || echo "  Unable to get container status"
        echo
    fi
}

# Main execution
main() {
    parse_args "$@"

    log "Starting NSS-based Sigul integration test"
    log "Test timeout: ${TEST_TIMEOUT}s"
    log "Debug mode: $DEBUG_MODE"
    log "Cleanup on exit: $CLEANUP_ON_EXIT"
    echo

    # Run test phases
    if test_environment_setup; then
        if test_service_startup; then
            show_container_status
            if test_certificate_validation; then
                if test_communication; then
                    test_configuration
                fi
            fi
        fi
    fi

    # Generate final report
    generate_report
}

# Execute main function
main "$@"
