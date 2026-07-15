#!/usr/bin/env bash
# One-shot installer: prepares a fresh Ubuntu EC2 instance to run moq-rs as a
# pub/relay with a valid Let's Encrypt (DuckDNS) TLS certificate.
#
# Usage:
#   cp config.example.sh config.sh   # then edit config.sh
#   ./setup.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_var DOMAIN
require_var EMAIL
require_var DUCKDNS_TOKEN

log "moq-rs EC2 setup for ${DOMAIN}"

"$EC2_DIR/01-install-deps.sh"
"$EC2_DIR/02-issue-cert.sh"
"$EC2_DIR/03-setup-certs.sh"

# Ensure cargo is on PATH for the build.
# shellcheck source=/dev/null
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

log "Building moq-rs binaries (relay, pub, sub) — this can take a few minutes"
cd "$REPO_ROOT"
cargo build --release --bin moq-relay-ietf --bin moq-pub --bin moq-sub

cat <<EOF

$(printf '\033[1;32m✓ Setup complete.\033[0m')

Next steps:
  1. Open your EC2 Security Group: allow UDP $PORT and TCP $PORT inbound.
  2. Start the relay:      ./ec2/run-relay.sh
  3. In another shell,
     start the publisher:  ./ec2/run-pub.sh
  4. Test playback from your laptop:
     moq-sub --name bbb 'https://${DOMAIN}:${PORT}' | ffplay -

Certs auto-renew via certbot; run ./ec2/renew-certs.sh after renewal (or wire it
as a deploy hook) to refresh the relay-readable copies.
EOF
