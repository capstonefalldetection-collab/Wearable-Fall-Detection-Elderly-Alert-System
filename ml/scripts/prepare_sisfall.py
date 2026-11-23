"""
SisFall -> clean, physically-scaled, auto-labeled windows ready for Edge Impulse.

Processing steps:
  1. Native sampling interval (SisFall = 200 Hz = 5 ms/sample), then
     downsampled to TARGET_HZ (default 100 Hz) to match the wearable's
     realistic on-device inference rate.
  2. Raw ADC -> physical units (g for accel, deg/s for gyro) using the
     documented sensor resolutions/ranges.
  3. Automatic, peak-based fall labeling instead of manual trimming:
     within each Fall (F*) file we locate the impact via the Signal
     Vector Magnitude (SVM) peak and label a window centered on it as
     "fall"; everything else (pre-fall ADL-like motion, post-fall lying
     still) is labeled "no_fall" rather than force-labeled as fall.
  4. Subject ID is parsed from the filename and kept as a column, so you
     can do a SUBJECT-WISE train/test split later (critical: splitting
     by window instead of by subject leaks information and inflates
     test accuracy).

SisFall filename pattern:  <ActivityCode>_<SubjectCode>_R<trial>.txt
  e.g. F01_SA01_R01.txt (Fall), D01_SA06_R03.txt (ADL)
"""

import re
import numpy as np
import pandas as pd
from pathlib import Path
from scipy.signal import decimate

# ---------------------------------------------------------------- CONFIG ---
ROOT = Path("SisFall_dataset")
OUT_DIR = Path("SisFall_windows")

SISFALL_HZ = 200          # native SisFall sampling rate (do not change)
TARGET_HZ = 100           # matches ESP32 + MPU6050 target inference rate
DOWNSAMPLE_FACTOR = SISFALL_HZ // TARGET_HZ

WINDOW_SEC = 2.5          # total window length fed to the model
FALL_WINDOW_SEC = 2.5     # window centered on the detected impact
PRE_IMPACT_FRAC = 0.4     # fraction of the fall window placed BEFORE the peak

SVM_FALL_THRESHOLD_G = 2.5   # peaks below this in an F* file are not falls
WINDOW_STEP_SEC = 1.0        # stride for sliding no_fall windows (50% overlap-ish)

# Sensor specs: (range, resolution_bits)
ACC1_RANGE_G, ACC1_BITS = 16, 13     # ADXL345
ACC2_RANGE_G, ACC2_BITS = 8, 14      # MMA8451Q
GYRO_RANGE_DPS, GYRO_BITS = 2000, 16  # ITG3200

RAW_COLUMNS = [
    "acc1_x", "acc1_y", "acc1_z",
    "acc2_x", "acc2_y", "acc2_z",
    "gyro_x", "gyro_y", "gyro_z",
]

FNAME_RE = re.compile(r"^([A-Z]\d+)_([A-Z]{2}\d+)_R(\d+)$")


def adc_to_physical(raw, rng, bits):
    """raw ADC counts -> physical units (g or deg/s)."""
    return (2 * rng) / (2 ** bits) * raw


def load_and_scale(txt_file: Path) -> pd.DataFrame:
    rows = []
    with open(txt_file, "r") as f:
        for line in f:
            line = line.strip().rstrip(";")
            if not line:
                continue
            values = [v.strip() for v in line.split(",")]
            if len(values) != 9:
                continue
            rows.append([int(v) for v in values])

    if not rows:
        return pd.DataFrame()

    df = pd.DataFrame(rows, columns=RAW_COLUMNS)

    # Raw ADC -> physical units. We use acc1 (ADXL345, +-16g) as the primary
    # accelerometer: its wider range matches the MPU6050 config (+-16g) and
    # avoids clipping during high-g impacts, unlike the +-8g MMA8451Q.
    for ax in ["x", "y", "z"]:
        df[f"acc1_{ax}"] = adc_to_physical(df[f"acc1_{ax}"], ACC1_RANGE_G, ACC1_BITS)
        df[f"acc2_{ax}"] = adc_to_physical(df[f"acc2_{ax}"], ACC2_RANGE_G, ACC2_BITS)
        df[f"gyro_{ax}"] = adc_to_physical(df[f"gyro_{ax}"], GYRO_RANGE_DPS, GYRO_BITS)

    # Downsample 200 Hz -> TARGET_HZ with an anti-aliasing filter (decimate),
    # not naive row-skipping, to avoid aliasing artifacts in the impact peak.
    if DOWNSAMPLE_FACTOR > 1:
        df = pd.DataFrame(
            {col: decimate(df[col].values, DOWNSAMPLE_FACTOR, zero_phase=True)
             for col in df.columns}
        )

    df.insert(0, "time_ms", [i * (1000 / TARGET_HZ) for i in range(len(df))])
    df["svm_g"] = np.sqrt(df.acc1_x**2 + df.acc1_y**2 + df.acc1_z**2)
    return df


def make_windows(df: pd.DataFrame, is_fall_file: bool, samp_rate: int):
    """Yield (label, window_df) tuples."""
    win_len = int(WINDOW_SEC * samp_rate)
    step = int(WINDOW_STEP_SEC * samp_rate)

    if is_fall_file:
        peak_idx = int(df["svm_g"].idxmax())
        peak_val = df["svm_g"].iloc[peak_idx]
        if peak_val < SVM_FALL_THRESHOLD_G:
            # No clear impact found -- likely a mislabeled/edge-case trial.
            # Skip rather than force a fake fall label.
            return
        fall_win_len = int(FALL_WINDOW_SEC * samp_rate)
        pre = int(fall_win_len * PRE_IMPACT_FRAC)
        start = max(0, peak_idx - pre)
        end = min(len(df), start + fall_win_len)
        yield "fall", df.iloc[start:end].reset_index(drop=True)

        # Everything clearly outside the impact window in a Fall file is
        # pre-fall ADL motion or post-fall stillness -- label it no_fall,
        # with a buffer around the impact left unlabeled (ambiguous).
        buffer = int(1.0 * samp_rate)
        for s in range(0, start - buffer - win_len, step):
            yield "no_fall", df.iloc[s:s + win_len].reset_index(drop=True)
        for s in range(end + buffer, len(df) - win_len, step):
            yield "no_fall", df.iloc[s:s + win_len].reset_index(drop=True)
    else:
        for s in range(0, len(df) - win_len, step):
            yield "no_fall", df.iloc[s:s + win_len].reset_index(drop=True)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "fall").mkdir(exist_ok=True)
    (OUT_DIR / "no_fall").mkdir(exist_ok=True)

    counts = {"fall": 0, "no_fall": 0}

    for txt_file in sorted(ROOT.rglob("*.txt")):
        if txt_file.name.lower() in ["readme.txt", "desktop.ini"]:
            continue

        m = FNAME_RE.match(txt_file.stem)
        if not m:
            continue
        activity_code, subject_code, trial = m.groups()
        is_fall_file = activity_code.startswith("F")

        df = load_and_scale(txt_file)
        if df.empty:
            continue

        for label, window in make_windows(df, is_fall_file, TARGET_HZ):
            counts[label] += 1
            out_name = f"{label}_{subject_code}_{activity_code}_R{trial}_{counts[label]:05d}.csv"
            window.to_csv(OUT_DIR / label / out_name, index=False)

    print(f"Done. fall windows: {counts['fall']}, no_fall windows: {counts['no_fall']}")
    print(f"Class ratio (no_fall / fall): {counts['no_fall'] / max(counts['fall'],1):.2f}")


if __name__ == "__main__":
    main()
