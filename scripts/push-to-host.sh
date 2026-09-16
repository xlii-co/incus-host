#!/usr/bin/env bash
# Syncs this repo's tracked files to an Incus host. scripts/deploy.sh (and
# the other scripts here) only run *on* that host, against its own local
# `incus` CLI — this repo isn't runnable from a dev machine, so getting
# the files there is a separate step.
#
# Pushes exactly `git ls-files` — whatever's actually committed/staged —
# so secrets/, deploy.env, and authelia/users_database.yml (all
# .gitignored, all host-owned; see README.md's "Secrets — NOT in this
# repo") never leave this machine. No --delete: a file removed here isn't
# removed there automatically, matching this project's existing "secrets
# stay hand-managed on the host" philosophy rather than trusting an rsync
# flag not to reach into the same directory's untracked, host-owned files.
#
# No default host: this repo is meant to apply to more than one Incus
# host (see README.md), so a silent default would just be tomorrow's
# stale-value bug — same class as the hardcoded IPs this repo has already
# had to fix twice.
#
# Usage: scripts/push-to-host.sh <user@host> [remote-path]
#   remote-path defaults to ~/incus-host (resolved by the remote shell,
#   i.e. relative to whatever user you connect as).
#
# If the host isn't in ~/.ssh/config, set RSYNC_RSH first, e.g.:
#   RSYNC_RSH="ssh -i ~/.ssh/id_ed25519" scripts/push-to-host.sh root@incus.xlii.co
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo "Usage: scripts/push-to-host.sh <user@host> [remote-path]" >&2
  exit 1
fi
target="$1"
remote_path="${2:-~/incus-host}"

git ls-files -z | rsync -av --files-from=- --from0 . "${target}:${remote_path}/"

echo
echo "Pushed to ${target}:${remote_path}"
echo "Secrets, deploy.env, and users_database.yml were NOT touched — those"
echo "stay exactly as already set up on the host."
