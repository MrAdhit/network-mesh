#!/bin/sh
# Run before the node package is removed.
#
# Stops the daemon, and nothing else. Deregistering belongs in postremove, where an upgrade can
# be told apart from a removal: taking a node out of its network because a package was being
# replaced by a newer copy of itself would be its own kind of outage.
set -e

case "${1:-}" in
    upgrade|1) exit 0 ;;
esac

systemctl stop meshd.service 2>/dev/null || true
systemctl disable meshd.service 2>/dev/null || true

exit 0
