#!/bin/sh
# Run after the control plane package is installed or upgraded.
#
# The one job that matters here is making sure MESH_CP_SECRET exists. Unset, meshcp generates an
# ephemeral key at startup and every stored Cloudflare and Tailscale token becomes unreadable at
# the next restart. That is the loudest footgun in the project and an installer is the right
# place to remove it.
set -e

ENV_FILE=/etc/meshcp/meshcp.env

if [ -f "$ENV_FILE" ] && ! grep -q '^MESH_CP_SECRET=..*' "$ENV_FILE"; then
    secret=""
    if [ -r /dev/urandom ]; then
        secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    fi
    if [ -z "$secret" ] && command -v openssl >/dev/null 2>&1; then
        secret=$(openssl rand -hex 32)
    fi
    if [ -n "$secret" ]; then
        # Rewritten in place rather than appended, so the file keeps one MESH_CP_SECRET line
        # and the comment above it still explains what it is.
        tmp=$(mktemp)
        sed "s|^MESH_CP_SECRET=.*|MESH_CP_SECRET=$secret|" "$ENV_FILE" > "$tmp"
        cat "$tmp" > "$ENV_FILE"
        rm -f "$tmp"
        chmod 0600 "$ENV_FILE"
        echo "generated MESH_CP_SECRET in $ENV_FILE; back it up with the database"
    else
        echo "WARNING: could not generate MESH_CP_SECRET; set one in $ENV_FILE before starting"
    fi
fi

systemctl daemon-reload 2>/dev/null || true

case "${1:-}" in
    configure|2)
        if systemctl is-enabled meshcp.service >/dev/null 2>&1; then
            systemctl try-restart meshcp.service || true
            exit 0
        fi
        ;;
esac

systemctl enable meshcp.service >/dev/null 2>&1 || true
systemctl start meshcp.service || true

exit 0
