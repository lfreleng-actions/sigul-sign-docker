#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Helper script to generate component certificates signed by the shared CA
# Usage: ./generate-component-cert.sh <component> <output-dir>

set -euo pipefail

COMPONENT="$1"
OUTPUT_DIR="$2"
PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CA_KEY="$PKI_DIR/ca-key.pem"
CA_CERT="$PKI_DIR/ca.crt"
CA_CONFIG="$PKI_DIR/ca.conf"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate component private key
openssl genrsa -out "$OUTPUT_DIR/${COMPONENT}-key.pem" 2048
chmod 600 "$OUTPUT_DIR/${COMPONENT}-key.pem"

# Create certificate signing request
openssl req -new -key "$OUTPUT_DIR/${COMPONENT}-key.pem" \
    -out "$OUTPUT_DIR/${COMPONENT}.csr" \
    -subj "/C=US/ST=California/L=San Francisco/O=Linux Foundation/OU=Sigul Infrastructure/CN=sigul-${COMPONENT}"

# Sign certificate with CA
openssl x509 -req -in "$OUTPUT_DIR/${COMPONENT}.csr" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$OUTPUT_DIR/${COMPONENT}.crt" \
    -days 365 -extensions "${COMPONENT}_extensions" \
    -extfile "$CA_CONFIG"

# Clean up CSR
rm "$OUTPUT_DIR/${COMPONENT}.csr"

# Copy CA certificate for trust
cp "$CA_CERT" "$OUTPUT_DIR/ca.crt"

echo "Generated certificates for $COMPONENT in $OUTPUT_DIR"
