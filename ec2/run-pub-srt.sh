#!/usr/bin/env bash
# Publish a live SRT ingest to the relay as a MoQ broadcast.
#
# ffmpeg receives an SRT stream (MPEG-TS), transcodes it to H.264/AAC, repackages
# it into fragmented MP4, and pipes it to moq-pub which speaks MoQ-over-QUIC to
# the relay. Transcoding guarantees the output is always compatible with moq-pub
# and browser players regardless of the source codecs.
#
# Usage:
#   ./run-pub-srt.sh                          # listener on :$SRT_PORT
#   SRT_MODE=caller SRT_HOST=1.2.3.4 ./run-pub-srt.sh
#
# Config (env vars, with defaults):
#   NAME        broadcast name              (default: bbb)
#   SRT_MODE    listener | caller           (default: listener)
#   SRT_PORT    SRT UDP port                (default: 9999)
#   SRT_HOST    remote host for caller mode (default: 0.0.0.0)
#   SRT_LATENCY SRT latency in ms           (default: 200)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_var DOMAIN
# shellcheck source=/dev/null
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

NAME="${NAME:-bbb}"
SRT_MODE="${SRT_MODE:-listener}"
SRT_PORT="${SRT_PORT:-9999}"
SRT_HOST="${SRT_HOST:-0.0.0.0}"
SRT_LATENCY="${SRT_LATENCY:-200}"

URL="https://${DOMAIN}:${PORT}"
SRT_URL="srt://${SRT_HOST}:${SRT_PORT}?mode=${SRT_MODE}&latency=${SRT_LATENCY}"

# Prefer the release binary; fall back to cargo run.
MOQ_PUB="$REPO_ROOT/target/release/moq-pub"
if [ ! -x "$MOQ_PUB" ]; then
	warn "release moq-pub not found; building it (cargo build --release --bin moq-pub)"
	( cd "$REPO_ROOT" && cargo build --release --bin moq-pub )
fi

# CMAF fragmentation flags required by moq-pub.
FRAG=(-f mp4 -movflags cmaf+separate_moof+delay_moov+skip_trailer+frag_every_frame)

log "SRT ingest: ${SRT_URL}"
log "Publishing broadcast '${NAME}' to ${URL} (transcode to H.264/AAC)"

# Always transcode: normalize to H.264 High / yuv420p + AAC stereo.
# -g 60 gives ~2s keyframe interval at 30fps so moq-pub segments cleanly.
#
# Timestamp handling: live SRT/MPEG-TS sources (e.g. OBS) can emit audio packets
# with missing PTS and out-of-range DTS ("pts has no value" / "Packet duration
# out of range"), which makes audio drop out after a few seconds while video
# keeps playing. -use_wallclock_as_timestamps 1 discards the broken source clock
# and stamps packets on arrival; -af aresample=async=1 regenerates a continuous
# audio PTS; -ar 48000 pins the sample rate so every frame matches the init moov.
ffmpeg -hide_banner \
	-use_wallclock_as_timestamps 1 \
	-i "$SRT_URL" \
	-map 0:v:0 -map 0:a:0 \
	-c:v libx264 -preset veryfast -tune zerolatency \
	-profile:v high -pix_fmt yuv420p \
	-g 60 -keyint_min 60 -sc_threshold 0 \
	-c:a aac -b:a 128k -ac 2 -ar 48000 -af aresample=async=1 \
	"${FRAG[@]}" \
	- | "$MOQ_PUB" --name "$NAME" "$URL"
