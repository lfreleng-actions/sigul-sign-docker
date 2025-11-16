<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Container Stack - Production Alignment Validation Checklist

**Purpose:** Comprehensive validation checklist for production-aligned Sigul deployment  
**Version:** 1.0  
**Date:** 2025-11-16

---

## Pre-Deployment Validation

### Prerequisites

- [ ] Docker 20.10+ installed and running
- [ ] Docker Compose V2 installed (`docker compose version`)
- [ ] Minimum 2GB RAM available
- [ ] Minimum 10GB disk space available
- [ ] Ports 44333 and 44334 available
- [ ] Git installed for repository cloning
- [ ] `bash` 4.0+ available
- [ ] `openssl` installed for secret generation

**Validation Command:**
```bash
docker --version && docker compose version && docker info
```

---

## Deployment Validation

### Environment Setup

- [ ] Repository cloned successfully
- [ ] NSS password generated: `export NSS_PASSWORD=$(openssl rand -base64 32)`
- [ ] NSS password backed up securely
- [ ] Environment file created: `.env` with proper permissions (600)
- [ ] Custom FQDNs configured (if not using defaults)

**Validation Command:**
```bash
test -f .env && test $(stat -f %A .env 2>/dev/null || stat -c %a .env) = "600"
```

### Configuration Generation

- [ ] Bridge configuration generated: `/etc/sigul/bridge.conf`
- [ ] Server configuration generated: `/etc/sigul/server.conf`
- [ ] Configuration templates processed correctly
- [ ] NSS password inserted in configurations
- [ ] FQDNs match certificate requirements

**Validation Command:**
```bash
./scripts/validate-configs.sh bridge
./scripts/validate-configs.sh server
```

---

## Infrastructure Validation

### Directory Structure

- [ ] `/etc/sigul/` exists in containers
- [ ] `/etc/pki/sigul/` exists in containers
- [ ] `/var/lib/sigul/` exists in containers
- [ ] `/var/log/sigul/` exists in containers
- [ ] Directory permissions correct (sigul:sigul ownership)
- [ ] FHS-compliant paths verified

**Validation Command:**
```bash
docker exec sigul-bridge test -d /etc/sigul && echo "OK"
docker exec sigul-server test -d /etc/pki/sigul && echo "OK"
docker exec sigul-server test -d /var/lib/sigul && echo "OK"
```

### Volume Configuration

- [ ] `sigul_bridge_nss` volume created
- [ ] `sigul_bridge_logs` volume created
- [ ] `sigul_server_nss` volume created
- [ ] `sigul_server_data` volume created
- [ ] `sigul_server_logs` volume created
- [ ] Volume labels configured correctly
- [ ] Backup priorities set (CRITICAL, HIGH, MEDIUM)

**Validation Command:**
```bash
docker volume ls | grep sigul
./scripts/validate-phase5-volume-persistence.sh
```

### File Permissions

- [ ] NSS database permissions: 700 (owner only)
- [ ] Configuration file permissions: 600 (owner only)
- [ ] Log directory permissions: 755 (owner write, all read)
- [ ] Data directory permissions: 700 (owner only)
- [ ] Files owned by sigul:sigul user

**Validation Command:**
```bash
docker exec sigul-bridge ls -ld /etc/pki/sigul
docker exec sigul-server ls -ld /var/lib/sigul
```

---

## Certificate Validation

### NSS Database Format

- [ ] Bridge uses modern format: `cert9.db` exists
- [ ] Server uses modern format: `cert9.db` exists
- [ ] No legacy `cert8.db` files present
- [ ] NSS database is SQLite format
- [ ] `key4.db` exists (modern private key database)
- [ ] `pkcs11.txt` exists

**Validation Command:**
```bash
docker exec sigul-bridge file /etc/pki/sigul/cert9.db | grep SQLite
docker exec sigul-server file /etc/pki/sigul/cert9.db | grep SQLite
./scripts/validate-nss.sh
```

### Certificate Presence

- [ ] CA certificate present in both containers
- [ ] Bridge certificate: `sigul-bridge.example.org` present
- [ ] Server certificate: `sigul-server.example.org` present
- [ ] CA trust flags: `CT,,` (Certificate Authority)
- [ ] Component trust flags: `u,u,u` (user certificates)

**Validation Command:**
```bash
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul
./scripts/validate-certificates.sh
```

### Certificate Details

- [ ] Bridge certificate CN matches FQDN: `sigul-bridge.example.org`
- [ ] Server certificate CN matches FQDN: `sigul-server.example.org`
- [ ] SANs include FQDNs
- [ ] Extended Key Usage includes: serverAuth, clientAuth
- [ ] Certificates valid (not expired)
- [ ] Certificates valid for 10 years from creation

**Validation Command:**
```bash
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server
```

---

## Network Validation

### Network Configuration

- [ ] Docker network `sigul-network` created
- [ ] Network subnet: `172.20.0.0/16`
- [ ] Network gateway: `172.20.0.1`
- [ ] Bridge static IP: `172.20.0.2`
- [ ] Server static IP: `172.20.0.3`
- [ ] Network aliases configured

**Validation Command:**
```bash
docker network inspect sigul-network
./scripts/validate-phase6-network-dns.sh
```

### DNS Resolution

- [ ] Bridge hostname resolves: `sigul-bridge.example.org`
- [ ] Server hostname resolves: `sigul-server.example.org`
- [ ] DNS resolution working from server to bridge
- [ ] DNS resolution working from bridge to server
- [ ] FQDNs resolve to correct static IPs

**Validation Command:**
```bash
./scripts/verify-dns.sh bridge
./scripts/verify-dns.sh server
```

### Port Configuration

- [ ] Bridge listening on `0.0.0.0:44333` (server port)
- [ ] Bridge listening on `0.0.0.0:44334` (client port)
- [ ] Ports exposed to host: `44333:44333`, `44334:44334`
- [ ] Server has NO listening ports (connects outbound only)
- [ ] Port bindings verified

**Validation Command:**
```bash
docker exec sigul-bridge netstat -tlnp | grep -E '44333|44334'
./scripts/verify-network.sh
```

### Connectivity

- [ ] Server can connect to bridge on port 44333
- [ ] Connection established (not just port open)
- [ ] TLS handshake successful
- [ ] Certificate validation successful during connection
- [ ] No connection refused errors

**Validation Command:**
```bash
docker exec sigul-server nc -zv sigul-bridge.example.org 44333
docker exec sigul-server netstat -tnp | grep 44333
```

---

## Service Validation

### Process Status

- [ ] Bridge process running: `sigul_bridge`
- [ ] Server process running: `sigul_server`
- [ ] Processes owned by sigul user
- [ ] No zombie processes
- [ ] Process arguments correct (no wrapper scripts)

**Validation Command:**
```bash
docker exec sigul-bridge pgrep -f sigul_bridge
docker exec sigul-server pgrep -f sigul_server
docker exec sigul-bridge ps aux | grep sigul_bridge
docker exec sigul-server ps aux | grep sigul_server
```

### Service Command

- [ ] Bridge uses direct invocation: `/usr/sbin/sigul_bridge -v`
- [ ] Server uses direct invocation: `/usr/sbin/sigul_server ...`
- [ ] No wrapper scripts in use
- [ ] Entrypoint scripts in `/usr/local/bin/`
- [ ] Entrypoints validate configuration before exec

**Validation Command:**
```bash
docker inspect sigul-bridge --format '{{.Config.Entrypoint}}'
docker inspect sigul-server --format '{{.Config.Entrypoint}}'
./scripts/validate-phase4-service-initialization.sh
```

### Health Checks

- [ ] Bridge health check passing
- [ ] Server health check passing
- [ ] Health check interval: 10s
- [ ] Health check timeout: 5s
- [ ] Health check retries: 3
- [ ] Start period: 30s

**Validation Command:**
```bash
docker inspect sigul-bridge --format '{{.State.Health.Status}}'
docker inspect sigul-server --format '{{.State.Health.Status}}'
```

### Database

- [ ] Server database exists: `/var/lib/sigul/server/sigul.db`
- [ ] Database is SQLite format
- [ ] Database integrity check passes
- [ ] Database permissions correct (600)
- [ ] Tables created successfully

**Validation Command:**
```bash
docker exec sigul-server test -f /var/lib/sigul/server/sigul.db
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "PRAGMA integrity_check;"
```

### GnuPG

- [ ] GnuPG home exists: `/var/lib/sigul/server/gnupg`
- [ ] GnuPG home permissions: 700
- [ ] GPG configuration present
- [ ] GPG agent socket accessible
- [ ] GPG version 2.x

**Validation Command:**
```bash
docker exec sigul-server test -d /var/lib/sigul/server/gnupg
docker exec sigul-server gpg --version | head -n1
```

### Logs

- [ ] Bridge logs being created: `/var/log/sigul/bridge.log`
- [ ] Server logs being created: `/var/log/sigul/server.log`
- [ ] No error messages in logs
- [ ] Log rotation configured
- [ ] Logs readable by sigul user

**Validation Command:**
```bash
docker exec sigul-bridge ls -la /var/log/sigul/
docker exec sigul-server ls -la /var/log/sigul/
docker-compose -f docker-compose.sigul.yml logs --tail=50 | grep -i error
```

---

## Functional Validation

### Integration Tests

- [ ] All integration tests pass
- [ ] Infrastructure tests pass
- [ ] Certificate tests pass
- [ ] Network tests pass
- [ ] Service tests pass

**Validation Command:**
```bash
./scripts/run-integration-tests.sh
```

### Functional Tests

- [ ] Service processes responding
- [ ] Database queries working
- [ ] Certificate validation working
- [ ] Network connectivity verified
- [ ] Configuration parsing successful

**Validation Command:**
```bash
./scripts/test-signing-operations.sh
```

### Performance Tests

- [ ] Network connectivity performance acceptable
- [ ] Certificate validation performance acceptable
- [ ] Database query performance acceptable
- [ ] Resource usage within limits
- [ ] No performance regressions

**Validation Command:**
```bash
./scripts/test-performance.sh
```

---

## Backup Validation

### Backup Script

- [ ] Backup script exists and is executable
- [ ] Backup script runs without errors
- [ ] Backup files created successfully
- [ ] Backup manifest generated
- [ ] Backup files compressed (tar.gz)

**Validation Command:**
```bash
./scripts/backup-volumes.sh
ls -lh backups/
```

### Backup Contents

- [ ] Critical volumes backed up: `sigul_server_data`
- [ ] High priority volumes backed up: NSS databases
- [ ] Backup files contain expected data
- [ ] Backup file permissions secure (600)
- [ ] Backup manifest accurate

**Validation Command:**
```bash
tar -tzf backups/sigul_server_data-*.tar.gz | head -20
```

### Restore Capability

- [ ] Restore script exists and is executable
- [ ] Restore script help working: `--help`
- [ ] Test restore procedure successful
- [ ] Restored data matches original
- [ ] Services work after restore

**Validation Command:**
```bash
./scripts/restore-volumes.sh --help
# Test restore in non-production environment
```

---

## Documentation Validation

### Required Documentation

- [ ] `README.md` updated with production alignment info
- [ ] `DEPLOYMENT_PRODUCTION_ALIGNED.md` complete
- [ ] `OPERATIONS_GUIDE.md` complete
- [ ] `VALIDATION_CHECKLIST.md` complete (this file)
- [ ] `NETWORK_ARCHITECTURE.md` complete
- [ ] All `PHASE*_COMPLETE.md` files present

**Validation Command:**
```bash
ls -1 *.md | grep -E 'README|DEPLOYMENT|OPERATIONS|VALIDATION|NETWORK|PHASE'
```

### Documentation Accuracy

- [ ] Network diagrams show correct connection pattern (server→bridge)
- [ ] Configuration examples accurate
- [ ] Command examples tested and working
- [ ] Troubleshooting steps accurate
- [ ] References and links valid

**Validation Command:**
```bash
grep -r "Server CONNECTS TO bridge" *.md
```

---

## Security Validation

### Secrets Management

- [ ] NSS password stored securely (not in git)
- [ ] `.env` file has proper permissions (600)
- [ ] No secrets in configuration files committed to git
- [ ] Backup files secured with proper permissions
- [ ] Password vault backup confirmed

**Validation Command:**
```bash
test $(stat -f %A .env 2>/dev/null || stat -c %a .env) = "600"
git status | grep -v .env
```

### Network Security

- [ ] Bridge binds to `0.0.0.0` (documented limitation)
- [ ] Firewall rules considered for production
- [ ] Network policies planned for production
- [ ] TLS 1.2+ enforced (no legacy protocols)
- [ ] Certificate validation enabled

**Validation Command:**
```bash
docker exec sigul-bridge grep nss-min-tls /etc/sigul/bridge.conf
docker exec sigul-server grep nss-min-tls /etc/sigul/server.conf
```

### File Permissions

- [ ] Sensitive files (NSS DB, configs) have restrictive permissions
- [ ] No world-readable sensitive files
- [ ] Proper user/group ownership (sigul:sigul)
- [ ] Volume permissions secure

**Validation Command:**
```bash
docker exec sigul-bridge find /etc/pki/sigul -ls
docker exec sigul-server find /var/lib/sigul -ls
```

---

## Phase-Specific Validation

### Phase 1-3 Validation (Foundation)

- [ ] Phase 1 complete: Directory structure aligned
- [ ] Phase 2 complete: Certificates aligned
- [ ] Phase 3 complete: Configuration aligned

**Validation Command:**
```bash
test -f PHASE1_COMPLETE.md && test -f PHASE2_COMPLETE.md && test -f PHASE3_COMPLETE.md
```

### Phase 4-6 Validation (Core)

- [ ] Phase 4 complete: Service initialization aligned
- [ ] Phase 5 complete: Volume strategy aligned
- [ ] Phase 6 complete: Network configuration aligned

**Validation Command:**
```bash
./scripts/validate-phase4-service-initialization.sh
./scripts/validate-phase5-volume-persistence.sh
./scripts/validate-phase6-network-dns.sh
```

### Phase 7 Validation (Testing)

- [ ] Phase 7 complete: Integration testing implemented
- [ ] Test infrastructure validated
- [ ] All test scripts executable
- [ ] Test validation passing

**Validation Command:**
```bash
./scripts/validate-phase7-integration-testing.sh
```

---

## Final Validation

### Complete System Test

- [ ] Full integration test suite passes
- [ ] All validation scripts pass
- [ ] No error messages in logs
- [ ] All health checks passing
- [ ] Performance within acceptable limits

**Validation Command:**
```bash
./scripts/test-infrastructure.sh
./scripts/run-integration-tests.sh
./scripts/test-signing-operations.sh
./scripts/test-performance.sh
```

### Production Readiness

- [ ] All validation checklist items completed
- [ ] Backup and restore procedures tested
- [ ] Disaster recovery plan documented
- [ ] Operations team trained
- [ ] Monitoring configured
- [ ] Incident response procedures documented

### Sign-Off

- [ ] Technical lead review complete
- [ ] Security review complete
- [ ] Operations team acceptance
- [ ] Documentation review complete
- [ ] Production deployment authorized

---

## Validation Summary

**Date Validated:** _________________  
**Validated By:** _________________  
**Environment:** [ ] Development [ ] Staging [ ] Production  
**Result:** [ ] PASS [ ] FAIL  

**Notes:**
```
[Add any notes, exceptions, or follow-up items here]
```

---

## Quick Validation Commands

Run all validations in sequence:

```bash
# Phase validations
./scripts/validate-phase4-service-initialization.sh
./scripts/validate-phase5-volume-persistence.sh
./scripts/validate-phase6-network-dns.sh
./scripts/validate-phase7-integration-testing.sh

# Infrastructure tests
./scripts/test-infrastructure.sh

# Integration tests
./scripts/run-integration-tests.sh

# Functional tests
./scripts/test-signing-operations.sh

# Performance tests
./scripts/test-performance.sh
```

**Expected Result:** All tests pass with 100% success rate.

---

*This checklist should be completed before any production deployment.*