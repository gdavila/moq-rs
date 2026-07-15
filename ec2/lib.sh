# shellcheck shell=bash
# Shared helpers sourced by the ec2/ scripts. Not meant to be run directly.

set -euo pipefail

EC2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EC2_DIR/.." && pwd)"

# Load config.sh (created from config.example.sh).
if [ -f "$EC2_DIR/config.sh" ]; then
	# shellcheck source=/dev/null
	source "$EC2_DIR/config.sh"
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_var() {
	local name="$1"
	local val="${!name:-}"
	if [ -z "$val" ]; then
		die "$name is not set. Copy ec2/config.example.sh to ec2/config.sh and fill it in."
	fi
}

# Defaults for anything not provided by config.sh.
: "${CERT_DIR:=$HOME/moq-certs}"
: "${PORT:=4443}"
