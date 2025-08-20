#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Generate test PKI infrastructure for Sigul integration testing
# This script creates a complete PKI setup including CA, server, and client certificates

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Generating Sigul Test PKI Infrastructure ==="
echo "This will create:"
echo "  - Certificate Authority (CA)"
echo "  - Server certificates for sigul-server and sigul-bridge"
echo "  - Client certificates and encrypted PKI archive"
echo ""

# Call the comprehensive PKI generation script
if [[ -f "$SCRIPT_DIR/generate-complete-pki.sh" ]]; then
    "$SCRIPT_DIR/generate-complete-pki.sh"
else
    echo "ERROR: PKI generation script not found!"
    echo "Expected: $SCRIPT_DIR/generate-complete-pki.sh"
    exit 1
fi

echo ""
echo "=== PKI Generation Complete ==="
echo "Ready for Sigul integration testing!"
