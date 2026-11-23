"""The KWS model as plain arrays: weights, biases and integer quantisation parameters.

Everything is read from kws/model/kws_ref_model.tflite (MLPerf Tiny keyword spotting,
from mlcommons/tiny, Apache-2.0). The layer numbers are the ones in the README:

     1      CONV_2D 10x4, stride 2, 64 filters        49x10x1 -> 25x5x64
     2,4,6,8  DEPTHWISE_CONV_2D 3x3                   25x5x64 -> 25x5x64
     3,5,7,9  CONV_2D 1x1 (pointwise)                 25x5x64 -> 25x5x64
    10      AVERAGE_POOL_2D 25x5                      -> 64
    11      RESHAPE (no work)
    12      FULLY_CONNECTED 64 -> 12
    13      SOFTMAX (not run on the core)
"""
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from ai_edge_litert.interpreter import Interpreter, OpResolverType

ROOT = Path(__file__).resolve().parents[2]
MODEL_PATH = ROOT / "kws" / "model" / "kws_ref_model.tflite"


def quantize_multiplier(d):
    """TFLite's QuantizeMultiplier: d = M * 2^(shift - 31), with M in [2^30, 2^31)."""
    if d == 0.0:
        return 0, 0
    q, shift = math.frexp(d)
    m = math.floor(q * (1 << 31) + 0.5)      # TfLiteRound: halves round away from zero
    if m == 1 << 31:
        m //= 2
        shift += 1
    return m, shift


@dataclass
class Layer:
    id: int
    kind: str                # conv, depthwise, pool, reshape, fc, softmax
    output_tensor: int
    weights: np.ndarray = None   # int8, in the file's layout
    bias: np.ndarray = None      # int32, one per output channel
    multiplier: np.ndarray = None  # M, one per output channel
    shift: np.ndarray = None       # TFLite's exponent (negative = right shift)
    input_zp: int = 0
    output_zp: int = 0
    float_scale: float = None      # FC only: TFLite's effective_output_scale


def open_interpreter(op_resolver=OpResolverType.BUILTIN_REF):
    """TFLite with its reference kernels and every intermediate tensor kept."""
    it = Interpreter(model_path=str(MODEL_PATH), experimental_op_resolver_type=op_resolver,
                     experimental_preserve_all_tensors=True)
    it.allocate_tensors()
    return it


def load_layers(it=None):
    """Return {layer id: Layer}, in order."""
    it = it or open_interpreter()
    details = {t["index"]: t for t in it.get_tensor_details()}
    layers = {}

    def quant(i):
        q = details[i]["quantization_parameters"]
        return q["scales"], q["zero_points"]

    for n, op in enumerate(it._get_ops_details()):
        kind = {"CONV_2D": "conv", "DEPTHWISE_CONV_2D": "depthwise", "AVERAGE_POOL_2D": "pool",
                "RESHAPE": "reshape", "FULLY_CONNECTED": "fc", "SOFTMAX": "softmax"}[op["op_name"]]
        ins, outs = [int(i) for i in op["inputs"]], [int(i) for i in op["outputs"]]
        layer = Layer(id=n + 1, kind=kind, output_tensor=outs[0])
        in_scale, in_zp = quant(ins[0])
        out_scale, out_zp = quant(outs[0])
        layer.input_zp, layer.output_zp = int(in_zp[0]), int(out_zp[0])
        if kind in ("conv", "depthwise", "fc"):
            layer.weights = it.get_tensor(ins[1]).copy()
            layer.bias = it.get_tensor(ins[2]).copy()
            w_scale, w_zp = quant(ins[1])
            assert not np.any(w_zp), "weight zero points must be 0"
            # static_cast<double>(input) * filter / static_cast<double>(output), in that order
            pairs = [quantize_multiplier(float(in_scale[0]) * float(s) / float(out_scale[0])) for s in w_scale]
            layer.multiplier = np.array([p[0] for p in pairs], dtype=np.int64)
            layer.shift = np.array([p[1] for p in pairs], dtype=np.int64)
            if kind == "fc":
                layer.float_scale = float(in_scale[0]) * float(w_scale[0]) / float(out_scale[0])
        layers[layer.id] = layer
    return layers


def input_details(it):
    d = it.get_input_details()[0]
    return d["index"], tuple(d["shape"])
