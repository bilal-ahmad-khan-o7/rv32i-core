"""Check the Python references against TFLite on every layer.

    python3 kws/ref/check_ref.py          # the 19 committed inputs
    python3 kws/ref/check_ref.py --all    # also the 1000 EEMBC files, if fetched

The reference is TFLite with its reference kernels (OpResolverType.BUILTIN_REF).
The NumPy model must equal it byte for byte on every layer. The script also runs
TFLite's other kernels and reports whether they differ from the reference ones.
"""
import sys

import numpy as np
from ai_edge_litert.interpreter import OpResolverType

import inputs
import model
import ref_numpy


def tflite_layers(it, layers, x):
    index, shape = model.input_details(it)
    it.set_tensor(index, np.asarray(x, dtype=np.int8).reshape(shape))
    it.invoke()
    return {i: it.get_tensor(layers[i].output_tensor).copy() for i in layers}


def check_fc_formula(fc):
    """The core's integer FC rounding must equal TFLite's float one on every accumulator
    any input can reach. Returns (lowest, highest), or stops the run."""
    w = fc.weights.astype(np.int64)
    lo_in, hi_in = -128 - fc.input_zp, 127 - fc.input_zp
    hi = int((np.clip(w, 0, None).sum(axis=1) * hi_in + np.clip(w, None, 0).sum(axis=1) * lo_in + fc.bias).max())
    lo = int((np.clip(w, None, 0).sum(axis=1) * hi_in + np.clip(w, 0, None).sum(axis=1) * lo_in + fc.bias).min())
    acc = np.arange(lo, hi + 1, dtype=np.int64)
    bad = int(np.count_nonzero(ref_numpy.fc_float_rounding(acc, fc) != ref_numpy.fc_integer_rounding(acc, fc)))
    if bad:
        raise SystemExit(f"FAIL: FC integer rounding differs from TFLite's on {bad} reachable accumulators")
    return lo, hi


def main():
    cases = inputs.regression()
    if "--all" in sys.argv:
        cases.update({p.stem: np.fromfile(p, dtype=np.int8) for p in sorted(inputs.ALL_DIR.glob("*.bin"))})
    ref = model.open_interpreter()
    layers = model.load_layers(ref)
    print("layer  kind       output zp  input zp  right shift")
    for l in layers.values():
        sh = f"{-l.shift.max()}..{-l.shift.min()}" if l.shift is not None else "-"
        print(f"{l.id:5}  {l.kind:9}  {l.output_zp:9}  {l.input_zp:8}  {sh}")
    lo, hi = check_fc_formula(layers[12])
    print(f"FC: integer rounding equals TFLite's float rounding on every accumulator from {lo} to {hi}")

    others ={name: model.open_interpreter(kind) for name, kind in
              (("BUILTIN", OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES), ("AUTO (default)", OpResolverType.AUTO))}
    other_diffs = {name: 0 for name in others}
    bad = softmax_changes = 0
    for name, x in cases.items():
        t = tflite_layers(ref, layers, x)
        n = ref_numpy.run(x, layers)
        softmax_changes += int(np.argmax(t[13]) != np.argmax(t[12]))
        for i in n:
            d = int(np.count_nonzero(n[i].ravel() != t[i].ravel()))
            if d:
                print(f"DIFF {name}: layer {i}: {d} of {t[i].size} bytes differ")
                bad += d
        for other, it in others.items():
            o = tflite_layers(it, layers, x)
            other_diffs[other] += sum(int(np.count_nonzero(o[i].ravel() != t[i].ravel())) for i in n)
    print(f"{len(cases)} inputs, {len(n)} layers each: NumPy vs TFLite reference kernels: {bad} bytes differ")
    print(f"inputs where TFLite's softmax has a different arg-max from the 12 FC scores: {softmax_changes}")
    for other, d in other_diffs.items():
        print(f"TFLite {other} kernels vs reference kernels: {d} bytes differ")
    print("PASS: check_ref" if bad == 0 else "FAIL: check_ref")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
