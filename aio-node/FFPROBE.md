# ffprobe through Nuvio

AIOStreams reads the tracks of a file the first time it is played (codecs,
audio and subtitle languages, HDR / Dolby Vision, chapters) with ffprobe and
remembers them for its stream lists. Apple TV can't run programs, so inside
Nuvio there is no ffprobe and AIOStreams leaves this out.

`ffprobe-bridge.mjs` (installed by `nuvio-main.mjs`) prepares the way round:
when Nuvio passes `NUVIO_FFPROBE_URL`, AIOStreams' ffprobe becomes
`nuvio-ffprobe`, and every ffprobe run is a request to that address. Nuvio
answers from its own player's probe (`AetherEngine.probe(url:)`, FFmpeg).
Without the variable nothing changes.

Nuvio's side is not written yet. This is what it has to answer.

## Requests

`POST <NUVIO_FFPROBE_URL>`, `content-type: application/json`, from
127.0.0.1 only. Three kinds, in the order AIOStreams sends them:

### Is there an ffprobe?

```json
{ "version": true }
```

Answer `200 {"version": "<anything>"}`. AIOStreams shows it as the ffprobe
version. Nothing listening, 404 or 501: AIOStreams treats ffprobe as missing.

### Format, streams and chapters of a file

```json
{ "input": "http://127.0.0.1:8770/…", "show": ["format", "streams", "chapters"] }
```

`input` is what ffprobe would open: usually an http(s) address (AIOStreams'
own loopback for Usenet, or a debrid link). Answer `200` with what
`ffprobe -v error -print_format json -show_format -show_streams -show_chapters <input>`
prints. The fields AIOStreams reads:

- `format`: `format_name`, `duration`, `size`, `bit_rate` (strings, as
  ffprobe gives them)
- `streams[]`: `index`, `codec_type` (`video` / `audio` / `subtitle`),
  `codec_name`, `codec_tag_string`, `profile`, `level`, `width`, `height`,
  `field_order`, `refs`, `r_frame_rate`, `avg_frame_rate`, `bit_rate`,
  `bits_per_raw_sample`, `pix_fmt`, `color_primaries`, `color_range`,
  `color_space`, `color_transfer`, `display_aspect_ratio`, `channels`,
  `channel_layout`, `sample_rate`, `side_data_list[]` (`side_data_type`,
  `dv_profile`, `dv_level` — Dolby Vision), `tags` (`language`, `title`, …),
  `disposition` (`default`, `forced`, `hearing_impaired`, … as 0/1)
- `chapters`: only whether there are any

### A few frames of the video (HDR10+)

```json
{ "input": "…", "show": ["streams", "frames"], "selectStreams": "v", "readIntervals": "%+#5" }
```

Asked only when the file has a video stream. Answer what
`ffprobe … -select_streams v -show_streams -show_frames -read_intervals %+#5`
prints: `streams[]` with `index` and `refs`, and `frames[]` with
`stream_index` and `side_data_list[].side_data_type` (HDR10+ shows as
`HDR Dynamic Metadata SMPTE2094-40 (HDR10+)`). If this is not worth doing,
answer `{"streams": [], "frames": []}`: only HDR10+ and reference frames go
missing.

Anything ffprobe doesn't know can be left out; AIOStreams skips what's not
there. Unknown flags (from a later AIOStreams) arrive in `extra`.

### Errors

A file that can't be read: any status ≥ 300 with `{"error": "…"}`. AIOStreams
records the probe as failed, as when ffprobe fails. AIOStreams waits 90 s at
most (its probe timeout) and probes one file at a time.

## Turning it on

In `AIOStreamsHost.start()`, once Nuvio answers these requests:

```swift
"NUVIO_FFPROBE_URL": "http://127.0.0.1:<port>/<token>/aio/ffprobe",
```

## Test

Checked outside this repository, on Linux with the official image: AIOStreams'
own ffprobe code ran through the bridge, with a stand-in for Nuvio answering
with the real ffprobe, and gave the same result as ffprobe run directly; with
nobody answering, AIOStreams saw no ffprobe.
