# Manifest

Batch mastering QA for macOS. Point it at a folder of masters and it tells you
what is wrong with them before you ship.

Companion to [Nyquist](../nyquist), which is the single-file interactive
spectrum analyzer. Manifest is the pass across a whole folder. Double-clicking a
row here opens that file in Nyquist.

## Building

```
./build.sh
```

Produces `build/Manifest.app` and `build/Manifest-1.0.dmg`. Command Line Tools
only — no Xcode, no package manager, no dependencies. Apple Silicon.

Rename via `APP_NAME`/`BUNDLE_ID` in `build.sh` and `Sources/AppInfo.swift`.

## What it measures

Per track, in one decode pass:

| | |
|---|---|
| **Integrated LUFS** | EBU R128 / ITU-R BS.1770-4, K-weighted with two-stage gating |
| **LRA** | Loudness range, 10th–95th percentile of gated short-term loudness |
| **True peak** | 4x oversampled, Kaiser-windowed sinc polyphase FIR |
| **Sample peak** | Raw, to distinguish "already clipped" from "merely loud" |
| **Correlation** | Per-block Pearson across L/R, plus worst-case and % phase-negative |
| **Width** | Side energy relative to mid, in dB |
| **Spectrogram** | 2048-point FFT thumbnail, mean-power pooled |
| **Vectorscope** | Lissajous density across every sample, log-compressed |

Across the batch it also flags mixed sample rates, mixed bit depths, and a
loudness spread wide enough to be audible on a release played end to end.

### Verification

The loudness engine is checked against ffmpeg's `ebur128`, which is the same
thing libebur128 implements:

| File | Manifest | ffmpeg | Δ |
|---|---|---|---|
| Shifter Master 01 (48 kHz) | −9.26 LUFS | −9.3 | 0.04 LU |
| Chrome (gossip) V1 (44.1 kHz) | −6.71 LUFS | −6.7 | 0.01 LU |
| pink noise target (48 kHz) | −17.01 LUFS | −17.0 | 0.01 LU |

LRA agrees to 0.02 LU, true peak to within ffmpeg's 0.1 dB display precision.
Both sample rates matter: the spec only tabulates filter coefficients at 48 kHz,
so the K-weighting is derived from the analog prototype and works at any rate.

Correlation was checked against known signals — identical channels read +1.000,
polarity-inverted read −1.000, independent noise +0.0007.

True peak follows the BS.1770 Annex 2 method but not its exact tabulated filter.
Across seven comparison files it was within 0.05 dB of ffmpeg on typical masters
and 0.13 dB on the most heavily clipped one, where the choice of interpolation
filter matters most. Good enough to judge headroom; not certified.

## Profiles

| Profile | Target | True peak ceiling |
|---|---|---|
| Club / DJ | none | −0.3 dBTP |
| Streaming | −14 LUFS ±1 | −1.0 dBTP |
| Apple Music | −16 LUFS ±1 | −1.0 dBTP |
| Broadcast | −23 LUFS ±0.5 | −1.0 dBTP |

Switching profile re-evaluates instantly — nothing is decoded again.

## Export

**Contact sheet** — the whole batch as one PNG at 2x, every row identical to what
the window draws, because it is the same renderer.

**CSV** — every measured number plus the verdict, for when you want it in a
spreadsheet.

## Distribution

Ad-hoc signed, not notarized. First launch on another Mac needs control-click →
Open, or `xattr -dr com.apple.quarantine /Applications/Manifest.app`.
