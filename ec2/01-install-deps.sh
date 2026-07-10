#!/usr/bin/env bash
# Install build toolchain, media tools, and the Rust toolchain needed to build
# and run moq-rs on Ubuntu.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "Installing system packages (build toolchain, ffmpeg, etc.)"
sudo apt update
sudo apt install -y \
	build-essential pkg-config cmake clang libclang-dev \
	git curl wget ffmpeg
# golang-go is only needed for the localhost self-signed dev cert (./dev/cert).
# We use Let's Encrypt instead, so it is optional; uncomment if you want it.
# sudo apt install -y golang-go

if command -v cargo >/dev/null 2>&1; then
	log "Rust toolchain already installed ($(cargo --version))"
else
	log "Installing Rust toolchain via rustup"
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

# Make cargo available in this shell for subsequent scripts.
# shellcheck source=/dev/null
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

log "Dependencies installed. cargo: $(cargo --version 2>/dev/null || echo 'restart your shell / run: source \$HOME/.cargo/env')"
