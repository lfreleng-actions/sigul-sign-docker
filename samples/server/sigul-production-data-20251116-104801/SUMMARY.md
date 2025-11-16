# Sigul Production Configuration Extraction Summary

**Hostname:** aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org
**Date:** Sun 16 Nov 10:48:05 UTC 2025
**Output Directory:** ./sigul-production-data-20251116-104801

## Extraction Sections

1. **System Information** - OS, kernel, packages, versions
2. **Sigul Configurations** - All config files from /etc/sigul/
3. **Certificates** - NSS database, certificate details, PKCS#12 files
4. **Database** - Schema, table structure (no sensitive data)
5. **GnuPG** - Directory structure, config files, key info
6. **Systemd Services** - Service files, status, drop-ins
7. **Network** - DNS, hosts, ports, connections (Sigul-specific only)
8. **NSS Details** - Modules, database format, crypto policy
9. **Environment** - Variables, locale, timezone, entropy
10. **Permissions** - File ownership, modes, SELinux contexts
11. **Logging** - Log structure, logrotate, journal samples
12. **Processes** - Running processes, limits, resources
13. **Source Code** - Script locations, parser code, crypto code
14. **Parser Test** - ConfigParser format compatibility

## Components Excluded (Not Part of Sigul)

- **RabbitMQ** - Present on hosts but not used by Sigul
- **LDAP** - No integration found in Sigul configs
- **Koji/FAS** - Empty config sections, not actively used

## Files Created

```
01-system-info.txt
02-sigul-configs/all-configs-combined.txt
02-sigul-configs/base.conf
02-sigul-configs/client.conf
02-sigul-configs/file-list.txt
02-sigul-configs/server-bridge-aws-us-west-2-dent-sigul-bridge-1.conf
02-sigul-configs/server-bridge-aws-us-west-2-lfit-sigul-bridge-1.conf
02-sigul-configs/server-bridge-aws-us-west-2-odpi-sigul-bridge-1.conf
03-certificates/cert-aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org.txt
03-certificates/cert-easyrsa.txt
03-certificates/certificate-list.txt
03-certificates/nss-database-info.txt
03-certificates/pkcs12-files.txt
04-database/database-file-info.txt
04-database/database-integrity.txt
04-database/database-schema.sql
04-database/database-tables-info.txt
05-gnupg/gnupg-config-files.txt
05-gnupg/gnupg-directory-info.txt
05-gnupg/gnupg-keys-info.txt
06-systemd/bridge-service.txt
06-systemd/bridge-status.txt
06-systemd/server-instance-sigul_server_bridge-aws-us-west-2-lfit-sigul-bridge-1_service.txt
06-systemd/server-instances-list.txt
06-systemd/server-service-template.txt
06-systemd/service-drop-ins.txt
07-network/dns-config.txt
07-network/established-connections.txt
07-network/listening-ports.txt
07-network/network-interfaces.txt
08-nss/crypto-policy.txt
08-nss/nss-config-files.txt
08-nss/nss-database-format.txt
08-nss/nss-modules.txt
09-environment/current-user-env.txt
09-environment/entropy-info.txt
09-environment/locale-timezone.txt
09-environment/nss-env-vars.txt
09-environment/sigul-user-env.txt
10-permissions/etc-pki-sigul-permissions.txt
10-permissions/etc-sigul-permissions.txt
10-permissions/user-group-info.txt
10-permissions/var-lib-sigul-permissions.txt
10-permissions/var-log-sigul-permissions.txt
11-logging/log-directory-structure.txt
11-logging/logrotate-config.txt
11-logging/sample-_var_log_sigul-bridge-aws-us-west-2-dent-sigul-bridge-1_sigul_server.log.txt
11-logging/sample-_var_log_sigul-bridge-aws-us-west-2-lfit-sigul-bridge-1_sigul_server.log.txt
11-logging/sample-_var_log_sigul-bridge-aws-us-west-2-odpi-sigul-bridge-1_sigul_server.log.txt
11-logging/sample-_var_log_sigul--etc-sigul-server-bridge-aws-us-west-2-dent-sigul-bridge-1.conf_sigul_server.log.txt
11-logging/sample-_var_log_sigul--etc-sigul-server-bridge-aws-us-west-2-odpi-sigul-bridge-1.conf_sigul_server.log.txt
11-logging/sample-_var_log_sigul_server.log.txt
11-logging/systemd-journal.txt
12-processes/sigul-processes.txt
12-processes/systemd-resource-limits.txt
13-source-code/certificate-validation-code.txt
13-source-code/config-parser-code.txt
13-source-code/nss-usage-code.txt
13-source-code/passphrase-encryption-code.txt
13-source-code/password-hashing-code.txt
13-source-code/script-locations.txt
14-config-parser-test/parser-test-results.txt
extraction.log
SUMMARY.md
```

## Key Findings

### Host Type Detection

- **SERVER HOST** - Contains server.py

### Sigul Version

sigul-0.207-1.el7.x86_64

### Python Version

- Python 2.7.5

### NSS Database Format

- **Legacy format** (cert8.db, key3.db)

### Certificates Found

3 certificates in NSS database

### Database Status

- **Present** at /var/lib/sigul/server.sqlite
- Size: 12K

### GnuPG Status

- **Present** at /var/lib/sigul/gnupg

## Next Steps

1. Review each section output file
2. Compare with containerized stack gap analysis
3. Update container configuration to match production patterns:
   - Use FHS paths (/etc/sigul/, /etc/pki/sigul/, /var/lib/sigul/)
   - Implement colon separator config format
   - Add certificate EKU/SAN flags
   - Add missing config parameters (GnuPG, resource limits, TLS versions)
   - Remove [bridge-server] section from bridge config
4. Test modernized stack with Python 3, current NSS, GPG 2.x
5. Validate against production behavior patterns

---
**Extraction completed successfully**
