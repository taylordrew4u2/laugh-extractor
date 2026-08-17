# Laugh Extractor

[![Download](https://img.shields.io/github/v/release/taylordrew4u2/laugh-extractor?label=Download%20for%20macOS&style=for-the-badge)](https://github.com/taylordrew4u2/laugh-extractor/releases/latest)
[![CI](https://github.com/taylordrew4u2/laugh-extractor/actions/workflows/ci.yml/badge.svg)](https://github.com/taylordrew4u2/laugh-extractor/actions/workflows/ci.yml)

Drop in a stand-up set. Get every burst of **pure audience laughter** as its own
audio file — one file per laugh, not a compilation.

Laughter the comedian talks over is discarded, not trimmed around. That's the
whole point: what comes out is clean crowd response you can drop straight into
an edit.

<!--
  Screenshot: save a window capture to docs/screenshot.png and swap the
  placeholder line below for:  ![Laugh Extractor](docs/screenshot.png)
-->
> **Screenshot:** _pending — capture the main window (drop zone, waveform with
> highlighted bursts, results list) and save it to `docs/screenshot.png`._

## Install

1. [**Download the latest DMG**](https://github.com/taylordrew4u2/laugh-extractor/releases/latest)
2. Open it and drag **LaughExtractor** to Applications
3. Launch it

The app is signed with a Developer ID certificate and notarized by Apple, so it
opens normally. No Gatekeeper warning, no right-click-Open workaround, no
terminal.

Requires macOS 14 (Sonoma) or later.

## How to use it

1. **Drop a video in** — MP4, MOV, M4A, MP3 or WAV.
2. **Click Analyze.** The audio is decoded and run through the system sound
   classifier. Progress is shown as it goes.
3. **Look at the waveform.** Detected bursts are highlighted. This is the fastest
   way to see whether detection is over- or under-firing.
4. **Nudge the thresholds.** Moving a slider re-runs *only* the segmenter — no
   re-decoding, no re-classifying — so the burst list updates instantly. Tune
   until the clips sound clean.
5. **Tick the ones you want** and hit **Export Selected**. Files land as
   `laugh_01`, `laugh_02`, … in a folder you choose, and Finder opens on them.

### Tuning

| Setting | Default | What it does |
|---|---|---|
| Laugh threshold | 0.25 | How confident the classifier must be before a window counts as laughter. |
| Speech ceiling | 0.60 | **The no-talking rule.** Bursts whose *average* speech score is above this are rejected. Judged on the burst mean rather than per window — the classifier reports speech almost continuously in live comedy, so a per-window veto rejects nearly everything real. |
| Laugh/speech dominance | 0.5× | A burst's average laugh score must be at least this multiple of its average speech score. 0 turns the check off. |
| Ambient noise margin | 6 dB | Laughter must stand out this far above the recording's own noise floor, so ambient rumble doesn't qualify. 0 disables the gate; it also steps aside automatically when the recording has no dynamic range to gate on. |
| Minimum duration | 500 ms | Measured *after* edge trimming. |
| Edge trim | 150 ms | Cut inward at both ends, where the comedian's voice is most likely to bleed in. |
| Bridge gap | 100 ms | Dropouts up to this long won't split one laugh into two clips. |

Defaults are forgiving on purpose: a first pass that finds too much is easy to
tune down, one that finds nothing is a dead end. For a close-mic'd comic in a
quiet room, **raise** the laugh threshold and **tighten** the speech ceiling
until the false positives drop off.

Getting nothing? The "No laughter detected" screen shows the classifier's peak
scores, how many windows passed the frame gates, and what happened to every
candidate burst — the stage rejecting everything is the one to loosen. If a
laugh you can clearly hear is being skipped, its burst probably averaged more
talk than laugh — that's intentional.

## Output formats

| Format | Notes |
|---|---|
| **M4A (AAC)** | Default. Compressed, small, opens everywhere. |
| **WAV** | Fully lossless — a bit-for-bit copy of the decoded source, no re-encode at all. |

**MP3 isn't offered.** macOS decodes MP3 but ships no MP3 *encoder*, and
AVFoundation cannot write one. Adding it would mean bundling libmp3lame (LGPL,
needs dynamic linking and a licence notice) or shipping an ffmpeg binary, which
roughly doubles the app size. Between high-bitrate AAC and lossless WAV, every
editor is covered.

Slicing always happens on a lossless 32-bit float intermediate at the source's
native sample rate and channel count. Encoding, if any, happens once at export.
A 20 ms fade is applied at each cut point so the clips don't click.

## Privacy

The app is sandboxed and has **no network access and no microphone access** —
check `Config/LaughExtractor.entitlements`, it grants exactly two things:
read/write to files you pick yourself, and the bookmark needed to remember your
export folder between launches. Nothing you drop in leaves your machine. All
classification runs locally against the model built into macOS.

## How it works

```
video ──▶ AudioExtractor ──┬──▶ master.wav    (native rate, 32-bit float, lossless)
                           └──▶ analysis.wav  (16 kHz mono)
                                     │
                                     ▼
                              LaughDetector     SoundAnalysis, 0.975 s windows,
                                     │          0.9 overlap → ~97 ms hop
                                     ▼
                               [FrameScore]     laugh / speech / applause per window
                                     │
                                     ▼
                               Segmenter        group → bridge → trim → reject
                                     │
                                     ▼
                              [LaughSegment]
                                     │
                                     ▼
                                Exporter        slice master, fade, encode once
```

Both intermediates are written to a temporary directory rather than held in
memory — an hour of 48 kHz stereo float is ~700 MB, which isn't something to
keep around just because someone dropped in a long special.

`Segmenter` is pure logic with no framework imports. That's deliberate: it makes
the entire detection policy unit-testable without audio fixtures, and it means
re-running it on a slider change costs a single array pass.

Classifier labels are resolved at runtime by substring-matching whatever
`SNClassifySoundRequest.knownClassifications` reports, never by hardcoded
strings — Apple has renamed classes between OS releases. If a group resolves to
zero labels the app fails loudly rather than silently detecting nothing.
(`baby_laughter` is excluded; it false-fires on high crowd noise.)

## Build from source

Requires **Xcode 16 or later** (the project uses file-system-synchronized
groups) and macOS 14+.

```sh
git clone https://github.com/taylordrew4u2/laugh-extractor.git
cd laugh-extractor
open LaughExtractor.xcodeproj
```

Then just build and run — Debug builds sign ad-hoc, so no developer account is
needed to run it locally.

**Zero third-party dependencies.** SwiftUI, SoundAnalysis, AVFoundation and
Accelerate are all first-party Apple frameworks that ship with the OS. There is
no package manifest and nothing to install.

### Tests

```sh
xcodebuild test -project LaughExtractor.xcodeproj -scheme LaughExtractor \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
```

Two suites, both run on every push:

**`SegmenterTests`** — the detection policy, driven by synthetic frame scores
instead of audio fixtures, which is why `Segmenter` has no framework imports.
Covers the no-talking rule, the 500 ms floor measured *after* trimming, a 100 ms
gap bridging into one burst where 300 ms splits into two, and the degenerate
cases: empty input, a zero hop, and an edge trim wide enough to invert a segment.

**`PipelineIntegrationTests`** — the real framework path, on audio generated at
runtime. Decodes both raw PCM and compressed AAC; checks the master keeps its
native rate and channel count while the analysis track lands at 16 kHz mono;
asserts the resampled length still tracks the source, which is what would break
if timing drifted; confirms inference returns ordered frames on the expected hop
grid; checks silence yields no bursts; and verifies both export formats write
readable clips of the right length, with filenames zero-padded and the 20 ms
fades reaching zero at both edges.

What the suite does **not** cover is detection *accuracy*. Whether the default
thresholds pick the right laughs out of a particular room is a listening test,
not something an assertion can settle.

### Cutting a release — how the DMG actually gets built

`.github/workflows/release.yml` does the whole thing: build, sign, notarize,
staple, and publish the DMG to a GitHub Release. It needs two things from you,
in this order.

**1. Add the signing secrets** (Settings → Secrets and variables → Actions).
Until these exist the workflow fails immediately, and no DMG is produced:

| Secret | What it is |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID **Application** certificate + private key, exported as `.p12`, base64-encoded |
| `P12_PASSWORD` | Password on that `.p12` |
| `KEYCHAIN_PASSWORD` | Any string — used for the temporary CI keychain |
| `NOTARY_KEY_BASE64` | App Store Connect API key (`.p8`), base64-encoded |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | Your App Store Connect issuer ID |
| `TEAM_ID` | Your 10-character Apple Developer team ID |

Developer ID Application is a **different certificate type** from the App Store
distribution one. A paid Apple Developer account can create both, but they are
not interchangeable — generate the Developer ID one separately in the
Certificates section of the account.

**2. Push a version tag.** That's what triggers the build:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

Watch it under the Actions tab. When it finishes, the DMG is attached to a new
Release and the download badge at the top of this page starts working.

Before the first release, change `PRODUCT_BUNDLE_IDENTIFIER` in the project from
`com.laughextractor.LaughExtractor` to something under your own domain.

There's also `.github/workflows/dmg-dryrun.yml` — run it manually from the
Actions tab to exercise the archive → app bundle → DMG mechanics without any
secrets. It proves the plumbing works, but what it produces is ad-hoc signed
and unnotarized, so it's a pipeline test, not something to hand to anyone.

Skipping notarization isn't viable: an unsigned DMG on macOS 14+ throws a
"damaged and can't be opened" error that looks exactly like malware, and the
workaround is buried in System Settings.

## Layout

```
LaughExtractor/
├── LaughExtractorApp.swift
├── Views/           ContentView, DropZone, SegmentRow, Waveform, Settings
├── Core/            AudioExtractor, LaughDetector, Segmenter, Exporter,
│                    AppModel, PreviewPlayer, Settings
└── Models/          LaughSegment, FrameScore
LaughExtractorTests/ SegmenterTests, PipelineIntegrationTests
Config/              entitlements
.github/workflows/   ci, release, dmg-dryrun
```
