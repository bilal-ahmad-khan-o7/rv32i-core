"""Fetch all 1000 EEMBC kws01 feature files into kws/inputs/eembc_all (not committed).

    python3 kws/ref/fetch_eembc.py

Each file is 490 INT8 values: the MFCC features of one Speech Commands v2 test
recording, from eembc/energyrunner (datasets/kws01). The file names give the word
and the label. EEMBC's files carry no open licence, so none are committed;
copy the 12 the README names into kws/inputs/real. See the README, "Inputs".
"""
import concurrent.futures
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "kws" / "inputs" / "eembc_all"
INDEX = "https://raw.githubusercontent.com/mlcommons/tiny/master/benchmark/evaluation/datasets/kws01/y_labels.csv"
BASE = "https://raw.githubusercontent.com/eembc/energyrunner/main/datasets/kws01/"


def fetch(name):
    path = OUT / name
    if path.exists() and path.stat().st_size == 490:
        return 0
    for attempt in range(5):
        try:
            data = urllib.request.urlopen(BASE + name, timeout=60).read()
            if len(data) != 490:
                raise IOError(f"{name}: {len(data)} bytes")
            path.write_bytes(data)
            return 1
        except OSError:
            if attempt == 4:
                raise
    return 0


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    text = urllib.request.urlopen(INDEX, timeout=60).read().decode()
    names = [line.split(",")[0].strip() for line in text.splitlines() if line.strip()]
    with concurrent.futures.ThreadPoolExecutor(16) as pool:
        got = sum(pool.map(fetch, names))
    print(f"{len(names)} files listed, {got} fetched, {len(list(OUT.glob('*.bin')))} present")


if __name__ == "__main__":
    main()
