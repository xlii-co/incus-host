# ingress reconciler — design

Replaces the manual "drop a Caddy snippet, `incus restart ingress`" step
with self-registration: a project sets a few `user.ingress.*` config keys
on its own front-facing instance, and this reconciler discovers them and
regenerates `ingress`'s routes on its own. See `incus-host/README.md` and
`nightscout-podman/incus/MIGRATION.md`'s manual version of this step for
the convention this replaces — the file format doesn't change, only who
writes the files.

## Why now, not earlier

This was deliberately deferred when `ingress` was first built: the manual
file-drop convention was the right-sized answer for one project
(Nightscout) registering once. Two costs make it worth building now:
every new registration currently means editing that project's own deploy
step by hand (no worse than before, but doesn't scale attention), and —
more importantly — updating routes today requires `incus restart ingress`,
a brief interruption to *every* domain on the host, not just the one
being added. Fixing the second problem is this design's real point; the
self-registration ergonomics are a bonus that falls out of it.

## Registration contract

Any instance opts in by setting on itself:

```
incus config set <instance> user.ingress.domain=example.xlii.co
incus config set <instance> user.ingress.port=80
incus config set <instance> user.ingress.enabled=true
```

- `user.ingress.domain` — the public hostname to route.
- `user.ingress.port` — which port on that instance's own address to
  reverse-proxy to. Plain HTTP only (matches every existing route; this
  host has never had a project terminate TLS anywhere but `ingress`).
- `user.ingress.enabled` — explicit second gate, default absent = not
  registered. Without this, setting `domain` mid-provisioning (before the
  instance is actually ready to receive traffic) would register a route
  that 502s until the instance catches up. Requiring both means "route me"
  is a deliberate act, not a side effect of setting a domain for some
  other reason.

Nothing else. No path-based routing, no header rewriting, no TLS options
— any project needing more than a flat `domain -> ip:port` reverse proxy
keeps doing that internally (see `nightscout-podman`'s own `ns-caddy`,
which is exactly this: ingress hands it one flat route, `ns-caddy` does
its own `/mcp*`-vs-everything-else split behind that).

## Discovery

One pass, each run:

1. Query `GET /1.0/instances?recursion=2` against the **local unix
   socket** (`/var/lib/incus/unix.socket`), not the network HTTPS API.
   Read-only, but "read every instance's full config" is real platform-
   level visibility — running this on the host as root, over the socket
   Incus already trusts unconditionally, matches the same trust boundary
   this whole platform already relies on (see `daemon/authorization.star`'s
   own comment on scriptlet-based trust). Giving that same visibility to
   a *container* instead would mean minting it real credentials against
   the network API — a bigger, avoidable exposure for no benefit.
2. Filter to instances where `config["user.ingress.enabled"] == "true"`
   and `config["user.ingress.domain"]` is set.
3. For each match, resolve its current address from
   `state.network.eth0.addresses` (not a static assumption) — this is
   what makes DHCP-leased instances safe to register: the reconciler
   re-resolves the real current IP every pass, so a lease change heals
   within one poll interval instead of needing a static IP the way
   `incus-ui`/`authelia` need one today for the *manual* routes.
4. Conflict check: two instances claiming the same domain — log and skip
   both, don't silently pick one.

## Render

For each matched instance, write a route file at
`generated/<instance-name>.caddy`:

```caddyfile
{{domain}} {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "same-origin"
		-Server
	}

	reverse_proxy http://{{address}}:{{port}} {
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
```

Same shape as the hand-written routes already in `ingress/routes/` —
deliberately, so a generated file and a hand-written one are
indistinguishable to Caddy, and a project can graduate from one to the
other without changing what gets served.

**`generated/` is its own subdirectory, separate from the hand-maintained
`ingress/routes/` this repo's own `deploy.sh` pushes into.** The
reconciler only ever touches `generated/*.caddy` — it must never be able
to delete or overwrite `incus-ui.caddy`/`auth.caddy`. `ingress/Caddyfile`
imports both:

```caddyfile
import /etc/caddy/routes/*.caddy
import /etc/caddy/routes/generated/*.caddy
```

## Diff and apply

Idempotent, full-rebuild-each-pass:

1. Render the complete desired set of `generated/*.caddy` files in a
   scratch directory.
2. Compare against what's currently in the volume (a checksum per file is
   enough).
3. If nothing changed, exit — no reload, no log noise, no restart.
4. If anything changed: push the new/changed files, **delete any
   `generated/*.caddy` file that isn't in this pass's desired set**
   (this is how a deregistered or deleted instance's route actually goes
   away, not just accumulates), then apply.

**Apply, without paying the "every domain briefly drops" cost**: turn
`admin` back on in `ingress/Caddyfile` (removing `admin off`), but do
**not** expose it — Caddy's admin API defaults to binding
`127.0.0.1:2019` inside the container's own network namespace, and
`ingress.profile.yaml` gets no proxy device for it, so nothing on
`incusbr-ns` — nothing outside `incus exec` — can ever reach it. The
reconciler applies changes with:

```
incus exec ingress -- caddy reload --config /etc/caddy/Caddyfile
```

`incus exec` is itself a host-privileged operation (same trust boundary
as step 1's socket read), so this doesn't reopen the "anything on the
bridge can reprogram the front door" exposure flagged when the admin API
question first came up — it's reachable only from exactly the same place
that already has unconditional read access to every instance's config.
`caddy reload` is graceful: existing connections drain, only the domains
whose config actually changed see so much as a hiccup, and domains that
didn't change never blip at all. This is strictly better than the manual
convention's `incus restart ingress`, which the reconciler replaces for
every route it manages — hand-pushed routes still restart, since
`ingress/Caddyfile` will *have* an admin API available. Once the
reconciler exists, consider retiring the manual `incus restart ingress`
step from `deploy.sh` too, since `caddy reload` covers it just as well.

## Trigger

Plain cron, not a timer unit, not a new container — matches this
project's stated stance on not growing systemd's footprint for new
pieces. A 60-second poll interval, run as root on the host (needed for
socket + `incus exec` access either way):

```
* * * * * /root/incus-host/reconciler/reconcile.sh >> /var/log/ingress-reconciler.log 2>&1
```

No event-stream listener for v1 — a 60s worst-case registration delay is
fine for what this actually serves (a homelab standing up new projects
occasionally, not a system needing sub-second service discovery). Revisit
only if that latency ever actually bites.

## Failure modes worth having thought about before they happen

- **Instance renamed**: old route vanishes next pass (full-rebuild-each-
  pass handles this for free), new one appears under the new name.
  Momentary gap between the two passes if renamed mid-poll — acceptable.
- **Two instances, same domain**: both skipped, logged loudly. Never
  silently pick a winner.
- **Instance deleted without deregistering first**: same as rename — its
  route just isn't in the next rebuilt set, gone within one poll.
- **Reconciler script itself crashes mid-run**: cron just tries again in
  60s; nothing it does is destructive if interrupted (renders to a
  scratch dir first, only pushes/reloads after the full set is computed).
- **`caddy reload` fails** (bad generated Caddyfile syntax somehow):
  Caddy's own reload semantics refuse a bad config and keep serving the
  last-known-good one — log the failure, don't retry-loop, next cron tick
  will just try the same render again if the underlying cause hasn't
  changed.

## What v1 deliberately doesn't do

- No web UI, no API of its own — `user.ingress.*` + logs is the whole
  interface.
- No support for anything beyond flat domain -> ip:port HTTP. Path
  routing, redirects, header injection all stay the registering project's
  own problem, same as today.
- No retroactive migration of `incus-ui.caddy`/`auth.caddy` to the
  generated path — those stay hand-maintained by `deploy.sh`, since they
  aren't really "a project registering," they're this repo's own two
  built-in domains.
