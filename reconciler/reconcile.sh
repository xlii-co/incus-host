#!/usr/bin/env bash
# ingress reconciler -- see DESIGN.md for the full story. One pass:
# discover instances that opted in via user.ingress.*, render their
# routes, apply only if something actually changed. Safe to run
# repeatedly (cron, every 60s) -- idempotent, and a bad pass never
# leaves ingress mid-update since routes only get pushed after the full
# desired set renders cleanly into a scratch directory first.
#
# Runs on the host as root (needed for the local socket + `incus exec`
# either way -- see DESIGN.md's "Discovery" section for why that's the
# right trust boundary, not a container with network-API credentials).
set -euo pipefail

SOCKET=/var/lib/incus/unix.socket
ROUTES_DIR=/var/lib/incus/storage-pools/default/custom/default_ingress-routes/generated
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$ROUTES_DIR"

instances="$(curl -sf --unix-socket "$SOCKET" 'http://localhost/1.0/instances?recursion=2&all-projects=true')"

# One JSON object per opted-in instance: {name, project, domain, port,
# address}. address comes from live state, not a stored value -- a DHCP
# lease change heals on the next pass instead of needing a static IP.
# all-projects=true is what lets a tenant project (e.g. `nightscout`)
# self-register the same way `default`-project instances always have --
# without it, anything moved out of `default` silently drops off ingress
# on the very next poll, no error anywhere (see DESIGN.md).
registered="$(echo "$instances" | jq -c '
  .metadata[]
  | select(.config["user.ingress.enabled"] == "true" and .config["user.ingress.domain"] != null)
  | {
      name: .name,
      project: .project,
      domain: .config["user.ingress.domain"],
      port: (.config["user.ingress.port"] // "80"),
      address: ([.state.network.eth0.addresses[]? | select(.family == "inet") | .address] | first)
    }
')"

# Conflict check: same domain claimed by more than one instance -- log and
# skip every instance claiming it, never silently pick a winner.
dupes="$(echo "$registered" | jq -s -c 'group_by(.domain) | map(select(length > 1) | .[0].domain)')"
echo "$dupes" | jq -r '.[]' | while IFS= read -r d; do
  echo "WARN: domain '$d' claimed by multiple instances, skipping all of them" >&2
done

echo "$registered" | jq -c --argjson dupes "$dupes" 'select(.domain as $d | ($dupes | index($d)) == null)' \
  | while IFS= read -r entry; do
  name="$(echo "$entry" | jq -r '.name')"
  project="$(echo "$entry" | jq -r '.project')"
  domain="$(echo "$entry" | jq -r '.domain')"
  port="$(echo "$entry" | jq -r '.port')"
  address="$(echo "$entry" | jq -r '.address')"

  # Only prefix non-default projects -- keeps every existing default-project
  # filename (and the hand-written incus-ui.caddy/auth.caddy alongside them)
  # unchanged, while still keeping a `nightscout`-project ns-caddy from
  # silently colliding with some other project's own ns-caddy on disk.
  if [ "$project" = "default" ]; then
    fname="${name}.caddy"
  else
    fname="${project}_${name}.caddy"
  fi

  if [ -z "$address" ] || [ "$address" = "null" ]; then
    echo "WARN: $project/$name has no address yet (not started?), skipping this pass" >&2
    continue
  fi

  cat > "$SCRATCH/${fname}" <<CADDYEOF
${domain} {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "same-origin"
		-Server
	}

	reverse_proxy http://${address}:${port} {
		header_up X-Real-IP {remote_host}
	}

	log {
		output file /data/access.log {
			roll_size 10MiB
			roll_keep 5
		}
		format json
	}
}
CADDYEOF
done

# No change -> no reload, no log noise. This is the common case on every
# poll but the first one after a real registration change.
if diff -rq "$ROUTES_DIR" "$SCRATCH" >/dev/null 2>&1; then
  exit 0
fi

# Full rebuild, not an incremental patch -- this is how a deregistered or
# deleted instance's stale route actually goes away instead of
# accumulating forever.
rm -f "${ROUTES_DIR:?}"/*.caddy
find "$SCRATCH" -maxdepth 1 -name '*.caddy' -exec cp {} "$ROUTES_DIR"/ \;

incus exec ingress -- caddy reload --config /etc/caddy/Caddyfile
echo "$(date -u +%FT%TZ) reconciled: $(ls "$ROUTES_DIR" 2>/dev/null | tr '\n' ' ')"
