# Publishing an SRT ingest to the relay

You can feed a live **SRT** stream into the publisher instead of the Big Buck
Bunny file. Only the ffmpeg **input** changes — `moq-pub` still speaks
MoQ-over-QUIC to the relay exactly as before.

```
SRT encoder ──SRT/MPEG-TS──> ffmpeg ──stdin──> moq-pub ──MoQ/QUIC──> relay ──> players
```

Use the wrapper:

```bash
./run-pub-srt.sh
```

## Quick start

**Listener mode** (ffmpeg waits for an encoder to push to it — most common):

```bash
SRT_PORT=9999 ./run-pub-srt.sh
# encoder pushes to: srt://<elastic-ip>:9999?mode=caller
```

**Caller mode** (ffmpeg pulls from a remote SRT server):

```bash
SRT_MODE=caller SRT_HOST=1.2.3.4 SRT_PORT=9999 ./run-pub-srt.sh
```

The script **always transcodes** the SRT source to H.264 High / yuv420p + AAC
stereo, so it works regardless of the source codecs. This costs CPU but
guarantees compatibility with `moq-pub` and browser players.

Open the SRT **UDP** port in your EC2 Security Group when using listener mode.

## Configuration (env vars)

| Var           | Default     | Meaning                                          |
|---------------|-------------|--------------------------------------------------|
| `NAME`        | `bbb`       | Broadcast name subscribers use                   |
| `SRT_MODE`    | `listener`  | `listener` (wait for push) or `caller` (pull)    |
| `SRT_PORT`    | `9999`      | SRT UDP port                                      |
| `SRT_HOST`    | `0.0.0.0`   | Remote host for `caller` mode                     |
| `SRT_LATENCY` | `200`       | SRT latency buffer in ms                          |

`DOMAIN` and `PORT` come from `config.sh` (same as the other scripts).

## Compatibility constraints

The SRT stream must contain codecs `moq-pub` and the browser can handle
(same profile as the sample). These are enforced by `moq-pub`'s parser and by
what browsers decode:

| Constraint     | Value                              | Why                                                                 |
|----------------|------------------------------------|---------------------------------------------------------------------|
| Video codec    | **H.264 / AVC** (`avc1`)           | `moq-pub` rejects HEVC (`"HEVC not yet supported"`); no AV1/VP9 path |
| Pixel format   | `yuv420p` (8-bit 4:2:0)            | Browser-decodable; avoid 10-bit / 4:2:2                             |
| Audio codec    | **AAC** (`mp4a`), stereo           | Only `mp4a` is handled                                              |
| Keyframes      | Regular IDR interval (~1–2 s)      | `moq-pub` starts a new segment on each keyframe                      |
| Tracks         | 1 video + 1 audio                  | Sample has exactly 2 tracks; extra TS streams are dropped via `-map` |
| Fragmentation  | `cmaf+separate_moof+delay_moov+skip_trailer` + `-frag_duration 16000` | Lets `moq-pub` extract the init + per-frame fragments. Do **not** use `frag_every_frame` — see below |

The script transcodes to H.264 High / yuv420p + AAC stereo with `-g 60`
(~2s keyframes at 30fps) so segmentation is clean and the output always meets
the constraints above, whatever the source codecs are.

If you change the frame rate, adjust `-g` (it is in *frames*: set it to
`2 × fps` for ~2s groups). `-frag_duration` needs no adjustment: 16ms is below
the frame duration up to 60fps, so every frame keeps its own fragment.

> If your source is *already* H.264 + AAC with a sane keyframe cadence, you can
> save CPU by remuxing instead of transcoding — replace the `-c:v … -c:a …`
> options in `run-pub-srt.sh` with `-c copy`.

## The audio-dropout bug (`frag_every_frame` + live re-encode)

**Symptom:** playback starts fine, then audio disappears after a few seconds
and never returns, while video keeps playing. Reproduces every time. In
`ffplay` the `A-V` drift grows steadily (e.g. to `+0.307`) and then freezes —
the audio clock has stopped.

**Publisher-side signature:** ffmpeg logs this for (nearly) every audio packet,
from the very first one:

```
[mp4 @ ...] Packet duration: -1024 / dts: ... in stream 1 is out of range
[mp4 @ ...] pts has no value
```

**Root cause (ffmpeg movenc bug, verified against ffmpeg 8.0.1):** with
`-movflags +frag_every_frame` the mp4 muxer closes a fragment immediately
after writing each packet — *before* it knows the next packet's dts — so it
must **estimate** the closing sample's duration (`check_pkt` /
`mov_flush_fragment` in `libavformat/movenc.c`). When **both video and audio
are encoded live** (interleaved arrival), the estimate overshoots the audio
track by exactly one AAC frame (1024 samples). Every subsequent audio packet
then appears to land *behind* the muxer's reference, so movenc clamps its dts
and discards its pts — corrupting the fragment timeline that `moq-pub`
streams. The player's audio clock drifts until it gives up.

Things that were **ruled out** while troubleshooting (don't chase these):

- **Not SRT and not OBS.** The bug reproduces with a plain local MPEG-TS
  *file* run through the same ffmpeg command — no network involved. The MoQ
  transport is also fine: `moq-sub` debug logs show audio objects arriving in
  lockstep with video the whole time.
- **Not source timestamps.** Probe the raw SRT feed if in doubt:

  ```bash
  ffprobe -v error -select_streams a:0 \
    -show_entries packet=pts_time,dts_time,duration_time \
    -read_intervals '%+5' -of csv 'srt://0.0.0.0:9999?mode=listener'
  ```

  Monotonic `pts_time`/`dts_time` with steady `duration_time` (`0.021333` =
  1024/48000) means the source is clean — and it was.
- **Not the filter chain.** The errors appear with or without
  `setpts`/`asetpts`/`aresample`, and shifting audio pts (e.g. to absorb AAC
  encoder priming) doesn't help.
- **Not fixable with mux tweaks around the flag:** `-avoid_negative_ts`,
  `-use_editlist 0`, `+negative_cts_offsets`, and dropping `delay_moov` all
  still error. Only removing `frag_every_frame` (or not re-encoding audio,
  `-c:a copy`) eliminates it. That's why `dev/pub` never hits it: `bbb.fmp4`
  was fragmented offline with `-c:v copy`, a different interleaving pattern.

**The fix (what the script uses):** time-based fragmentation instead of
per-frame fragmentation:

```
-movflags cmaf+separate_moof+delay_moov+skip_trailer -frag_duration 16000
```

With `-frag_duration` a fragment is closed when the *next* packet arrives, so
sample durations are exact and no estimation happens — zero muxer errors and a
gapless audio timeline (verified end-to-end: OBS → SRT → publisher → relay →
`moq-sub`, uniform 1024-sample spacing across the whole capture). 16ms is
below one frame duration up to 60fps, so chunking and latency are the same as
`frag_every_frame`: one fragment per frame. AAC audio (21.3ms per frame at
48kHz) always gets one fragment per frame regardless of the video rate.

## Timestamp hygiene (kept in the script, but not the dropout fix)

- **`-vf setpts=PTS-STARTPTS`** / **`-af asetpts=PTS-STARTPTS`** — rebase both
  streams to a zero-based timeline regardless of the source's MPEG-TS PCR
  origin, preserving A/V sync.
- **`-af aresample=async=1`** — guards against SRT burst jitter by keeping the
  audio timeline continuous.
- **`-ar 48000`** — pins the audio sample rate so every frame matches the init
  `moov` (a mid-stream rate change can mute audio).

> Do **not** use `-use_wallclock_as_timestamps 1` here: on a bursty SRT feed it
> stamps packets by arrival time, collapsing their deltas to ~0 and producing
> negative durations.

## Other safe flags (no side effects on well-formed streams)

- **`-map 0:v:0 -map 0:a:0`** — *(included)* selects exactly one video + one
  audio stream, dropping subtitles/KLV/data tracks that `moq-pub` doesn't
  handle. No effect on a clean 2-track source.
- **Drop `-re` and `-stream_loop`** — *(done)* those are for files; a live SRT
  feed is already realtime, so omitting them is correct, not a workaround.

## Flags to add only if you hit the specific problem

- **`-vsync cfr` / `-r <fps>`** — forces a constant frame rate by
  dropping/duplicating frames. Use only if a variable-frame-rate source causes
  playback stutter.
- **`-c copy`** — skip transcoding to save CPU **only** if the source is already
  H.264 + AAC with a sane keyframe cadence (replaces the `-c:v … -c:a …` opts).

## Testing

Publish, then subscribe from your laptop:

```bash
moq-sub --name bbb 'https://<your-domain>.duckdns.org:4443' | ffplay -
```

Or point a draft-14 moq-js player in Chrome at the same URL (broadcast `bbb`,
catalog `.catalog`). Remember the start order: **relay → publisher →
subscriber** (the init segment is emitted once when ffmpeg starts).

To verify audio continuity objectively (instead of listening), capture the
broadcast to a file and check that every audio packet is exactly one AAC frame
(1024 samples) after the previous one:

```bash
timeout 40 moq-sub --name bbb 'https://<your-domain>.duckdns.org:4443' > capture.mp4
ffprobe -v error -select_streams a -show_packets -show_entries packet=pts \
  -of csv=p=0 capture.mp4 | python3 -c "
import sys
pts=[int(float(l.split(',')[0])) for l in sys.stdin if l.strip()]
gaps=[(a,b) for a,b in zip(pts,pts[1:]) if b-a != 1024]
print(f'{len(pts)} packets, {len(gaps)} gaps', gaps[:5])"
```

Zero gaps means the audio timeline is clean. (A single "Packet corrupt"
warning at the very end of the capture is just the file being truncated
mid-fragment by `timeout` — not a stream problem.)
