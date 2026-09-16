# Incus has no built-in fine-grained permission/identity groups system (that's
# an LXD-only feature the web UI's "Permissions" pages assume but Incus never
# implemented — see README.md). This is the whole authorization policy: trust
# anyone who made it through the OIDC login (Authelia) at all. Fine for a
# single-admin host; if that stops being true, look at OpenFGA instead of
# growing this script — see https://linuxcontainers.org/incus/docs/main/authorization/
#
# `details.RequestDetails.Protocol` is confirmed correct on Incus 7.4 only —
# Incus changed this internal shape once already between 6.0 and 7.x with no
# changelog entry (it used to be the flatter `details.Protocol`). If this
# stops working on a different host's Incus version, it fails quietly on
# list endpoints (empty results, no error) but loudly on a direct fetch:
#   incus query /1.0/projects/default
# will show the real Starlark error ("Invalid field ..."), which tells you
# the new field path to use.
def authorize(details, object, entitlement):
    if details.RequestDetails.Protocol == "oidc":
        return True
    return False
