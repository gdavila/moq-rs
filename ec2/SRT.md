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

## Timestamp handling (why audio can drop out)

Live SRT/MPEG-TS sources carry valid timestamps, but with a **large origin** —
the MPEG-TS PCR starts at a high value rather than 0. The CMAF fragment muxer
rejects that, logging:

```
[mp4 @ ...] pts has no value
[mp4 @ ...] Packet duration: -1024 / dts: ... in stream 1 is out of range
```

The audio bytes still arrive at the player, but with a broken output timeline
the player drops audio after a few seconds while video keeps playing. `moq-sub`
debug logs confirm this: the audio track keeps receiving objects in lockstep
with video, yet playback goes silent — a muxing-timestamp problem, not a MoQ
transport problem.

You can confirm the source itself is clean by probing the raw SRT audio:

```bash
ffprobe -v error -select_streams a:0 \
  -show_entries packet=pts_time,dts_time,duration_time \
  -read_intervals '%+5' -of csv 'srt://0.0.0.0:9999?mode=listener'
```

Monotonic `pts_time`/`dts_time` with a steady `duration_time` (e.g. `0.021333`
= 1024/48000) means the source is fine and the fix belongs in ffmpeg's output.

The script rebases both streams to start at 0:

- **`-vf setpts=PTS-STARTPTS`** / **`-af asetpts=PTS-STARTPTS`** — *(included)*
  subtract each stream's first PTS so timestamps start at 0, keeping the
  source's timing and A/V sync intact while fixing the "out of range" rejection.
- **`-af aresample=async=1`** — *(included)* guards against SRT burst jitter by
  keeping the audio timeline continuous.
- **`-ar 48000`** — *(included)* pins the audio sample rate so every frame
  matches the init `moov` (a mid-stream rate change can mute audio).

> Do **not** use `-use_wallclock_as_timestamps 1` here: on a bursty SRT feed it
> stamps packets by arrival time, collapsing their deltas to ~0 and producing
> negative durations — it makes the audio dropout worse, not better.

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
