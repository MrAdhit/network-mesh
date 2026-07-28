#!/bin/sh
# Run after the node package is removed.
#
# Debian semantics, deliberately. `remove` takes the software off and leaves /var/lib/mesh, so
# reinstalling comes back as the same node with the same address. `purge` is the statement that
# this machine is leaving the network, and only then is the registration given back.
#
# It matters which one you use: a removed-but-not-purged node still holds an address in its
# owner's subnet, and nothing on the control plane can tell that its machine is gone.
set -e

systemctl daemon-reload 2>/dev/null || true

case "${1:-}" in
    purge|0)
        # `--keep-account` is not passed: purging is exactly when the record should go.
        if [ -x /usr/lib/mesh/uninstall.sh ]; then
            /usr/lib/mesh/uninstall.sh --prefix /usr || true
        else
            rm -rf /var/lib/mesh /etc/mesh
        fi
        rm -rf /usr/lib/mesh
        ;;
    *)
        # remove, upgrade, or an rpm that is being replaced. Say what was kept, because the
        # difference is invisible otherwise and only shows up as a ghost node months later.
        if [ -d /var/lib/mesh ]; then
            echo "kept /var/lib/mesh and this node's registration; 'apt purge mesh' to leave the network"
        fi
        ;;
esac

exit 0
