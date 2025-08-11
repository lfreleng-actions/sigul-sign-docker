<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2025 The Linux Foundation -->

# Sigul Test PKI Infrastructure

This directory contains the PKI infrastructure for Sigul integration testing.

## Files

### Certificate Authority

- `ca.crt` - Root CA certificate (public)

### Server Certificates

- `server.crt` - Sigul server certificate (public)
- `server-key.pem` - Sigul server private key (private)

### Bridge Certificates

- `bridge.crt` - Sigul bridge certificate (public)
- `bridge-key.pem` - Sigul bridge private key (private)

### Configuration Templates

- `server.conf.template` - Server configuration template
- `bridge.conf.template` - Bridge configuration template

## Client PKI

The `pki/client-pki-encrypted.asc` file packages the client PKI separately
and contains:

- Client certificate and private key
- CA certificate for verification
- Client configuration
- Test signing key

## Usage in Docker Compose

This script generates certificates for containerized deployments where
sigul-init.sh handles certificate management.

## Usage in Workflows

The client PKI generates dynamically during workflow execution using the
`./scripts/generate-test-pki.sh` script. This process captures the encrypted
PKI content and passes it via environment variables.

Example workflow usage:

```yaml
- name: Generate PKI infrastructure
  run: ./scripts/generate-test-pki.sh

- name: Use Sigul signing action
  uses: ./
  with:
    sigul-pki: ${{ steps.generate-real-pki.outputs.encrypted-pki }}
    sigul-pass: 'integration_test_password'
```

## Security Note

This PKI infrastructure serves testing purposes. Do not use in production.
