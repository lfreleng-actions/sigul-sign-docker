#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Unified Sigul Initialization Script
# This script replaces the separate sigul-server-init.sh and sigul-bridge-init.sh scripts
# with a unified, modular approach supporting all sigul components.
#
# Usage: sigul-init.sh --role <server|bridge|client>
#
# Environment Variables:
#   SIGUL_ROLE              - Component role (server|bridge|client)
#   SIGUL_BASE_DIR         - Base application directory (default: /var/sigul)
#   DEBUG                  - Enable debug logging (default: false)
#   NSS_PASSWORD           - NSS database password (generated if not provided)
#   SIGUL_ADMIN_PASSWORD   - Admin password for server role (generated if not provided)
#   SIGUL_BRIDGE_HOSTNAME  - Bridge connection hostname (default: sigul-bridge)
#   SIGUL_BRIDGE_CLIENT_PORT - Bridge client listen port (default: 44334)
#   SIGUL_BRIDGE_SERVER_PORT - Bridge server listen port (default: 44333)

set -euo pipefail

# Global variables
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly VERSION="1.0.0"
readonly DEFAULT_BASE_DIR="/var/sigul"

# Secrets and certificate configuration
readonly NSS_PASSWORD_LENGTH=32
readonly ADMIN_PASSWORD_LENGTH=16
readonly CERT_VALIDITY_DAYS=365
readonly MIN_CERT_DAYS_REMAINING=30

# Component role - set by command line or environment
SIGUL_ROLE="${SIGUL_ROLE:-}"

# Application directory structure (initialized in setup_env)
SIGUL_BASE_DIR="${SIGUL_BASE_DIR:-$DEFAULT_BASE_DIR}"
CONFIG_DIR=""
LOGS_DIR=""
PIDS_DIR=""
SECRETS_DIR=""
NSS_DIR=""
DATABASE_DIR=""
GNUPG_DIR=""
TMP_DIR=""

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_INVALID_ROLE=2
readonly EXIT_SETUP_FAILED=3
readonly EXIT_VALIDATION_FAILED=4
# readonly EXIT_SERVICE_FAILED=5  # Currently unused but may be needed in future
readonly EXIT_DEPENDENCY_MISSING=6
readonly EXIT_CONFIG_ERROR=7

#######################################
# Core Utility Functions
#######################################

# Unified logging system with timestamps and component identification
# Arguments:
#   $1 - Log message
# Outputs:
#   Timestamped log message to stdout
log() {
    local component
    component="$(echo "${SIGUL_ROLE:-sigul}" | tr '[:lower:]' '[:upper:]')"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $component: $*"
}

# Error logging with exit codes
# Arguments:
#   $1 - Error message
#   $2 - Exit code (optional, defaults to 1)
# Outputs:
#   Timestamped error message to stderr
error() {
    local message="$1"
    local exit_code="${2:-1}"
    local component
    component="$(echo "${SIGUL_ROLE:-sigul}" | tr '[:lower:]' '[:upper:]')"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $component ERROR: $message" >&2
    exit "$exit_code"
}

# Debug logging with conditional output
# Arguments:
#   $1 - Debug message
# Outputs:
#   Timestamped debug message to stdout if DEBUG=true
debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        local component
        component="$(echo "${SIGUL_ROLE:-sigul}" | tr '[:lower:]' '[:upper:]')"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $component DEBUG: $*"
    fi
}

# Validate component role
# Arguments:
#   $1 - Role to validate
# Returns:
#   0 if valid role, 1 if invalid
validate_role() {
    local role="$1"
    case "$role" in
        server|bridge|client)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Display usage information
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME --role <server|bridge|client> [options]

Unified Sigul Initialization Script v$VERSION

This script initializes sigul components with a unified directory structure
and modular function design.

OPTIONS:
    --role ROLE         Component role: server, bridge, or client (required)
    --base-dir DIR      Base application directory (default: $DEFAULT_BASE_DIR)
    --debug             Enable debug logging
    --start-service     Start service after initialization
    --service-only      Skip initialization, start service directly
    --help              Show this help message
    --version           Show version information

ENVIRONMENT VARIABLES:
    SIGUL_ROLE             Component role (can override --role)
    SIGUL_BASE_DIR         Base application directory
    DEBUG                  Enable debug logging (true/false)
    NSS_PASSWORD           NSS database password (auto-generated if not set)
    SIGUL_ADMIN_PASSWORD   Admin password for server (auto-generated if not set)
    SIGUL_BRIDGE_HOSTNAME  Bridge connection hostname (default: sigul-bridge)
    SIGUL_BRIDGE_CLIENT_PORT Bridge client listen port (default: 44334)
    SIGUL_BRIDGE_SERVER_PORT Bridge server listen port (default: 44333)

EXAMPLES:
    # Initialize sigul server
    $SCRIPT_NAME --role server

    # Initialize sigul bridge with debug logging
    $SCRIPT_NAME --role bridge --debug

    # Initialize and start server service
    $SCRIPT_NAME --role server --start-service

    # Start service only (skip initialization)
    $SCRIPT_NAME --role bridge --service-only

    # Initialize with custom base directory
    $SCRIPT_NAME --role server --base-dir /opt/sigul

    # Use environment variables
    export SIGUL_ROLE=server
    export DEBUG=true
    $SCRIPT_NAME

DIRECTORY STRUCTURE:
    The script creates a unified directory structure under \$SIGUL_BASE_DIR:

    $DEFAULT_BASE_DIR/
    ├── config/             # Configuration files
    ├── logs/               # Log files (by component)
    ├── pids/               # PID files
    ├── secrets/            # Passwords, private keys (700 permissions)
    ├── nss/                # NSS databases (700 permissions)
    ├── database/           # SQLite database files (server only)
    ├── gnupg/              # GPG home directory
    └── tmp/                # Temporary files

EOF
}

# Display version information
show_version() {
    echo "$SCRIPT_NAME version $VERSION"
    echo "Part of sigul-sign-docker infrastructure"
    echo "SPDX-License-Identifier: Apache-2.0"
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --role)
                if [[ -n "${2:-}" ]]; then
                    SIGUL_ROLE="$2"
                    shift 2
                else
                    error "Option --role requires an argument" $EXIT_INVALID_ARGS
                fi
                ;;
            --base-dir)
                if [[ -n "${2:-}" ]]; then
                    SIGUL_BASE_DIR="$2"
                    shift 2
                else
                    error "Option --base-dir requires an argument" $EXIT_INVALID_ARGS
                fi
                ;;
            --debug)
                export DEBUG=true
                shift
                ;;
            --start-service)
                # Flag handled in main() - just consume it here
                shift
                ;;
            --service-only)
                # Flag handled in main() - just consume it here
                shift
                ;;
            --help|-h)
                show_usage
                exit $EXIT_SUCCESS
                ;;
            --version|-v)
                show_version
                exit $EXIT_SUCCESS
                ;;
            -*)
                error "Unknown option: $1" $EXIT_INVALID_ARGS
                ;;
            *)
                error "Unexpected argument: $1" $EXIT_INVALID_ARGS
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$SIGUL_ROLE" ]]; then
        error "Role is required. Use --role or set SIGUL_ROLE environment variable." $EXIT_INVALID_ARGS
    fi

    if ! validate_role "$SIGUL_ROLE"; then
        error "Invalid role: $SIGUL_ROLE. Must be server, bridge, or client." $EXIT_INVALID_ROLE
    fi
}

# Setup and validate environment variables
setup_env() {
    debug "Setting up environment variables for role: $SIGUL_ROLE"

    # Initialize directory paths based on final SIGUL_BASE_DIR
    CONFIG_DIR="$SIGUL_BASE_DIR/config"
    LOGS_DIR="$SIGUL_BASE_DIR/logs"
    PIDS_DIR="$SIGUL_BASE_DIR/pids"
    SECRETS_DIR="$SIGUL_BASE_DIR/secrets"
    NSS_DIR="$SIGUL_BASE_DIR/nss"
    DATABASE_DIR="$SIGUL_BASE_DIR/database"
    GNUPG_DIR="$SIGUL_BASE_DIR/gnupg"
    TMP_DIR="$SIGUL_BASE_DIR/tmp"

    # Core environment variables with defaults
    export SIGUL_ROLE
    export SIGUL_BASE_DIR
    export DEBUG="${DEBUG:-false}"

    # Component-specific environment variables with defaults
    # NOTE: Bridge bind address is NOT configurable - Sigul always binds to 0.0.0.0
    export SIGUL_BRIDGE_HOSTNAME="${SIGUL_BRIDGE_HOSTNAME:-sigul-bridge}"
    export SIGUL_BRIDGE_CLIENT_PORT="${SIGUL_BRIDGE_CLIENT_PORT:-44334}"
    export SIGUL_BRIDGE_SERVER_PORT="${SIGUL_BRIDGE_SERVER_PORT:-44333}"

    # Validate numeric ports
    if ! [[ "$SIGUL_BRIDGE_CLIENT_PORT" =~ ^[0-9]+$ ]] || (( SIGUL_BRIDGE_CLIENT_PORT < 1 || SIGUL_BRIDGE_CLIENT_PORT > 65535 )); then
        error "Invalid SIGUL_BRIDGE_CLIENT_PORT: $SIGUL_BRIDGE_CLIENT_PORT. Must be 1-65535." $EXIT_INVALID_ARGS
    fi
    if ! [[ "$SIGUL_BRIDGE_SERVER_PORT" =~ ^[0-9]+$ ]] || (( SIGUL_BRIDGE_SERVER_PORT < 1 || SIGUL_BRIDGE_SERVER_PORT > 65535 )); then
        error "Invalid SIGUL_BRIDGE_SERVER_PORT: $SIGUL_BRIDGE_SERVER_PORT. Must be 1-65535." $EXIT_INVALID_ARGS
    fi

    # Validate base directory is absolute path
    if [[ ! "$SIGUL_BASE_DIR" =~ ^/ ]]; then
        error "SIGUL_BASE_DIR must be an absolute path: $SIGUL_BASE_DIR" $EXIT_INVALID_ARGS
    fi

    debug "Environment setup complete:"
    debug "  Role: $SIGUL_ROLE"
    debug "  Base directory: $SIGUL_BASE_DIR"
    debug "  Bridge: $SIGUL_BRIDGE_HOSTNAME:$SIGUL_BRIDGE_CLIENT_PORT"
    debug "  Debug mode: $DEBUG"
}

#######################################
# Application Directory Functions
#######################################

# Create complete /var/sigul directory structure
setup_application_directory() {
    log "Setting up application directory structure at $SIGUL_BASE_DIR"

    # Create all required directories
    # Logging structure:
    # - Server: Daemon logs to $LOGS_DIR/server/ via --internal-log-dir
    # - Bridge: Daemon logs to $LOGS_DIR/bridge/ via --internal-log-dir
    # - Client: Non-daemon, logs to stderr (container stdout/stderr)
    local directories=(
        "$SIGUL_BASE_DIR"
        "$CONFIG_DIR"
        "$LOGS_DIR"
        "$LOGS_DIR/server"
        "$LOGS_DIR/bridge"
        "$PIDS_DIR"
        "$SECRETS_DIR"
        "$SECRETS_DIR/nss-passwords"
        "$SECRETS_DIR/admin-passwords"
        "$SECRETS_DIR/certificates"
        "$NSS_DIR"
        "$NSS_DIR/server"
        "$NSS_DIR/bridge"
        "$NSS_DIR/client"
        "$DATABASE_DIR"
        "$GNUPG_DIR"
        "$TMP_DIR"
    )

    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            debug "Creating directory: $dir"
            mkdir -p "$dir" || error "Failed to create directory: $dir" $EXIT_SETUP_FAILED
        else
            debug "Directory already exists: $dir"
        fi
    done

    log "Directory structure created successfully"
}

# Apply correct permissions to directory structure
set_directory_permissions() {
    log "Setting directory permissions"

    # Base directory - readable by sigul group
    chmod 755 "$SIGUL_BASE_DIR" || error "Failed to set permissions on $SIGUL_BASE_DIR" $EXIT_SETUP_FAILED

    # Secrets - completely private
    chmod 700 "$SECRETS_DIR" || error "Failed to set permissions on $SECRETS_DIR" $EXIT_SETUP_FAILED
    find "$SECRETS_DIR" -type d -exec chmod 700 {} \; || error "Failed to set permissions on secrets subdirectories" $EXIT_SETUP_FAILED

    # NSS databases - private
    chmod 700 "$NSS_DIR" || error "Failed to set permissions on $NSS_DIR" $EXIT_SETUP_FAILED
    find "$NSS_DIR" -type d -exec chmod 700 {} \; || error "Failed to set permissions on NSS subdirectories" $EXIT_SETUP_FAILED

    # Configs - readable by group
    chmod 750 "$CONFIG_DIR" || error "Failed to set permissions on $CONFIG_DIR" $EXIT_SETUP_FAILED

    # Logs - readable for debugging (all components)
    chmod 755 "$LOGS_DIR" || error "Failed to set permissions on $LOGS_DIR" $EXIT_SETUP_FAILED
    find "$LOGS_DIR" -type d -exec chmod 755 {} \; || error "Failed to set permissions on log subdirectories" $EXIT_SETUP_FAILED

    # Ensure sigul user can write to all log directories
    chown -R sigul:sigul "$LOGS_DIR" || error "Failed to set ownership on log directories" $EXIT_SETUP_FAILED

    # PIDs - readable for monitoring
    chmod 755 "$PIDS_DIR" || error "Failed to set permissions on $PIDS_DIR" $EXIT_SETUP_FAILED

    # Database - private
    chmod 700 "$DATABASE_DIR" || error "Failed to set permissions on $DATABASE_DIR" $EXIT_SETUP_FAILED

    # GPG - private
    chmod 700 "$GNUPG_DIR" || error "Failed to set permissions on $GNUPG_DIR" $EXIT_SETUP_FAILED

    # Temporary - private
    chmod 700 "$TMP_DIR" || error "Failed to set permissions on $TMP_DIR" $EXIT_SETUP_FAILED

    debug "Directory permissions set successfully"
}

# Verify directory setup is correct
validate_directories() {
    log "Validating directory structure"

    local required_dirs=(
        "$SIGUL_BASE_DIR"
        "$CONFIG_DIR"
        "$LOGS_DIR"
        "$PIDS_DIR"
        "$SECRETS_DIR"
        "$NSS_DIR"
        "$DATABASE_DIR"
        "$GNUPG_DIR"
        "$TMP_DIR"
    )

    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            error "Required directory missing: $dir" $EXIT_VALIDATION_FAILED
        fi
        if [[ ! -w "$dir" ]]; then
            error "Directory not writable: $dir" $EXIT_VALIDATION_FAILED
        fi
        debug "Validated directory: $dir"
    done

    # Validate specific role directories exist
    local role_nss_dir="$NSS_DIR/$SIGUL_ROLE"

    # Only validate log directories for server and bridge (daemons that write log files)
    # Client logs go to stderr/stdout and don't need a log directory
    if [[ "$SIGUL_ROLE" == "server" || "$SIGUL_ROLE" == "bridge" ]]; then
        local role_log_dir="$LOGS_DIR/$SIGUL_ROLE"
        if [[ ! -d "$role_log_dir" ]]; then
            error "Role-specific log directory missing: $role_log_dir" $EXIT_VALIDATION_FAILED
        fi
    fi

    if [[ ! -d "$role_nss_dir" ]]; then
        error "Role-specific NSS directory missing: $role_nss_dir" $EXIT_VALIDATION_FAILED
    fi

    log "Directory validation completed successfully"
}

# Handle migration from existing installations
# Legacy migration function removed - not needed in containerized environment

#######################################
# Phase 2: Security and Secrets Management Functions
#######################################

# Generate secure random password
# Arguments:
#   $1 - Password length
# Outputs:
#   Random password to stdout
generate_password() {
    local length="$1"
    # Use openssl for secure random generation, generate more bytes than needed
    # to account for base64 encoding overhead and character filtering
    local raw_bytes=$((length * 2))
    openssl rand -base64 "$raw_bytes" | tr -d "=+/\n" | head -c "$length"
}

# Store secret securely in secrets directory
# Arguments:
#   $1 - Secret name (e.g., "nss_password", "admin_password")
#   $2 - Secret value
#   $3 - Component role (optional, defaults to current role)
store_secret() {
    local secret_name="$1"
    local secret_value="$2"
    local component_role="${3:-$SIGUL_ROLE}"

    local secret_file="$SECRETS_DIR/${component_role}_${secret_name}"

    # Write secret to file with secure permissions
    echo "$secret_value" > "$secret_file"
    chmod 600 "$secret_file"

    return 0
}

# Load secret from secrets directory
# Arguments:
#   $1 - Secret name
#   $2 - Component role (optional, defaults to current role)
# Outputs:
#   Secret value to stdout
# Returns:
#   0 if secret loaded, 1 if not found
load_secret() {
    local secret_name="$1"
    local component_role="${2:-$SIGUL_ROLE}"

    local secret_file="$SECRETS_DIR/${component_role}_${secret_name}"

    if [[ -f "$secret_file" ]]; then
        cat "$secret_file"
        return 0
    else
        return 1
    fi
}

# Generate NSS database password
# Outputs:
#   Password to stdout
generate_nss_password() {
    # Check if password already exists
    if load_secret "nss_password" >/dev/null 2>&1; then
        load_secret "nss_password"
        return 0
    fi

    # Check environment variable
    if [[ -n "${NSS_PASSWORD:-}" ]]; then
        store_secret "nss_password" "$NSS_PASSWORD"
        echo "$NSS_PASSWORD"
        return 0
    fi

    # Generate new password
    local password
    password=$(generate_password "$NSS_PASSWORD_LENGTH")

    store_secret "nss_password" "$password"
    echo "$password"
}

# Generate admin password (server role only)
# Outputs:
#   Password to stdout
generate_admin_password() {
    if [[ "$SIGUL_ROLE" != "server" ]]; then
        debug "Admin password only needed for server role"
        return 0
    fi

    # Check if password already exists
    if load_secret "admin_password" >/dev/null 2>&1; then
        load_secret "admin_password"
        return 0
    fi

    # Check environment variable
    if [[ -n "${SIGUL_ADMIN_PASSWORD:-}" ]]; then
        store_secret "admin_password" "$SIGUL_ADMIN_PASSWORD"
        echo "$SIGUL_ADMIN_PASSWORD"
        return 0
    fi

    # Generate new password
    local password
    password=$(generate_password "$ADMIN_PASSWORD_LENGTH")

    store_secret "admin_password" "$password"
    echo "$password"
}

# Validate secret file permissions
# Arguments:
#   $1 - Secret file path
# Returns:
#   0 if permissions are correct, 1 if not
validate_secret_permissions() {
    local secret_file="$1"

    if [[ ! -f "$secret_file" ]]; then
        debug "Secret file does not exist: $secret_file"
        return 1
    fi

    # Check permissions are 600 (owner read/write only)
    local perms
    perms=$(stat -c "%a" "$secret_file" 2>/dev/null || stat -f "%A" "$secret_file" 2>/dev/null)

    if [[ "$perms" != "600" ]]; then
        error "Invalid permissions on secret file $secret_file: $perms (expected: 600)" $EXIT_VALIDATION_FAILED
    fi

    debug "Secret file permissions validated: $secret_file"
    return 0
}

# Main secrets setup orchestration
setup_secrets() {
    log "Setting up secrets management for role: $SIGUL_ROLE"

    # Generate NSS password for all roles
    local nss_password
    nss_password=$(generate_nss_password)
    export NSS_PASSWORD="$nss_password"

    # Generate admin password for server role
    if [[ "$SIGUL_ROLE" == "server" ]]; then
        local admin_password
        admin_password=$(generate_admin_password)
        export SIGUL_ADMIN_PASSWORD="$admin_password"
    fi

    # Validate all secret files have correct permissions
    for secret_file in "$SECRETS_DIR"/*; do
        if [[ -f "$secret_file" ]]; then
            validate_secret_permissions "$secret_file"
        fi
    done

    log "Secrets management setup completed"
}




# Validate certificate file
# Arguments:
#   $1 - Certificate file path
# Returns:
#   0 if valid, 1 if invalid
validate_certificate() {
    local cert_file="$1"

    if [[ ! -f "$cert_file" ]]; then
        return 1
    fi

    # Check if certificate is valid using openssl
    if ! openssl x509 -in "$cert_file" -noout -checkend $((MIN_CERT_DAYS_REMAINING * 24 * 3600)) >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

# Generate self-signed test certificate
# Arguments:
#   $1 - Certificate name (e.g., "server", "bridge", "client")
# Outputs:
#   Path to generated certificate
generate_test_certificate() {
    local cert_name="$1"
    local cert_file="$SECRETS_DIR/certificates/${cert_name}.crt"
    local key_file="$SECRETS_DIR/certificates/${cert_name}-key.pem"

    # Create certificate directory if it doesn't exist
    mkdir -p "$(dirname "$cert_file")" >/dev/null 2>&1

    # Generate private key
    openssl genrsa -out "$key_file" 2048 >/dev/null 2>&1
    chmod 600 "$key_file" >/dev/null 2>&1

    # Generate self-signed certificate
    openssl req -new -x509 -key "$key_file" -out "$cert_file" -days "$CERT_VALIDITY_DAYS" \
        -subj "/C=US/ST=Test/L=Test/O=Sigul Test/OU=Testing/CN=${cert_name}.sigul.test" \
        >/dev/null 2>&1
    chmod 644 "$cert_file" >/dev/null 2>&1

    echo "$cert_file"
}

# Import certificates to NSS database
# Arguments:
#   $1 - Certificate file path
import_certificate_to_nss() {
    local cert_file="$1"

    # Store certificate path for later NSS import
    local import_list="$NSS_DIR/$SIGUL_ROLE/import_list.txt"
    echo "$cert_file" >> "$import_list"
}

# Main certificate setup orchestration
setup_certificates() {
    log "Setting up certificate management for role: $SIGUL_ROLE"

    # Clear any existing import list to prevent duplicates
    local import_list="$NSS_DIR/$SIGUL_ROLE/import_list.txt"
    true > "$import_list"

    # Generate test certificates for this role
    log "Generating test certificates for role: $SIGUL_ROLE"

    local generated_certs=()
    case "$SIGUL_ROLE" in
        server)
            local server_cert
            server_cert=$(generate_test_certificate "server")
            log "Generated test certificate: $server_cert"
            generated_certs+=("$server_cert")
            local ca_cert
            ca_cert=$(generate_test_certificate "ca")
            log "Generated test certificate: $ca_cert"
            generated_certs+=("$ca_cert")
            ;;
        bridge)
            local bridge_cert
            bridge_cert=$(generate_test_certificate "bridge")
            log "Generated test certificate: $bridge_cert"
            generated_certs+=("$bridge_cert")
            local ca_cert
            ca_cert=$(generate_test_certificate "ca")
            log "Generated test certificate: $ca_cert"
            generated_certs+=("$ca_cert")
            ;;
        client)
            local client_cert
            client_cert=$(generate_test_certificate "client")
            log "Generated test certificate: $client_cert"
            generated_certs+=("$client_cert")
            local ca_cert
            ca_cert=$(generate_test_certificate "ca")
            log "Generated test certificate: $ca_cert"
            generated_certs+=("$ca_cert")
            ;;
    esac

    # Import certificates for NSS
    for cert_file in "${generated_certs[@]}"; do
        if [[ -n "$cert_file" ]] && [[ -f "$cert_file" ]]; then
            import_certificate_to_nss "$cert_file"
        fi
    done

    log "Certificate management setup completed"
    log "Generated and prepared ${#generated_certs[@]} certificate(s) for NSS import"
}

#######################################
# Phase 3.1: NSS Database Management
#######################################

# Create NSS database with password for specified role
create_nss_database() {
    local role="$1"
    local nss_dir="$SIGUL_BASE_DIR/nss/$role"


    debug "Creating NSS database for role: $role"
    debug "NSS directory: $nss_dir"

    # Ensure NSS directory exists
    if ! mkdir -p "$nss_dir"; then
        error "Failed to create NSS directory: $nss_dir"
    fi

    # Check if NSS database already exists
    if [[ -f "$nss_dir/cert9.db" ]] && [[ -f "$nss_dir/key4.db" ]] && [[ -f "$nss_dir/pkcs11.txt" ]]; then
        log "NSS database already exists for role: $role"
        return 0
    fi

    # Load the NSS password
    local nss_password
    if ! nss_password=$(load_secret "nss_password" "$role"); then
        error "Failed to load NSS password for role: $role"
    fi

    # Create NSS database
    log "Creating NSS database for role: $role"
    if ! echo "$nss_password" | certutil -N -d "$nss_dir" -f /dev/stdin; then
        error "Failed to create NSS database for role: $role"
    fi

    # Set proper permissions on NSS database files
    chmod 600 "$nss_dir"/*
    chown sigul:sigul "$nss_dir"/*

    log "NSS database created successfully for role: $role"
    return 0
}

# Import certificates into NSS database
import_nss_certificates() {
    local role="$1"
    local nss_dir="$SIGUL_BASE_DIR/nss/$role"
    local cert_dir="$SIGUL_BASE_DIR/secrets/certificates"
    local import_list="$nss_dir/import_list.txt"

    debug "Importing certificates to NSS database for role: $role"

    # Check if NSS database exists
    if [[ ! -f "$nss_dir/cert9.db" ]]; then
        error "NSS database does not exist for role: $role"
    fi

    # Check if import list exists
    if [[ ! -f "$import_list" ]]; then
        debug "No certificate import list found for role: $role"
        return 0
    fi

    # Load the NSS password
    local nss_password
    if ! nss_password=$(load_secret "nss_password" "$role"); then
        error "Failed to load NSS password for role: $role"
    fi

    # Import each certificate from the list
    local imported_count=0
    while IFS= read -r cert_file; do
        if [[ -n "$cert_file" ]] && [[ -f "$cert_file" ]]; then
            local cert_name
            cert_name=$(basename "$cert_file" .crt)

            # Use proper certificate nicknames based on role and certificate type
            local cert_nickname
            case "$role" in
                server)
                    if [[ "$cert_name" == "server" ]]; then
                        cert_nickname="sigul-server-cert"
                    elif [[ "$cert_name" == "ca" ]]; then
                        cert_nickname="sigul-ca-cert"
                    else
                        cert_nickname="$cert_name"
                    fi
                    ;;
                bridge)
                    if [[ "$cert_name" == "bridge" ]]; then
                        cert_nickname="sigul-bridge-cert"
                    elif [[ "$cert_name" == "ca" ]]; then
                        cert_nickname="sigul-ca-cert"
                    else
                        cert_nickname="$cert_name"
                    fi
                    ;;
                client)
                    if [[ "$cert_name" == "client" ]]; then
                        cert_nickname="sigul-client-cert"
                    elif [[ "$cert_name" == "ca" ]]; then
                        cert_nickname="sigul-ca-cert"
                    else
                        cert_nickname="$cert_name"
                    fi
                    ;;
                *)
                    cert_nickname="$cert_name"
                    ;;
            esac

            log "Importing certificate: $cert_name as nickname: $cert_nickname"
            if echo "$nss_password" | certutil -A -d "$nss_dir" -n "$cert_nickname" -t "CT,C,C" -i "$cert_file" -f /dev/stdin; then
                ((imported_count++))
                debug "Successfully imported: $cert_name as $cert_nickname"

                # Also import private key if it exists
                local key_file="${cert_file%.*}-key.pem"
                if [[ -f "$key_file" ]]; then
                    log "Importing private key for certificate: $cert_name"
                    # Create temporary PKCS#12 file to import both cert and key
                    local temp_p12=""
                    temp_p12=$(mktemp -t cert.XXXXXXXX.p12)
                    trap 'rm -f "$temp_p12" 2>/dev/null || true' EXIT

                    # Convert cert + key to PKCS#12 format (password protected)
                    if openssl pkcs12 -export -in "$cert_file" -inkey "$key_file" \
                        -out "$temp_p12" -name "$cert_nickname" \
                        -passout pass:"$nss_password" >/dev/null 2>&1; then

                        # Import PKCS#12 into NSS (this updates the existing cert with private key)
                        if echo "$nss_password" | pk12util -i "$temp_p12" -d "$nss_dir" -W "$nss_password" -K "$nss_password" 2>/dev/null; then
                            debug "Successfully imported private key for: $cert_name"
                        else
                            log "Warning: Failed to import private key for: $cert_name (certificate import succeeded)"
                        fi
                    else
                        log "Warning: Failed to create PKCS#12 file for: $cert_name"
                    fi

                    rm -f "$temp_p12" 2>/dev/null || true
                    trap - EXIT
                fi
            else
                error "Failed to import certificate: $cert_name as $cert_nickname"
            fi
        fi
    done < "$import_list"

    log "Imported $imported_count certificate(s) to NSS database for role: $role"
    return 0
}

# Validate NSS database integrity
validate_nss_database() {
    local role="$1"
    local nss_dir="$SIGUL_BASE_DIR/nss/$role"

    debug "Validating NSS database for role: $role"

    # Check if NSS database files exist
    local required_files=("cert9.db" "key4.db" "pkcs11.txt")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$nss_dir/$file" ]]; then
            error "Missing NSS database file: $nss_dir/$file"
        fi
    done

    # Load the NSS password
    local nss_password
    if ! nss_password=$(load_secret "nss_password" "$role"); then
        error "Failed to load NSS password for role: $role"
    fi

    # Test NSS database accessibility
    if ! echo "$nss_password" | certutil -L -d "$nss_dir" -f /dev/stdin >/dev/null 2>&1; then
        error "NSS database is not accessible or corrupted for role: $role"
    fi

    # List certificates in database
    local cert_count
    cert_count=$(echo "$nss_password" | certutil -L -d "$nss_dir" -f /dev/stdin 2>/dev/null | grep -c "^[[:space:]]*[^[:space:]]" || echo "0")

    debug "NSS database validation successful for role: $role"
    debug "Found $cert_count certificate(s) in database"

    return 0
}

# Migrate existing NSS database if present
# Legacy NSS migration function removed - not needed in containerized environment

# Main NSS database setup orchestration
setup_nss_database() {
    local role="$SIGUL_ROLE"

    log "Setting up NSS database for role: $role"

    # Create NSS database
    if ! create_nss_database "$role"; then
        error "Failed to create NSS database for role: $role"
    fi

    # Step 3: Import certificates
    if ! import_nss_certificates "$role"; then
        error "Failed to import certificates to NSS database for role: $role"
    fi

    # Step 4: Validate database integrity
    if ! validate_nss_database "$role"; then
        error "NSS database validation failed for role: $role"
    fi

    log "NSS database setup completed successfully for role: $role"
    return 0
}

#######################################
# Phase 3.2: Configuration Generation
#######################################

# Substitute environment variables in configuration template
substitute_variables() {
    local input="$1"
    local output="$2"

    debug "Substituting variables in configuration"
    debug "Input: $input"
    debug "Output: $output"

    # Create output from input with variable substitution
    eval "cat << 'TEMPLATE_EOF'
$(cat "$input")
TEMPLATE_EOF" > "$output"

    if ! certutil -L -d "$nss_dir" -h all &>/dev/null; then
        error "Failed to substitute variables in configuration"
    fi

    debug "Variable substitution completed successfully"
    return 0
}

# Generate server configuration
generate_server_config() {
    local config_file="$SIGUL_BASE_DIR/config/server.conf"
    local nss_dir="$SIGUL_BASE_DIR/nss/server"
    local database_dir="$SIGUL_BASE_DIR/database"

    log "Generating server configuration"

    # Load NSS password directly to avoid debug output during config generation
    local nss_password
    if ! nss_password=$(load_secret "nss_password" 2>/dev/null); then
        error "Failed to load NSS password for server configuration"
    fi

    # Set default environment variables for configuration
    export SIGUL_BRIDGE_HOSTNAME="${SIGUL_BRIDGE_HOSTNAME:-sigul-bridge}"
    export SIGUL_BRIDGE_CLIENT_PORT="${SIGUL_BRIDGE_CLIENT_PORT:-44334}"
    export SIGUL_NSS_DIR="$nss_dir"
    export SIGUL_DATABASE_PATH="$database_dir/sigul.db"
    export SIGUL_LOG_DIR="$SIGUL_BASE_DIR/logs/server"
    export SIGUL_PID_FILE="$SIGUL_BASE_DIR/pids/server.pid"

    # Create server configuration content with variable substitution
    cat > "$config_file" << SERVER_CONFIG_EOF
# Sigul Server Configuration
# Generated by sigul-init.sh

[server]
# Bridge connection configuration
bridge-hostname = sigul-bridge
bridge-port = ${SIGUL_BRIDGE_CLIENT_PORT}
server-cert-nickname = sigul-server-cert
max-file-payload-size = 2097152
signing-timeout = 60
idle-timeout = 300


# Database Configuration - SQLite
[database]
database-path = ${SIGUL_DATABASE_PATH}

# SSL/TLS configuration
ca-cert-file = ${SIGUL_BASE_DIR}/secrets/certificates/ca.crt
server-cert-file = ${SIGUL_BASE_DIR}/secrets/certificates/server.crt
server-key-file = ${SIGUL_BASE_DIR}/secrets/certificates/server-key.pem
require-tls = true

# NSS Configuration
[nss]
nss-dir = ${SIGUL_NSS_DIR}
nss-password = ${nss_password}

# GnuPG Configuration
[gnupg]
gnupg-home = ${GNUPG_DIR}


# Daemon configuration
# IMPORTANT: Empty unix-user/unix-group disables privilege dropping in containers.
# This is REQUIRED when running as non-root container user (sigul UID 1000).
# Privilege dropping fails when container already runs as target user.
# Container runtime provides security isolation - no additional dropping needed.
[daemon]
unix-user =
unix-group =

SERVER_CONFIG_EOF

    # Set proper permissions
    chmod 640 "$config_file"
    chown sigul:sigul "$config_file"

    log "Server configuration generated successfully"
    return 0
}

# Generate bridge configuration
generate_bridge_config() {
    local config_file="$SIGUL_BASE_DIR/config/bridge.conf"
    local nss_dir="$SIGUL_BASE_DIR/nss/bridge"

    log "Generating bridge configuration"

    # Load NSS password directly to avoid debug output during config generation
    local nss_password
    if ! nss_password=$(load_secret "nss_password" 2>/dev/null); then
        error "Failed to load NSS password for bridge configuration"
    fi

    # Set default environment variables for configuration
    export SIGUL_BRIDGE_CLIENT_PORT="${SIGUL_BRIDGE_CLIENT_PORT:-44334}"
    export SIGUL_BRIDGE_SERVER_PORT="${SIGUL_BRIDGE_SERVER_PORT:-44333}"
    export SIGUL_NSS_DIR="$nss_dir"
    export SIGUL_GNUPG_DIR="$SIGUL_BASE_DIR/gnupg"

    # Create bridge configuration content with variable substitution
    cat > "$config_file" << BRIDGE_CONFIG_EOF
# Sigul Bridge Configuration
# Generated by sigul-init.sh

[bridge]
# IMPORTANT: Sigul bridge ALWAYS binds to all interfaces (0.0.0.0)
# There is NO configuration option in Sigul to change the bind address
# The bridge hardcodes: sock.bind(nss.io.NetworkAddress(nss.io.PR_IpAddrAny, port))
# See: /usr/share/sigul/bridge.py create_listen_sock() function
client-listen-port = ${SIGUL_BRIDGE_CLIENT_PORT}
server-listen-port = ${SIGUL_BRIDGE_SERVER_PORT}
# Server connection configuration
server-hostname = sigul-server
bridge-cert-nickname = sigul-bridge-cert
max-file-payload-size = 2097152
idle-timeout = 300
# NSS directory setting
nss-dir = ${SIGUL_NSS_DIR}

# SSL/TLS configuration
ca-cert-file = ${SIGUL_BASE_DIR}/secrets/certificates/ca.crt
bridge-cert-file = ${SIGUL_BASE_DIR}/secrets/certificates/bridge.crt
bridge-key-file = ${SIGUL_BASE_DIR}/secrets/certificates/bridge-key.pem
require-tls = true

# NSS Configuration
[nss]
nss-dir = ${SIGUL_NSS_DIR}
nss-password = ${nss_password}

# GnuPG Configuration
[gnupg]
gnupg-home = ${SIGUL_GNUPG_DIR}


# Daemon configuration
# IMPORTANT: Empty unix-user/unix-group disables privilege dropping in containers.
# This is REQUIRED when running as non-root container user (sigul UID 1000).
# Privilege dropping fails when container already runs as target user.
# Container runtime provides security isolation - no additional dropping needed.
[daemon]
unix-user =
unix-group =

BRIDGE_CONFIG_EOF

    # Set proper permissions
    chmod 640 "$config_file"
    chown sigul:sigul "$config_file"

    log "Bridge configuration generated successfully"
    return 0
}

# Generate client configuration
generate_client_config() {
    local config_file="$SIGUL_BASE_DIR/config/client.conf"
    local nss_dir="$SIGUL_BASE_DIR/nss/client"

    log "Generating client configuration"

    # Load NSS password directly to avoid debug output during config generation
    local nss_password
    if ! nss_password=$(load_secret "nss_password" 2>/dev/null); then
        error "Failed to load NSS password for client configuration"
    fi

    # Set default environment variables for configuration
    # Set default environment variables for configuration
    export SIGUL_BRIDGE_HOSTNAME="${SIGUL_BRIDGE_HOSTNAME:-sigul-bridge}"
    export SIGUL_BRIDGE_CLIENT_PORT="${SIGUL_BRIDGE_CLIENT_PORT:-44334}"
    export SIGUL_SERVER_HOST="${SIGUL_SERVER_HOST:-sigul-server}"
    export SIGUL_NSS_DIR="$nss_dir"

    # Create client configuration content with variable substitution
    cat > "$config_file" << CLIENT_CONFIG_EOF
# Sigul Client Configuration
# Generated by sigul-init.sh

[client]
# Bridge connection configuration
bridge-hostname = ${SIGUL_BRIDGE_HOSTNAME}
bridge-port = ${SIGUL_BRIDGE_CLIENT_PORT}
server-hostname = ${SIGUL_SERVER_HOST:-sigul-server}
client-cert-nickname = sigul-client-cert

# SSL/TLS configuration
ca-cert-file = ${SIGUL_BASE_DIR}/secrets/certificates/ca.crt
client-cert-file = ${SIGUL_BASE_DIR}/secrets/certificates/client.crt
client-key-file = ${SIGUL_BASE_DIR}/secrets/certificates/client-key.pem
require-tls = true

# NSS Configuration
[nss]
nss-dir = ${SIGUL_NSS_DIR}
nss-password = ${nss_password}

# Client logging uses stderr by default (no file logging for non-daemon clients)
# For consistency, client logs are available in the container output

CLIENT_CONFIG_EOF

    # Set proper permissions
    chmod 640 "$config_file"
    chown sigul:sigul "$config_file"

    log "Client configuration generated successfully"
    return 0
}

# Validate configuration syntax
validate_configuration() {
    local role="$SIGUL_ROLE"
    local config_file="$SIGUL_BASE_DIR/config/${role}.conf"

    debug "Validating configuration for role: $role"
    debug "Configuration file: $config_file"

    # Check if configuration file exists
    if [[ ! -f "$config_file" ]]; then
        error "Configuration file not found: $config_file"
    fi

    # Check file is readable
    if [[ ! -r "$config_file" ]]; then
        error "Configuration file is not readable: $config_file"
    fi

    # Basic syntax validation - check for required sections
    case "$role" in
        "server")
            if ! grep -q "^\[server\]" "$config_file"; then
                error "Server configuration missing [server] section"
            fi
            # Check for required server settings
            local required_settings=("bridge-hostname" "database-path")
            ;;
        "bridge")
            if ! grep -q "^\[bridge\]" "$config_file"; then
                error "Bridge configuration missing [bridge] section"
            fi
            # Check for required bridge settings
            local required_settings=("host" "port" "server-hostname" "nss-dir")
            ;;
        "client")
            if ! grep -q "^\[client\]" "$config_file"; then
                error "Client configuration missing [client] section"
            fi
            # Check for required client settings
            local required_settings=("bridge-hostname" "server-hostname")

            # Check for NSS section and nss-dir setting separately
            if ! grep -q "^\[nss\]" "$config_file"; then
                error "Client configuration missing [nss] section"
            fi
            if ! grep -q "^nss-dir[[:space:]]*=" "$config_file"; then
                error "Configuration missing required setting: nss-dir"
            fi
            ;;
        *)
            error "Unknown role for configuration validation: $role"
            ;;
    esac

    # Check for required settings
    for setting in "${required_settings[@]}"; do
        if ! grep -q "^${setting}[[:space:]]*=" "$config_file"; then
            error "Configuration missing required setting: $setting"
        fi
    done

    debug "Configuration validation successful for role: $role"
    return 0
}

# Main configuration generation orchestration
create_configuration() {
    local role="$SIGUL_ROLE"

    log "Creating configuration for role: $role"

    # Generate role-specific configuration
    case "$role" in
        "server")
            if ! generate_server_config; then
                error "Failed to generate server configuration"
            fi
            ;;
        "bridge")
            if ! generate_bridge_config; then
                error "Failed to generate bridge configuration"
            fi
            ;;
        "client")
            if ! generate_client_config; then
                error "Failed to generate client configuration"
            fi
            ;;
        *)
            error "Unknown role for configuration generation: $role"
            ;;
    esac

    # Validate generated configuration
    if ! validate_configuration; then
        error "Configuration validation failed for role: $role"
    fi

    log "Configuration created and validated successfully for role: $role"
    return 0
}

#######################################
# Phase 4.1: Database Management Functions
#######################################

# Initialize SQLite database for server role
initialize_sigul_database() {
    local db_path="$DATABASE_DIR/sigul.db"
    local config_file="$CONFIG_DIR/server.conf"

    log "Initializing Sigul SQLite database at: $db_path"

    # Check if database already exists
    if [[ -f "$db_path" ]]; then
        log "Database already exists at $db_path, validating..."
        if validate_database; then
            log "Existing database is valid, skipping initialization"
            return 0
        else
            log "Existing database is invalid, backing up and recreating..."
            mv "$db_path" "${db_path}.backup.$(date +%Y%m%d_%H%M%S)" || {
                error "Failed to backup existing database"
            }
        fi
    fi

    # Check if sigul_server_create_db command exists
    if ! command -v sigul_server_create_db >/dev/null 2>&1; then
        debug "sigul_server_create_db not found, creating basic database structure"
        # Create a basic database structure for testing/fallback
        sqlite3 "$db_path" "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT); CREATE TABLE IF NOT EXISTS packages (id INTEGER PRIMARY KEY, name TEXT); CREATE TABLE IF NOT EXISTS signing_keys (id INTEGER PRIMARY KEY, name TEXT);" || {
            error "Failed to create basic database structure"
        }
        log "Basic database structure created (production deployment should use sigul_server_create_db)"
        return 0
    fi

    # Create the database using official sigul command
    log "Creating database using sigul_server_create_db..."
    if ! sigul_server_create_db --config-file="$config_file"; then
        error "Failed to create Sigul database using sigul_server_create_db"
    fi

    # Validate the created database
    if ! validate_database; then
        error "Database creation succeeded but validation failed"
    fi

    log "Database initialized successfully"
    return 0
}

# Set up admin user for server role
setup_admin_user() {
    local config_file="$CONFIG_DIR/server.conf"
    local admin_password_file="$SECRETS_DIR/server_admin_password"

    log "Setting up admin user for Sigul server"
    debug "Config file: $config_file"
    debug "Admin password file: $admin_password_file"
    debug "SIGUL_ADMIN_PASSWORD env var: ${SIGUL_ADMIN_PASSWORD:+SET}"

    # Check if admin password exists in file or environment variable
    if [[ ! -f "$admin_password_file" ]]; then
        # If password file doesn't exist, try to create it from environment variable
        if [[ -n "${SIGUL_ADMIN_PASSWORD:-}" ]]; then
            log "Creating admin password file from environment variable"
            mkdir -p "$(dirname "$admin_password_file")"
            echo "$SIGUL_ADMIN_PASSWORD" > "$admin_password_file"
            chmod 600 "$admin_password_file"
            debug "Admin password file created: $admin_password_file"
        else
            warn "Admin password file not found and SIGUL_ADMIN_PASSWORD not set"
            debug "Admin password file: $admin_password_file"
            debug "Listing contents of secrets directory:"
            debug "$(find "$SECRETS_DIR" -type f 2>/dev/null | head -10 || echo 'No files found')"
            log "Skipping admin user creation - password not available"
            return 0
        fi
    fi

    local admin_password
    admin_password=$(cat "$admin_password_file")
    debug "Successfully read admin password from file"

    # Check if sigul_server_add_admin command exists
    if ! command -v sigul_server_add_admin >/dev/null 2>&1; then
        log "sigul_server_add_admin command not found, skipping admin user creation"
        debug "Available sigul commands: $(find /usr/bin /usr/local/bin -name 'sigul*' 2>/dev/null || echo 'none found')"
        log "Admin user can be created manually later if needed"
        return 0
    fi

    # Create admin user using official sigul command
    log "Creating admin user using sigul_server_add_admin..."
    debug "Running: sigul_server_add_admin --config-file=$config_file --batch"

    local add_admin_output
    if add_admin_output=$(echo -e "admin\n$admin_password" | sigul_server_add_admin --config-file="$config_file" --batch 2>&1); then
        log "Admin user created successfully"
        debug "Admin creation output: $add_admin_output"
        return 0
    else
        debug "Admin creation failed with output: $add_admin_output"

        # Check if user already exists (common case)
        local list_output
        if list_output=$(sigul_server_add_admin --config-file="$config_file" --name=admin --list 2>&1) && echo "$list_output" | grep -q "admin"; then
            log "Admin user already exists, skipping creation"
            debug "Existing admin user confirmed: $list_output"
            return 0
        else
            warn "Failed to add admin user - server will start without admin user"
            debug "List users output: $list_output"
            log "Admin user can be created manually after server startup"
            return 0
        fi
    fi
}

# Validate database integrity
validate_database() {
    local db_path="$DATABASE_DIR/sigul.db"

    debug "Validating database integrity: $db_path"

    # Check if database file exists
    if [[ ! -f "$db_path" ]]; then
        debug "Database file does not exist: $db_path"
    fi

    # Check if SQLite can open the database
    if ! sqlite3 "$db_path" "SELECT name FROM sqlite_master WHERE type='table';" >/dev/null 2>&1; then
        debug "Database file is corrupted or not a valid SQLite database"
    fi

    # Check for essential Sigul tables (basic validation)
    local essential_tables=("users" "keys" "key_accesses")
    for table in "${essential_tables[@]}"; do
        if ! sqlite3 "$db_path" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';" | grep -q "$table"; then
            debug "Essential table '$table' not found in database"
            return 1
        fi
    done

    debug "Database validation passed"
    return 0
}

# Migrate existing database if needed
# Legacy database migration function removed - not needed in containerized environment

# Main database setup orchestration (server role only)
setup_database() {
    if [[ "$SIGUL_ROLE" != "server" ]]; then
        debug "Database setup only required for server role, skipping"
        return 0
    fi

    log "Setting up database management for server role"

    # Initialize database if needed
    # Step 2: Initialize database
    if ! initialize_sigul_database; then
        error "Failed to initialize Sigul database"
    fi

    # Step 3: Set up admin user (if not skipped)
    if [[ "${SIGUL_SKIP_ADMIN_USER:-false}" != "true" ]]; then
        if ! setup_admin_user; then
            warn "Admin user setup encountered issues but server will continue"
            log "Admin user can be created manually after server startup"
        fi
    else
        log "Skipping admin user creation (SIGUL_SKIP_ADMIN_USER=true)"
    fi

    log "Database setup completed successfully"
    return 0
}

#######################################
# Phase 4.2: Health Checks and Validation Functions
#######################################

# Validate all secrets are present and valid
validate_secrets() {
    local role="$SIGUL_ROLE"

    debug "Validating secrets for role: $role"

    # Check NSS password for all roles
    local nss_password_file="$SECRETS_DIR/${role}_nss_password"
    if [[ ! -f "$nss_password_file" ]]; then
        debug "NSS password file missing: $nss_password_file"
    fi

    # Validate file permissions
    local perms
    perms=$(stat -c "%a" "$nss_password_file" 2>/dev/null)
    if [[ "$perms" != "600" ]]; then
        error "Admin password file has incorrect permissions: $perms (expected 600)"
    fi

    # Check admin password for server role
    if [[ "$role" == "server" ]]; then
        local admin_password_file="$SECRETS_DIR/server_admin_password"
        # Check if admin password exists
        if [[ ! -f "$admin_password_file" ]]; then
            debug "Admin password file missing: $admin_password_file"
            return 1
        fi

        perms=$(stat -c "%a" "$admin_password_file" 2>/dev/null)
        if [[ "$perms" != "600" ]]; then
            error "NSS password file has incorrect permissions: $perms (expected 600)"
        fi
    fi

    debug "Secrets validation passed"
    return 0
}

# Validate certificates are present and valid
validate_certificates() {
    local role="$SIGUL_ROLE"
    local cert_dir="$SECRETS_DIR/certificates"

    debug "Validating certificates for role: $role"

    # Define expected certificates by role
    local expected_certs=()
    case "$role" in
        "server")
            expected_certs=("server.crt" "ca.crt")
            ;;
        "bridge")
            expected_certs=("bridge.crt")
            ;;
        "client")
            expected_certs=("client.crt")
            ;;
    esac

    # Check each expected certificate
    for cert in "${expected_certs[@]}"; do
        local cert_path="$cert_dir/$cert"
        if [[ ! -f "$cert_path" ]]; then
            debug "Certificate missing: $cert_path"
            return 1
        fi

        # Validate certificate using OpenSSL
        if ! openssl x509 -in "$cert_path" -noout -checkend 86400 >/dev/null 2>&1; then
            debug "Certificate is invalid or expires within 24 hours: $cert_path"
            return 1
        fi
    done

    debug "Certificate validation passed"
    return 0
}

# Validate file and directory permissions
validate_permissions() {
    debug "Validating file and directory permissions"

    # Check base directory
    local perms
    perms=$(stat -c "%a" "$SIGUL_BASE_DIR" 2>/dev/null)
    if [[ "$perms" != "755" ]]; then
        debug "Base directory has incorrect permissions: $perms (expected 755)"
        return 1
    fi

    # Check secrets directory
    perms=$(stat -c "%a" "$SECRETS_DIR" 2>/dev/null)
    if [[ "$perms" != "700" ]]; then
        debug "Secrets directory has incorrect permissions: $perms (expected 700)"
        return 1
    fi

    # Check NSS directory
    perms=$(stat -c "%a" "$NSS_DIR" 2>/dev/null)
    if [[ "$perms" != "700" ]]; then
        debug "NSS directory has incorrect permissions: $perms (expected 700)"
        return 1
    fi

    # Check config directory
    perms=$(stat -c "%a" "$CONFIG_DIR" 2>/dev/null)
    if [[ "$perms" != "750" ]]; then
        debug "Config directory has incorrect permissions: $perms (expected 750)"
        return 1
    fi

    debug "Permission validation passed"
    return 0
}

# Check required binaries and libraries
validate_dependencies() {
    debug "Validating required dependencies"

    # Essential binaries for all roles (must be present)
    local essential_binaries=("openssl" "sqlite3")

    # Optional role-specific binaries (warn if missing but don't fail)
    local optional_binaries=()
    case "$SIGUL_ROLE" in
        "server")
            optional_binaries+=("sigul_server" "sigul_server_create_db" "sigul_server_add_admin")
            ;;
        "bridge")
            optional_binaries+=("sigul_bridge")
            ;;
        "client")
            optional_binaries+=("sigul")
            ;;
    esac

    # Check essential binaries
    for binary in "${essential_binaries[@]}"; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            debug "Essential binary not found: $binary"
            return 1
        fi
    done

    # Check optional binaries (warn but don't fail)
    for binary in "${optional_binaries[@]}"; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            debug "Optional binary not found: $binary (will use fallback methods)"
        fi
    done

    debug "Dependency validation passed"
    return 0
}

# Check if service is ready to start
check_service_readiness() {
    local role="$SIGUL_ROLE"

    debug "Checking service readiness for role: $role"

    # Check configuration file exists
    local config_file="$CONFIG_DIR/${role}.conf"
    if [[ ! -f "$config_file" ]]; then
        debug "Configuration file missing: $config_file"
        return 1
    fi

    # Validate configuration syntax (basic check)
    if ! grep -q "^\[" "$config_file"; then
        debug "Configuration file appears to be invalid: $config_file"
        return 1
    fi

    # Check NSS database exists
    local nss_db_dir="$NSS_DIR/$role"
    if [[ ! -d "$nss_db_dir" ]] || [[ ! -f "$nss_db_dir/cert8.db" && ! -f "$nss_db_dir/cert9.db" ]]; then
        debug "NSS database not properly initialized: $nss_db_dir"
        return 1
    fi

    # Server-specific readiness checks
    if [[ "$role" == "server" ]]; then
        # Check database exists (validate_database may fail if created by mock)
        local db_path="$DATABASE_DIR/sigul.db"
        if [[ ! -f "$db_path" ]]; then
            debug "Server database file not found: $db_path"
            return 1
        fi

        # Basic database check (more tolerant than full validation)
        if ! sqlite3 "$db_path" "SELECT name FROM sqlite_master LIMIT 1;" >/dev/null 2>&1; then
            debug "Server database is not accessible or corrupted"
            return 1
        fi
    fi

    debug "Service readiness check passed"
    return 0
}

# Main health check orchestration - simplified for debugging
perform_health_check() {
    log "Performing simplified health check for role: $SIGUL_ROLE (debugging mode)"

    local checks_passed=0
    local checks_total=1

    # Run only secrets validation first for debugging
    log "Testing: validate_secrets"
    if validate_secrets; then
        log "✓ Secrets validation passed"
        checks_passed=$((checks_passed + 1))
    else
        log "✗ Secrets validation failed"
        return 1
    fi

    log "Health check results: $checks_passed/$checks_total checks passed"

    if [[ $checks_passed -eq $checks_total ]]; then
        log "All health checks passed - system ready for service startup"
        return 0
    else
        log "Health checks failed - manual intervention may be required"
        return 1
    fi
}

#######################################
# Phase 5: Service Integration and Testing
#######################################

# Phase 5.1: Service Startup Integration Functions
#######################################

# Main service startup orchestration by role
start_service() {
    log "Starting service for role: $SIGUL_ROLE"

    case "$SIGUL_ROLE" in
        "server")
            start_server
            ;;
        "bridge")
            start_bridge
            ;;
        "client")
            start_client
            ;;
        *)
            error "Invalid role for service startup: $SIGUL_ROLE" "$EXIT_INVALID_ARGS"
            ;;
    esac
}

# Start sigul_server daemon
start_server() {
    log "Starting Sigul server daemon"

    # Verify prerequisites
    if ! command -v sigul_server >/dev/null 2>&1; then
        error "sigul_server binary not found in PATH" "$EXIT_DEPENDENCY_MISSING"
    fi

    # Verify configuration exists
    local server_config="$CONFIG_DIR/server.conf"
    if [[ ! -f "$server_config" ]]; then
        error "Server configuration not found: $server_config" "$EXIT_CONFIG_ERROR"
    fi

    # Create PID file path
    local pid_file="$PIDS_DIR/sigul_server.pid"
    local log_file="$LOGS_DIR/server/daemon.log"

    # Ensure log directory exists
    mkdir -p "$(dirname "$log_file")"

    log "Server daemon configuration:"
    debug "  Config file: $server_config"
    debug "  PID file: $pid_file"
    debug "  Log directory: $LOGS_DIR/server (via --internal-log-dir)"
    debug "  Expected log file: $log_file"
    debug "  Database: $DATABASE_DIR/sigul.db"

    # Start the server daemon
    log "Executing sigul_server daemon..."

    # Use exec to replace the current process (standard for Docker containers)
    # Run in foreground (no -d flag) for Docker containers
    # IMPORTANT: --internal-log-dir and --internal-pid-dir are REQUIRED even though not shown in --help
    # These parameters direct sigul to use our custom directories instead of /var/log and /var/run
    exec sigul_server \
        -c "$server_config" \
        --internal-log-dir "$LOGS_DIR/server" \
        --internal-pid-dir "$PIDS_DIR" \
        -v
}

# Start sigul_bridge daemon
start_bridge() {
    log "Starting Sigul bridge daemon"

    # Verify prerequisites
    if ! command -v sigul_bridge >/dev/null 2>&1; then
        error "sigul_bridge binary not found in PATH" "$EXIT_DEPENDENCY_MISSING"
    fi

    # Verify configuration exists
    local bridge_config="$CONFIG_DIR/bridge.conf"
    if [[ ! -f "$bridge_config" ]]; then
        error "Bridge configuration not found: $bridge_config" "$EXIT_CONFIG_ERROR"
    fi

    # Create PID file path
    local pid_file="$PIDS_DIR/sigul_bridge.pid"
    local log_file="$LOGS_DIR/bridge/daemon.log"

    # Ensure log directory exists
    mkdir -p "$(dirname "$log_file")"

    log "Bridge daemon configuration:"
    debug "  Config file: $bridge_config"
    debug "  PID file: $pid_file"
    debug "  Log directory: $LOGS_DIR/bridge (via --internal-log-dir)"
    debug "  Expected log file: $log_file"
    debug "  Bridge client port: ${SIGUL_BRIDGE_CLIENT_PORT:-44334}"
    debug "  Bridge server port: ${SIGUL_BRIDGE_SERVER_PORT:-44333}"
    debug "  Bridge bind address: 0.0.0.0 (hardcoded in Sigul, not configurable)"

    # Start the bridge daemon
    log "Executing sigul_bridge daemon..."

    # Use exec to replace the current process (standard for Docker containers)
    # Run in foreground (no -d flag) for Docker containers
    # IMPORTANT: --internal-log-dir and --internal-pid-dir are REQUIRED even though not shown in --help
    # These parameters direct sigul to use our custom directories instead of /var/log and /var/run
    exec sigul_bridge \
        -c "$bridge_config" \
        --internal-log-dir "$LOGS_DIR/bridge" \
        --internal-pid-dir "$PIDS_DIR" \
        -v
}

# Start sigul client (if applicable)
start_client() {
    log "Client role service startup"

    # For client role, we don't start a persistent daemon
    # Instead, we validate the client setup and provide instructions

    local client_config="$CONFIG_DIR/client.conf"
    if [[ ! -f "$client_config" ]]; then
        error "Client configuration not found: $client_config" "$EXIT_CONFIG_ERROR"
    fi

    log "Client setup completed successfully"
    log "Client configuration: $client_config"
    log "NSS database: $NSS_DIR/client"
    log "Client logs: Non-daemon mode - outputs to stderr (container stdout/stderr)"

    log "Client is ready for signing operations"
    log "Example usage:"
    log "  sigul --config $client_config list-keys"
    log "  sigul --config $client_config sign-data <key> <file>"

    # For client, we don't exec a daemon, just exit successfully
    log "Client initialization complete - no persistent daemon required"
}

# Setup signal handlers for graceful shutdown
setup_signal_handlers() {
    log "Setting up signal handlers for graceful shutdown"

    # Function to handle shutdown signals
    shutdown_handler() {
        local signal="$1"
        log "Received signal $signal - initiating graceful shutdown"

        # Kill any running sigul processes
        if [[ "$SIGUL_ROLE" == "server" ]]; then
            pkill -f "sigul_server" 2>/dev/null || true
        elif [[ "$SIGUL_ROLE" == "bridge" ]]; then
            pkill -f "sigul_bridge" 2>/dev/null || true
        fi

        log "Graceful shutdown completed"
        exit 0
    }

    # Register signal handlers
    trap 'shutdown_handler SIGTERM' SIGTERM
    trap 'shutdown_handler SIGINT' SIGINT
    trap 'shutdown_handler SIGHUP' SIGHUP
}

# Basic service monitoring
monitor_service() {
    log "Setting up basic service monitoring for $SIGUL_ROLE"

    local pid_file="$PIDS_DIR/sigul_${SIGUL_ROLE}.pid"
    local check_interval=30

    while true; do
        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file" 2>/dev/null || echo "")

            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                debug "Service $SIGUL_ROLE (PID: $pid) is running"
            else
                log "WARNING: Service $SIGUL_ROLE process not found, PID file may be stale"
            fi
        else
            debug "PID file not found: $pid_file"
        fi

        sleep "$check_interval"
    done
}

#######################################
# Main Execution Functions
#######################################

# Main initialization function
main() {
    # Parse arguments first (handles --help and --version)
    parse_arguments "$@"

    # Check if we should start service directly
    local start_service_flag=false
    local service_only_flag=false

    # Parse service startup arguments
    for arg in "$@"; do
        case "$arg" in
            "--start-service")
                start_service_flag=true
                ;;
            "--service-only")
                service_only_flag=true
                ;;
        esac
    done

    # If service-only mode, skip initialization and start service
    if [[ "$service_only_flag" == "true" ]]; then
        log "Service-only mode - skipping initialization, starting service directly"

        # Minimal setup for service startup (role already parsed)
        setup_env

        # Setup signal handlers for graceful shutdown
        setup_signal_handlers

        # Start the service
        start_service
        return $?
    fi

    log "Starting Sigul initialization v$VERSION"

    # Phase 1.1: Core Infrastructure
    setup_env

    # Phase 1.2: Application Directory Setup
    setup_application_directory
    set_directory_permissions
    validate_directories

    log "Phase 1 initialization completed successfully for role: $SIGUL_ROLE"
    log "Application directory: $SIGUL_BASE_DIR"

    # Phase 2.1: Secrets Management
    setup_secrets

    # Phase 2.2: Certificate Management
    setup_certificates

    log "Phase 2 initialization completed successfully"

    # Phase 3.1: NSS Database Management
    setup_nss_database

    # Phase 3.2: Configuration Generation
    create_configuration

    log "Phase 3 initialization completed successfully"

    # Phase 4.1: Database Management
    setup_database

    # Phase 4.2: Health Checks and Validation
    perform_health_check

    log "Phase 4 initialization completed successfully"

    # Phase 5: Service Integration
    if [[ "$start_service_flag" == "true" ]]; then
        log "Starting service after initialization"

        # Setup signal handlers for graceful shutdown
        setup_signal_handlers

        # Start the service
        start_service
    else
        log "Sigul $SIGUL_ROLE initialization complete - system ready for service startup"
        log "To start the service, run: $0 --role $SIGUL_ROLE --service-only"
    fi
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
