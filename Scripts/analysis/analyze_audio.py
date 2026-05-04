#!/usr/bin/env python3
"""
Analyze a Tango test recording: detect onsets, compute spectral features per
event, and recommend keystroke-rejection thresholds.

Usage:
    ./analyze_audio.py <input-file>                 # auto-detect events
    ./analyze_audio.py <input-file> --label-ranges 'claps:5-15,typing:20-30'
        # tell the script which time ranges contain which gesture, so it can
        # show centroid/peak distributions per category and recommend a cut.

Accepts any format ffmpeg can read (.wav, .m4a, .mp3, …). Outputs:
  * <file>.spectrogram.png  — time/freq spectrogram with onset markers
  * <file>.histograms.png   — peak/centroid histograms per category
  * <file>.events.csv       — every detected onset row
  * Stdout: per-category stats + recommended thresholds
"""
import argparse
import csv
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy.io import wavfile
from scipy.signal import butter, lfilter


# ---------- Audio I/O ----------

def load_audio_via_ffmpeg(path: str, target_sr: int = 48000) -> tuple[np.ndarray, int]:
    """Decode any audio file to mono float32 at target_sr via ffmpeg pipe."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", path,
            "-ac", "1",
            "-ar", str(target_sr),
            "-acodec", "pcm_s16le",
            tmp_path,
        ]
        subprocess.run(cmd, check=True)
        sr, samples = wavfile.read(tmp_path)
        if samples.dtype == np.int16:
            samples = samples.astype(np.float32) / 32768.0
        elif samples.dtype == np.int32:
            samples = samples.astype(np.float32) / (2**31)
        else:
            samples = samples.astype(np.float32)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        return samples, sr
    finally:
        os.unlink(tmp_path)


# ---------- DSP helpers ----------

def highpass(samples: np.ndarray, sr: int, cutoff_hz: float = 200) -> np.ndarray:
    nyq = sr / 2
    b, a = butter(2, cutoff_hz / nyq, btype="highpass")
    return lfilter(b, a, samples).astype(np.float32)


def db(x: float, eps: float = 1e-7) -> float:
    return 20.0 * np.log10(max(abs(x), eps))


@dataclass
class Onset:
    t: float                # event time (s)
    peak_db: float
    rms_db: float
    centroid_hz: float
    flatness: float
    decay_ms: float         # time for envelope to fall 12 dB after peak


def detect_onsets(
    samples: np.ndarray,
    sr: int,
    *,
    buffer_size: int = 1024,
    threshold_db_above_floor: float = 6.0,
    crest_min_db: float = 4.0,
    refractory_s: float = 0.05,
) -> tuple[list[Onset], np.ndarray]:
    """Buffer-by-buffer onset detection. Returns events + per-buffer rms history."""
    filtered = highpass(samples, sr)
    n_buffers = len(filtered) // buffer_size
    rms_history = np.zeros(n_buffers, dtype=np.float32)
    floor_db = -50.0
    floor_alpha = 0.05
    refractory_until = -1.0
    events: list[Onset] = []
    for b in range(n_buffers):
        seg = filtered[b * buffer_size:(b + 1) * buffer_size]
        rms = float(np.sqrt(np.mean(seg ** 2)))
        peak = float(np.max(np.abs(seg)))
        rms_db = db(rms)
        peak_db = db(peak)
        rms_history[b] = rms_db
        t = b * buffer_size / sr
        if t < refractory_until:
            # still in refractory; let floor catch up but don't emit
            target = min(rms_db, floor_db + 6)
            floor_db = floor_db * (1 - floor_alpha) + target * floor_alpha
            continue
        above_floor = rms_db - floor_db
        crest = peak_db - rms_db
        if above_floor > threshold_db_above_floor and crest > crest_min_db:
            # Compute spectral features on this buffer (Hann + FFT, 1024 pts).
            window = np.hanning(buffer_size).astype(np.float32)
            spec = np.fft.rfft(seg * window)
            mag = np.abs(spec)
            # Drop very-low bins (DC + sub-150 Hz).
            low_bin = max(2, int(150 * buffer_size / sr))
            sub = mag[low_bin:]
            arith = float(np.mean(sub)) + 1e-12
            geom = float(np.exp(np.mean(np.log(np.maximum(sub, 1e-12)))))
            flatness = geom / arith
            freqs = np.linspace(0, sr / 2, len(mag))
            centroid = float(np.sum(freqs[low_bin:] * sub) / (np.sum(sub) + 1e-12))
            # Decay time: walk forward through subsequent buffers' rms_db until
            # we drop 12 dB from the peak (or hit 200 ms).
            decay_ms = 200.0
            for b2 in range(b + 1, min(n_buffers, b + 10)):
                seg2 = filtered[b2 * buffer_size:(b2 + 1) * buffer_size]
                r2 = db(float(np.sqrt(np.mean(seg2 ** 2))))
                if r2 < rms_db - 12:
                    decay_ms = (b2 - b) * buffer_size / sr * 1000.0
                    break
            events.append(
                Onset(t=t, peak_db=peak_db, rms_db=rms_db,
                      centroid_hz=centroid, flatness=flatness, decay_ms=decay_ms)
            )
            refractory_until = t + refractory_s
        else:
            target = min(rms_db, floor_db + 6)
            floor_db = floor_db * (1 - floor_alpha) + target * floor_alpha
    return events, rms_history


# ---------- Plotting ----------

def plot_spectrogram(samples: np.ndarray, sr: int, events: list[Onset], out_path: str):
    fig, ax = plt.subplots(figsize=(14, 4))
    pxx, freqs, bins, im = ax.specgram(samples, NFFT=1024, Fs=sr, noverlap=512, cmap="magma")
    for e in events:
        ax.axvline(e.t, color="cyan", alpha=0.4, linewidth=0.7)
    ax.set_ylim(0, min(8000, sr / 2))
    ax.set_ylabel("Hz")
    ax.set_xlabel("time (s)")
    ax.set_title(f"Spectrogram + onsets (n={len(events)})")
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)


def plot_histograms(events: list[Onset], categories: dict[str, list[Onset]], out_path: str):
    fig, axes = plt.subplots(1, 3, figsize=(15, 4))
    colors = {"claps": "#3aa", "tap-desk": "#f93", "typing": "#b35", "other": "#888"}

    # Centroid
    for cat, ev in categories.items():
        if not ev:
            continue
        axes[0].hist(
            [e.centroid_hz for e in ev],
            bins=30, alpha=0.6,
            label=f"{cat} (n={len(ev)})",
            color=colors.get(cat, "#888"),
        )
    axes[0].set_title("Spectral centroid (Hz)")
    axes[0].axvline(2500, color="red", linestyle="--", label="current cut 2500Hz")
    axes[0].set_xlabel("Hz"); axes[0].legend()

    # Peak
    for cat, ev in categories.items():
        if not ev:
            continue
        axes[1].hist(
            [e.peak_db for e in ev],
            bins=30, alpha=0.6,
            label=f"{cat} (n={len(ev)})",
            color=colors.get(cat, "#888"),
        )
    axes[1].set_title("Peak (dBFS)")
    axes[1].axvline(-35, color="red", linestyle="--", label="current cut -35 dB")
    axes[1].set_xlabel("dB"); axes[1].legend()

    # Decay
    for cat, ev in categories.items():
        if not ev:
            continue
        axes[2].hist(
            [e.decay_ms for e in ev],
            bins=30, alpha=0.6,
            label=f"{cat} (n={len(ev)})",
            color=colors.get(cat, "#888"),
        )
    axes[2].set_title("Decay to −12 dB (ms)")
    axes[2].set_xlabel("ms"); axes[2].legend()

    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)


# ---------- Recommendation ----------

def recommend_thresholds(categories: dict[str, list[Onset]]) -> dict:
    """Pick (centroid_max, peak_min) that separate keep-set from reject-set."""
    keep = []
    for cat, ev in categories.items():
        if cat in ("claps", "tap-desk", "tap-case"):
            keep.extend(ev)
    reject = []
    for cat, ev in categories.items():
        if cat in ("typing", "keys"):
            reject.extend(ev)
    if not keep or not reject:
        return {"note": "need both keep and reject categories for recommendation"}
    keep_centroid_max = float(np.percentile([e.centroid_hz for e in keep], 95))
    reject_centroid_min = float(np.percentile([e.centroid_hz for e in reject], 5))
    keep_peak_min = float(np.percentile([e.peak_db for e in keep], 5))
    reject_peak_max = float(np.percentile([e.peak_db for e in reject], 95))
    return {
        "keep_centroid_p95_hz": round(keep_centroid_max, 1),
        "reject_centroid_p5_hz": round(reject_centroid_min, 1),
        "centroid_recommended_max_hz": round((keep_centroid_max + reject_centroid_min) / 2, 1),
        "keep_peak_p5_db": round(keep_peak_min, 2),
        "reject_peak_p95_db": round(reject_peak_max, 2),
        "peak_recommended_min_db": round((keep_peak_min + reject_peak_max) / 2, 2),
        "n_keep": len(keep),
        "n_reject": len(reject),
    }


# ---------- Main ----------

def parse_label_ranges(s: str) -> dict[str, list[tuple[float, float]]]:
    """e.g. 'claps:5-12,typing:20-30,tap-desk:13-19'"""
    out: dict[str, list[tuple[float, float]]] = {}
    if not s:
        return out
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        cat, rng = part.split(":")
        a, b = rng.split("-")
        out.setdefault(cat.strip(), []).append((float(a), float(b)))
    return out


def categorize(events: list[Onset], ranges: dict[str, list[tuple[float, float]]]) -> dict[str, list[Onset]]:
    cats: dict[str, list[Onset]] = {k: [] for k in ranges}
    cats["other"] = []
    for e in events:
        placed = False
        for cat, rngs in ranges.items():
            for a, b in rngs:
                if a <= e.t <= b:
                    cats[cat].append(e)
                    placed = True
                    break
            if placed:
                break
        if not placed:
            cats["other"].append(e)
    return cats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--label-ranges", default="",
                    help="comma-separated 'category:start-end' pairs in seconds")
    ap.add_argument("--threshold-db", type=float, default=6.0)
    ap.add_argument("--crest-db", type=float, default=4.0)
    args = ap.parse_args()

    base, _ = os.path.splitext(args.input)
    print(f"==> Loading {args.input}")
    samples, sr = load_audio_via_ffmpeg(args.input)
    duration = len(samples) / sr
    print(f"    sr={sr}, duration={duration:.2f}s, peak={db(np.max(np.abs(samples))):.1f} dB")

    print(f"==> Detecting onsets (threshold +{args.threshold_db} dB above floor, crest > {args.crest_db} dB)")
    events, _ = detect_onsets(
        samples, sr,
        threshold_db_above_floor=args.threshold_db,
        crest_min_db=args.crest_db,
    )
    print(f"    detected {len(events)} onsets")

    ranges = parse_label_ranges(args.label_ranges)
    categories = categorize(events, ranges) if ranges else {"all": events}

    # Print per-category stats
    print("\n==> Per-category stats")
    for cat, ev in categories.items():
        if not ev:
            continue
        c = np.array([e.centroid_hz for e in ev])
        p = np.array([e.peak_db for e in ev])
        d = np.array([e.decay_ms for e in ev])
        print(f"  {cat:>10s}  n={len(ev):3d}  "
              f"centroid={np.median(c):>5.0f} Hz [p5={np.percentile(c,5):>5.0f}, p95={np.percentile(c,95):>5.0f}]  "
              f"peak={np.median(p):>+5.1f} dB [p5={np.percentile(p,5):>+5.1f}, p95={np.percentile(p,95):>+5.1f}]  "
              f"decay={np.median(d):>4.0f} ms")

    # Spectrogram + histograms
    spec_path = base + ".spectrogram.png"
    hist_path = base + ".histograms.png"
    csv_path = base + ".events.csv"
    plot_spectrogram(samples, sr, events, spec_path)
    plot_histograms(events, categories, hist_path)

    with open(csv_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t_sec", "category", "peak_db", "rms_db", "centroid_hz", "flatness", "decay_ms"])
        # Reverse-lookup category for each event
        cat_by_event = {id(e): cat for cat, evs in categories.items() for e in evs}
        for e in events:
            cat = cat_by_event.get(id(e), "other")
            w.writerow([f"{e.t:.3f}", cat, f"{e.peak_db:.2f}",
                        f"{e.rms_db:.2f}", f"{e.centroid_hz:.1f}",
                        f"{e.flatness:.3f}", f"{e.decay_ms:.1f}"])

    print(f"\n==> Wrote {spec_path}")
    print(f"==> Wrote {hist_path}")
    print(f"==> Wrote {csv_path}")

    if ranges:
        print("\n==> Recommended thresholds")
        rec = recommend_thresholds(categories)
        for k, v in rec.items():
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
