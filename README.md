# incus-host

Was declarative config for the Incus web UI + a traditional
username/password login in front of it (via Authelia, OIDC). **As of
2026-09-18, the actual config templates and the tool that applies them
both live in [`github.com/minihci/tink`](https://github.com/minihci/tink)**
(`configs/` and `tink deploy`, respectively) — this repo's role inverted
from "the thing that gets applied" to "design history and a reference
bash implementation," see below for exactly what's still here and why.

Originally split out of `nightscout-podman` deliberately (that repo is
about one T1D monitoring stack on one box; this was foundational
Incus-host infrastructure that stack happened to run *on*), then this
repo's own config templates moved again into `tink` once `tink deploy`
existed for real — a tool and the templates it renders don't need to be
two repos just because they started in two places. See `tink`'s own
README ("Relationship to `incus-host`") for the fuller reasoning.

## What's still here, and why

| path | purpose |
|---|---|
| `reconciler/reconcile.sh` + `reconciler/DESIGN.md` | the ingress self-registration mechanism's reference bash implementation and full design writeup — kept for history and for the design reasoning, even though `tink daemon run` (the Go port) is what's actually running this on every real host now |
| `scripts/generate-authelia-secrets.sh` | one-time per host: generates every secret via Authelia's own CLI — still real, still used, has no config template to move |
| `scripts/push-to-host.sh` | syncs this (now much smaller) repo's tracked files to a host |

Everything else — `daemon/authorization.star`, `daemon/server-config.yaml`,
the `incus-ui`/`authelia`/`ingress` profile YAMLs, Authelia's
`configuration.yml`, the `ingress` Caddyfile and its hand-maintained
routes, `deploy.env.example` — moved to `tink/configs/`
([layout + purpose of each](https://github.com/minihci/tink/blob/main/configs/README.md)).
`scripts/deploy.sh` is gone with them (it read exactly those files); use
`tink deploy` instead — see `tink`'s own README for building/running it.

## Why Incus has no native permission groups

The web UI (`zabbly/incus-ui-canonical`, a fork of `canonical/lxd-ui`) ships
full "Permissions" pages — identities, groups, IDP group mapping. They
don't work against Incus: that's an LXD-only feature (LXD forked from
Incus and built its own proprietary fine-grained authorization system).
Incus itself only ever supported three authorization methods — TLS,
OpenFGA, and Scriptlet (`doc/authorization.md` in the incus repo) — and
this platform uses the third,
[`tink/configs/daemon/authorization.star`](https://github.com/minihci/tink/blob/main/configs/daemon/authorization.star):
trust anyone who authenticated through Authelia, or who holds a trusted
TLS client cert (`incus config trust add` — this is what cross-host
automation like `tink`'s volume-backup story authenticates as). Good
enough for one admin; if that stops being true, look at OpenFGA instead
of growing the scriptlet.

## Deploying a fresh host

Now `tink`'s job end to end — see that repo's README for building it and
`configs/README.md` for the layout of what `--repo-root` points at
(`tink`'s own `configs/` by default). Roughly:

```
git clone https://github.com/minihci/tink && cd tink
go build -o tink ./cmd/tink   # or fetch a prebuilt binary
cp configs/deploy.env.example configs/deploy.env    # fill in
# generate-authelia-secrets.sh hasn't moved -- run it from a checkout of
# *this* repo instead, pointing its output at tink's configs/ below
/path/to/incus-host/scripts/generate-authelia-secrets.sh
# fill in configs/authelia/users_database.yml from users_database.yml.example
./tink deploy
```

## Network shape

```
Browser → Caddy (ingress, public :80/:443)
              ├─→ incus-ui (internal) ──→ Incus API (internal)
              └─→ Authelia (internal)
Incus daemon  → Authelia directly (server-to-server, verifies OIDC tokens)
```

Only `ingress` ever touches the public interface — `incus-ui`, Authelia,
and the Incus API itself all stay off it entirely, reached only over the
Incus-managed bridge network. `incus-ui`'s own internal Caddy handles the
`/1.0*`-vs-API split at `ingress` itself now (moved there so `incus-ui`'s
image stays a pure static-file server — see `minihci/incus-ui`); it just
no longer terminates public TLS or owns a public port — that moved to
`ingress` so that other projects on this same host (nightscout-podman's
`nightscout-caddy`, for one) can get a public domain without ever
touching this repo or `tink/configs/`: they self-register by setting
`user.ingress.{domain,port,enabled}` on their own front-facing instance,
and the reconciler (`reconciler/reconcile.sh`'s design, now running as
`tink daemon run`) discovers it and generates the route on its own — see
`reconciler/DESIGN.md`.

## What this doesn't cover

- **Multiple admins.** One Authelia user today. Adding a second is
  mechanical (another entry in `users_database.yml`) but this repo doesn't
  script it, and the authorization scriptlet doesn't distinguish between
  users at all yet — see "Why Incus has no native permission groups" above.
- **Backups.** `incus storage volume snapshot` gives volume-level
  snapshotting for the persistent state (Caddy certs, Authelia db) for
  free — not wired up here, just noted as available, same as
  `nightscout-podman/incus/README.md` flags for its own workload.
- **A second bridge network per host colliding with the first.** `deploy.env`
  assumes one Incus-managed bridge with one DHCP range; if a host runs
  more than one, you'll need to adapt `tink/configs/authelia/authelia.profile.yaml`'s
  static-IP placement by hand.
