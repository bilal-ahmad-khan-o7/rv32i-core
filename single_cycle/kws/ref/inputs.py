"""The test inputs: 490 INT8 values each (49 frames x 10 MFCCs).

Synthetic inputs stress the arithmetic and the layout. Real inputs are INT8 MFCC
features of Speech Commands v2 recordings, published by EEMBC for MLPerf Tiny
(eembc/energyrunner, datasets/kws01): the exact output of the MLPerf pipeline.
Twelve of them, one per class, are in kws/inputs/real. The other 988 stay outside
git (kws/inputs/eembc_all, see fetch_eembc.py): EEMBC's files carry no open licence.
"""
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
REAL_DIR = ROOT / "kws" / "inputs" / "real"
ALL_DIR = ROOT / "kws" / "inputs" / "eembc_all"

WORDS = ["Down", "Go", "Left", "No", "Off", "On", "Right", "Stop", "Up", "Yes", "Silence", "Unknown"]


def synthetic():
    """{name: 490 int8}. The same bytes on every run."""
    rng = np.random.default_rng(2026)
    ramp = np.array([[(3 * y + 7 * x) % 256 - 128 for x in range(10)] for y in range(49)], dtype=np.int8)
    impulse = np.full((49, 10), 83, dtype=np.int8)     # the zero point everywhere...
    impulse[0, 0] = 127                                # ... except the corners,
    impulse[48, 9] = -128                              # next to the padding
    return {
        "syn_min": np.full(490, -128, dtype=np.int8),
        "syn_max": np.full(490, 127, dtype=np.int8),
        "syn_zp": np.full(490, 83, dtype=np.int8),     # the real value 0.0
        "syn_zero": np.zeros(490, dtype=np.int8),
        "syn_random": rng.integers(-128, 128, 490, dtype=np.int16).astype(np.int8),
        "syn_ramp": ramp.ravel(),
        "syn_impulse": impulse.ravel(),
    }


def label_of(path):
    """tst_000005_Down_0.bin -> 0"""
    return int(Path(path).stem.rsplit("_", 1)[1])


def real():
    """{file stem: 490 int8} for the 12 committed files."""
    return {p.stem: np.fromfile(p, dtype=np.int8) for p in sorted(REAL_DIR.glob("*.bin"))}


def regression():
    """Every input with committed expected outputs."""
    return {**synthetic(), **real()}
