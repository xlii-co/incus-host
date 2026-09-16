#!/usr/bin/env bash
# Manual publish step for incus-ui's image. NOT run by CI, on purpose —
# same policy nightscout-podman uses for its own OCI pilot: deploying (and
# here, publishing) stays a manual, confirmed step, not something that
# fires on every push.
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
