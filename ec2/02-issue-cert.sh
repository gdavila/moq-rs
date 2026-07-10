#!/usr/bin/env bash
# Install certbot + the DuckDNS DNS plugin and issue a Let's Encrypt certificate
# for $DOMAIN using the DNS-01 challenge (works even without inbound port 80).
#
# NOTE: Let's Encrypt refuses to issue certs for AWS-owned hostnames like
# *.compute-1.amazonaws.com, which is why we use a DuckDNS subdomain instead.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_var DOMAIN
require_var EMAIL
require_var DUCKDNS_TOKEN

log "Installing certbot (snap) and the DuckDNS plugin"
sudo snap install core && sudo snap refresh core
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/local/bin/certbot

sudo snap install certbot-dns-duckdns
sudo snap set certbot trust-plugin-with-root=ok
sudo snap connect certbot:plugin certbot-dns-duckdns

log "Writing DuckDNS credentials to /etc/letsencrypt/duckdns.ini"
sudo mkdir -p /etc/letsencrypt
sudo tee /etc/letsencrypt/duckdns.ini > /dev/null <<EOF
dns_duckdns_token = ${DUCKDNS_TOKEN}
EOF
sudo chmod 600 /etc/letsencrypt/duckdns.ini

log "Issuing certificate for ${DOMAIN} via DNS-01"
sudo certbot certonly \
	--authenticator dns-duckdns \
	--dns-duckdns-credentials /etc/letsencrypt/duckdns.ini \
	--dns-duckdns-propagation-seconds 60 \
	--preferred-challenges dns \
	--agree-tos --no-eff-email \
	-m "${EMAIL}" \
	-d "${DOMAIN}"

log "Certificate issued. Files:"
log "  /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
log "  /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
