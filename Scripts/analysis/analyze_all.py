#!/usr/bin/env python3
"""
Analyze every audio file in a directory. The filename determines the category
and whether it's a keep-pattern or a filter-pattern, e.g.:

    "Clap with hands - Keep.m4a"      → category "clap",     keep=True
    "Finger tap on the desk - Keep.m4a" → category "finger-tap", keep=True
    "Keystroke - Filter.m4a"          → category "keystroke", keep=False

Outputs:
  * <dir>/_combined.spectrogram.png        (one panel per file)
  * <dir>/_combined.histograms.png         (centroid/peak/decay/flatness)
  * <dir>/_combined.events.csv             (every onset across all files)
  * Stdout: per-category stats + recommended thresholds + per-file accuracy
"""
import os
import sys
import csv
import re
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Reuse the building blocks from the per-file analyzer.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze_audio import load_audio_via_ffmpeg, detect_onsets, db, Onset


CATEGORY_COLORS = {
    "clap": "#3aa",
    "finger-tap": "#f93",
    "pat-desk": "#fb5",
    "keystroke": "#b35",
    "voice": "#73d",
    "other": "#888",
}


def category_from_name(stem: str) -> tuple[str, bool]:
    s = stem.lower()
    keep = "keep" in s
    if "clap" in s:
        cat = "clap"
    elif "finger" in s and "tap" in s:
        cat = "finger-tap"
    elif "pat" in s:
        cat = "pat-desk"
    elif "key" in s:
        cat = "keystroke"
    elif "voice" in s:
        cat = "voice"
    else:
        cat = re.split(r"[\s\-]+", stem)[0].lower() or "other"
    return cat, keep


def stats_summary(events: list[Onset]) -> dict:
    if not events:
        return {"n": 0}
    c = np.array([e.centroid_hz for e in events])
    p = np.array([e.peak_db for e in events])
    r = np.array([e.rms_db for e in events])
    d = np.array([e.decay_ms for e in events])
    f = np.array([e.flatness for e in events])
    return {
        "n": len(events),
        "centroid_hz": (np.percentile(c, 5), np.median(c), np.percentile(c, 95)),
        "peak_db":     (np.percentile(p, 5), np.median(p), np.percentile(p, 95)),
        "rms_db":      (np.percentile(r, 5), np.median(r), np.percentile(r, 95)),
        "decay_ms":    (np.percentile(d, 5), np.median(d), np.percentile(d, 95)),
        "flatness":    (np.percentile(f, 5), np.median(f), np.percentile(f, 95)),
    }


def grid_search_thresholds(by_category: dict[str, list[Onset]], keep_cats: set[str], reject_cats: set[str]) -> dict:
    """3D grid over (peak_min, flatness_min, centroid_max). Score = keep_rate * reject_rate.
    Plus per-reject-category breakdown so we can see which filters catch which noise."""
    keep = []
    reject = []
    by_reject_cat = {}
    for cat, evs in by_category.items():
        if cat in keep_cats:
            keep.extend(evs)
        elif cat in reject_cats:
            reject.extend(evs)
            by_reject_cat[cat] = evs
    if not keep or not reject:
        return {}

    peak_grid = np.arange(-44, -19, 1)
    flat_grid = np.arange(0.0, 0.31, 0.02)
    centroid_grid = np.concatenate([np.arange(2000, 7001, 500), [99999]])  # last = effectively disabled

    # Per-category recall — keystroke rejection is the explicit priority.
    keystroke_evs = by_reject_cat.get("keystroke", [])
    voice_evs = by_reject_cat.get("voice", [])

    def passes(e, pmin, fmin, cmax):
        return e.peak_db >= pmin and e.flatness >= fmin and e.centroid_hz <= cmax

    best = {"score": -1.0}
    for pmin in peak_grid:
        for fmin in flat_grid:
            for cmax in centroid_grid:
                keep_kept = sum(1 for e in keep if passes(e, pmin, fmin, cmax))
                keystroke_kept = sum(1 for e in keystroke_evs if passes(e, pmin, fmin, cmax))
                voice_kept = sum(1 for e in voice_evs if passes(e, pmin, fmin, cmax))
                reject_filtered = sum(1 for e in reject if not passes(e, pmin, fmin, cmax))
                keep_rate = keep_kept / len(keep)
                reject_rate = reject_filtered / len(reject)
                # Score: prioritize keystroke rejection (hard requirement),
                # then keep rate, then voice rejection (soft).
                keystroke_reject_rate = 1.0 - (keystroke_kept / max(1, len(keystroke_evs)))
                voice_reject_rate = 1.0 - (voice_kept / max(1, len(voice_evs)))
                # Hard-floor on keystroke rejection: must be ≥ 95%; otherwise heavy penalty.
                keystroke_penalty = 0.0 if keystroke_reject_rate >= 0.95 else (0.95 - keystroke_reject_rate) * 5
                score = keep_rate * 2 + voice_reject_rate * 0.5 - keystroke_penalty
                if score > best["score"]:
                    per_cat_kept = {}
                    per_cat_total = {}
                    for cat, evs in by_reject_cat.items():
                        per_cat_total[cat] = len(evs)
                        per_cat_kept[cat] = sum(1 for e in evs if passes(e, pmin, fmin, cmax))
                    per_keep_kept = {}
                    per_keep_total = {}
                    for cat, evs in by_category.items():
                        if cat not in keep_cats:
                            continue
                        per_keep_total[cat] = len(evs)
                        per_keep_kept[cat] = sum(1 for e in evs if passes(e, pmin, fmin, cmax))
                    best = {
                        "score": round(score, 3),
                        "peak_min_db": int(pmin),
                        "flatness_min": round(float(fmin), 2),
                        "centroid_max_hz": "off" if cmax >= 99999 else int(cmax),
                        "keep_kept": keep_kept,
                        "keep_total": len(keep),
                        "keep_rate": round(keep_rate, 3),
                        "reject_filtered": reject_filtered,
                        "reject_total": len(reject),
                        "reject_rate": round(reject_rate, 3),
                        "kept_per_keep_cat": {
                            c: f"{per_keep_kept[c]}/{per_keep_total[c]}" for c in per_keep_total
                        },
                        "false_positives_per_reject_cat": {
                            c: f"{per_cat_kept[c]}/{per_cat_total[c]}" for c in per_cat_total
                        },
                    }
    return best


def plot_combined(per_file: dict[str, tuple[np.ndarray, int, list[Onset]]], out_path: str):
    n = len(per_file)
    fig, axes = plt.subplots(n, 1, figsize=(14, 2.5 * n), squeeze=False)
    for i, (name, (samples, sr, events)) in enumerate(per_file.items()):
        ax = axes[i, 0]
        pxx, freqs, bins, im = ax.specgram(samples, NFFT=1024, Fs=sr, noverlap=512, cmap="magma")
        for e in events:
            ax.axvline(e.t, color="cyan", alpha=0.5, linewidth=0.6)
        ax.set_ylim(0, min(8000, sr / 2))
        ax.set_ylabel("Hz")
        ax.set_title(f"{name}  (n_onsets={len(events)})")
    axes[-1, 0].set_xlabel("time (s)")
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)


def plot_distributions(by_category: dict[str, list[Onset]], out_path: str):
    fig, axes = plt.subplots(2, 2, figsize=(14, 9))
    metrics = [
        ("centroid_hz", "Spectral centroid (Hz)", 2500, axes[0, 0]),
        ("peak_db",     "Peak (dBFS)",            -35,  axes[0, 1]),
        ("decay_ms",    "Decay to −12 dB (ms)",   None, axes[1, 0]),
        ("flatness",    "Spectral flatness",      None, axes[1, 1]),
    ]
    for attr, title, current_cut, ax in metrics:
        for cat, ev in by_category.items():
            if not ev:
                continue
            vals = [getattr(e, attr) for e in ev]
            ax.hist(vals, bins=30, alpha=0.55, label=f"{cat} (n={len(ev)})",
                    color=CATEGORY_COLORS.get(cat, "#888"))
        ax.set_title(title)
        if current_cut is not None:
            ax.axvline(current_cut, color="red", linestyle="--",
                       label=f"current cut {current_cut}")
        ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)


def main():
    audio_dir = Path(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__)))
    files = sorted(p for p in audio_dir.iterdir() if p.suffix.lower() in (".m4a", ".wav", ".mp3"))
    if not files:
        print(f"no audio files in {audio_dir}")
        sys.exit(1)

    per_file: dict[str, tuple[np.ndarray, int, list[Onset]]] = {}
    by_category: dict[str, list[Onset]] = {}
    keep_cats = set()
    reject_cats = set()

    for path in files:
        cat, keep = category_from_name(path.stem)
        (keep_cats if keep else reject_cats).add(cat)
        print(f"==> {path.name}  → category={cat} ({'keep' if keep else 'filter'})")
        samples, sr = load_audio_via_ffmpeg(str(path))
        # Use a relatively permissive threshold so we capture every event;
        # we'll then look at distribution properties to pick the right cut.
        events, _ = detect_onsets(samples, sr,
                                  threshold_db_above_floor=4.0,
                                  crest_min_db=3.0,
                                  refractory_s=0.05)
        per_file[path.name] = (samples, sr, events)
        by_category.setdefault(cat, []).extend(events)
        st = stats_summary(events)
        if st["n"]:
            print(f"     n={st['n']}  centroid p5/p50/p95={st['centroid_hz'][0]:.0f}/{st['centroid_hz'][1]:.0f}/{st['centroid_hz'][2]:.0f} Hz   "
                  f"peak={st['peak_db'][0]:.1f}/{st['peak_db'][1]:.1f}/{st['peak_db'][2]:.1f} dB   "
                  f"decay={st['decay_ms'][0]:.0f}/{st['decay_ms'][1]:.0f}/{st['decay_ms'][2]:.0f} ms   "
                  f"flat={st['flatness'][0]:.2f}/{st['flatness'][1]:.2f}/{st['flatness'][2]:.2f}")
        else:
            print("     no onsets detected")

    print("\n==> Per-category aggregate")
    for cat, ev in by_category.items():
        st = stats_summary(ev)
        if not st["n"]:
            continue
        tag = "KEEP" if cat in keep_cats else "REJECT"
        print(f"  {tag:6s}  {cat:12s} n={st['n']:3d}  "
              f"centroid p5/p50/p95={st['centroid_hz'][0]:>5.0f}/{st['centroid_hz'][1]:>5.0f}/{st['centroid_hz'][2]:>5.0f} Hz   "
              f"peak={st['peak_db'][0]:>+5.1f}/{st['peak_db'][1]:>+5.1f}/{st['peak_db'][2]:>+5.1f} dB   "
              f"decay={st['decay_ms'][0]:>3.0f}/{st['decay_ms'][1]:>3.0f}/{st['decay_ms'][2]:>3.0f} ms   "
              f"flat={st['flatness'][0]:.2f}/{st['flatness'][1]:.2f}/{st['flatness'][2]:.2f}")

    out_spec = audio_dir / "_combined.spectrogram.png"
    out_dist = audio_dir / "_combined.histograms.png"
    out_csv = audio_dir / "_combined.events.csv"
    plot_combined(per_file, str(out_spec))
    plot_distributions(by_category, str(out_dist))
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["file", "category", "keep", "t_sec", "peak_db", "rms_db", "centroid_hz", "flatness", "decay_ms"])
        for fname, (_, _, events) in per_file.items():
            cat, keep = category_from_name(Path(fname).stem)
            for e in events:
                w.writerow([fname, cat, keep, f"{e.t:.3f}",
                            f"{e.peak_db:.2f}", f"{e.rms_db:.2f}",
                            f"{e.centroid_hz:.1f}", f"{e.flatness:.3f}",
                            f"{e.decay_ms:.1f}"])

    print(f"\n==> Plots: {out_spec.name} · {out_dist.name}")
    print(f"==> CSV:   {out_csv.name}")

    print(f"\n==> Grid-search recommendation (keep={sorted(keep_cats)} reject={sorted(reject_cats)})")
    rec = grid_search_thresholds(by_category, keep_cats, reject_cats)
    if rec:
        for k, v in rec.items():
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
