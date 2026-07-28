#!/bin/sh
# Run before the control plane package is removed.
#
# The database is never touched here, on removal or on purge. It holds every account, every node
# and the sealed backhaul credentials, and nothing else has a copy: taking the software off a
# server is not the same statement as destroying the network it runs.
set -e

case "${1:-}" in
    upgrade|1) exit 0 ;;
esac

systemctl stop meshcp.service 2>/dev/null || true
systemctl disable meshcp.service 2>/dev/null || true

if [ -d /var/lib/meshcp ]; then
    echo "kept /var/lib/meshcp: it holds the accounts and the sealed backhaul credentials"
fi

exit 0
