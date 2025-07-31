#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Comprehensive PKI Infrastructure Generation for Sigul Testing
#
# This script creates a complete PKI infrastructure including:
# - Root Certificate Authority (CA)
# - Server certificates for sigul-server and sigul-bridge
# - Client certificates and configuration for sigul-client
# - Proper .sigul directory structure for clients
#
# Usage:
#   ./generate-complete-pki.sh [output_directory]
#
# Output:
#   - pki/ directory with CA and server certificates (for containers)
#   - pki/client-pki-encrypted.asc encrypted client PKI archive (for workflows)

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT"
TEST_PKI_DIR="$OUTPUT_DIR/pki"
TEMP_DIR=$(mktemp -d -t sigul-complete-pki.XXXXXXXX)

# PKI Configuration
CA_DAYS=3650
SERVER_DAYS=365
CLIENT_DAYS=365
RSA_BITS=2048

# Test passwords and identities
CA_PASS="sigul_ca_test_password"
CLIENT_PASS="sigul_client_test_password"
GPG_ENCRYPT_PASS="integration_test_password"

# Subject configurations
CA_SUBJECT="/C=US/ST=Test/L=TestCity/O=Sigul Test CA/CN=Sigul Test Root CA"
SERVER_SUBJECT="/C=US/ST=Test/L=TestCity/O=Sigul Test/CN=sigul-server"
BRIDGE_SUBJECT="/C=US/ST=Test/L=TestCity/O=Sigul Test/CN=sigul-bridge"
CLIENT_SUBJECT="/C=US/ST=Test/L=TestCity/O=Sigul Test/CN=integration-tester"

# Cleanup function
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=== Starting Comprehensive Sigul PKI Generation ==="
log "Output directory: $OUTPUT_DIR"
log "Test PKI directory: $TEST_PKI_DIR"
log "Temporary directory: $TEMP_DIR"

# Create output directories
mkdir -p "$TEST_PKI_DIR"
mkdir -p "$TEMP_DIR/client-pki/.sigul"

log "=== Step 1: Generate Root Certificate Authority ==="

# Generate CA private key
openssl genrsa -aes256 -out "$TEMP_DIR/ca-key.pem" -passout pass:"$CA_PASS" $RSA_BITS
log "Generated CA private key"

# Generate CA certificate
openssl req -new -x509 -days $CA_DAYS -key "$TEMP_DIR/ca-key.pem" \
    -out "$TEST_PKI_DIR/ca.crt" -passin pass:"$CA_PASS" \
    -subj "$CA_SUBJECT"
log "Generated CA certificate: $TEST_PKI_DIR/ca.crt"

# Copy CA certificate to client PKI
cp "$TEST_PKI_DIR/ca.crt" "$TEMP_DIR/client-pki/.sigul/ca.crt"

log "=== Step 2: Generate Server Certificate (sigul-server) ==="

# Generate server private key
openssl genrsa -out "$TEST_PKI_DIR/server-key.pem" $RSA_BITS

# Generate server certificate request
openssl req -new -key "$TEST_PKI_DIR/server-key.pem" \
    -out "$TEMP_DIR/server.csr" -subj "$SERVER_SUBJECT"

# Create server certificate extensions
cat > "$TEMP_DIR/server.ext" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = sigul-server
DNS.2 = localhost
IP.1 = 127.0.0.1
IP.2 = 172.20.0.2
EOF

# Sign server certificate
openssl x509 -req -in "$TEMP_DIR/server.csr" -CA "$TEST_PKI_DIR/ca.crt" \
    -CAkey "$TEMP_DIR/ca-key.pem" -CAcreateserial \
    -out "$TEST_PKI_DIR/server.crt" -days $SERVER_DAYS \
    -extfile "$TEMP_DIR/server.ext" \
    -passin pass:"$CA_PASS"
log "Generated server certificate: $TEST_PKI_DIR/server.crt"

log "=== Step 3: Generate Bridge Certificate (sigul-bridge) ==="

# Generate bridge private key
openssl genrsa -out "$TEST_PKI_DIR/bridge-key.pem" $RSA_BITS

# Generate bridge certificate request
openssl req -new -key "$TEST_PKI_DIR/bridge-key.pem" \
    -out "$TEMP_DIR/bridge.csr" -subj "$BRIDGE_SUBJECT"

# Create bridge certificate extensions
cat > "$TEMP_DIR/bridge.ext" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = sigul-bridge
DNS.2 = localhost
IP.1 = 127.0.0.1
IP.2 = 172.20.0.3
EOF

# Sign bridge certificate
openssl x509 -req -in "$TEMP_DIR/bridge.csr" -CA "$TEST_PKI_DIR/ca.crt" \
    -CAkey "$TEMP_DIR/ca-key.pem" -CAcreateserial \
    -out "$TEST_PKI_DIR/bridge.crt" -days $SERVER_DAYS \
    -extfile "$TEMP_DIR/bridge.ext" \
    -passin pass:"$CA_PASS"
log "Generated bridge certificate: $TEST_PKI_DIR/bridge.crt"

log "=== Step 4: Generate Client Certificate ==="

# Generate client private key
openssl genrsa -out "$TEMP_DIR/client-pki/.sigul/client.key" $RSA_BITS

# Generate client certificate request
openssl req -new -key "$TEMP_DIR/client-pki/.sigul/client.key" \
    -out "$TEMP_DIR/client.csr" -subj "$CLIENT_SUBJECT"

# Create client certificate extensions
cat > "$TEMP_DIR/client.ext" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

# Sign client certificate
openssl x509 -req -in "$TEMP_DIR/client.csr" -CA "$TEST_PKI_DIR/ca.crt" \
    -CAkey "$TEMP_DIR/ca-key.pem" -CAcreateserial \
    -out "$TEMP_DIR/client-pki/.sigul/client.crt" -days $CLIENT_DAYS \
    -extfile "$TEMP_DIR/client.ext" \
    -passin pass:"$CA_PASS"
log "Generated client certificate"

log "=== Step 5: Create Client Configuration ==="

# Create client configuration file
cat > "$TEMP_DIR/client-pki/.sigul/client.conf" << EOF
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

[client]
bridge-hostname = localhost
bridge-port = 44334
username = integration-tester
max-file-payload-size = 2097152

# PKI Configuration
ca-cert-file = ~/.sigul/ca.crt
client-cert-file = ~/.sigul/client.crt
client-key-file = ~/.sigul/client.key

# Security settings
require-tls = true
verify-server-cert = true

# Logging
log-level = info
EOF
log "Created client configuration"

# Create password file for client
echo "$CLIENT_PASS" > "$TEMP_DIR/client-pki/.sigul/password"
chmod 600 "$TEMP_DIR/client-pki/.sigul/password"
log "Created client password file"

log "=== Step 6: Generate Test Signing Key ==="

# Create a placeholder GPG key for testing
# In a real environment, this would be generated properly with GPG
cat > "$TEMP_DIR/client-pki/.sigul/signing-key.asc" << 'EOF'
-----BEGIN PGP PRIVATE KEY BLOCK-----

lQOYBGZCqL8BCADGvRX1oJKEHzqF9V3rJ8yNcKkPqX2mH4dQzL8xR5vT3wN9B6yE
2pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN8pS1wT7hD5qF9xJ3mK2yV8nL4tN6rQ9sE2
jW5xP1yZ7qB4nH8uM3tK6cR1wN9B6yE2pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN8pS
1wT7hD5qF9xJ3mK2yV8nL4tN6rQ9sE2jW5xP1yZ7qB4nH8uM3tK6cR1wN9B6yE2p
S4jK7nM9xF1eQ8tY2zL4vK6bR3nN8pS1wT7hD5qF9xJ3mK2yV8nL4tN6rQ9sE2jW
5xP1yZ7qB4nH8uM3tK6cR1wN9B6yE2pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN8pS1w
T7hD5qF9xJ3mK2yV8nL4tN6rQ9sE2jW5xP1yZ7qB4nH8uM3tK6cR1ABEBAAEAAQEG
L2Q+z9tN3xD5qF9xJ3mK2yV8nL4tN6rQ9sE2jW5xP1yZ7qB4nH8uM3tK6cR1wN9B
6yE2pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN8pS1wT7hD5qF9xJ3mK2yV8nL4tN6rQ9
sE2jW5xP1yZ7qB4nH8uM3tK6cR1wN9B6yE2pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN
8pS1wT7hD5qF9xJ3mK2yV8nL4tN6rQ9sE2jW5xP1yZ7qB4nH8uM3tK6cR1wN9B6y
E2pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN8pS1wT7hD5qF9xJ3mK2yV8nL4tN6rQ9sE
2jW5xP1yZ7qB4nH8uM3tK6cR1wN9B6yE2pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN8p
S1wT7hD5qF9xJ3mK2yV8nL4tN6rQ9sE2jW5xP1yZ7qB4nH8uM3tK6cR1wN9B6yE2
pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN8pS1wT7hD5qF9xJ3mK2yV8nL4tN6rQ9sE2j
W5xP1yZ7qB4nH8uM3tK6cR1wN9B6yE2pS4jK7nM9xF1eQ8tY2zL4vK6bR3nN8pS1
wT7hD5qF9xJ3mK2yV8nL4tN6rQ9sE2jW5xP1yZ7qB4nH8uM3tK6cR1AABVKAEAA==
=MOCK
-----END PGP PRIVATE KEY BLOCK-----
EOF

log "Created placeholder test signing key (for testing only)"

log "=== Step 7: Create Encrypted Client PKI Archive ==="

# Create the client PKI archive
cd "$TEMP_DIR/client-pki"
tar -Jcf ../client-sigul.tar.xz .sigul/

# Encrypt the archive with GPG
echo "$GPG_ENCRYPT_PASS" | gpg --batch --yes --cipher-algo AES256 \
    --compress-algo 2 --symmetric \
    --passphrase-fd 0 \
    --armor \
    --output "$TEST_PKI_DIR/client-pki-encrypted.asc" \
    ../client-sigul.tar.xz

log "Created encrypted client PKI archive: $TEST_PKI_DIR/client-pki-encrypted.asc"

log "=== Step 8: Create Server Configuration Templates ==="

# Create server configuration template
cat > "$TEST_PKI_DIR/server.conf.template" << EOF
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

[server]
bridge-hostname = sigul-bridge
bridge-port = 44334
max-file-payload-size = 2097152

# Database Configuration - SQLite
[database]
database-path = /var/lib/sigul/sigul.db

# TLS Configuration using containerized certificates
ca-cert-file = /var/sigul/secrets/certificates/ca.crt
server-cert-file = /var/sigul/secrets/certificates/server.crt
server-key-file = /var/sigul/secrets/certificates/server-key.pem
require-tls = true

[daemon]
uid = sigul
gid = sigul
EOF

# Create bridge configuration template
cat > "$TEST_PKI_DIR/bridge.conf.template" << EOF
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

[bridge]
host = 0.0.0.0
port = 44334
server-hostname = sigul-server
max-file-payload-size = 2097152

# TLS Configuration using containerized certificates
ca-cert-file = /var/sigul/secrets/certificates/ca.crt
bridge-cert-file = /var/sigul/secrets/certificates/bridge.crt
bridge-key-file = /var/sigul/secrets/certificates/bridge-key.pem
require-tls = true

[daemon]
uid = sigul
gid = sigul
EOF

log "Created configuration templates"

log "=== Step 9: Create PKI Documentation ==="

cat > "$TEST_PKI_DIR/README.md" << EOF
# Sigul Test PKI Infrastructure

This directory contains the PKI infrastructure for Sigul integration testing.

## Files

### Certificate Authority
- \`ca.crt\` - Root CA certificate (public)

### Server Certificates
- \`server.crt\` - Sigul server certificate (public)
- \`server-key.pem\` - Sigul server private key (private)

### Bridge Certificates
- \`bridge.crt\` - Sigul bridge certificate (public)
- \`bridge-key.pem\` - Sigul bridge private key (private)

### Configuration Templates
- \`server.conf.template\` - Server configuration template
- \`bridge.conf.template\` - Bridge configuration template

## Client PKI

The client PKI is packaged separately in \`pki/client-pki-encrypted.asc\` and contains:
- Client certificate and private key
- CA certificate for verification
- Client configuration
- Test signing key

## Usage in Docker Compose

This script generates certificates for containerized deployments where certificates are managed via sigul-init.sh.

## Usage in Workflows

The client PKI is generated dynamically during workflow execution using the \`./scripts/generate-test-pki.sh\` script. The workflows will capture the generated encrypted PKI content and pass it via environment variables.

Example workflow usage:
\`\`\`yaml
- name: Generate PKI infrastructure
  run: ./scripts/generate-test-pki.sh

- name: Use Sigul signing action
  uses: ./
  with:
    sigul-pki: \${{ steps.generate-real-pki.outputs.encrypted-pki }}
    sigul-pass: 'integration_test_password'
\`\`\`

## Security Note

This PKI infrastructure is for testing purposes only. Do not use in production.
EOF

log "Created PKI documentation"

log "=== Step 10: Verify Generated PKI ==="

# Verify certificates
log "Verifying generated certificates..."

# Verify server certificate
if openssl verify -CAfile "$TEST_PKI_DIR/ca.crt" "$TEST_PKI_DIR/server.crt" >/dev/null 2>&1; then
    log "✅ Server certificate verification: OK"
else
    log "❌ Server certificate verification: FAILED"
fi

# Verify bridge certificate
if openssl verify -CAfile "$TEST_PKI_DIR/ca.crt" "$TEST_PKI_DIR/bridge.crt" >/dev/null 2>&1; then
    log "✅ Bridge certificate verification: OK"
else
    log "❌ Bridge certificate verification: FAILED"
fi

# Verify client certificate
if openssl verify -CAfile "$TEST_PKI_DIR/ca.crt" "$TEMP_DIR/client-pki/.sigul/client.crt" >/dev/null 2>&1; then
    log "✅ Client certificate verification: OK"
else
    log "❌ Client certificate verification: FAILED"
fi

# Test encrypted archive decryption
log "Testing encrypted client PKI archive..."
TEST_DECRYPT_DIR=$(mktemp -d)
cd "$TEST_DECRYPT_DIR"
if echo "$GPG_ENCRYPT_PASS" | gpg --batch --passphrase-fd 0 -o test-sigul.tar.xz -d "$TEST_PKI_DIR/client-pki-encrypted.asc" 2>/dev/null; then
    if tar -tf test-sigul.tar.xz | grep -q ".sigul/client.crt"; then
        log "✅ Encrypted client PKI archive: OK"
    else
        log "❌ Encrypted client PKI archive: Missing expected files"
    fi
else
    log "❌ Encrypted client PKI archive: Decryption failed"
fi
rm -rf "$TEST_DECRYPT_DIR"

log "=== PKI Generation Summary ==="
log "Generated files:"
log "  CA Certificate: $TEST_PKI_DIR/ca.crt"
log "  Server Certificate: $TEST_PKI_DIR/server.crt"
log "  Server Private Key: $TEST_PKI_DIR/server-key.pem"
log "  Bridge Certificate: $TEST_PKI_DIR/bridge.crt"
log "  Bridge Private Key: $TEST_PKI_DIR/bridge-key.pem"
log "  Server Config Template: $TEST_PKI_DIR/server.conf.template"
log "  Bridge Config Template: $TEST_PKI_DIR/bridge.conf.template"
log "  Encrypted Client PKI: $TEST_PKI_DIR/client-pki-encrypted.asc"
log "  PKI Documentation: $TEST_PKI_DIR/README.md"
log ""
log "Encryption password for client PKI: $GPG_ENCRYPT_PASS"
log ""
log "=== PKI Generation Complete ==="
log "The PKI infrastructure is ready for Sigul integration testing."
log "Server and bridge containers will use certificates from: $TEST_PKI_DIR"
log "Client containers will use the encrypted PKI archive: $TEST_PKI_DIR/client-pki-encrypted.asc"
