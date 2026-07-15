#!/usr/bin/env bash
# Start the moq-rs relay using the Let's Encrypt certificate.
# Any extra args are forwarded to ./dev/relay (and on to moq-relay-ietf).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_var DOMAIN
# shellcheck source=/dev/null
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

CERT="$CERT_DIR/fullchain.pem"
KEY="$CERT_DIR/privkey.pem"
[ -f "$CERT" ] || die "Missing $CERT — run ./03-setup-certs.sh first."

log "Starting relay on [::]:$PORT with cert for ${DOMAIN}"
cd "$REPO_ROOT"
# Setting CERT makes dev/relay skip its localhost self-signed generation.
CERT="$CERT" KEY="$KEY" PORT="$PORT" ./dev/relay "$@"
