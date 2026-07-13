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
|----------------|-------------------------------------|-----------------------------------------------------------------------|
| Video codec    | **H.264 / AVC** (`avc1`)           | `moq-pub` rejects HEVC (`"HEVC not yet supported"`); no AV1/VP9 path |
| Pixel format   | `yuv420p` (8-bit 4:2:0)            | Browser-decodable; avoid 10-bit / 4:2:2                             |
| Audio codec    | **AAC** (`mp4a`), stereo           | Only `mp4a` is handled                                              |
| Keyframes      | Regular IDR interval (~1–2 s)      | `moq-pub` starts a new segment on each keyframe                      |
| Tracks         | 1 video + 1 audio                  | Sample has exactly 2 tracks; extra TS streams are dropped via `-map` |

The script transcodes to H.264 High / yuv420p + AAC stereo with `-g 60`
(~2s keyframes at 30fps) so segmentation is clean and the output always meets
the constraints above, whatever the source codecs are.

> If your source is *already* H.264 + AAC with a sane keyframe cadence, you can
> save CPU by remuxing instead of transcoding — replace the `-c:v … -c:a …`
> options in `run-pub-srt.sh` with `-c copy`.

## Why each ffmpeg option is used

The full ffmpeg command in `run-pub-srt.sh` is tested and working end-to-end
(OBS → SRT → publisher → relay → player, gapless audio and video). Here's what
each part does:

- **`-map 0:v:0 -map 0:a:0`** — selects exactly one video + one audio stream,
  dropping any subtitle/KLV/data tracks the source might carry.
- **`-c:v libx264 -preset veryfast -tune zerolatency -profile:v high -pix_fmt yuv420p`**
  — encodes video to a browser/`moq-pub`-compatible H.264 profile with low
  encoding latency.
- **`-g 60 -keyint_min 60 -sc_threshold 0`** — fixed ~2s keyframe interval at
  30fps, disabling scene-cut detection so keyframes land on a predictable
  cadence. `moq-pub` starts a new MoQ group at each keyframe, so a steady
  interval keeps segmentation clean. If you change the source frame rate, set
  `-g` to `2 × fps` to keep ~2s groups.
- **`-vf setpts=PTS-STARTPTS`** / **`-af asetpts=PTS-STARTPTS`** — rebase both
  streams to a zero-based timeline, preserving A/V sync regardless of the
  source's timestamp origin.
- **`-c:a aac -b:a 128k -ac 2 -ar 48000`** — encodes audio to stereo AAC at a
  fixed 48kHz sample rate, matching the init segment `moq-pub` generates.
- **`-af aresample=async=1`** — smooths out small timing jitter from a live
  SRT feed so the audio timeline stays continuous.
- **`-movflags cmaf+separate_moof+delay_moov+skip_trailer`** — produces
  fragmented MP4 (moof/mdat pairs) with a separate init segment, the format
  `moq-pub` expects.
- **`-frag_duration 16000`** — fragments the output roughly every 16ms
  (**recommended over the default `frag_every_frame`**, see below).

> Do **not** use `-use_wallclock_as_timestamps 1`: on a bursty SRT feed it
> stamps packets by arrival time, which collapses packet deltas to ~0 and
> produces negative durations.

## `-frag_duration` vs. `frag_every_frame`

Use `-frag_duration 16000` instead of `-movflags +frag_every_frame`.

Both produce one fragment per video frame in practice (16ms is shorter than a
frame at up to 60fps, and an AAC frame is always 21.3ms at 48kHz — so audio
always gets one fragment per frame either way). The difference is *how* the
fragment boundary is decided:

- `frag_every_frame` closes each fragment immediately, without seeing the next
  packet's timestamp.
- `-frag_duration` closes a fragment once the next packet's timestamp would
  exceed the target duration, so it always has the real timestamp available.

In practice, `-frag_duration` has produced clean, gapless audio in every test
against a live re-encoded SRT source, while `frag_every_frame` has caused
audio dropouts a few seconds into playback. Stick with `-frag_duration` for
live ingest with `moq-pub`.

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
