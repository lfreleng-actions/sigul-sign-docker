<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Production-Aligned Deployment Guide

This guide covers deployment of the production-aligned Sigul container stack. This deployment model mirrors the production configuration patterns used in AWS deployments while maintaining modern security and containerization best practices.

## Overview

The production-aligned Sigul container stack provides:

- **FHS-compliant directory structure** matching production deployments
- **FQDN-based certificates** with proper SAN extensions
- **Modern cryptographic formats** (cert9.db, TLS 1.2+, GPG 2.x)
- **Persistent volume strategy** for reliable backups and disaster recovery
- **Production-verified configuration patterns** for stability and security

## Architecture

**Connection Flow (Correct):**

```text
┌─────────────────┐
│  Sigul Client   │
│                 │
└────────┬────────┘
         │ Connects to
         │ Port 44334
         ▼
┌─────────────────┐
│  Sigul Bridge   │◄─────────────┐
│                 │              │
│ Listens on:     │              │ Connects to
│  - 0.0.0.0:44333│              │ Port 44333
│  - 0.0.0.0:44334│              │
└─────────────────┘              │
                         ┌───────┴────────┐
                         │  Sigul Server  │
                         │                │
                         └────────────────┘
```

**Key Point:** Server CONNECTS TO bridge (server is active, bridge is passive listener).

### Components

- **Sigul Bridge**: TLS proxy managing communication on ports 44333 (server) and 44334 (client)
- **Sigul Server**: Core signing service with GPG key management and SQLite database
- **Sigul Client**: Command-line interface for signing operations (not included in base stack)

## Prerequisites

### System Requirements

- **Docker**: 20.10 or later
- **Docker Compose**: 2.0 or later (V2 CLI)
- **Operating System**: Linux (tested on RHEL/CentOS 8+, Ubuntu 20.04+)
- **RAM**: Minimum 2GB, recommended 4GB
- **Disk Space**: Minimum 10GB for container images and volumes
- **Network**: Ports 44333 and 44334 available

### Software Dependencies

- `bash` 4.0+
- `openssl` for secret generation
- `git` for repository cloning

### Verify Prerequisites

```bash
# Check Docker version
docker --version

# Check Docker Compose version
docker compose version

# Verify Docker daemon is running
docker info

# Check available disk space
df -h /var/lib/docker
```

## Deployment Steps

### 1. Clone Repository

```bash
git clone https://github.com/lf-releng/sigul-sign-docker.git
cd sigul-sign-docker
```

### 2. Generate Secrets

The NSS password is critical for certificate database security. Generate and store it securely:

```bash
# Generate a strong NSS password
export NSS_PASSWORD=$(openssl rand -base64 32)

# Save to environment file (ensure proper permissions)
echo "NSS_PASSWORD=${NSS_PASSWORD}" > .env
chmod 600 .env

# IMPORTANT: Back up this password to your secure password vault
echo "NSS Password: ${NSS_PASSWORD}" | tee nss-password-backup.txt
chmod 600 nss-password-backup.txt
```

⚠️ **CRITICAL**: Store the NSS password in a secure location (password manager, secrets vault). Loss of this password means loss of access to the certificate database.

### 3. Customize Configuration (Optional)

The default configuration uses example FQDNs. For production deployments, customize these:

```bash
# Set custom FQDNs (optional)
export BRIDGE_FQDN="sigul-bridge.example.org"
export SERVER_FQDN="sigul-server.example.org"

# Edit configuration templates if needed
vi configs/bridge.conf.template
vi configs/server.conf.template
```

**Configuration Template Locations:**
- Bridge: `configs/bridge.conf.template`
- Server: `configs/server.conf.template`

### 4. Deploy Infrastructure

Use the deployment script to automate the entire setup process:

```bash
./scripts/deploy-sigul-infrastructure.sh
```

**This script performs:**
1. Validates prerequisites
2. Generates configuration files from templates
3. Creates NSS certificate databases
4. Generates CA and component certificates
5. Builds Docker images
6. Starts containers with proper dependencies
7. Verifies deployment health

**Expected output:**
```text
=== Sigul Infrastructure Deployment ===
[INFO] Validating prerequisites...
[PASS] Docker is available
[PASS] Docker Compose is available
[INFO] Generating configurations...
[PASS] Bridge configuration created
[PASS] Server configuration created
[INFO] Creating certificates...
[PASS] CA certificate created
[PASS] Bridge certificate created
[PASS] Server certificate created
[INFO] Starting containers...
[PASS] Bridge container healthy
[PASS] Server container healthy
=== Deployment Complete ===
```

### 5. Verify Deployment

Run the infrastructure tests to ensure everything is working:

```bash
./scripts/test-infrastructure.sh
```

Run validation scripts:

```bash
# Phase 4: Service Initialization
./scripts/validate-phase4-service-initialization.sh

# Phase 5: Volume Persistence
./scripts/validate-phase5-volume-persistence.sh

# Phase 6: Network & DNS
./scripts/validate-phase6-network-dns.sh

# Phase 7: Integration Testing
./scripts/validate-phase7-integration-testing.sh
```

### 6. Check Service Status

```bash
# View container status
docker-compose -f docker-compose.sigul.yml ps

# View logs
docker-compose -f docker-compose.sigul.yml logs

# Check health
docker-compose -f docker-compose.sigul.yml ps --format json | jq '.Health'
```

## Directory Structure

The production-aligned deployment uses FHS-compliant paths:

```text
/etc/sigul/           # Configuration files
  ├── bridge.conf     # Bridge configuration
  └── server.conf     # Server configuration

/etc/pki/sigul/       # NSS certificate database
  ├── cert9.db        # Certificate database (modern format)
  ├── key4.db         # Private key database (modern format)
  └── pkcs11.txt      # PKCS#11 module configuration

/var/lib/sigul/       # Persistent data
  ├── server/
  │   ├── sigul.db    # SQLite signing database
  │   └── gnupg/      # GnuPG home directory
  └── gnupg/          # Server GPG keys

/var/log/sigul/       # Log files
  ├── bridge.log      # Bridge logs
  └── server.log      # Server logs
```

## Configuration

### Bridge Configuration

Key settings in `/etc/sigul/bridge.conf`:

```ini
[bridge]
bridge-cert-nickname: sigul-bridge.example.org
client-listen-port: 44334
server-listen-port: 44333

[nss]
nss-dir: /etc/pki/sigul
nss-password: <generated-password>
nss-min-tls: tls1.2
```

### Server Configuration

Key settings in `/etc/sigul/server.conf`:

```ini
[server]
bridge-hostname: sigul-bridge.example.org
bridge-port: 44333
server-cert-nickname: sigul-server.example.org
max-file-payload-size: 1073741824

[database]
database-path: /var/lib/sigul/server/sigul.db

[gnupg]
gnupg-home: /var/lib/sigul/server/gnupg

[nss]
nss-dir: /etc/pki/sigul
nss-password: <generated-password>
nss-min-tls: tls1.2
```

## Certificate Management

### Certificate Details

Modern NSS database format (cert9.db) is used with FQDN-based certificates:

| Component | CN | SAN | Trust Flags |
|-----------|------|-----|-------------|
| CA | Sigul CA | - | CT,, |
| Bridge | sigul-bridge.example.org | sigul-bridge.example.org | u,u,u |
| Server | sigul-server.example.org | sigul-server.example.org | u,u,u |

### Certificate Validation

```bash
# List certificates
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul

# Verify certificate details
docker exec sigul-bridge certutil -L -n "sigul-bridge.example.org" -d sql:/etc/pki/sigul

# Check certificate expiration
docker exec sigul-bridge certutil -L -n "sigul-bridge.example.org" -d sql:/etc/pki/sigul | grep "Not After"
```

## Volumes

Critical data is stored in Docker volumes with backup priorities:

| Volume | Purpose | Backup Priority |
|--------|---------|-----------------|
| sigul_bridge_nss | Bridge certificates | HIGH |
| sigul_server_nss | Server certificates | HIGH |
| sigul_server_data | Database and GPG keys | CRITICAL |
| sigul_bridge_logs | Bridge logs | MEDIUM |
| sigul_server_logs | Server logs | MEDIUM |

### Backup

```bash
# Backup all critical volumes
./scripts/backup-volumes.sh

# Backups stored in: ./backups/
```

### Restore

```bash
# Stop services
docker-compose -f docker-compose.sigul.yml down

# Restore specific volume
./scripts/restore-volumes.sh sigul_server_data backups/sigul_server_data-<timestamp>.tar.gz

# Restart services
docker-compose -f docker-compose.sigul.yml up -d
```

## Troubleshooting

### Services Not Starting

**Check logs:**
```bash
docker logs sigul-bridge
docker logs sigul-server
```

**Common issues:**
- Certificate not found: Re-run certificate generation
- Permission denied: Check volume ownership
- Connection refused: Verify network configuration

### Certificate Issues

**Verify certificates:**
```bash
./scripts/validate-certificates.sh
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server
```

**Common issues:**
- Certificate CN mismatch: Regenerate with correct FQDN
- Trust flags incorrect: Check NSS database
- Certificate expired: Regenerate certificates

### Network Issues

**Test connectivity:**
```bash
./scripts/verify-dns.sh bridge
./scripts/verify-dns.sh server
./scripts/verify-network.sh
```

**Verify bridge is listening:**
```bash
docker exec sigul-bridge netstat -tlnp | grep -E '44333|44334'

# Expected output:
# tcp  0.0.0.0:44333  LISTEN  <pid>/python
# tcp  0.0.0.0:44334  LISTEN  <pid>/python
```

**Verify server connection:**
```bash
docker exec sigul-server netstat -tnp | grep 44333

# Expected output:
# tcp  <server-ip>:<port>  <bridge-ip>:44333  ESTABLISHED  <pid>/python
```

### Database Issues

**Check database integrity:**
```bash
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "PRAGMA integrity_check;"
```

**Check database permissions:**
```bash
docker exec sigul-server ls -la /var/lib/sigul/server/
```

## Maintenance

### Routine Tasks

**Daily:**
- Monitor logs: `docker-compose -f docker-compose.sigul.yml logs --tail=100`
- Check health: `docker-compose -f docker-compose.sigul.yml ps`

**Weekly:**
- Backup volumes: `./scripts/backup-volumes.sh`
- Review disk usage: `df -h`

**Monthly:**
- Test restore procedure: `./scripts/restore-volumes.sh --help`
- Review certificate expiration dates
- Run performance tests: `./scripts/test-performance.sh`

### Upgrade

```bash
# Backup before upgrade
./scripts/backup-volumes.sh

# Pull latest changes
git pull

# Rebuild containers
docker-compose -f docker-compose.sigul.yml build

# Restart services
docker-compose -f docker-compose.sigul.yml up -d

# Verify
./scripts/test-infrastructure.sh
```

### Certificate Rotation

Certificates are valid for 10 years. To rotate before expiration:

```bash
# Backup current certificates
./scripts/backup-volumes.sh

# Stop services
docker-compose -f docker-compose.sigul.yml down

# Remove certificate volumes
docker volume rm sigul_bridge_nss sigul_server_nss

# Redeploy (generates new certificates)
./scripts/deploy-sigul-infrastructure.sh
```

## Security Considerations

### Network Exposure

- **Bridge**: Listens on 0.0.0.0 (all interfaces) - hardcoded behavior
- **Solution**: Use Docker network policies or firewall rules
- **Production**: Place behind load balancer with TLS termination

### Secrets Management

- **NSS Password**: Store in secrets vault (HashiCorp Vault, AWS Secrets Manager)
- **Avoid**: Committing .env file to version control
- **Use**: Environment variable injection in production

### Certificate Security

- **Storage**: Volumes with restricted permissions
- **Backup**: Encrypted backups in secure location
- **Rotation**: Regular certificate rotation schedule

## Production Deployment Pattern

### AWS/Cloud Deployment

```text
Internet
    │
    ▼
[Load Balancer] :44334 (client traffic)
    │
    ▼
[Sigul Bridge]
    │ Port 44333
    │ (internal network)
    ▼
[Sigul Server] ─────► [Bridge]
(no public exposure)   (outbound connection)
```

### High Availability

For production HA deployments:

1. **Multiple Bridge Instances**: Load balanced for client connections
2. **Multiple Server Instances**: Each server connects to bridge(s)
3. **Shared Storage**: Use network volumes for server data
4. **Database Replication**: Consider PostgreSQL for multi-server setups

## References

- **Network Architecture**: See `NETWORK_ARCHITECTURE.md` for detailed connection patterns
- **ALIGNMENT_PLAN.md**: Complete alignment plan with all phases
- **Phase Completion Docs**: PHASE[1-7]_COMPLETE.md for detailed phase information
- **Operations Guide**: See `OPERATIONS_GUIDE.md` for day-to-day operations

## Support

For issues, questions, or contributions:

- **GitHub Issues**: https://github.com/lf-releng/sigul-sign-docker/issues
- **Documentation**: All PHASE*.md files in repository
- **Validation Scripts**: Use scripts/validate-*.sh for troubleshooting

---

*For detailed operations and maintenance procedures, see OPERATIONS_GUIDE.md*