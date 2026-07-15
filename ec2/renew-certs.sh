#!/usr/bin/env bash
# Renew the Let's Encrypt certificate and refresh the relay-readable copies.
# Let's Encrypt certs last ~90 days. Run this after a renewal, then restart the
# relay so it picks up the new cert. You can also wire the copy step as a
# certbot deploy hook (see ec2/README.md).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_var DOMAIN

log "Renewing certificates"
sudo certbot renew

log "Refreshing relay-readable copies in ${CERT_DIR}"
"$EC2_DIR/03-setup-certs.sh"

warn "Restart the relay (./ec2/run-relay.sh) so it loads the renewed certificate."
