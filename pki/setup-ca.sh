#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# PKI Setup Script for Sigul Infrastructure
#
# This script creates a Certificate Authority (CA) that will be used by all
# Sigul components (server, bridge, client) to establish a chain of trust.
#
# The CA certificate and key are committed to the repository and used by
# sigul-init.sh to derive component-specific certificates.
#
# Usage:
#   ./pki/setup-ca.sh [--force]
#
# Options:
#   --force    Regenerate CA even if it already exists

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"  # Currently unused
PKI_DIR="$SCRIPT_DIR"

# Certificate configuration
CA_VALIDITY_DAYS=3650  # 10 years for CA
# CERT_VALIDITY_DAYS=365 # 1 year for component certificates  # Currently unused
CA_KEY_SIZE=4096
# CERT_KEY_SIZE=2048  # Currently unused

# File paths
CA_KEY_FILE="$PKI_DIR/ca-key.pem"
CA_CERT_FILE="$PKI_DIR/ca.crt"
CA_CONFIG_FILE="$PKI_DIR/ca.conf"

# Options
FORCE_REGENERATE=false

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

# Function to show help
show_help() {
    cat << EOF
PKI Setup Script for Sigul Infrastructure

This script creates a Certificate Authority (CA) for the Sigul infrastructure.
The CA certificate and key are stored in the repository and used by all
Sigul components to establish a chain of trust.

Usage:
  $0 [OPTIONS]

Options:
  --force         Regenerate CA even if it already exists
  --help          Show this help message

Generated Files:
  ca.crt          CA certificate (public)
  ca-key.pem      CA private key (committed to repo for testing)
  ca.conf         CA configuration file

Note: This CA is for testing purposes only. In production, use a proper
      Certificate Authority with appropriate security controls.

EOF
}

# Function to parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_REGENERATE=true
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

# Function to create CA configuration file
create_ca_config() {
    log "Creating CA configuration file..."

    cat > "$CA_CONFIG_FILE" << 'EOF'
# Certificate Authority Configuration for Sigul Infrastructure
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

[ req ]
default_bits = 4096
prompt = no
distinguished_name = ca_distinguished_name
x509_extensions = ca_extensions

[ ca_distinguished_name ]
C = US
ST = California
L = San Francisco
O = Linux Foundation
OU = Sigul Infrastructure
CN = Sigul Test CA

[ ca_extensions ]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer:always

# Extensions for component certificates
[ server_extensions ]
basicConstraints = CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = @server_alt_names

[ bridge_extensions ]
basicConstraints = CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = @bridge_alt_names

[ client_extensions ]
basicConstraints = CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = @client_alt_names

# Subject Alternative Names for different components
[ server_alt_names ]
DNS.1 = sigul-server
DNS.2 = localhost
IP.1 = 127.0.0.1

[ bridge_alt_names ]
DNS.1 = sigul-bridge
DNS.2 = localhost
IP.1 = 127.0.0.1

[ client_alt_names ]
DNS.1 = sigul-client
DNS.2 = sigul-client-test
DNS.3 = localhost
IP.1 = 127.0.0.1

EOF

    success "CA configuration created: $CA_CONFIG_FILE"
}

# Function to generate CA certificate and key
generate_ca() {
    log "Generating Certificate Authority..."

    # Generate CA private key
    log "Generating CA private key..."
    openssl genrsa -out "$CA_KEY_FILE" $CA_KEY_SIZE
    chmod 600 "$CA_KEY_FILE"

    # Generate CA certificate
    log "Generating CA certificate..."
    openssl req -new -x509 -key "$CA_KEY_FILE" -out "$CA_CERT_FILE" \
        -days $CA_VALIDITY_DAYS -config "$CA_CONFIG_FILE"
    chmod 644 "$CA_CERT_FILE"

    success "Certificate Authority generated successfully"
}

# Function to validate CA certificate
validate_ca() {
    log "Validating CA certificate..."

    # Check if files exist
    if [[ ! -f "$CA_KEY_FILE" ]]; then
        error "CA private key not found: $CA_KEY_FILE"
        return 1
    fi

    if [[ ! -f "$CA_CERT_FILE" ]]; then
        error "CA certificate not found: $CA_CERT_FILE"
        return 1
    fi

    # Verify certificate structure
    if ! openssl x509 -in "$CA_CERT_FILE" -noout -text >/dev/null 2>&1; then
        error "CA certificate is invalid or corrupted"
        return 1
    fi

    # Check if certificate is a CA
    if ! openssl x509 -in "$CA_CERT_FILE" -noout -text | grep -q "CA:TRUE"; then
        error "Certificate is not a valid CA certificate"
        return 1
    fi

    # Check validity period
    local not_after
    not_after=$(openssl x509 -in "$CA_CERT_FILE" -noout -enddate | cut -d= -f2)
    log "CA certificate valid until: $not_after"

    # Verify key and certificate match
    local key_hash cert_hash
    key_hash=$(openssl rsa -in "$CA_KEY_FILE" -pubout -outform DER 2>/dev/null | openssl dgst -sha256)
    cert_hash=$(openssl x509 -in "$CA_CERT_FILE" -pubkey -noout | openssl rsa -pubin -outform DER 2>/dev/null | openssl dgst -sha256)

    if [[ "$key_hash" != "$cert_hash" ]]; then
        error "CA private key and certificate do not match"
        return 1
    fi

    success "CA certificate validation successful"
    return 0
}

# Function to display CA information
display_ca_info() {
    log "Certificate Authority Information:"
    echo
    echo "CA Certificate Details:"
    openssl x509 -in "$CA_CERT_FILE" -noout -subject -issuer -dates -purpose | sed 's/^/  /'
    echo
    echo "CA Certificate Fingerprint:"
    openssl x509 -in "$CA_CERT_FILE" -noout -fingerprint -sha256 | sed 's/^/  /'
    echo
    echo "Files created:"
    echo "  $CA_CERT_FILE (CA certificate - public)"
    echo "  $CA_KEY_FILE (CA private key - testing only)"
    echo "  $CA_CONFIG_FILE (CA configuration)"
    echo
}

# Function to create helper scripts
create_helper_scripts() {
    log "Creating helper scripts..."

    # Create certificate generation helper
    cat > "$PKI_DIR/generate-component-cert.sh" << 'EOF'
#!/bin/bash
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
EOF

    chmod +x "$PKI_DIR/generate-component-cert.sh"

    success "Helper scripts created"
}

# Function to check if CA already exists
ca_exists() {
    [[ -f "$CA_KEY_FILE" && -f "$CA_CERT_FILE" && -f "$CA_CONFIG_FILE" ]]
}

# Main execution function
main() {
    parse_args "$@"

    log "=== Sigul PKI Setup ==="
    log "PKI Directory: $PKI_DIR"

    # Check if CA already exists
    if ca_exists && [[ "$FORCE_REGENERATE" != "true" ]]; then
        log "Certificate Authority already exists"
        if validate_ca; then
            display_ca_info
            log "Use --force to regenerate the CA"
            return 0
        else
            warn "Existing CA is invalid, regenerating..."
        fi
    fi

    if [[ "$FORCE_REGENERATE" == "true" ]] && ca_exists; then
        warn "Regenerating existing Certificate Authority"
        rm -f "$CA_KEY_FILE" "$CA_CERT_FILE" "$CA_CONFIG_FILE"
    fi

    # Create CA configuration
    create_ca_config

    # Generate CA certificate and key
    generate_ca

    # Validate the generated CA
    if ! validate_ca; then
        error "CA validation failed after generation"
        exit 1
    fi

    # Create helper scripts
    create_helper_scripts

    # Display information
    display_ca_info

    success "=== PKI Setup Complete ==="
    log "The CA certificate and key have been created and can be committed to the repository."
    log "Use sigul-init.sh to generate component certificates from this CA."
}

# Execute main function
main "$@"
