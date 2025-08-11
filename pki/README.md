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

The client PKI is packaged separately in `pki/client-pki-encrypted.asc` and contains:

- Client certificate and private key
- CA certificate for verification
- Client configuration
- Test signing key

## Usage in Docker Compose

This script generates certificates for containerized deployments where certificates are managed via sigul-init.sh.

## Usage in Workflows

The client PKI is generated dynamically during workflow execution using the `./scripts/generate-test-pki.sh` script. The workflows will capture the generated encrypted PKI content and pass it via environment variables.

Example workflow usage:

```yaml
- name: Generate PKI infrastructure
  run: ./scripts/generate-test-pki.sh

- name: Use Sigul signing action
  uses: ./
  with:
    sigul-pki: ${{ steps.generate-real-pki.outputs.encrypted-pki }}
    sigul-pass: ${{ steps.generate-real-pki.outputs.ephemeral-password }}
```

## Security Note

This PKI infrastructure is for testing purposes only. Do not use in production.
