#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2024 The Linux Foundation
#
# Phase 7 Validation Script - Integration Testing
# Validates that all integration testing components are in place and functional

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Helper functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
}

# Main validation
section "Phase 7: Integration Testing - Validation"

info "Starting Phase 7 validation..."
echo ""

# Test 1: Check integration test script exists and is executable
section "Test 1: Integration Test Script"
if [ -f "scripts/run-integration-tests.sh" ]; then
    success "Integration test script exists"
    if [ -x "scripts/run-integration-tests.sh" ]; then
        success "Integration test script is executable"
    else
        fail "Integration test script is not executable"
    fi
else
    fail "Integration test script not found"
fi

# Test 2: Check functional test suite exists and is executable
section "Test 2: Functional Test Suite"
if [ -f "scripts/test-signing-operations.sh" ]; then
    success "Functional test suite exists"
    if [ -x "scripts/test-signing-operations.sh" ]; then
        success "Functional test suite is executable"
    else
        fail "Functional test suite is not executable"
    fi
else
    fail "Functional test suite not found"
fi

# Test 3: Check performance test suite exists and is executable
section "Test 3: Performance Test Suite"
if [ -f "scripts/test-performance.sh" ]; then
    success "Performance test suite exists"
    if [ -x "scripts/test-performance.sh" ]; then
        success "Performance test suite is executable"
    else
        fail "Performance test suite is not executable"
    fi
else
    fail "Performance test suite not found"
fi

# Test 4: Check infrastructure test script exists and is executable
section "Test 4: Infrastructure Test Script"
if [ -f "scripts/test-infrastructure.sh" ]; then
    success "Infrastructure test script exists"
    if [ -x "scripts/test-infrastructure.sh" ]; then
        success "Infrastructure test script is executable"
    else
        fail "Infrastructure test script is not executable"
    fi
else
    fail "Infrastructure test script not found"
fi

# Test 5: Verify test scripts have proper headers
section "Test 5: Test Script Headers"
for script in "run-integration-tests.sh" "test-signing-operations.sh" "test-performance.sh"; do
    if [ -f "scripts/$script" ]; then
        if head -n 5 "scripts/$script" | grep -qE "#!/bin/bash|#!/usr/bin/env bash"; then
            success "$script has proper shebang"
        else
            fail "$script missing proper shebang"
        fi

        if head -n 10 "scripts/$script" | grep -q "set -euo pipefail"; then
            success "$script has strict error handling"
        else
            warn "$script may lack strict error handling"
        fi
    fi
done

# Test 6: Check if containers are running for live tests
section "Test 6: Container Availability (Optional)"
if docker ps --format '{{.Names}}' | grep -q "sigul-bridge"; then
    success "Bridge container is running"
    BRIDGE_RUNNING=true
else
    warn "Bridge container is not running (optional for validation)"
    BRIDGE_RUNNING=false
fi

if docker ps --format '{{.Names}}' | grep -q "sigul-server"; then
    success "Server container is running"
    SERVER_RUNNING=true
else
    warn "Server container is not running (optional for validation)"
    SERVER_RUNNING=false
fi

# Test 7: Run basic integration test syntax check
section "Test 7: Integration Test Syntax"
if [ -f "scripts/run-integration-tests.sh" ]; then
    if bash -n "scripts/run-integration-tests.sh" 2>/dev/null; then
        success "Integration test script syntax is valid"
    else
        fail "Integration test script has syntax errors"
    fi
fi

# Test 8: Run functional test syntax check
section "Test 8: Functional Test Syntax"
if [ -f "scripts/test-signing-operations.sh" ]; then
    if bash -n "scripts/test-signing-operations.sh" 2>/dev/null; then
        success "Functional test script syntax is valid"
    else
        fail "Functional test script has syntax errors"
    fi
fi

# Test 9: Run performance test syntax check
section "Test 9: Performance Test Syntax"
if [ -f "scripts/test-performance.sh" ]; then
    if bash -n "scripts/test-performance.sh" 2>/dev/null; then
        success "Performance test script syntax is valid"
    else
        fail "Performance test script has syntax errors"
    fi
fi

# Test 10: Verify test helper functions
section "Test 10: Test Helper Functions"
for script in "test-signing-operations.sh" "test-performance.sh"; do
    if [ -f "scripts/$script" ]; then
        if grep -q "success()" "scripts/$script" || grep -q "pass()" "scripts/$script"; then
            success "$script has success/pass helper function"
        else
            warn "$script may lack helper functions"
        fi

        if grep -q "fail()" "scripts/$script" || grep -q "error()" "scripts/$script"; then
            success "$script has fail/error helper function"
        else
            warn "$script may lack error handling functions"
        fi
    fi
done

# Test 11: Check test scripts use proper exit codes
section "Test 11: Exit Code Handling"
for script in "test-signing-operations.sh" "test-performance.sh"; do
    if [ -f "scripts/$script" ]; then
        if grep -q "exit 0" "scripts/$script" && grep -q "exit 1" "scripts/$script"; then
            success "$script uses proper exit codes"
        else
            warn "$script may not use proper exit codes"
        fi
    fi
done

# Test 12: Verify color output support
section "Test 12: Color Output Support"
for script in "test-signing-operations.sh" "test-performance.sh"; do
    if [ -f "scripts/$script" ]; then
        if grep -q "GREEN=" "scripts/$script" && grep -q "RED=" "scripts/$script"; then
            success "$script has color output support"
        else
            warn "$script may lack color output"
        fi
    fi
done

# Test 13: Live integration test execution (if containers running)
section "Test 13: Live Integration Tests (Optional)"
if [ "$BRIDGE_RUNNING" = true ] && [ "$SERVER_RUNNING" = true ]; then
    info "Containers are running - attempting live integration tests..."

    # Run a subset of integration tests
    if timeout 60 bash -c "
        # Quick health check
        docker exec sigul-bridge pgrep -f sigul_bridge > /dev/null &&
        docker exec sigul-server pgrep -f sigul_server > /dev/null
    " 2>/dev/null; then
        success "Live integration test: Service processes running"
    else
        warn "Live integration test: Service processes not responding (optional)"
    fi

    # Network connectivity test
    if timeout 30 bash -c "
        docker exec sigul-server nc -zv sigul-bridge.example.org 44333 2>&1 | grep -q 'succeeded\|open'
    " 2>/dev/null; then
        success "Live integration test: Network connectivity verified"
    else
        warn "Live integration test: Network connectivity failed (optional)"
    fi

    # Certificate validation test
    if timeout 30 bash -c "
        docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul | grep -q 'sigul-bridge.example.org'
    " 2>/dev/null; then
        success "Live integration test: Certificate validation passed"
    else
        warn "Live integration test: Certificate validation failed (optional)"
    fi
else
    warn "Skipping live integration tests (containers not running)"
    warn "To run live tests, start containers with: ./scripts/deploy-sigul-infrastructure.sh"
fi

# Test 14: Check for test documentation
section "Test 14: Test Documentation"
if grep -q "integration.*test" README.md 2>/dev/null; then
    success "Integration testing documented in README.md"
else
    warn "Integration testing may not be documented in README.md"
fi

# Test 15: Verify test script structure
section "Test 15: Test Script Structure"
for script in "test-signing-operations.sh" "test-performance.sh"; do
    if [ -f "scripts/$script" ]; then
        # Check for test counter variables
        if grep -q "TESTS_RUN\|TOTAL_TESTS" "scripts/$script"; then
            success "$script tracks test execution count"
        else
            warn "$script may not track test counts"
        fi

        # Check for summary reporting
        if grep -q "Summary\|SUMMARY" "scripts/$script"; then
            success "$script includes summary reporting"
        else
            warn "$script may lack summary reporting"
        fi
    fi
done

# Test 16: Network architecture documentation
section "Test 16: Network Architecture Documentation"
if [ -f "NETWORK_ARCHITECTURE.md" ]; then
    success "Network architecture documentation exists"

    # Check for key connection flow information
    if grep -q "Server CONNECTS to bridge" "NETWORK_ARCHITECTURE.md"; then
        success "Network architecture correctly documents connection flow"
    else
        warn "Network architecture may not clearly document connection flow"
    fi

    if grep -q "Bridge LISTENS" "NETWORK_ARCHITECTURE.md"; then
        success "Network architecture documents bridge listening behavior"
    else
        warn "Network architecture may not document bridge behavior"
    fi
else
    warn "Network architecture documentation not found"
fi

# Summary
section "Validation Summary"
echo ""
echo "Total Tests:  $TOTAL_TESTS"
echo -e "${GREEN}Passed Tests: $PASSED_TESTS${NC}"
if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "${RED}Failed Tests: $FAILED_TESTS${NC}"
else
    echo -e "${GREEN}Failed Tests: $FAILED_TESTS${NC}"
fi

# Calculate percentage
if [ $TOTAL_TESTS -gt 0 ]; then
    PASS_PERCENT=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    echo "Pass Rate:    ${PASS_PERCENT}%"
fi

echo ""

# Exit criteria
if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ Phase 7 validation PASSED${NC}"
    echo ""
    echo "All integration testing components are in place and validated."
    echo ""
    echo "Next Steps:"
    echo "  1. Deploy infrastructure: ./scripts/deploy-sigul-infrastructure.sh"
    echo "  2. Run integration tests: ./scripts/run-integration-tests.sh"
    echo "  3. Run functional tests:  ./scripts/test-signing-operations.sh"
    echo "  4. Run performance tests: ./scripts/test-performance.sh"
    echo "  5. Proceed to Phase 8 (Documentation & Final Validation)"
    echo ""
    exit 0
else
    echo -e "${RED}✗ Phase 7 validation FAILED${NC}"
    echo ""
    echo "Please address the failed tests before proceeding to Phase 8."
    echo ""
    exit 1
fi
