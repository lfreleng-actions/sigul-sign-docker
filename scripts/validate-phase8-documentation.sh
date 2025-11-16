#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 The Linux Foundation
#
# Phase 8 Validation Script - Documentation & Final Validation
# Validates that all Phase 8 deliverables are complete and accurate

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
section "Phase 8: Documentation & Final Validation"

info "Starting Phase 8 validation..."
echo ""

# Test 1: Check DEPLOYMENT_PRODUCTION_ALIGNED.md
section "Test 1: Production Deployment Guide"
if [ -f "DEPLOYMENT_PRODUCTION_ALIGNED.md" ]; then
    success "Production deployment guide exists"
    
    # Check for correct network diagram
    if grep -q "Server CONNECTS TO bridge" "DEPLOYMENT_PRODUCTION_ALIGNED.md" || \
       grep -q "Connects to" "DEPLOYMENT_PRODUCTION_ALIGNED.md"; then
        success "Network diagram shows correct connection pattern"
    else
        fail "Network diagram may not show correct connection pattern"
    fi
    
    # Check for key sections
    if grep -q "Prerequisites" "DEPLOYMENT_PRODUCTION_ALIGNED.md"; then
        success "Prerequisites section present"
    else
        warn "Prerequisites section may be missing"
    fi
    
    if grep -q "Troubleshooting" "DEPLOYMENT_PRODUCTION_ALIGNED.md"; then
        success "Troubleshooting section present"
    else
        warn "Troubleshooting section may be missing"
    fi
    
    if grep -q "Certificate" "DEPLOYMENT_PRODUCTION_ALIGNED.md"; then
        success "Certificate management section present"
    else
        warn "Certificate management section may be missing"
    fi
else
    fail "Production deployment guide not found"
fi

# Test 2: Check OPERATIONS_GUIDE.md
section "Test 2: Operations Guide"
if [ -f "OPERATIONS_GUIDE.md" ]; then
    success "Operations guide exists"
    
    # Check for key sections
    if grep -q "Daily Operations" "OPERATIONS_GUIDE.md"; then
        success "Daily operations section present"
    else
        warn "Daily operations section may be missing"
    fi
    
    if grep -q "Incident Response" "OPERATIONS_GUIDE.md"; then
        success "Incident response section present"
    else
        warn "Incident response section may be missing"
    fi
    
    if grep -q "Monitoring" "OPERATIONS_GUIDE.md"; then
        success "Monitoring section present"
    else
        warn "Monitoring section may be missing"
    fi
    
    if grep -q "Backup" "OPERATIONS_GUIDE.md"; then
        success "Backup procedures documented"
    else
        warn "Backup procedures may be missing"
    fi
else
    fail "Operations guide not found"
fi

# Test 3: Check VALIDATION_CHECKLIST.md
section "Test 3: Validation Checklist"
if [ -f "VALIDATION_CHECKLIST.md" ]; then
    success "Validation checklist exists"
    
    # Check for comprehensive sections
    if grep -q "Pre-Deployment" "VALIDATION_CHECKLIST.md"; then
        success "Pre-deployment validation section present"
    else
        warn "Pre-deployment section may be missing"
    fi
    
    if grep -q "Infrastructure Validation" "VALIDATION_CHECKLIST.md"; then
        success "Infrastructure validation section present"
    else
        warn "Infrastructure validation section may be missing"
    fi
    
    if grep -q "Certificate Validation" "VALIDATION_CHECKLIST.md"; then
        success "Certificate validation section present"
    else
        warn "Certificate validation section may be missing"
    fi
    
    if grep -q "Network Validation" "VALIDATION_CHECKLIST.md"; then
        success "Network validation section present"
    else
        warn "Network validation section may be missing"
    fi
    
    # Check for checkboxes
    if grep -q "\[ \]" "VALIDATION_CHECKLIST.md"; then
        success "Checklist uses proper checkbox format"
    else
        warn "Checklist may lack checkbox format"
    fi
else
    fail "Validation checklist not found"
fi

# Test 4: Check DEPLOYMENT_GUIDE.md updates
section "Test 4: Updated DEPLOYMENT_GUIDE.md"
if [ -f "DEPLOYMENT_GUIDE.md" ]; then
    success "DEPLOYMENT_GUIDE.md exists"
    
    if grep -q "Production-Aligned Deployment" "DEPLOYMENT_GUIDE.md"; then
        success "References to production-aligned deployment added"
    else
        fail "Missing references to production-aligned deployment"
    fi
    
    if grep -q "DEPLOYMENT_PRODUCTION_ALIGNED.md" "DEPLOYMENT_GUIDE.md"; then
        success "Links to new documentation present"
    else
        fail "Missing links to new documentation"
    fi
else
    fail "DEPLOYMENT_GUIDE.md not found"
fi

# Test 5: Check all phase completion documents
section "Test 5: Phase Completion Documents"
for phase in 1 2 3 4 5 6 7; do
    if [ -f "PHASE${phase}_COMPLETE.md" ]; then
        success "Phase ${phase} completion document exists"
    else
        warn "Phase ${phase} completion document not found"
    fi
done

# Test 6: Check NETWORK_ARCHITECTURE.md
section "Test 6: Network Architecture Documentation"
if [ -f "NETWORK_ARCHITECTURE.md" ]; then
    success "Network architecture documentation exists"
    
    if grep -q "Server CONNECTS to bridge" "NETWORK_ARCHITECTURE.md" || \
       grep -q "Server CONNECTS TO bridge" "NETWORK_ARCHITECTURE.md"; then
        success "Correct connection pattern documented"
    else
        fail "Connection pattern may be incorrect"
    fi
    
    if grep -q "Bridge LISTENS" "NETWORK_ARCHITECTURE.md"; then
        success "Bridge listening behavior documented"
    else
        warn "Bridge listening behavior may not be documented"
    fi
else
    warn "Network architecture documentation not found (should exist from Phase 7)"
fi

# Test 7: Verify all validation scripts exist
section "Test 7: Validation Scripts Inventory"
VALIDATION_SCRIPTS=(
    "scripts/validate-phase4-service-initialization.sh"
    "scripts/validate-phase5-volume-persistence.sh"
    "scripts/validate-phase6-network-dns.sh"
    "scripts/validate-phase7-integration-testing.sh"
)

for script in "${VALIDATION_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        success "$(basename "$script") exists"
        if [ -x "$script" ]; then
            success "$(basename "$script") is executable"
        else
            fail "$(basename "$script") is not executable"
        fi
    else
        fail "$(basename "$script") not found"
    fi
done

# Test 8: Check documentation consistency
section "Test 8: Documentation Consistency"

# Check for SPDX headers in new docs
for doc in "DEPLOYMENT_PRODUCTION_ALIGNED.md" "OPERATIONS_GUIDE.md" "VALIDATION_CHECKLIST.md"; do
    if [ -f "$doc" ]; then
        if head -n 5 "$doc" | grep -q "SPDX-License-Identifier"; then
            success "$doc has SPDX header"
        else
            warn "$doc may be missing SPDX header"
        fi
    fi
done

# Check for correct year (2025)
for doc in "DEPLOYMENT_PRODUCTION_ALIGNED.md" "OPERATIONS_GUIDE.md" "VALIDATION_CHECKLIST.md"; do
    if [ -f "$doc" ]; then
        if head -n 10 "$doc" | grep -q "2025"; then
            success "$doc has correct year (2025)"
        else
            warn "$doc may have incorrect year"
        fi
    fi
done

# Test 9: Documentation cross-references
section "Test 9: Documentation Cross-References"

# Check if docs reference each other
if [ -f "DEPLOYMENT_PRODUCTION_ALIGNED.md" ]; then
    if grep -q "OPERATIONS_GUIDE.md" "DEPLOYMENT_PRODUCTION_ALIGNED.md"; then
        success "Production guide references operations guide"
    else
        warn "Production guide may not reference operations guide"
    fi
fi

if [ -f "OPERATIONS_GUIDE.md" ]; then
    if grep -q "DEPLOYMENT_PRODUCTION_ALIGNED.md" "OPERATIONS_GUIDE.md"; then
        success "Operations guide references deployment guide"
    else
        warn "Operations guide may not reference deployment guide"
    fi
fi

# Test 10: Check README.md exists
section "Test 10: README.md Check"
if [ -f "README.md" ]; then
    success "README.md exists"
    
    # Check if it mentions production alignment or new docs
    if grep -qi "production\|alignment\|DEPLOYMENT_PRODUCTION_ALIGNED" "README.md"; then
        success "README.md references production alignment"
    else
        info "README.md may benefit from production alignment references"
    fi
else
    fail "README.md not found"
fi

# Test 11: Check ALIGNMENT_PLAN.md
section "Test 11: Alignment Plan Document"
if [ -f "ALIGNMENT_PLAN.md" ]; then
    success "ALIGNMENT_PLAN.md exists"
    
    if grep -q "Phase 8" "ALIGNMENT_PLAN.md"; then
        success "Phase 8 documented in alignment plan"
    else
        warn "Phase 8 may not be in alignment plan"
    fi
else
    fail "ALIGNMENT_PLAN.md not found"
fi

# Test 12: Test script functionality (syntax check)
section "Test 12: Test Script Syntax"
for script in scripts/test-*.sh scripts/validate-*.sh; do
    if [ -f "$script" ]; then
        if bash -n "$script" 2>/dev/null; then
            success "$(basename "$script") syntax valid"
        else
            fail "$(basename "$script") has syntax errors"
        fi
    fi
done

# Test 13: Check backup and restore scripts
section "Test 13: Backup and Restore Scripts"
if [ -f "scripts/backup-volumes.sh" ]; then
    success "Backup script exists"
    if [ -x "scripts/backup-volumes.sh" ]; then
        success "Backup script is executable"
    else
        fail "Backup script is not executable"
    fi
else
    fail "Backup script not found"
fi

if [ -f "scripts/restore-volumes.sh" ]; then
    success "Restore script exists"
    if [ -x "scripts/restore-volumes.sh" ]; then
        success "Restore script is executable"
    else
        fail "Restore script is not executable"
    fi
else
    fail "Restore script not found"
fi

# Test 14: Documentation formatting
section "Test 14: Documentation Format Check"
for doc in "DEPLOYMENT_PRODUCTION_ALIGNED.md" "OPERATIONS_GUIDE.md" "VALIDATION_CHECKLIST.md"; do
    if [ -f "$doc" ]; then
        # Check for markdown headers
        if grep -q "^# " "$doc"; then
            success "$doc has markdown headers"
        else
            warn "$doc may lack markdown headers"
        fi
        
        # Check for code blocks
        if grep -q '```' "$doc"; then
            success "$doc includes code examples"
        else
            warn "$doc may lack code examples"
        fi
    fi
done

# Test 15: File count verification
section "Test 15: File Count Verification"
EXPECTED_DOCS=(
    "DEPLOYMENT_PRODUCTION_ALIGNED.md"
    "OPERATIONS_GUIDE.md"
    "VALIDATION_CHECKLIST.md"
    "NETWORK_ARCHITECTURE.md"
    "ALIGNMENT_PLAN.md"
    "DEPLOYMENT_GUIDE.md"
    "README.md"
)

FOUND_COUNT=0
for doc in "${EXPECTED_DOCS[@]}"; do
    if [ -f "$doc" ]; then
        ((FOUND_COUNT++))
    fi
done

if [ $FOUND_COUNT -eq ${#EXPECTED_DOCS[@]} ]; then
    success "All expected documentation files present ($FOUND_COUNT/${#EXPECTED_DOCS[@]})"
else
    warn "Some documentation files missing ($FOUND_COUNT/${#EXPECTED_DOCS[@]} found)"
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
    echo -e "${GREEN}✓ Phase 8 validation PASSED${NC}"
    echo ""
    echo "All documentation and final validation components are complete."
    echo ""
    echo "Next Steps:"
    echo "  1. Review all documentation for accuracy"
    echo "  2. Run complete end-to-end validation:"
    echo "     - ./scripts/validate-phase4-service-initialization.sh"
    echo "     - ./scripts/validate-phase5-volume-persistence.sh"
    echo "     - ./scripts/validate-phase6-network-dns.sh"
    echo "     - ./scripts/validate-phase7-integration-testing.sh"
    echo "  3. Complete VALIDATION_CHECKLIST.md"
    echo "  4. Create final Phase 8 completion document"
    echo "  5. Commit all changes"
    echo ""
    exit 0
else
    echo -e "${RED}✗ Phase 8 validation FAILED${NC}"
    echo ""
    echo "Please address the failed tests before proceeding."
    echo ""
    exit 1
fi