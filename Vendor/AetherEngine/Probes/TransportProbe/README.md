# Transport probe (AE#377)

A measurement, not a test. It answers whether the media read path can move off URLSession data
tasks onto `URLSessionStreamTask`, and it is meant to be run against the origin that produced the
failure rather than against a loopback server.

Nothing here imports AetherEngine. The question is a property of the transport; routing it through
the reader under suspicion would answer a different one.

## Why it is a test bundle, and its own package

tvOS has no command line, so an executable cannot run on the device that has the failure. An XCTest
bundle can. The same code runs under `swift test` on macOS, where the earlier loopback attempt
failed to tell the arms apart, which is the reason the device run exists at all.

It is a separate package because the engine's package scheme carries `aetherctl`, which uses
`Foundation.Process` and cannot build for tvOS. The device that has the failure could not otherwise
build the harness meant to measure it.

## Run it

1. Put the source URL in `Tests/TransportProbe/ProbeTarget.swift`. That file is the whole
   configuration, and it is a source file rather than an environment variable on purpose:
   `TEST_RUNNER_`-prefixed settings are forwarded to UI-test runner apps, not to a unit-test bundle,
   and a tvOS run with them set skipped the entire suite in silence. Measured, not assumed.
2. Run it:

```bash
cd Probes/TransportProbe
xcodebuild test -scheme TransportProbe-Package \
  -destination 'platform=tvOS,id=<device-udid>' \
  -test-timeouts-enabled NO \
  -allowProvisioningUpdates
```

Device UDIDs: `xcrun devicectl list devices`. In Xcode, open this directory as a package and run the
test bundle against the Apple TV; the same file supplies the URL.

On macOS the environment still works and overrides the file, which keeps a local shakedown to one
line: `AE_PROBE_URL='…' swift test`.

With no URL in either place the whole suite is disabled and reports as skipped, which is what lets
CI compile it without reaching the network.

## Proving the probe before trusting it

`window-origin.py` is a local origin with this issue's shape: ranges, an endless body, and a refusal
window on a compressed clock. It is not the measurement, it is how the harness was checked before it
was handed over, and it is the fastest way to see what a good run looks like.

```bash
python3 window-origin.py 8477 40 20     # serve 40 s, refuse 20 s
AE_PROBE_URL=http://127.0.0.1:8477/big.bin AE_PROBE_WINDOW_SECONDS=110 \
  AE_PROBE_HOLD_SECONDS=8 AE_PROBE_WARMUP_MB=4 AE_PROBE_MBPS=8 \
  AE_PROBE_CANARY_URL=http://127.0.0.1:8477/neutral swift test
```

Loopback makes arm B inconclusive by construction (250 ms of loopback is gigabytes), which is the
harness telling the truth about itself.

One arm at a time, if sitting through the set is not wanted. The trailing `()` is not optional:
without it xcodebuild matches nothing, runs zero tests and reports green.

```bash
xcodebuild test -scheme TransportProbe-Package -destination '…' \
  '-only-testing:TransportProbe/TransportProbe/heldAcrossWindow()'
```

Names: `resolve()`, `streamBackpressure()`, `dataTaskSuspendControl()`, `heldAcrossWindow()`.

## The arms

They are serialized and run in order. About 20 minutes for the set. Each arm waits for the origin
to serve before it starts, because a source that refuses four minutes in ten would otherwise decide
the run by timing.

| arm | duration | question |
| --- | --- | --- |
| A resolve | seconds | which edge answers, http/1.1 or h2, does it range |
| B stream hold | ~2 min | does a stream task stop the sender when reads stop |
| C data task + suspend | ~2 min | positive control: it must NOT stop the sender (#220) |
| D held across the window | ~15 min | does a held connection cross the origin's refusal window |

**Arm C is the one that validates the run.** #220 measured 911 MB arriving after a `suspend()`. If
arm C reports a small "delivered DURING hold" and a flat footprint, this harness is not reproducing
the known failure and arm B's healthy result means nothing. That is exactly how the macOS loopback
attempt ended.

**Arm D can end the plan on its own.** If the held stream gaps at the same moment its canary flips
to 429, the origin cuts held connections too, no transport change helps, and nobody should write it.

## Knobs

Every knob exists in both places: a field in `ProbeTarget.swift` (0 or empty means "default") and an
environment variable that overrides it.

| field / variable | default | what it is |
| --- | --- | --- |
| `sourceURL` / `AE_PROBE_URL` | none, required | the source URL, redirects followed once like the reader does |
| `holdSeconds` / `AE_PROBE_HOLD_SECONDS` | 60 | how long arms B and C issue no reads |
| `windowSeconds` / `AE_PROBE_WINDOW_SECONDS` | 900 | how long arm D runs |
| `megabitsPerSecond` / `AE_PROBE_MBPS` | 65 | arm D's consumption rate, i.e. the bitrate being emulated |
| `warmupMegabytes` / `AE_PROBE_WARMUP_MB` | 16 | bytes consumed before the hold, matching `winHighWater` on VOD |
| `neutralCanaryURL` / `AE_PROBE_CANARY_URL` | captive.apple.com | a non-origin host, so a refusal can be told from #310's starvation. `none` disables it |
| `abortMegabytes` / `AE_PROBE_ABORT_MB` | 400 | footprint growth that ends an arm early. Unbounded delivery is the finding; a jetsam kill while proving it is not |

## What it will not tell you

The origin's own books. Every witness here is client side, so "the sender was stopped" is inferred
from a flat footprint plus a post-hold drain no larger than the wire could have carried in 250 ms.
That inference is stated as the arm's verdict line rather than left to the reader.

## Reading the output

Each arm prints a `paste this` block. The three lines that carry the decision:

- arm C `delivered DURING hold` large and footprint climbing: the harness reproduces #220, so the
  run counts.
- arm B footprint flat, first read after the hold instant and small, stream continues: demand-driven
  reads give real backpressure and a held connection survives a viewer pause.
- arm D canary at 429 while the stream shows no stall: a held connection is exempt from the window,
  which is the whole reason to consider the change.

Canary lines are condensed per run of identical outcomes, so a fifteen minute arm reads as a handful
of lines with the flip visible in the middle.
