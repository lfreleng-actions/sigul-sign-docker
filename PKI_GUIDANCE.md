<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul PKI Architecture and Implementation Guidance

## Executive Summary

This document provides comprehensive guidance on the correct PKI architecture for Sigul deployment, based on analysis of official documentation and common deployment pitfalls. Our current standalone CA approach is incompatible with Sigul's designed architecture, requiring significant refactoring.

## Key Findings from Documentation Analysis

### What We Discovered

1. **Sigul has a specific PKI topology requirement** that differs from traditional CA hierarchies
2. **The bridge component acts as the Certificate Authority**, not an external standalone CA
3. **The server inherits CA private key capabilities** from the bridge for client certificate management
4. **Official documentation is poorly structured** with contradictory guidance that led to our incorrect implementation

### Why Our Current Approach Failed

Our standalone external CA approach fails because:

- Sigul expects the bridge to have CA certificate generation capabilities
- The server needs CA private key access for user/client certificate lifecycle management
- The protocol design assumes specific certificate relationships that external CAs don't provide
- Certificate validation logic is hardcoded for the bridge-as-CA topology

## Correct Sigul PKI Architecture

### Component Roles and Responsibilities

#### Bridge (Certificate Authority)

- **Role**: Primary CA and gateway controller
- **Certificate Requirements**:
  - Self-signed CA certificate OR imports external CA cert + private key
  - Bridge service certificate signed by its own CA
- **Key Materials**:
  - CA private key (for issuing server/client certificates)
  - Bridge private key (for TLS communications)
- **NSS Database Contents**:
  - CA certificate (marked as trusted CA: `CT,,`)
  - CA private key
  - Bridge certificate (marked as user cert: `u,,`)
  - Bridge private key

#### Server (Signing Vault)

- **Role**: Secure signing operations + client certificate management
- **Certificate Requirements**:
  - Server certificate signed by bridge's CA
  - Copy of bridge's CA certificate AND private key
- **Key Materials**:
  - CA private key (inherited from bridge - for client cert operations)
  - Server private key (for TLS communications)
- **NSS Database Contents**:
  - CA certificate (marked as trusted CA: `CT,,`)
  - CA private key (copied from bridge)
  - Server certificate (marked as user cert: `u,,`)
  - Server private key

#### Client

- **Role**: Request signing operations
- **Certificate Requirements**:
  - Client certificate signed by bridge's CA
  - Copy of bridge's CA certificate (public only)
- **Key Materials**:
  - Client private key (for TLS communications)
- **NSS Database Contents**:
  - CA certificate (marked as trusted CA: `CT,,`)
  - Client certificate (marked as user cert: `u,,`)
  - Client private key

### Certificate Issuance Flow

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

## Gap Analysis: Current vs Required Architecture

### Current Implementation Issues

#### ❌ Incorrect CA Topology

- **Current**: Standalone external CA issues all certificates
- **Required**: Bridge acts as CA, server inherits CA capabilities
- **Impact**: Communication failures between all components

#### ❌ Wrong Certificate Chain Structure

- **Current**: All certificates directly signed by external CA
- **Required**: Bridge CA → Bridge cert, Server cert, Client certs
- **Impact**: Certificate validation failures

#### ❌ Missing CA Private Key Distribution

- **Current**: Only CA has private key, components only have public certs
- **Required**: Server needs CA private key for client certificate management
- **Impact**: Cannot manage client certificates dynamically

#### ❌ Incorrect NSS Database Setup

- **Current**: Each component has isolated certificate store
- **Required**: Coordinated distribution of CA materials between bridge/server
- **Impact**: TLS handshake failures

### Required Changes Summary

| Component | Current State | Required Changes | Impact Level |
|-----------|---------------|------------------|--------------|
| Bridge | External cert import | Create self-signed CA, own service cert | **HIGH** |
| Server | External cert import | Import bridge CA + private key, create server cert | **HIGH** |
| Client | External cert import | Import bridge CA (public), create client cert request | **MEDIUM** |
| Scripts | External CA generation | Bridge-centric certificate management | **HIGH** |

## Refactoring Implementation Plan

### Phase 1: Bridge Reconfiguration

#### 1.1 Bridge CA Setup Script

**File**: `scripts/setup-bridge-ca.sh`

**Actions Required**:

- Remove external CA certificate imports
- Implement bridge self-signed CA generation:

  ```bash
  certutil -d $bridge_dir -S -n sigul-ca -s 'CN=Sigul CA' -t CT,, -x -v 120
  ```

- Generate bridge service certificate:

  ```bash
  certutil -d $bridge_dir -S -n sigul-bridge-cert \
    -s 'CN=BRIDGE_HOSTNAME' -c sigul-ca -t u,, -v 120
  ```

- Export CA certificate and private key for server distribution

#### 1.2 Bridge Configuration Updates

**File**: `config/bridge.conf`

**Actions Required**:

- Update `bridge-cert-nickname` to match new certificate name
- Verify NSS database paths
- Ensure proper certificate trust settings

### Phase 2: Server Reconfiguration

#### 2.1 Server Certificate Setup Script

**File**: `scripts/setup-server-certs.sh`

**Actions Required**:

- Import bridge CA certificate and private key:

  ```bash
  pk12util -d $bridge_dir -o ca.p12 -n sigul-ca
  pk12util -d $server_dir -i ca.p12
  certutil -d $server_dir -M -n sigul-ca -t CT,,
  ```

- Generate server certificate signed by bridge CA:

  ```bash
  certutil -d $server_dir -S -n sigul-server-cert \
    -s 'CN=SERVER_HOSTNAME' -c sigul-ca -t u,, -v 120
  ```

#### 2.2 Server Configuration Updates

**File**: `config/server.conf`

**Actions Required**:

- Update `server-cert-nickname` to match new certificate
- Verify bridge hostname matches certificate CN
- Ensure NSS database configuration alignment

### Phase 3: Client Reconfiguration

#### 3.1 Client Certificate Setup Script

**File**: `scripts/setup-client-certs.sh`

**Actions Required**:

- Import bridge CA certificate (public only):

  ```bash
  certutil -d $bridge_dir -L -n sigul-ca -a > ca.pem
  certutil -d $client_dir -A -n sigul-ca -t CT,, -a -i ca.pem
  ```

- Generate client certificate signed by bridge CA:

  ```bash
  certutil -d $client_dir -S -n sigul-client-cert \
    -s 'CN=CLIENT_USERNAME' -c sigul-ca -t u,, -v 120
  ```

#### 3.2 Client Configuration Updates

**File**: `config/client.conf`

**Actions Required**:

- Update certificate nicknames
- Verify bridge/server hostnames match certificate CNs
- Ensure user-name matches certificate subject

### Phase 4: Docker and Deployment Changes

#### 4.1 Dockerfile Modifications

**Files**: `bridge/Dockerfile`, `server/Dockerfile`, `client/Dockerfile`

**Actions Required**:

- Update certificate generation sequences in entrypoint scripts
- Modify volume mounts for certificate sharing between bridge/server
- Add dependency management (bridge must complete before server starts)

#### 4.2 Docker Compose Orchestration

**File**: `docker-compose.yml`

**Actions Required**:

- Add service dependency: `server depends_on: bridge`
- Implement shared volume for CA certificate distribution
- Add initialization containers for certificate setup coordination
- Update network configuration for proper hostname resolution

#### 4.3 Environment Variables

**File**: `.env` and related configuration

**Actions Required**:

- Remove external CA configuration variables
- Add bridge/server/client hostname variables
- Update certificate nickname environment variables
- Add NSS database password management

### Phase 5: Testing and Validation

#### 5.1 Certificate Validation Scripts

**File**: `scripts/validate-pki.sh`

**Actions Required**:

- Certificate chain validation tests
- NSS database integrity checks
- TLS handshake verification between components
- Signing operation end-to-end tests

#### 5.2 Integration Testing

**Actions Required**:

- Component startup sequence validation
- Certificate distribution verification
- Communication pathway testing
- Error handling and rollback procedures

## Implementation Priorities

### Critical Path Items (Must Fix First)

1. **Bridge CA generation** - Foundation for entire PKI
2. **Server CA inheritance** - Required for client management
3. **Certificate nickname alignment** - Configuration compatibility
4. **Docker service dependencies** - Proper startup sequence

### Secondary Items (Can Be Implemented Incrementally)

1. Client certificate automation
2. Certificate renewal procedures
3. Advanced security hardening
4. Monitoring and alerting

## Security Considerations

### Enhanced Security Measures

- Implement certificate pinning where possible
- Use hardware security modules (HSM) for CA private key protection in production
- Establish certificate rotation procedures
- Implement proper key escrow for disaster recovery

### Operational Security

- Separate development/staging/production certificate hierarchies
- Implement proper certificate lifecycle management
- Establish monitoring for certificate expiration
- Document incident response procedures for certificate compromise

## Rollback and Migration Strategy

### Migration Approach

1. **Parallel Environment**: Build new PKI alongside existing (broken) setup
2. **Incremental Testing**: Validate each component before integration
3. **Data Preservation**: Maintain GPG keys and user data during certificate migration
4. **Rollback Readiness**: Maintain ability to revert to previous configuration

### Risk Mitigation

- Complete backup of existing NSS databases before migration
- Document all configuration changes for audit trail
- Implement automated testing to catch regressions
- Establish communication plan for stakeholders during migration

## Next Steps

1. **Review and Approve**: Validate this analysis with team
2. **Environment Preparation**: Set up isolated development environment
3. **Script Development**: Implement Phase 1 bridge reconfiguration
4. **Iterative Testing**: Validate each phase before proceeding
5. **Production Migration**: Execute in controlled maintenance window

## Conclusion

The root cause of our Sigul communication failures is architectural mismatch between our standalone CA approach and Sigul's bridge-centric PKI requirements. This refactoring plan addresses all identified gaps and provides a roadmap for successful deployment. The effort is substantial but necessary for a functional Sigul implementation.

---

*Document Version: 1.0*
*Created: [Current Date]*
*Status: Planning Phase*
