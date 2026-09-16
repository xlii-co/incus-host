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
   **Be honest about what this actually grants**: root on the local socket
   is not a scoped, read-only view — it's the exact same unrestricted
   access the `incus` CLI itself has (create/delete/reconfigure anything,
   on any instance). The reconciler *choosing* to only read configs and
   `exec` into `ingress` describes this script's current behavior, not a
   real privilege boundary — a bug or a compromised dependency here has
   the blast radius of "full control of this Incus daemon," not "can see
   some configs." Running it as a host-level script rather than inside a
   container avoids handing that same unrestricted power to something
   with a network attack surface too, which is a real reason to prefer
   this shape — but it is not the same claim as "this access is scoped,"
   and earlier drafts of this doc conflated the two. See "Open question"
   at the end for what an actually-scoped version might look like.
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
`admin` back on in `ingress/Caddyfile` (removing `admin off`) so
`caddy reload` (Caddy's own graceful reload, no restart, existing
connections drain, unrelated domains never blip) is available at all.
`ingress.profile.yaml` gets no proxy device for the admin API's default
`127.0.0.1:2019` bind, so nothing on `incusbr-ns` can reach it directly.
The reconciler applies changes with:

```
incus exec ingress -- caddy reload --config /etc/caddy/Caddyfile
```

**What this does and doesn't actually buy you, stated plainly**: keeping
the admin API off the bridge is a real, correct piece of hygiene — it
closes one specific path (anything else on `incusbr-ns` calling it
directly). It is not, on its own, a meaningful security boundary against
the reconciler itself, or against anything else with host root: that
same actor could push an arbitrary Caddyfile via `incus file push` or
just `incus restart ingress` outright, neither of which the admin API's
exposure has any bearing on. So "the admin API is locked away" and "this
is safe because of the trust boundary" are two different claims — the
first is true and worth keeping, the second doesn't actually follow from
it, since host root already has total authority over `ingress` through
several other doors regardless. The genuine safety property here is
narrower than earlier drafts of this doc implied: `caddy reload` over
`incus exec` is a *convenient and graceful* way to apply changes, not a
*restricted* one. See "Open question" below for what actual restriction
would take.

This is still strictly better than the manual convention's
`incus restart ingress` for the routes it replaces — hand-pushed routes
(`incus-ui.caddy`, `auth.caddy`) still go through a full restart on
change, since those are `deploy.sh`'s own concern, not the reconciler's.

## Open question: what would an actually-scoped identity look like?

The reconciler's real privilege today is "full root on this Incus
daemon," used narrowly. A genuinely least-privilege version would give it
an identity that can only read instance configs and reload `ingress`
specifically — nothing else. Incus's own restricted-client mechanism
(`authorization.client.tls-restricted`, already referenced in
`daemon/server-config.yaml` for a different purpose, backed by the same
Starlark scriptlet authorization model `daemon/authorization.star` already
uses for OIDC) is the most likely place this would live — mint the
reconciler a TLS client certificate, and have the scriptlet's `authorize()`
function grant it exactly the two permissions it needs rather than the
current "anyone through OIDC, or the local socket, gets everything" logic.
Genuinely unresolved whether Incus's scriptlet model can express
per-identity, per-instance, per-action grants this granular, or whether it
only really distinguishes coarser classes of client (as it does today,
`oidc` vs `tls` vs `tls-restricted`, without acting differently based on
*which* restricted client it is). Worth a real investigation before
building it — not assumed to be straightforward just because the pieces
exist.

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
