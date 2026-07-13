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
| Fragmentation  | `cmaf+separate_moof+delay_moov+skip_trailer+frag_every_frame` | Lets `moq-pub` extract the init + per-frame fragments |

The script transcodes to H.264 High / yuv420p + AAC stereo with `-g 60`
(~2s keyframes at 30fps) so segmentation is clean and the output always meets
the constraints above, whatever the source codecs are.

> If your source is *already* H.264 + AAC with a sane keyframe cadence, you can
> save CPU by remuxing instead of transcoding — replace the `-c:v … -c:a …`
> options in `run-pub-srt.sh` with `-c copy`.

## Gotchas (safe, no side effects on well-formed streams)

These are baked into `run-pub-srt.sh` or listed as safe additions:

- **`-fflags +genpts`** — *(included in the script)* generates presentation
  timestamps only for packets that are **missing** them. TS from SRT sometimes
  has gaps; this fills them. On a well-formed stream it changes nothing (it does
  not overwrite existing PTS), so it is safe to leave on.
- **`-map 0:v:0 -map 0:a:0`** — *(included)* selects exactly one video + one
  audio stream, dropping subtitles/KLV/data tracks that `moq-pub` doesn't
  handle. No effect on a clean 2-track source.
- **Drop `-re` and `-stream_loop`** — *(done)* those are for files; a live SRT
  feed is already realtime, so omitting them is correct, not a workaround.

## Gotchas that DO have side effects — apply only if you hit the problem

These are intentionally **not** in the script because they alter timing/audio
even on good streams. Add them manually only to fix a specific symptom:

- **`-af aresample=async=1`** — pads/stretches audio to keep A/V in sync. Fixes
  audible drift on bad TS, but resamples audio unconditionally. Use only if you
  observe A/V drift.
- **`-vsync cfr` / `-r <fps>`** — forces a constant frame rate by
  dropping/duplicating frames. Use only if a variable-frame-rate source causes
  playback stutter.
- **`-c:v libx264` on an already-H.264 source** — re-encoding costs CPU and
  quality. Prefer `-c copy` unless the codec is genuinely incompatible.

## Testing

Publish, then subscribe from your laptop:

```bash
moq-sub --name bbb 'https://<your-domain>.duckdns.org:4443' | ffplay -
```

Or point a draft-14 moq-js player in Chrome at the same URL (broadcast `bbb`,
catalog `.catalog`). Remember the start order: **relay → publisher →
subscriber** (the init segment is emitted once when ffmpeg starts).
