#!/usr/bin/env bash
# Applies (or re-applies) this whole stack to whatever Incus host `incus`
# is currently pointed at — the VPS, the home lab box, the Home Assistant
# box, whichever. Safe to re-run: every step is idempotent, and instances
# get recreated (not left half-updated) when their profile or image changes.
#
# Prerequisites (see README.md for the full story):
#   - deploy.env filled in from deploy.env.example
#   - Both domains' DNS already pointing at this host
#   - an incus-ui image already published (see github.com/minihci/incus-ui)
#   - scripts/generate-authelia-secrets.sh already run, and
#     authelia/users_database.yml filled in from the .example using the
#     hash it printed
#
# Usage: scripts/deploy.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f deploy.env ]; then
  echo "deploy.env not found — copy deploy.env.example, fill it in, and try again." >&2
  exit 1
fi
set -a; source deploy.env; set +a

for f in secrets/reset_password_jwt_secret secrets/session_secret secrets/storage_encryption_key \
         secrets/oidc_hmac_secret secrets/oidc.key authelia/users_database.yml; do
  if [ ! -f "$f" ]; then
    echo "$f not found — run scripts/generate-authelia-secrets.sh (and fill in" >&2
    echo "authelia/users_database.yml from the .example) before deploying." >&2
    exit 1
  fi
done

render() { # render TEMPLATE — substitutes ${VAR} placeholders, prints to stdout
  # Explicit sed substitution, not eval+heredoc: an earlier version of this
  # function used `eval "cat <<EOF ... EOF"`, and it was a real bug, not a
  # style choice — unquoted heredocs run command substitution on their
  # content, so a backtick anywhere in a template file (including in an
  # innocent markdown-style comment like `` `scripts/deploy.sh` ``) gets
  # executed as a shell command. That specific comment made deploy.sh
  # re-launch itself from inside render(), recursively, every time this
  # function ran — confirmed live on the VPS as ~100s of stacked bash
  # processes within about a minute of an unattended run. sed only ever
  # does the literal substitutions listed below; it cannot execute
  # anything a template file contains, by construction.
  if [ ! -f "$1" ]; then
    echo "render: $1 not found" >&2
    exit 1
  fi
  sed \
    -e "s|\${ADMIN_EMAIL}|${ADMIN_EMAIL}|g" \
    -e "s|\${INCUS_UI_DOMAIN}|${INCUS_UI_DOMAIN}|g" \
    -e "s|\${AUTH_DOMAIN}|${AUTH_DOMAIN}|g" \
    -e "s|\${INCUS_API_ADDR}|${INCUS_API_ADDR}|g" \
    -e "s|\${AUTHELIA_STATIC_IP}|${AUTHELIA_STATIC_IP}|g" \
    -e "s|\${INCUS_UI_STATIC_IP}|${INCUS_UI_STATIC_IP}|g" \
    -e "s|\${BRIDGE_NETWORK}|${BRIDGE_NETWORK}|g" \
    -e "s|\${STORAGE_POOL}|${STORAGE_POOL}|g" \
    "$1"
}

render_server_config() { # renders daemon/server-config.yaml, splicing in daemon/authorization.star
  # A plain sed s/// can't hold a multi-line replacement, so the scriptlet
  # is spliced in via sed's r (read file) address command instead: r inserts
  # authorization.star's content after the placeholder line, d then drops
  # the placeholder itself. No eval, no command substitution of file
  # content — see render()'s own comment for why that matters here.
  local indented
  indented="$(mktemp)"
  trap 'rm -f "$indented"' RETURN
  sed 's/^/    /' daemon/authorization.star > "$indented"
  render daemon/server-config.yaml \
    | sed -e "/__AUTHORIZATION_SCRIPTLET__/r $indented" -e "/__AUTHORIZATION_SCRIPTLET__/d"
}

echo "== registries =="
incus remote list -f csv -c n | grep -qx docker-oci || \
  incus remote add docker-oci https://docker.io --protocol oci
REGISTRY_HOST="${IMAGE_REGISTRY%%/*}"
# IMAGE_REGISTRY may or may not have a path component (ghcr.io/you does;
# a bare host:port registry like a local throwaway one doesn't) — keep
# REGISTRY_PATH empty rather than wrongly falling back to the whole
# string when there's no "/" for the `#*/` pattern to match.
if [[ "$IMAGE_REGISTRY" == */* ]]; then
  REGISTRY_PATH="${IMAGE_REGISTRY#*/}/"
else
  REGISTRY_PATH=""
fi
desired_registry_url="https://${REGISTRY_HOST}"
# Keyed on name only would silently keep pointing at a stale registry —
# confirmed live: switching IMAGE_REGISTRY from a local registry to GHCR
# left incus-ui-oci pointed at 127.0.0.1:5000, since a same-named remote
# already "existed" and this used to just skip re-adding it. Compare the
# URL too, and replace the remote outright when it's changed.
current_registry_url=$(incus remote list -f csv | awk -F, -v n=incus-ui-oci '$1==n{print $2}')
if [ "$current_registry_url" != "$desired_registry_url" ]; then
  [ -n "$current_registry_url" ] && incus remote remove incus-ui-oci
  incus remote add incus-ui-oci "$desired_registry_url" --protocol oci ${IMAGE_REGISTRY_TOKEN:+--token "$IMAGE_REGISTRY_TOKEN"}
fi

echo "== storage volumes (created once, never recreated by this script) =="
incus storage volume list "$STORAGE_POOL" -f csv -c n | grep -qx incus-ui-caddy-data || \
  incus storage volume create "$STORAGE_POOL" incus-ui-caddy-data
incus storage volume list "$STORAGE_POOL" -f csv -c n | grep -qx authelia-config || \
  incus storage volume create "$STORAGE_POOL" authelia-config
incus storage volume list "$STORAGE_POOL" -f csv -c n | grep -qx ingress-caddy-data || \
  incus storage volume create "$STORAGE_POOL" ingress-caddy-data
incus storage volume list "$STORAGE_POOL" -f csv -c n | grep -qx ingress-routes || \
  incus storage volume create "$STORAGE_POOL" ingress-routes

echo "== profiles =="
incus profile list -f csv -c n | grep -qx incus-ui || incus profile create incus-ui
render incus-ui/incus-ui.profile.yaml | incus profile edit incus-ui
incus profile list -f csv -c n | grep -qx authelia || incus profile create authelia
render authelia/authelia.profile.yaml | incus profile edit authelia
incus profile list -f csv -c n | grep -qx ingress || incus profile create ingress
render ingress/ingress.profile.yaml | incus profile edit ingress

echo "== incus-ui =="
if incus list -f csv -c n | grep -qx incus-ui; then
  incus delete incus-ui --force
fi
incus launch "incus-ui-oci:${REGISTRY_PATH}incus-ui:latest" incus-ui \
  --profile default --profile incus-ui

echo "== authelia =="
if incus list -f csv -c n | grep -qx authelia; then
  incus delete authelia --force
fi
incus launch docker-oci:authelia/authelia:latest authelia \
  --profile default --profile authelia
for i in $(seq 1 20); do
  incus exec authelia -- test -d /config 2>/dev/null && break
  sleep 1
  [ "$i" -eq 20 ] && { echo "/config never appeared in authelia — aborting" >&2; exit 1; }
done
incus file push authelia/configuration.yml authelia/config/configuration.yml
incus file push authelia/users_database.yml authelia/config/users_database.yml
incus file push --create-dirs secrets/reset_password_jwt_secret authelia/config/secrets/reset_password_jwt_secret
incus file push secrets/session_secret authelia/config/secrets/session_secret
incus file push secrets/storage_encryption_key authelia/config/secrets/storage_encryption_key
incus file push secrets/oidc_hmac_secret authelia/config/secrets/oidc_hmac_secret
incus file push secrets/oidc.key authelia/config/secrets/oidc.key
incus restart authelia # first boot almost always beat the config being there

echo "== ingress =="
if incus list -f csv -c n | grep -qx ingress; then
  incus delete ingress --force
fi
incus launch docker-oci:caddy:2.11.4 ingress \
  --profile default --profile ingress
for i in $(seq 1 20); do
  incus exec ingress -- test -d /etc/caddy 2>/dev/null && break
  sleep 1
  [ "$i" -eq 20 ] && { echo "/etc/caddy never appeared in ingress — aborting" >&2; exit 1; }
done
incus file push ingress/Caddyfile ingress/etc/caddy/Caddyfile
# Plain files, not rendered: these use Caddy's own {$VAR} runtime env-var
# syntax (resolved from ingress.profile.yaml's environment.* keys, same
# pattern minihci/incus-ui's own Caddyfile uses), not this script's ${VAR}
# sed templating — different bracket order, deliberately, so the two
# never collide.
incus file push --create-dirs ingress/routes/incus-ui.caddy ingress/etc/caddy/routes/incus-ui.caddy
incus file push ingress/routes/auth.caddy ingress/etc/caddy/routes/auth.caddy
incus restart ingress # picks up the Caddyfile + routes pushed above

echo "== incus daemon: OIDC + authorization =="
render_server_config | incus config edit

echo "== reconciler daemon =="
# Superseded by github.com/minihci/tink's "tink daemon run": real
# restart-on-crash/start-on-boot supervision under the host's actual init
# system, which cron never provided. Remove any cron entry left by an
# older run of this script first -- confirmed live on incus.xlii.co that
# leaving one in place just means two things reconciling the same routes.
#
# The parens + `|| true` are both load-bearing, not decoration: once the
# reconciler line is the *only* line in the crontab, `grep -v` matches
# nothing and exits 1 -- `|| true` absorbs that under this script's
# `set -e`, and the parens make sure it's the *filtered output*, not just
# a bare `true`, that reaches `crontab -`. Without the parens, `A | B ||
# true | C` parses as `(A | B) || (true | C)`, which skips C on the
# success path entirely -- confirmed by writing that exact bug once
# already while fixing this.
(crontab -l 2>/dev/null | grep -v 'reconciler/reconcile.sh' || true) | crontab -

if command -v tink >/dev/null 2>&1; then
  tink daemon install | tee /etc/systemd/system/tink-daemon.service >/dev/null
  systemctl daemon-reload
  systemctl enable --now tink-daemon
else
  echo "tink not found on PATH -- reconciler daemon NOT installed." >&2
  echo "Install tink (see github.com/minihci/tink), then run: tink daemon install" >&2
fi

echo
echo "Done. https://${INCUS_UI_DOMAIN} should be up within a minute or so"
echo "(Caddy needs a moment to get its certs on first boot)."
