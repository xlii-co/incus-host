# incus-host

Declarative config for the Incus web UI + a traditional username/password
login in front of it (via Authelia, OIDC), meant to be applied to more than
one Incus host — this VPS today, home lab boxes later. Everything that
differs between hosts lives in one file, `deploy.env`; everything else here
is generic.

Split out of `nightscout-podman` deliberately: that repo is about one T1D
monitoring stack on one box. This is foundational Incus-host infrastructure
that stack happens to run *on*, not something specific to it.

## Why Incus has no native permission groups

The web UI (`zabbly/incus-ui-canonical`, a fork of `canonical/lxd-ui`) ships
full "Permissions" pages — identities, groups, IDP group mapping. They
don't work against Incus: that's an LXD-only feature (LXD forked from
Incus and built its own proprietary fine-grained authorization system).
Incus itself only ever supported three authorization methods — TLS,
OpenFGA, and Scriptlet (`doc/authorization.md` in the incus repo) — and
this repo uses the third, `daemon/authorization.star`: trust anyone who
authenticated through Authelia. Good enough for one admin; if that stops
being true, look at OpenFGA instead of growing the scriptlet.

## Layout

| path | purpose |
|---|---|
| `deploy.env.example` | per-host values — copy to `deploy.env`, fill in, never commit |
| `incus-ui/Containerfile` | multi-stage build: `incus-ui-canonical`'s static UI + a custom Caddy (matches `nightscout-podman/caddy/Containerfile`'s build) |
| `incus-ui/Caddyfile` | serves the UI, reverse-proxies the Incus API and Authelia; reads its own env vars, no templating step |
| `incus-ui/incus-ui.profile.yaml` | Incus profile template for the above, as an OCI application container |
| `authelia/configuration.yml` | Authelia config — safe to commit as-is, see the comment at its top for how secrets and per-host domains get resolved without ever being written to this file |
| `authelia/users_database.yml.example` | shape only; the real file has a real password hash and isn't committed |
| `authelia/authelia.profile.yaml` | Incus profile template for Authelia, official upstream image |
| `daemon/authorization.star` | the whole authorization policy — see above |
| `daemon/server-config.yaml` | Incus server-config template (OIDC, authorization, trusted proxy); applied as one `incus config edit`, same pattern as the profile templates above |
| `scripts/generate-authelia-secrets.sh` | one-time per host: generates every secret via Authelia's own CLI |
| `scripts/publish-incus-ui.sh` | builds + pushes the `incus-ui` image to your registry |
| `scripts/deploy.sh` | applies everything above to whatever host `incus` is pointed at |

## Apply order (fresh host)

Assumes an Incus daemon already exists on the target (storage pool,
`incus` CLI pointed at it — see `nightscout-podman/incus/preseed.yaml` for
how that gets bootstrapped in the first place) and both domains' DNS
already resolve to it.

```
cp deploy.env.example deploy.env    # fill in
scripts/publish-incus-ui.sh          # needs: podman login <your registry>
scripts/generate-authelia-secrets.sh # needs: podman (pulls authelia/authelia once)
# fill in authelia/users_database.yml from users_database.yml.example,
# using the password hash generate-authelia-secrets.sh just printed
scripts/deploy.sh
```

Re-running `scripts/deploy.sh` after changing anything is the normal way
to apply an edit — it's idempotent, and recreates `incus-ui`/`authelia`
from scratch rather than leaving them half-updated. Their persistent state
(Caddy's TLS certs, Authelia's session db, its own config) lives in
storage volumes deploy.sh creates once and never touches again, so
recreating the containers doesn't lose either.

## Network shape

```
Browser → Caddy (incus-ui, public :80/:443)
              ├─→ Authelia (internal only, auth domain)
              └─→ Incus API (internal only, incus daemon)
Incus daemon  → Authelia directly (server-to-server, verifies OIDC tokens)
```

Only `incus-ui` ever touches the public interface — Authelia and the Incus
API itself stay off it entirely, reached only over the Incus-managed
bridge network.

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
  more than one, you'll need to adapt `authelia/authelia.profile.yaml`'s
  static-IP placement by hand.
