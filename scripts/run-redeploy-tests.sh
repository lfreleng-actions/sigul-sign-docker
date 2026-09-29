#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for a clean redeploy over a running stack.
#
# `deploy-sigul-infrastructure.sh --force-clean-volumes` is meant to
# discard every piece of state and start again. It used to remove
# nothing while the stack was up: it passed all the container IDs to
# `docker stop` as one quoted argument, so the stop and then the
# removal failed, silently; and it removed volumes by names from before
# the repository was renamed, which never matched. The server kept its
# NSS database while cert-init issued a new CA, and exited 255.
#
# CI deploys onto a fresh runner, where there is nothing to clean, so
# only a redeploy over a live stack exercises the path. This deploys,
# provisions a client and signs; deploys again with
# --force-clean-volumes while everything is still running; and asserts
# the redeploy succeeded, the CA was replaced, and a freshly
# provisioned client can create a key and produce a signature that gpg
# verifies.
#
# It starts from a stack deployed under the Compose project name a
# checkout of this repository used to get implicitly, so the clean also
# has to find and retire a live stack outside its own project - the
# first redeploy after upgrading.
#
# Leaves the redeployed stack running, as the deploy script does.
#
#   SIGUL_CLIENT_IMAGE=... SIGUL_SERVER_IMAGE=... SIGUL_BRIDGE_IMAGE=... \
#       ./scripts/run-redeploy-tests.sh

set -euo pipefail

for var in SIGUL_CLIENT_IMAGE SIGUL_SERVER_IMAGE SIGUL_BRIDGE_IMAGE; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var must be set" >&2
        exit 1
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

PASSED=0
FAILED=0
pass() { echo "  PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $*" >&2; FAILED=$((FAILED + 1)); }
phase() { echo; echo "=== $* ==="; }

# deploy <log label> [deploy-script flags...]
#
# --mode local, so that only calls passing --force-clean-volumes clean:
# left to detect its mode, the deploy script picks ci under GitHub
# Actions, which always cleans, and the plain upgrade would test nothing.
deploy() {
    local label="$1"
    shift
    ./scripts/deploy-sigul-infrastructure.sh --local-debug --mode local "$@" \
        > "test-artifacts/redeploy-${label}.log" 2>&1
}

# SHA-256 fingerprint of the CA the bridge holds.
ca_fingerprint() {
    docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge \
        -n sigul-ca 2>/dev/null \
        | awk '/Fingerprint \(SHA-256\)/{getline; gsub(/[[:space:]]/, ""); print; exit}'
}

# Run a sigul client in the stack. Reads NUL-separated secrets on
# stdin; the script given runs in a scratch directory.
sigul_client() {
    local network
    network="$(docker network ls --filter 'name=sigul' --format '{{.Name}}' | head -1)"
    docker run --rm -i --init --user 1000:1000 --network "$network" \
        -v sigul-docker_sigul_client_nss:/etc/pki/sigul/client:ro \
        -v sigul-docker_sigul_client_config:/etc/sigul:ro \
        -e KEY="${KEY:-}" "$SIGUL_CLIENT_IMAGE" \
        bash -c 'set -e; cd "$(mktemp -d)"; conf=/etc/sigul/client.conf; '"$1"
}

KEY_PASSPHRASE="redeploy-key-passphrase"

# Create a signing key with a unique name - new-key refuses a name the
# server already has - and print the name.
create_key() {
    local key
    key="redeploy-$(date +%s)-${RANDOM}"
    # shellcheck disable=SC2016  # expanded by the client container
    printf '%s\0%s\0' "$(cat test-artifacts/admin-password)" "$KEY_PASSPHRASE" \
        | KEY="$key" sigul_client '
            timeout 300 sigul --batch -c "$conf" new-key --key-admin admin \
                --gnupg-name-real "Redeploy Test" \
                --gnupg-name-email redeploy@example.invalid "$KEY"' \
            >/dev/null 2>&1 || return 1
    echo "$key"
}

# Sign a file with key $1 and verify the signature with gpg against the
# public key the server returns. Proves the stack signs, not only that
# it authenticates.
sign_and_verify() {
    # shellcheck disable=SC2016  # expanded by the client container
    printf '%s\0%s\0' "$(cat test-artifacts/admin-password)" "$KEY_PASSPHRASE" \
        | KEY="$1" sigul_client '
            IFS= read -r -d "" admin
            IFS= read -r -d "" pass
            printf "%s\0" "$admin" | timeout 60 sigul --batch -c "$conf" \
                get-public-key --password "$KEY" > key.asc
            head -c 4096 /dev/urandom > blob
            printf "%s\0" "$pass" | timeout 60 sigul --batch -c "$conf" \
                sign-data -o blob.sig "$KEY" blob
            export GNUPGHOME="$PWD/gnupg"
            mkdir -m 700 "$GNUPGHOME"
            gpg --batch --quiet --import key.asc 2>/dev/null
            gpg --batch --quiet --verify blob.sig blob 2>/dev/null' \
        >/dev/null 2>&1
}

# A new key signs, and gpg verifies it.
new_key_signs() {
    local key
    key="$(create_key)" && sign_and_verify "$key"
}

# Deploy under the legacy project name and check it serves.
deploy_legacy() {
    COMPOSE_PROJECT_NAME="$LEGACY_PROJECT" deploy "$1" --force-clean-volumes \
        && ./scripts/setup-client.sh >/dev/null && new_key_signs
}

# Wait up to $2 seconds for container $1 to report healthy.
wait_for_healthy() {
    local deadline=$(( $(date +%s) + $2 ))
    while (( $(date +%s) < deadline )); do
        [[ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" == "healthy" ]] \
            && return 0
        sleep 3
    done
    return 1
}

running_under() {
    [[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
            sigul-server 2>/dev/null)" == "$1" \
        && "$(docker inspect -f '{{.State.Running}}' sigul-server 2>/dev/null)" == "true" ]]
}

mkdir -p test-artifacts

# The name a checkout called sigul-docker-k8s gave the stack before the
# compose file pinned one.
LEGACY_PROJECT="sigul-docker-k8s"
# The project the compose file pins; its volumes are named after it.
PROJECT="sigul-docker"

# A release from before #37, which kept the server's database and GnuPG
# home on the container's writable layer. Its images run their own
# cert-init and entrypoint, so the stack they build is the real thing.
RELEASE_TAG="${SIGUL_REDEPLOY_FROM_TAG:-v2.5.0}"
RELEASE_REGISTRY="${SIGUL_REDEPLOY_FROM_REGISTRY:-ghcr.io/lfreleng-actions/sigul-docker-k8s}"

phase "0: upgrading from ${RELEASE_TAG} keeps keys it kept off the volume"
release_ok=true
for component in server bridge client; do
    docker pull -q "${RELEASE_REGISTRY}/${component}:${RELEASE_TAG}" >/dev/null 2>&1 \
        || release_ok=false
done
if [[ "$release_ok" != "true" ]]; then
    fail "could not pull the ${RELEASE_TAG} images to upgrade from"
else
    if SIGUL_SERVER_IMAGE="${RELEASE_REGISTRY}/server:${RELEASE_TAG}" \
            SIGUL_BRIDGE_IMAGE="${RELEASE_REGISTRY}/bridge:${RELEASE_TAG}" \
            SIGUL_CLIENT_IMAGE="${RELEASE_REGISTRY}/client:${RELEASE_TAG}" \
            deploy release --force-clean-volumes \
            && SIGUL_CLIENT_IMAGE="${RELEASE_REGISTRY}/client:${RELEASE_TAG}" \
                ./scripts/setup-client.sh >/dev/null; then
        pass "${RELEASE_TAG} stack deployed"
    else
        fail "${RELEASE_TAG} deploy failed - see test-artifacts/redeploy-release.log"
        exit 1
    fi
    release_key="$(create_key)" || { fail "could not create a key on ${RELEASE_TAG}"; exit 1; }
    if docker exec sigul-server test -s /var/lib/sigul/server.sqlite \
            && docker exec sigul-server sh -c 'test -n "$(ls -A /var/lib/sigul/gnupg)"'; then
        pass "${RELEASE_TAG} keeps its database and keys on the writable layer, as expected"
    else
        fail "${RELEASE_TAG} did not keep its state on the writable layer - the test proves nothing"
    fi
    if deploy from-release; then
        pass "a plain deploy of this branch over ${RELEASE_TAG} succeeded"
    else
        fail "the deploy over ${RELEASE_TAG} failed - see test-artifacts/redeploy-from-release.log"
    fi
    if sign_and_verify "$release_key"; then
        pass "a key created on ${RELEASE_TAG} still signs after the upgrade, and gpg verifies it"
    else
        fail "the key created on ${RELEASE_TAG} was lost in the upgrade"
    fi
    # What the server is configured with, not only what is on the volume:
    # a copy there proves nothing if server.conf still names the old
    # paths, as an upgraded Compose stack's did.
    if docker exec sigul-server test -s /var/lib/sigul/server/server.sqlite \
            && docker exec sigul-server grep -qx \
                'database-path: /var/lib/sigul/server/server.sqlite' /etc/sigul/server.conf \
            && docker exec sigul-server grep -qx \
                'gnupg-home: /var/lib/sigul/server/gnupg' /etc/sigul/server.conf; then
        pass "the server now keeps its database and GnuPG home on the volume"
    else
        fail "the server does not keep its database and GnuPG home on the volume after the upgrade"
    fi
fi

phase "1: plain upgrade over a running legacy stack keeps its state"
if deploy_legacy upgrade-base && running_under "$LEGACY_PROJECT"; then
    pass "legacy stack deployed and a client signs"
else
    fail "legacy deploy failed - see test-artifacts/redeploy-upgrade-base.log"
    exit 1
fi
legacy_ca="$(ca_fingerprint)"
old_key="$(create_key)" || { fail "could not create a key on the legacy stack"; exit 1; }

if deploy upgrade; then
    pass "plain redeploy over the legacy stack succeeded"
else
    fail "plain redeploy failed - see test-artifacts/redeploy-upgrade.log"
fi
if running_under "sigul-docker"; then
    pass "server now runs under the pinned project"
else
    fail "server not running under the pinned project"
fi
if [[ -n "$legacy_ca" && "$(ca_fingerprint)" == "$legacy_ca" ]]; then
    pass "the CA was carried over"
else
    fail "the CA changed: the legacy state was not adopted"
fi
# The client provisioned before the upgrade, not re-provisioned: it is
# still trusted, and its recorded credentials still open the server.
if new_key_signs; then
    pass "the client provisioned before the upgrade still signs, and gpg verifies it"
else
    fail "the client provisioned before the upgrade can no longer sign"
fi
# And the key made before it: the server's database and GnuPG home are
# on the volumes the upgrade carried over (#37).
if sign_and_verify "$old_key"; then
    pass "a key created before the upgrade still signs, and gpg verifies it"
else
    fail "the key created before the upgrade no longer signs"
fi
if [[ -n "$(docker volume ls -q --filter "label=com.docker.compose.project=${LEGACY_PROJECT}")" ]]; then
    pass "the legacy volumes are kept as a backup"
else
    fail "the legacy volumes were removed by a plain upgrade"
fi

phase "2: clean redeploy over a running legacy stack"
if deploy_legacy initial && running_under "$LEGACY_PROJECT"; then
    pass "legacy stack deployed and a client signs"
else
    fail "legacy deploy failed - see test-artifacts/redeploy-initial.log"
    exit 1
fi
first_ca="$(ca_fingerprint)"
if [[ -z "$first_ca" ]]; then
    fail "could not read the CA fingerprint from the bridge"
    exit 1
fi
if deploy clean --force-clean-volumes; then
    pass "redeploy with --force-clean-volumes succeeded"
else
    fail "redeploy failed - see test-artifacts/redeploy-clean.log"
fi

state="$(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}})' sigul-server 2>/dev/null || echo missing)"
if [[ "$state" == running* ]]; then
    pass "server running after the redeploy"
else
    fail "server after the redeploy: $state"
fi

second_ca="$(ca_fingerprint)"
if [[ -n "$second_ca" && "$second_ca" != "$first_ca" ]]; then
    pass "a new CA was issued"
else
    fail "CA unchanged or unreadable: the old state survived the clean"
fi

left="$(docker ps -aq --filter "label=com.docker.compose.project=${LEGACY_PROJECT}"; \
    docker volume ls -q --filter "label=com.docker.compose.project=${LEGACY_PROJECT}")"
if [[ -z "$left" ]]; then
    pass "nothing of the legacy project is left"
else
    fail "legacy project resources survived: $(echo "$left" | tr '\n' ' ')"
fi

phase "3: a recreated server keeps its keys"
# Recreating the container discards its writable layer; a server whose
# database or GnuPG home lived there lost every user and key (#37).
./scripts/setup-client.sh >/dev/null || { fail "could not provision a client"; exit 1; }
recreate_key="$(create_key)" || { fail "could not create a key before recreating"; exit 1; }
if NSS_PASSWORD="$(cat test-artifacts/nss-password)" \
        SIGUL_ADMIN_PASSWORD="$(cat test-artifacts/admin-password)" \
        docker compose -f docker-compose.sigul.yml up -d --force-recreate --no-deps \
            sigul-server > test-artifacts/redeploy-recreate.log 2>&1 \
        && wait_for_healthy sigul-server 180; then
    pass "the server container was recreated"
else
    fail "the server container could not be recreated - see test-artifacts/redeploy-recreate.log"
fi
if sign_and_verify "$recreate_key"; then
    pass "a key created before the recreation still signs, and gpg verifies it"
else
    fail "a key created before the recreation was lost with the container"
fi

phase "4: a clean removes volumes restored outside Compose"
# restore-volumes.sh recreates volumes with docker volume create, so
# they carry no Compose project label; a clean must remove them all the
# same, or the server keeps an NSS database the new CA did not issue.
restored="${PROJECT}_sigul_server_data"
if docker compose -f docker-compose.sigul.yml --profile '*' down --volumes \
            --remove-orphans --timeout 10 > test-artifacts/redeploy-restore.log 2>&1 \
        && docker volume create "$restored" >/dev/null \
        && docker run --rm --user 0 --entrypoint sh -v "${restored}:/v" \
            "$SIGUL_SERVER_IMAGE" -c 'echo restored > /v/restored-marker'; then
    pass "a data volume restored without Compose labels is in place"
else
    fail "could not stage a restored volume - see test-artifacts/redeploy-restore.log"
fi
if deploy restored --force-clean-volumes \
        && ! docker exec sigul-server test -e /var/lib/sigul/server/restored-marker \
        && [[ "$(docker volume inspect -f \
            '{{index .Labels "com.docker.compose.project"}}' "$restored")" == "$PROJECT" ]]; then
    pass "the clean replaced it with a fresh volume Compose owns"
else
    fail "the restored volume survived the clean - see test-artifacts/redeploy-restored.log"
fi

phase "5: the redeployed stack serves"
if ./scripts/setup-client.sh >/dev/null && new_key_signs; then
    pass "a freshly provisioned client signs, and gpg verifies it"
else
    fail "a freshly provisioned client cannot produce a verified signature"
fi

echo
echo "Redeploy tests: ${PASSED} passed, ${FAILED} failed"
[[ "$FAILED" -eq 0 ]]
