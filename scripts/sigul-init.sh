#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul NSS Initialization Script
#
# This script provides clean, focused NSS certificate management for Sigul components
# implementing the bridge-centric CA architecture for production deployments.
#
# Key Design Principles:
# - NSS certificate management with certificate nicknames
# - Bridge-centric CA architecture
# - Simple validation focused on certificate existence
# - Fast startup with minimal complexity
# - Clean error handling with NSS-specific diagnostics
#
# Usage:
#   ./sigul-init-nss-only.sh --role bridge [--start-service]
#   ./sigul-init-nss-only.sh --role server [--start-service]
#   ./sigul-init-nss-only.sh --role client
#
# Arguments:
#   --role ROLE         Component role (bridge|server|client)
#   --start-service     Start the Sigul service after initialization
#   --debug             Enable debug logging
#   --validate-only     Only run validation, no initialization

set -euo pipefail

# Script version
readonly SCRIPT_VERSION="2.0.0-nss-only"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Configuration constants
readonly SIGUL_BASE_DIR="/var/sigul"
readonly NSS_BASE_DIR="$SIGUL_BASE_DIR/nss"
readonly SECRETS_DIR="$SIGUL_BASE_DIR/secrets"
readonly CONFIG_DIR="$SIGUL_BASE_DIR/config"
readonly LOGS_DIR="$SIGUL_BASE_DIR/logs"
readonly DB_DIR="/var/lib/sigul"
readonly GNUPG_DIR="/var/lib/sigul/gnupg"
readonly CA_EXPORT_DIR="$SIGUL_BASE_DIR/ca-export"
readonly CA_IMPORT_DIR="$SIGUL_BASE_DIR/ca-import"

# NSS certificate nicknames (standardized)
readonly CA_NICKNAME="sigul-ca"
readonly BRIDGE_CERT_NICKNAME="sigul-bridge-cert"
readonly SERVER_CERT_NICKNAME="sigul-server-cert"
readonly CLIENT_CERT_NICKNAME="sigul-client-cert"

# Default values
SIGUL_ROLE="${SIGUL_ROLE:-}"
DEBUG="${DEBUG:-false}"
START_SERVICE=false
VALIDATE_ONLY=false

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] NSS-INIT:${NC} $*"
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%H:%M:%S')] NSS-DEBUG:${NC} $*"
    fi
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] NSS-SUCCESS:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] NSS-WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] NSS-ERROR:${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

#######################################
# Directory and File Management
#######################################

create_directory_structure() {
    log "Creating NSS-only directory structure"

    # Create base directories
    local dirs=(
        "$SIGUL_BASE_DIR"
        "$NSS_BASE_DIR"
        "$SECRETS_DIR"
        "$CONFIG_DIR"
        "$LOGS_DIR"
        "$DB_DIR"
        "$GNUPG_DIR"
        "$CA_EXPORT_DIR"
        "$CA_IMPORT_DIR"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            debug "Created directory: $dir"
        fi
        # Ensure proper ownership for mounted volumes and special directories
        if [[ "$dir" == "$CA_EXPORT_DIR" ]] || [[ "$dir" == "$CA_IMPORT_DIR" ]]; then
            chmod 755 "$dir" 2>/dev/null || true
            debug "Set permissions for shared directory: $dir"
        elif [[ "$dir" == "$GNUPG_DIR" ]]; then
            chmod 700 "$dir" 2>/dev/null || true
            debug "Set secure permissions for GPG directory: $dir"
        elif [[ "$dir" == "$DB_DIR" ]]; then
            mkdir -p "$dir" 2>/dev/null || true
            chmod 755 "$dir" 2>/dev/null || true
            debug "Set permissions for database directory: $dir"
        fi
    done

    # Create component-specific NSS directories
    local components=("bridge" "server" "client")
    for component in "${components[@]}"; do
        local nss_component_dir="$NSS_BASE_DIR/$component"
        if [[ ! -d "$nss_component_dir" ]]; then
            mkdir -p "$nss_component_dir"
            debug "Created NSS directory: $nss_component_dir"
        fi
    done

    success "Directory structure created"
}

generate_nss_password() {
    local password_file="$SECRETS_DIR/nss-password"

    if [[ -f "$password_file" ]]; then
        debug "NSS password file already exists"
        return 0
    fi

    log "Generating NSS database password"

    # Generate strong password
    local password
    password=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

    echo "$password" > "$password_file"
    chmod 600 "$password_file"

    success "NSS password generated and saved"
}

get_nss_password() {
    local password_file="$SECRETS_DIR/nss-password"
    if [[ -f "$password_file" ]]; then
        cat "$password_file"
    else
        fatal "NSS password file not found: $password_file"
    fi
}

#######################################
# NSS Database Management
#######################################

create_nss_database() {
    local component="$1"
    local nss_dir="$NSS_BASE_DIR/$component"
    local password_file="$SECRETS_DIR/nss-password"

    log "Creating NSS database for $component"

    # Check if database already exists
    if [[ -f "$nss_dir/cert9.db" ]] && [[ -f "$nss_dir/key4.db" ]]; then
        debug "NSS database already exists for $component"
        return 0
    fi

    # Create NSS database
    if certutil -N -d "sql:$nss_dir" -f "$password_file" >/dev/null 2>&1; then
        success "NSS database created for $component"
    else
        fatal "Failed to create NSS database for $component"
    fi
}

import_ca_certificate() {
    local component="$1"
    local ca_cert_file="$2"
    local nss_dir="$NSS_BASE_DIR/$component"
    local password_file="$SECRETS_DIR/nss-password"

    log "Importing CA certificate for $component"

    # Check if CA already exists
    if certutil -d "sql:$nss_dir" -L -n "$CA_NICKNAME" >/dev/null 2>&1; then
        debug "CA certificate already exists for $component"
        return 0
    fi

    # Import CA certificate with appropriate trust flags
    if certutil -A -d "sql:$nss_dir" -n "$CA_NICKNAME" -t "CT,C,C" -i "$ca_cert_file" >/dev/null 2>&1; then
        success "CA certificate imported for $component"
    else
        fatal "Failed to import CA certificate for $component"
    fi
}

import_ca_private_key() {
    local component="$1"
    local nss_dir="$NSS_BASE_DIR/$component"
    local password_file="$SECRETS_DIR/nss-password"
    local ca_p12_file="/var/sigul/bridge-shared/ca-export/bridge-ca.p12"
    local ca_p12_password_file="/var/sigul/bridge-shared/ca-export/ca-p12-password"

    log "Importing CA private key for $component"

    # Wait for PKCS#12 file to be available
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if [[ -f "$ca_p12_file" ]] && [[ -s "$ca_p12_file" ]] && [[ -f "$ca_p12_password_file" ]]; then
            debug "CA PKCS#12 file found"
            break
        fi
        debug "Waiting for CA PKCS#12 file (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        fatal "CA PKCS#12 file not available from bridge"
    fi

    # Import PKCS#12 file containing CA certificate and private key
    if pk12util -d "sql:$nss_dir" -i "$ca_p12_file" -k "$password_file" -w "$ca_p12_password_file" >/dev/null 2>&1; then
        success "CA private key imported for $component"
        # Set proper trust flags for the imported CA
        certutil -d "sql:$nss_dir" -M -n "$CA_NICKNAME" -t "CT,C,C" >/dev/null 2>&1 || true
    else
        fatal "Failed to import CA private key for $component"
    fi
}

generate_component_certificate() {
    local component="$1"
    local cert_nickname="$2"
    local nss_dir="$NSS_BASE_DIR/$component"
    local password_file="$SECRETS_DIR/nss-password"

    log "Generating certificate for $component: $cert_nickname"

    # Check if certificate already exists
    if certutil -d "sql:$nss_dir" -L -n "$cert_nickname" >/dev/null 2>&1; then
        debug "Certificate already exists: $cert_nickname"
        return 0
    fi

    # Generate certificate subject
    local subject="CN=sigul-$component,O=Sigul Infrastructure,C=US"

    # Generate certificate signed by CA
    # Create entropy file for key generation
    local entropy_file
    entropy_file=$(mktemp)
    head -c 1024 /dev/urandom > "$entropy_file"

    if certutil -S -d "sql:$nss_dir" -n "$cert_nickname" -s "$subject" -c "$CA_NICKNAME" -t "u,u,u" -f "$password_file" -k rsa -g 2048 -z "$entropy_file" >/dev/null 2>&1; then
        success "Certificate generated: $cert_nickname"
    else
        fatal "Failed to generate certificate: $cert_nickname"
    fi

    # Clean up entropy file
    rm -f "$entropy_file" 2>/dev/null || true
}

#######################################
# Bridge-Specific Operations (CA)
#######################################

setup_bridge_ca() {
    log "Setting up bridge as Certificate Authority"

    local bridge_nss_dir="$NSS_BASE_DIR/bridge"
    local password_file="$SECRETS_DIR/nss-password"
    local ca_export_file="$CA_EXPORT_DIR/bridge-ca.crt"

    # Create NSS database
    create_nss_database "bridge"

    # Check if CA already exists
    if certutil -d "sql:$bridge_nss_dir" -L -n "$CA_NICKNAME" >/dev/null 2>&1; then
        debug "Bridge CA already exists"
    else
        log "Creating bridge CA certificate"

        # Generate self-signed CA certificate
        local ca_subject="CN=Sigul CA,O=Sigul Infrastructure,C=US"
        # Create entropy file for CA key generation
        local ca_entropy_file
        ca_entropy_file=$(mktemp)
        head -c 1024 /dev/urandom > "$ca_entropy_file"

        if certutil -S -d "sql:$bridge_nss_dir" -n "$CA_NICKNAME" -s "$ca_subject" -t "CT,C,C" -x -f "$password_file" -k rsa -g 2048 -z "$ca_entropy_file" >/dev/null 2>&1; then
            success "Bridge CA certificate created"
        else
            fatal "Failed to create bridge CA certificate"
        fi

        # Clean up CA entropy file
        rm -f "$ca_entropy_file"
    fi

    # Generate bridge service certificate
    generate_component_certificate "bridge" "$BRIDGE_CERT_NICKNAME"

    # Export CA certificate AND private key for other components
    # Ensure CA export directory is writable
    if [[ ! -w "$CA_EXPORT_DIR" ]]; then
        debug "CA export directory not writable, attempting to fix permissions"
        mkdir -p "$CA_EXPORT_DIR" 2>/dev/null || true
        chmod 755 "$CA_EXPORT_DIR" 2>/dev/null || true
    fi

    # Export CA certificate
    local temp_ca_file
    temp_ca_file=$(mktemp)
    if certutil -L -d "sql:$bridge_nss_dir" -n "$CA_NICKNAME" -a > "$temp_ca_file" 2>/dev/null; then
        if cp "$temp_ca_file" "$ca_export_file" 2>/dev/null; then
            success "CA certificate exported for other components"
        else
            debug "Direct copy failed, trying alternative approach"
            if cat "$temp_ca_file" > "$ca_export_file" 2>/dev/null; then
                success "CA certificate exported for other components (alternative method)"
            else
                error "Failed to export CA certificate: $ca_export_file not writable"
                ls -la "$CA_EXPORT_DIR" || true
                fatal "CA export failed - check volume permissions"
            fi
        fi
    else
        fatal "Failed to extract CA certificate from NSS database"
    fi
    rm -f "$temp_ca_file" 2>/dev/null || true

    # Export CA private key in PKCS#12 format for server/client import
    local ca_p12_file="$CA_EXPORT_DIR/bridge-ca.p12"
    local ca_p12_password_file="$CA_EXPORT_DIR/ca-p12-password"

    # Generate password for PKCS#12 file
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25 > "$ca_p12_password_file"
    chmod 600 "$ca_p12_password_file"

    # Export CA certificate and private key to PKCS#12
    if pk12util -d "sql:$bridge_nss_dir" -o "$ca_p12_file" -n "$CA_NICKNAME" -k "$password_file" -w "$ca_p12_password_file" >/dev/null 2>&1; then
        chmod 600 "$ca_p12_file"
        success "CA private key exported for server/client import"
    else
        fatal "Failed to export CA private key"
    fi
}

#######################################
# Server-Specific Operations
#######################################

setup_server_certificates() {
    log "Setting up server certificates"

    local ca_import_file="/var/sigul/bridge-shared/ca-export/bridge-ca.crt"

    # Wait for CA from bridge
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if [[ -f "$ca_import_file" ]] && [[ -s "$ca_import_file" ]]; then
            debug "CA import file found"
            break
        fi
        debug "Waiting for CA from bridge (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        fatal "CA certificate not available from bridge"
    fi

    # Create NSS database
    create_nss_database "server"

    # Import CA certificate and private key
    import_ca_certificate "server" "$ca_import_file"
    import_ca_private_key "server"

    # Generate server certificate
    generate_component_certificate "server" "$SERVER_CERT_NICKNAME"

    # Initialize database file
    initialize_server_database
}

#######################################
# Client-Specific Operations
#######################################

setup_client_certificates() {
    log "Setting up client certificates"

    local ca_import_file="/var/sigul/bridge-shared/ca-export/bridge-ca.crt"

    # Wait for CA from bridge
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if [[ -f "$ca_import_file" ]] && [[ -s "$ca_import_file" ]]; then
            debug "CA import file found"
            break
        fi

        debug "Waiting for CA from bridge (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done

    if [[ ! -f "$ca_import_file" ]] || [[ ! -s "$ca_import_file" ]]; then
        fatal "CA certificate not available from bridge"
    fi

    # Create NSS database
    create_nss_database "client"

    # Import CA certificate and private key
    import_ca_certificate "client" "$ca_import_file"
    import_ca_private_key "client"

    # Generate client certificate
    generate_component_certificate "client" "$CLIENT_CERT_NICKNAME"
}

#######################################
# Configuration Generation
#######################################

initialize_server_database() {
    log "Initializing server database"

    local db_file="$DB_DIR/server.sqlite"

    # Create database file if it doesn't exist
    if [[ ! -f "$db_file" ]]; then
        touch "$db_file"
        chmod 644 "$db_file"
        success "Database file created: $db_file"
    else
        debug "Database file already exists: $db_file"
    fi
}

generate_configuration() {
    local role="$1"
    local config_file="$CONFIG_DIR/$role.conf"

    log "Generating NSS-only configuration for $role"

    # Configuration variables
    local nss_password_file="$SECRETS_DIR/nss-password"
    local bridge_hostname="${SIGUL_BRIDGE_HOSTNAME:-sigul-bridge}"
    local bridge_client_port="${SIGUL_BRIDGE_CLIENT_PORT:-44334}"
    local bridge_server_port="${SIGUL_BRIDGE_SERVER_PORT:-44333}"
    local admin_user="${SIGUL_ADMIN_USER:-admin}"

    # Generate role-specific configuration
    case "$role" in
        "bridge")
            cat > "$config_file" << EOF
[nss]
nss-dir = $NSS_BASE_DIR/bridge
nss-password = $(cat "$nss_password_file")

[bridge]
bridge-cert-nickname = $BRIDGE_CERT_NICKNAME
client-listen-port = $bridge_client_port
server-listen-port = $bridge_server_port
max-file-payload-size = 67108864
required-fas-group =

[daemon]
unix-user =
unix-group =
EOF
            ;;
        "server")
            cat > "$config_file" << EOF
[nss]
nss-dir = $NSS_BASE_DIR/server
nss-password = $(cat "$nss_password_file")

[server]
database-path = $DB_DIR/server.sqlite
nss-dir = sql:$NSS_BASE_DIR/server
nss-password-file = $nss_password_file
ca-cert-nickname = $CA_NICKNAME
server-cert-nickname = $SERVER_CERT_NICKNAME
bridge-hostname = $bridge_hostname
bridge-port = $bridge_server_port
require-tls = true
gnupg-home = $GNUPG_DIR
log-level = INFO
log-file = $LOGS_DIR/server.log
EOF
            ;;
        "client")
            cat > "$config_file" << EOF
[nss]
nss-dir = $NSS_BASE_DIR/client
nss-password = $(cat "$nss_password_file")

[client]
nss-dir = sql:$NSS_BASE_DIR/client
nss-password-file = $nss_password_file
ca-cert-nickname = $CA_NICKNAME
client-cert-nickname = $CLIENT_CERT_NICKNAME
bridge-hostname = $bridge_hostname
bridge-port = $bridge_client_port
require-tls = true
user-name = $admin_user
log-level = INFO
log-file = $LOGS_DIR/client.log
EOF
            ;;
    esac

    success "Configuration generated: $config_file"
}

#######################################
# NSS-Only Validation
#######################################

validate_nss_setup() {
    local role="$1"

    log "Validating NSS setup for $role"

    local nss_dir="$NSS_BASE_DIR/$role"
    local validation_passed=true

    # Check NSS database files
    local required_files=("cert9.db" "key4.db" "pkcs11.txt")
    for file in "${required_files[@]}"; do
        if [[ -f "$nss_dir/$file" ]]; then
            debug "NSS file exists: $file"
        else
            error "Missing NSS file: $file"
            validation_passed=false
        fi
    done

    # Check CA certificate
    if certutil -d "sql:$nss_dir" -L -n "$CA_NICKNAME" >/dev/null 2>&1; then
        debug "CA certificate exists: $CA_NICKNAME"
    else
        error "Missing CA certificate: $CA_NICKNAME"
        validation_passed=false
    fi

    # Check component certificate
    local cert_nickname
    case "$role" in
        "bridge") cert_nickname="$BRIDGE_CERT_NICKNAME" ;;
        "server") cert_nickname="$SERVER_CERT_NICKNAME" ;;
        "client") cert_nickname="$CLIENT_CERT_NICKNAME" ;;
    esac

    if certutil -d "sql:$nss_dir" -L -n "$cert_nickname" >/dev/null 2>&1; then
        debug "Component certificate exists: $cert_nickname"
    else
        error "Missing component certificate: $cert_nickname"
        validation_passed=false
    fi

    if [[ "$validation_passed" == "true" ]]; then
        success "NSS validation passed for $role"
        return 0
    else
        error "NSS validation failed for $role"
        return 1
    fi
}

#######################################
# Service Management
#######################################

start_sigul_service() {
    local role="$1"
    local config_file="$CONFIG_DIR/$role.conf"

    log "Starting Sigul $role service"

    case "$role" in
        "bridge")
            exec sigul_bridge -c "$config_file"
            ;;
        "server")
            exec sigul_server -c "$config_file"
            ;;
        "client")
            log "Client initialized - ready for interactive use"
            exec /bin/bash
            ;;
    esac
}

#######################################
# Main Functions
#######################################

initialize_component() {
    local role="$1"

    log "Initializing Sigul $role with NSS-only approach"

    # Create directory structure
    create_directory_structure

    # Generate NSS password
    generate_nss_password

    # Component-specific setup
    case "$role" in
        "bridge")
            setup_bridge_ca
            ;;
        "server")
            setup_server_certificates
            ;;
        "client")
            setup_client_certificates
            ;;
        *)
            fatal "Invalid role: $role"
            ;;
    esac

    # Generate configuration
    generate_configuration "$role"

    # Validate setup
    if ! validate_nss_setup "$role"; then
        fatal "NSS setup validation failed for $role"
    fi

    success "NSS-only initialization completed for $role"
}

show_usage() {
    cat << EOF
Sigul NSS-Only Initialization Script v$SCRIPT_VERSION

This script initializes Sigul components using NSS certificate management
with bridge-centric CA architecture.

Usage:
  $0 --role ROLE [OPTIONS]

Arguments:
  --role ROLE         Component role (bridge|server|client)

Options:
  --start-service     Start the Sigul service after initialization
  --debug             Enable debug logging
  --validate-only     Only run validation, no initialization
  --help              Show this help message

Examples:
  $0 --role bridge --start-service
  $0 --role server --debug --start-service
  $0 --role client
  $0 --role bridge --validate-only

Environment Variables:
  SIGUL_BRIDGE_HOSTNAME      Bridge hostname (default: sigul-bridge)
  SIGUL_BRIDGE_CLIENT_PORT   Bridge client port (default: 44334)
  SIGUL_BRIDGE_SERVER_PORT   Bridge server port (default: 44333)
  SIGUL_ADMIN_USER          Admin username (default: admin)
  DEBUG                     Enable debug mode (default: false)

EOF
}

main() {
    log "Sigul NSS-Only Initialization Script v$SCRIPT_VERSION"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --role)
                SIGUL_ROLE="$2"
                shift 2
                ;;
            --start-service)
                START_SERVICE=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --validate-only)
                VALIDATE_ONLY=true
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

    # Validate required arguments
    if [[ -z "$SIGUL_ROLE" ]]; then
        error "Role is required. Use --role bridge|server|client"
        show_usage
        exit 1
    fi

    if [[ ! "$SIGUL_ROLE" =~ ^(bridge|server|client)$ ]]; then
        error "Invalid role: $SIGUL_ROLE. Must be bridge, server, or client"
        exit 1
    fi

    # Run validation only if requested
    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        log "Running validation only for $SIGUL_ROLE"
        if validate_nss_setup "$SIGUL_ROLE"; then
            success "Validation passed"
            exit 0
        else
            error "Validation failed"
            exit 1
        fi
    fi

    # Initialize component
    initialize_component "$SIGUL_ROLE"

    # Start service if requested
    if [[ "$START_SERVICE" == "true" ]]; then
        start_sigul_service "$SIGUL_ROLE"
    else
        log "Initialization complete. Use --start-service to start the service."
    fi
}

# Run main function
main "$@"
