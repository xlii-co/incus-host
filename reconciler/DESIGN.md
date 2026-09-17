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
specifically — nothing else.

**Confirmed possible in principle, 2026-09-16, against Incus's actual
authorization docs** — the mechanism just isn't wired up yet. The
scriptlet's `authorize(details, object, entitlement)` function (Starlark;
`daemon/authorization.star` already has one, routed to via
`authorization.client.{oidc,tls,tls-restricted}` in
`daemon/server-config.yaml`) receives real per-identity, per-resource
granularity, not just a client class:

- `details.Username` — for a TLS client, this is the **certificate's
  fingerprint**, individually distinguishable. Mint the reconciler its
  own certificate, and the scriptlet can check for that exact fingerprint
  rather than "any TLS client."
- `object` — the specific resource the request is about (a specific
  instance, e.g. `ingress`, not "any instance").
- `entitlement` — the specific permission requested (view vs. exec vs.
  update are distinct, not one blob).

So `authorize()` can express "this exact identity, on this exact object,
for this exact action" — in principle, an instance-and-action-scoped
grant for the reconciler is expressible. There's also a coarser,
zero-custom-code layer worth using as a first step regardless:
`incus config trust add --restricted --projects default` mints a
certificate Incus itself confines to one project and blocks from any
global server config change, no scriptlet logic needed at all — real
restriction, just project-granularity rather than instance-granularity.

**Resolved further, 2026-09-16 (later session): the two options above
aren't interchangeable — they solve different-shaped problems.** The
project-restricted client is a single flat gate — "this cert may act
inside project X" — with no distinction between view and exec, and no
distinction between instances within that project. But the reconciler's
job is asymmetric: it needs to *view* configs across every project that
might self-register (any current or future tenant), while *exec*ing only
into `ingress` specifically. A project-restricted client can't express
that split — granting it view of every tenant project means listing each
one explicitly (reintroducing the manual per-project step self-
registration was built to remove), or it can't see projects it wasn't
granted into at all. The scriptlet is the only one of the two that can
express "broad view, narrow act," since `object` and `entitlement` are
independent inputs to `authorize()`. So *if* this gets built, it's the
scriptlet — the restricted client isn't a simpler version of the same
fix, it's a worse fit for this specific job.

**The bigger reason it's still not built: scoping is decorative unless
the reconciler also stops running as host root.** A scoped TLS identity
only restricts requests made *through the network API*. As long as
`reconcile.sh` runs as root on the bare host with access to
`/var/lib/incus/unix.socket`, it — or anything that compromises it — can
always fall back to that unscoped local socket regardless of what
certificate or scriptlet grant exists; the two paths coexist, and the
socket is strictly more powerful. An actually-meaningful scoped identity
requires *also* moving the reconciler off the host into its own
container with no local socket access, which reopens this doc's
"Discovery" section's tradeoff in the other direction (host-level
script, no network attack surface, in exchange for unrestricted local
access). Scoping and de-hosting are a package deal — doing one without
the other is mostly documentation of intent, not a real boundary.

**This is a platform-wide question, not specific to this script** —
expect the same shape to recur for any future host-level automation
(backup jobs, health checks, metrics scraping, cert rotation, etc.), so
the answer is worth generalizing rather than re-deriving per script:

1. Ask placement first, before any permission design: does new
   automation need to be host-level at all, or can it run in its own
   container talking only over the network API? Container placement is
   what makes a scoped identity real; host placement makes it decorative,
   per above.
2. If a scoped identity is ever built for anything, build one generic
   `identity -> {view, exec}` capability table inside a single scriptlet,
   not bespoke `authorize()` logic per script — so the *next*
   reconciler-shaped thing is a cert plus one table row, not a new
   design. Incus projects, if a platform/tenant project split ever
   happens on this host, become a field that table can reference (e.g.
   `"view": "project:nightscout"`), not a competing enforcement
   mechanism.

**Still unresolved**: how much scriptlet logic the instance-level check
actually takes to get right in practice — whether matching `object`
against "specifically the `ingress` instance" is a one-line comparison or
something messier once real code is written against it — and, now, the
larger open question of whether/when de-hosting the reconciler into its
own container is worth the network attack surface it (re-)introduces.
Worth prototyping before deciding, not assumed either way.

## Future extension: opt-in SSO via `forward_auth`

Not built, not decided — sketched 2026-09-16 as the natural next
generalization of the same idea this whole reconciler is built on: a
project shouldn't need a manual step to get something the platform
already knows how to do. Today that's "get a public domain." The same
argument applies to "require login before anyone reaches this" — right
now that protection only exists hand-wired for `incus-ui`/`auth.xlii.co`
themselves, nothing a tenant project can opt into.

**The shape, if built:** one more registration key, `user.ingress.auth`,
alongside `domain`/`port`/`enabled`. When set to `true`, the reconciler
renders that instance's route with a `forward_auth` block pointing at
Authelia instead of a bare `reverse_proxy` — the same mechanism, not a
new one, that already protects `incus-ui` today, just generated instead
of hand-written. This is a direct exception to the Registration
contract's "nothing else, no path routing, no header rewriting" line
above — the one deliberate addition worth making if this gets built, not
a sign that line was wrong.

**Two ways to do it, genuinely different in cost:**

- **Broad policy (cheap):** one Authelia access-control rule — "a valid
  session is enough for anything under `*.xlii.co`" — with Caddy's
  `forward_auth` decision (present or absent per route) as the actual
  per-app gate. The reconciler never touches Authelia's own config, only
  Caddy's, same single-system blast radius as today's design.
- **Per-app/per-group policy (expensive):** different user groups allowed
  into different services. This needs the reconciler to also manage
  Authelia's `access_control` rules, not just Caddy's routes — a second
  system it writes to, a materially bigger scope than anything built so
  far.

**Recommendation, if this ever gets picked up:** the broad-policy version
first, for the same reason the scoped-identity question above stays
deferred — build the general, cheap case when something actually asks
for "logged in or not," and only reach for per-app policies once a real
workload needs finer control than that.

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
