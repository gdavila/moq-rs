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
#
# NOTE: frag_every_frame is intentionally NOT used. When both video and audio
# are re-encoded live, ffmpeg's mp4 muxer (movenc) mis-estimates the audio
# track duration on the per-frame fragment flushes, clamping every audio
# packet ("Packet duration: -1024 ... out of range" / "pts has no value").
# The corrupted audio fragment timeline makes players drop audio after a few
# seconds. Time-based fragmentation (-frag_duration) gives the same per-frame
# chunking without triggering the bug. 16ms is below the frame duration up to
# 60fps, so every video frame still gets its own fragment.
FRAG=(-f mp4 -movflags cmaf+separate_moof+delay_moov+skip_trailer -frag_duration 16000)

log "SRT ingest: ${SRT_URL}"
log "Publishing broadcast '${NAME}' to ${URL} (transcode to H.264/AAC)"

# Always transcode: normalize to H.264 High / yuv420p + AAC stereo.
# -g 60 gives ~2s keyframe interval at 30fps so moq-pub segments cleanly.
#
# Timestamp handling: setpts/asetpts rebase both streams to start at 0
# (preserving the source's timing and A/V sync) so downstream tooling sees a
# zero-based timeline regardless of the source's MPEG-TS PCR origin; aresample
# guards against SRT burst jitter; -ar 48000 pins the rate to match the init
# moov.
# NOTE: do NOT use -use_wallclock_as_timestamps here — on bursty SRT it collapses
# packet deltas to ~0 and produces negative durations.
ffmpeg -hide_banner \
	-i "$SRT_URL" \
	-map 0:v:0 -map 0:a:0 \
	-c:v libx264 -preset veryfast -tune zerolatency \
	-profile:v high -pix_fmt yuv420p \
	-g 60 -keyint_min 60 -sc_threshold 0 \
	-vf setpts=PTS-STARTPTS \
	-c:a aac -b:a 128k -ac 2 -ar 48000 -af aresample=async=1,asetpts=PTS-STARTPTS \
	"${FRAG[@]}" \
	- | "$MOQ_PUB" --name "$NAME" "$URL"
