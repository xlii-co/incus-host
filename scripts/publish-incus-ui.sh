#!/usr/bin/env bash
# Manual, local publish step for incus-ui's image — for a registry that
# isn't GHCR (a home lab's own local registry, say), or for smoke-testing
# a build before trusting it. If IMAGE_REGISTRY is ghcr.io/<owner>, prefer
# .github/workflows/publish-incus-ui.yml (gh workflow run
# publish-incus-ui.yml -f tag=<tag>) instead — same manual-trigger policy,
# just built on GitHub's infra instead of whatever machine this runs on.
#
# Either way, publishing stays a deliberate, confirmed step, never
# something that fires on every push — same policy nightscout-podman uses
# for its own OCI pilot. And whichever you use, this is also the way to
# validate a bumped incus-ui/Containerfile's INCUS_UI_REF before trusting
# it — see that file's own comment on why that pin needs an actual build,
# not just a glance at the commit.
#
# One-time setup: podman login <registry>
#
# Usage: scripts/publish-incus-ui.sh [tag]   (defaults to "latest")
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f deploy.env ]; then
  echo "deploy.env not found — copy deploy.env.example, fill it in, and try again." >&2
  exit 1
fi
set -a; source deploy.env; set +a

tag="${1:-latest}"
image="${IMAGE_REGISTRY}/incus-ui:${tag}"

podman build -f incus-ui/Containerfile -t "$image" incus-ui
podman push "$image"

echo "Published $image"
echo "scripts/deploy.sh pulls this automatically — nothing else to do by hand."
