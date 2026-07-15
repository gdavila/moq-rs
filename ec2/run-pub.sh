#!/usr/bin/env bash
# Start the Big Buck Bunny publisher against the local relay.
# Connects using $DOMAIN so the TLS hostname validates; the /etc/hosts loopback
# entry added by 03-setup-certs.sh keeps the traffic local (no UDP hairpin).
# Any extra args are forwarded to ./dev/pub (and on to moq-pub).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_var DOMAIN
# shellcheck source=/dev/null
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

log "Publishing broadcast 'bbb' to https://${DOMAIN}:${PORT}"
cd "$REPO_ROOT"
HOST="$DOMAIN" PORT="$PORT" ./dev/pub "$@"
