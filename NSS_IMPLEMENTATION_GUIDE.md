<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# NSS-Based Sigul Implementation Guide

## Overview

This guide documents the NSS-based PKI architecture implementation for Sigul, which replaces the previous OpenSSL-based standalone CA approach with Sigul's required bridge-centric PKI model.

## What Changed

### Previous Architecture (Broken)

- **External standalone CA**: Generated certificates outside of Sigul components
- **File-based certificates**: Used PEM files for TLS configuration
- **No CA inheritance**: Server couldn't manage client certificates
- **Communication failures**: Components couldn't validate each other's certificates

### New Architecture (Working)

- **Bridge-as-CA**: Bridge component acts as the Certificate Authority
- **NSS databases**: All certificates stored in component-specific NSS databases
- **CA inheritance**: Server inherits CA private key from bridge for client management
- **Proper certificate chain**: All certificates signed by bridge's CA

## Architecture Components

### Bridge Component (Certificate Authority)

- **Role**: Primary CA and communication gateway
- **NSS Database**: `/var/sigul/nss/bridge/`
- **Certificates**:
  - `sigul-ca` - Self-signed CA certificate (trust: `CT,,`)
  - `sigul-bridge-cert` - Bridge service certificate (trust: `u,,`)
- **Exports**: CA certificate and private key to `/var/sigul/ca-export/`

### Server Component (Signing Vault)

- **Role**: Secure signing operations + client certificate management
- **NSS Database**: `/var/sigul/nss/server/`
- **Certificates**:
  - `sigul-ca` - Inherited CA certificate and private key (trust: `CT,,`)
  - `sigul-server-cert` - Server service certificate (trust: `u,,`)
- **Imports**: CA materials from `/var/sigul/ca-import/`

### Client Component

- **Role**: Request signing operations
- **NSS Database**: `/var/sigul/nss/client/`
- **Certificates**:
  - `sigul-ca` - CA certificate public only (trust: `CT,,`)
  - `sigul-client-cert` - Client certificate (trust: `u,,`)

## Certificate Flow

```
1. Bridge creates self-signed CA certificate + private key
2. Bridge creates its own service certificate (signed by its CA)
3. Bridge exports CA cert + private key → Server imports both
4. Server creates server certificate (signed by bridge's CA)
5. For each client:
   a. Client creates certificate request
   b. Server signs client certificate (using inherited CA private key)
   c. Client imports signed certificate + CA certificate (public only)
```

## Configuration Changes

### Bridge Configuration (`/var/sigul/config/bridge.conf`)

```ini
[bridge]
client-listen-port = 44334
server-listen-port = 44333
server-hostname = sigul-server
max-file-payload-size = 2097152

[nss]
nss-dir = /var/sigul/nss/bridge
nss-password-file = /var/sigul/secrets/nss-password
bridge-cert-nickname = sigul-bridge-cert
ca-cert-nickname = sigul-ca
require-tls = true
```

### Server Configuration (`/var/sigul/config/server.conf`)

```ini
[server]
bridge-hostname = sigul-bridge
bridge-port = 44333
max-file-payload-size = 2097152

[database]
database-path = /var/sigul/database/sigul.db

[nss]
nss-dir = /var/sigul/nss/server
nss-password-file = /var/sigul/secrets/nss-password
server-cert-nickname = sigul-server-cert
ca-cert-nickname = sigul-ca
require-tls = true
```

### Client Configuration (`/var/sigul/config/client.conf`)

```ini
[client]
bridge-hostname = sigul-bridge
bridge-port = 44334
server-hostname = sigul-server
user-name = admin

[nss]
nss-dir = /var/sigul/nss/client
nss-password-file = /var/sigul/secrets/nss-password
client-cert-nickname = sigul-client-cert
ca-cert-nickname = sigul-ca
require-tls = true
```

## Docker Compose Changes

### Service Dependencies

```yaml
services:
  sigul-server:
    depends_on:
      sigul-bridge:
        condition: service_healthy
    volumes:
      - sigul_server_data:/var/sigul
      - sigul_ca_sharing:/var/sigul/ca-import:ro

  sigul-bridge:
    healthcheck:
      test: ["CMD-SHELL", "certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    volumes:
      - sigul_bridge_data:/var/sigul
      - sigul_ca_sharing:/var/sigul/ca-export

volumes:
  sigul_ca_sharing:
    driver: local
```

## New Scripts

### NSS Certificate Setup Scripts

- `scripts/setup-bridge-ca.sh` - Bridge CA creation and export
- `scripts/setup-server-certs.sh` - Server certificate setup with CA inheritance
- `scripts/setup-client-certs.sh` - Client certificate setup

### Validation and Testing

- `scripts/validate-nss-certificates.sh` - Certificate validation across components
- `scripts/run-integration-test.sh` - End-to-end integration testing

## Deployment Guide

### Step 1: Build Updated Images

```bash
docker compose -f docker-compose.sigul.yml build
```

### Step 2: Start Services in Order

```bash
# Start bridge first (creates CA)
docker compose -f docker-compose.sigul.yml up -d sigul-bridge

# Wait for bridge health check
docker compose -f docker-compose.sigul.yml ps sigul-bridge

# Start server (inherits CA)
docker compose -f docker-compose.sigul.yml up -d sigul-server

# Start client for testing
docker compose -f docker-compose.sigul.yml up -d sigul-client-test
```

### Step 3: Validate Setup

```bash
# Run comprehensive validation
./scripts/validate-nss-certificates.sh all

# Run integration test
./scripts/run-integration-test.sh
```

## Troubleshooting

### Common Issues

#### Bridge CA Not Created

**Symptoms**: Server can't start, health check fails
**Solution**:

```bash
# Check bridge logs
docker logs sigul-bridge

# Verify CA creation
docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L
```

#### Server CA Import Failed

**Symptoms**: Server certificates invalid, can't inherit CA
**Solution**:

```bash
# Check CA export files
docker exec sigul-bridge ls -la /var/sigul/ca-export/

# Verify shared volume
docker volume inspect sigul-sign-docker_sigul_ca_sharing
```

#### Certificate Chain Validation Failed

**Symptoms**: TLS handshake failures, certificate errors
**Solution**:

```bash
# Validate individual component certificates
./scripts/validate-nss-certificates.sh bridge
./scripts/validate-nss-certificates.sh server
./scripts/validate-nss-certificates.sh client

# Check certificate consistency
./scripts/validate-nss-certificates.sh all
```

### Debug Commands

#### View NSS Database Contents

```bash
# List all certificates in bridge database
docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L

# Show CA certificate details
docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca

# Verify certificate trust settings
docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca | grep Trust
```

#### Test Certificate Validation

```bash
# Validate certificate chain
docker exec sigul-server sh -c 'cat /var/sigul/secrets/nss-password | certutil -d sql:/var/sigul/nss/server -V -n sigul-server-cert -u S -f /dev/stdin'
```

#### Check Service Communication

```bash
# Test bridge port accessibility
docker exec sigul-client-test nc -z sigul-bridge 44334

# Test bridge-server communication
docker exec sigul-server nc -z sigul-bridge 44333
```

## File Structure

### NSS Databases

```
/var/sigul/nss/
├── bridge/
│   ├── cert9.db
│   ├── key4.db
│   └── pkcs11.txt
├── server/
│   ├── cert9.db
│   ├── key4.db
│   └── pkcs11.txt
└── client/
    ├── cert9.db
    ├── key4.db
    └── pkcs11.txt
```

### Configuration Files

```
/var/sigul/config/
├── bridge.conf
├── server.conf
└── client.conf
```

### Secrets

```
/var/sigul/secrets/
├── nss-password
├── bridge_nss_password
├── server_nss_password
├── server_admin_password
└── client_nss_password
```

### CA Sharing

```
/var/sigul/ca-export/    # Bridge exports
├── bridge-ca.p12       # CA cert + private key
├── bridge-ca.pem       # CA cert public only
└── ca-export-timestamp

/var/sigul/ca-import/    # Server/Client imports
├── bridge-ca.p12 -> ../ca-export/bridge-ca.p12
└── bridge-ca.pem -> ../ca-export/bridge-ca.pem
```

## Testing

### Unit Tests

```bash
# Test individual components
./scripts/validate-nss-certificates.sh bridge
./scripts/validate-nss-certificates.sh server
./scripts/validate-nss-certificates.sh client
```

### Integration Tests

```bash
# Full integration test
./scripts/run-integration-test.sh

# Integration test with cleanup
./scripts/run-integration-test.sh --cleanup

# Debug mode integration test
./scripts/run-integration-test.sh --debug
```

### Manual Testing

```bash
# Connect to debug container
docker compose -f docker-compose.sigul.yml run --rm debug-helper

# Test network connectivity
nc -z sigul-bridge 44334

# Examine certificates
openssl x509 -in /debug/bridge-data/secrets/certificates/ca.crt -text -noout
```

## Security Considerations

### NSS Database Security

- All NSS databases have `700` permissions
- NSS password file has `600` permissions
- CA private key export file (`bridge-ca.p12`) has `600` permissions

### Certificate Validity

- CA certificates valid for 120 months (10 years)
- Service certificates valid for 120 months (10 years)
- Client certificates valid for 365 days (1 year)

### Trust Settings

- CA certificates: `CT,,` (trusted for issuing certs and CRLs)
- Service certificates: `u,,` (user certificates)
- Client certificates: `u,,` (user certificates)

## Migration from OpenSSL

### Backup Old Setup

```bash
# Backup existing volumes
docker volume create sigul_backup_$(date +%Y%m%d)
# ... backup process
```

### Clean Migration

```bash
# Stop all services
docker compose -f docker-compose.sigul.yml down -v

# Remove old volumes
docker volume prune

# Start with new NSS-based setup
docker compose -f docker-compose.sigul.yml up -d
```

## Performance Considerations

### NSS Database Performance

- NSS databases are optimized for certificate operations
- Use SQL-format databases (`sql:` prefix) for better performance
- Regular database integrity checks recommended

### Certificate Caching

- NSS automatically caches certificates for performance
- Consider certificate renewal strategies for long-running services

## Monitoring

### Health Checks

```bash
# Bridge health check
certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca >/dev/null 2>&1

# Server health check
certutil -d sql:/var/sigul/nss/server -L -n sigul-server-cert >/dev/null 2>&1

# Client health check
certutil -d sql:/var/sigul/nss/client -L -n sigul-client-cert >/dev/null 2>&1
```

### Certificate Expiration Monitoring

```bash
# Check certificate expiration
certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca | grep "Not After"
```

## References

- [NSS Tools Documentation](https://developer.mozilla.org/en-US/docs/Mozilla/Projects/NSS/tools)
- [Sigul Documentation](https://pagure.io/sigul)
- [PKI Best Practices](https://www.rfc-editor.org/rfc/rfc4158.html)

---

*Document Version: 1.0*
*Created: $(date -Iseconds)*
*Status: Implementation Complete*
