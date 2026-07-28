#!/bin/sh
# Run after the node package is installed or upgraded.
set -e

systemctl daemon-reload 2>/dev/null || true

case "${1:-}" in
    # Debian passes "configure <old-version>"; rpm passes "2" for an upgrade. Either way an
    # upgrade should restart what was already running and start nothing that was not.
    configure|2)
        if systemctl is-enabled meshd.service >/dev/null 2>&1; then
            systemctl try-restart meshd.service || true
        fi
        ;;
esac

if ! systemctl is-enabled meshd.service >/dev/null 2>&1; then
    systemctl enable meshd.service >/dev/null 2>&1 || true
    systemctl start meshd.service || true
    cat <<'EOF'

mesh installed. The daemon is running but has not joined a network yet:

    meshctl join <enrollment-key>

Mint a key on the control plane with `meshctl enrollment-key`.
EOF
fi

exit 0
