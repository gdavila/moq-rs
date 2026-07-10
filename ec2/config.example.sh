# shellcheck shell=bash
# Copy this file to `config.sh` and fill in your values:
#   cp config.example.sh config.sh && edit config.sh
#
# config.sh is git-ignored so your DuckDNS token never gets committed.
# All ec2/ scripts source config.sh automatically.

# Your DuckDNS subdomain (the full hostname), e.g. moq-gabriel.duckdns.org
export DOMAIN="your-name.duckdns.org"

# Email used for Let's Encrypt registration / expiry notices.
export EMAIL="you@example.com"

# DuckDNS token from https://www.duckdns.org (top of the page once logged in).
# Required only for issuing/renewing the certificate.
export DUCKDNS_TOKEN="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Where the relay-readable copies of the certs live (owned by your user).
export CERT_DIR="$HOME/moq-certs"

# QUIC/WebTransport port the relay listens on (UDP + TCP in the security group).
export PORT="4443"
