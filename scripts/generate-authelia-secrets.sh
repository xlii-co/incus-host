#!/usr/bin/env bash
# Generates every secret authelia/configuration.yml needs, using Authelia's
# own crypto CLI (via its official image, so the source of truth for "what
# counts as a valid secret" is Authelia itself, not a hand-rolled script).
# Writes them to secrets/ (gitignored) — nothing here gets committed, and
# nothing here talks to the Incus host; scripts/deploy.sh pushes the output
# in as a separate step.
#
# Usage: scripts/generate-authelia-secrets.sh
set -euo pipefail

cd "$(dirname "$0")/.."
out="secrets"
mkdir -p "$out"

run() { podman run --rm docker.io/authelia/authelia:latest "$@"; }

rand() { run authelia crypto rand --length 64 --charset alphanumeric | sed 's/Random Value: //'; }

echo "Generating secrets into ${out}/ ..."

rand > "$out/reset_password_jwt_secret"
rand > "$out/session_secret"
rand > "$out/storage_encryption_key"
rand > "$out/oidc_hmac_secret"

# `podman run --rm` throws away the container's filesystem on exit, so this
# one step (the only one producing a file authelia's CLI can't just print
# to stdout) uses a named container instead of --rm, to pull the key back out.
cid=$(podman create docker.io/authelia/authelia:latest authelia crypto pair rsa generate \
  --bits 2048 --directory /tmp --file.private-key oidc.key --file.public-key oidc.pub)
podman start -a "$cid" >/dev/null
podman cp "$cid:/tmp/oidc.key" "$out/oidc.key"
podman rm "$cid" >/dev/null

password=$(run authelia crypto rand --length 20 --charset alphanumeric | sed 's/Random Value: //')
hash=$(run authelia crypto hash generate argon2 --password "$password" | sed 's/Digest: //')

echo "$hash" > "$out/admin_password_hash"
echo "$password" > "$out/admin_password.txt"

chmod 600 "$out"/*

echo
echo "Done. Login password (also saved to ${out}/admin_password.txt — read it, then delete that one file):"
echo "  $password"
echo
echo "Next: fill in authelia/users_database.yml from users_database.yml.example using"
echo "the hash in ${out}/admin_password_hash, then run scripts/deploy.sh."
