#!/usr/bin/env bash
# Copy the root-owned Let's Encrypt PEMs to a user-readable directory so the
# relay (run as your user via cargo) can read them, and add a loopback
# /etc/hosts entry so a same-box publisher avoids UDP hairpinning.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_var DOMAIN

LIVE="/etc/letsencrypt/live/${DOMAIN}"
[ -f "$LIVE/fullchain.pem" ] || die "No cert found at $LIVE — run ./02-issue-cert.sh first."

log "Copying certs to ${CERT_DIR} (owned by ${USER})"
mkdir -p "$CERT_DIR"
sudo cp "$LIVE/fullchain.pem" "$LIVE/privkey.pem" "$CERT_DIR/"
sudo chown "$USER:$USER" "$CERT_DIR"/*.pem
chmod 600 "$CERT_DIR/privkey.pem"

# Loopback entry: lets a publisher on this same box connect to $DOMAIN without
# hairpinning out to the public Elastic IP over UDP, while the TLS hostname
# still validates against the cert.
if grep -q "127.0.0.1[[:space:]].*${DOMAIN}" /etc/hosts; then
	log "/etc/hosts already maps ${DOMAIN} -> 127.0.0.1"
else
	log "Adding loopback entry for ${DOMAIN} to /etc/hosts"
	echo "127.0.0.1 ${DOMAIN}" | sudo tee -a /etc/hosts > /dev/null
fi

log "Cert setup complete:"
log "  CERT=${CERT_DIR}/fullchain.pem"
log "  KEY=${CERT_DIR}/privkey.pem"
