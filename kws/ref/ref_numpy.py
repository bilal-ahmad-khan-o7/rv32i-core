"""Plain integer re-implementation of the KWS model, in NumPy.

It follows TFLite's reference int8 kernels line by line, so that a difference from
TFLite is a real finding. The helpers below are TFLite's and gemmlowp's formulas,
written out in full (including the sign-dependent nudge), not the shorter sequence
the C code uses; that way the C code is checked against the long form.

The convolutions use double rounding (MultiplyByQuantizedMultiplier). The fully
connected layer does not: TFLite's kernel takes float scales and rounds once, in
floating point. fc_integer_rounding() is the integer form the core uses instead;
check_ref.check_fc_formula() shows the two agree on every reachable accumulator.

run(x, layers) takes the 490 INT8 input bytes and returns {layer id: output array}.
"""
import numpy as np


def saturating_rounding_doubling_high_mul(a, b):
    """gemmlowp::SaturatingRoundingDoublingHighMul (b is positive, so it never saturates)."""
    ab = a * b
    nudge = np.where(ab >= 0, 1 << 30, 1 - (1 << 30))
    v = ab + nudge
    return np.sign(v) * (np.abs(v) >> 31)    # C++ integer division truncates toward zero


def rounding_divide_by_pot(x, exponent):
    """gemmlowp::RoundingDivideByPOT."""
    mask = (np.int64(1) << exponent) - 1
    remainder = x & mask
    threshold = (mask >> 1) + (x < 0)
    return (x >> exponent) + (remainder > threshold)


def multiply_by_quantized_multiplier(x, multiplier, shift):
    """TFLite's double-rounding MultiplyByQuantizedMultiplier; all of this model's shifts are right shifts."""
    assert np.all(shift <= 0)
    return rounding_divide_by_pot(saturating_rounding_doubling_high_mul(x, multiplier), -shift)


def requantise(acc, layer):
    assert acc.min() >= -(1 << 31) and acc.max() < (1 << 31), "TFLite's accumulator is 32 bits"
    v = multiply_by_quantized_multiplier(acc, layer.multiplier, layer.shift) + layer.output_zp
    return np.clip(v, -128, 127)             # fused ReLU with output zero point -128 ends here too


def first_conv(x, layer):
    """CONV_2D 10x4, stride 2, SAME: 4 rows above, 5 below, 1 column each side."""
    pad = np.full((58, 12), layer.input_zp, dtype=np.int64)
    pad[4:53, 1:11] = x.reshape(49, 10)
    w = layer.weights.reshape(64, 40).astype(np.int64)
    windows = np.array([pad[2 * oy:2 * oy + 10, 2 * ox:2 * ox + 4].ravel()
                        for oy in range(25) for ox in range(5)], dtype=np.int64)
    acc = (windows - layer.input_zp) @ w.T + layer.bias      # padded taps contribute 0
    return requantise(acc, layer).reshape(25, 5, 64)


def depthwise(x, layer):
    """DEPTHWISE_CONV_2D 3x3, stride 1, SAME: 1 pixel of padding on every side."""
    pad = np.full((27, 7, 64), layer.input_zp, dtype=np.int64)
    pad[1:26, 1:6, :] = x
    w = layer.weights.reshape(3, 3, 64).astype(np.int64)
    acc = np.zeros((25, 5, 64), dtype=np.int64)
    for dy in range(3):
        for dx in range(3):
            acc += w[dy, dx, :] * (pad[dy:dy + 25, dx:dx + 5, :] - layer.input_zp)
    return requantise(acc + layer.bias, layer)


def pointwise(x, layer):
    """CONV_2D 1x1: a 64-element dot product per output."""
    w = layer.weights.reshape(64, 64).astype(np.int64)
    acc = (x.reshape(125, 64) - layer.input_zp) @ w.T + layer.bias
    return requantise(acc, layer).reshape(25, 5, 64)


def average_pool(x):
    """AVERAGE_POOL_2D over the 25x5 grid: (acc +- count/2) / count, truncating."""
    acc = x.reshape(125, 64).sum(axis=0)
    r = np.where(acc > 0, acc + 62, acc - 62)
    return np.clip(np.sign(r) * (np.abs(r) // 125), -128, 127)


def fc_accumulators(x, layer):
    return (x - layer.input_zp) @ layer.weights.astype(np.int64).T + layer.bias


def fc_float_rounding(acc, layer):
    """What TFLite's reference FC kernel does: round(double(acc) * scale), one rounding,
    with std::round's halves away from zero."""
    v = np.asarray(acc, dtype=np.float64) * layer.float_scale
    return np.trunc(v + np.copysign(0.5, v)).astype(np.int64)


def fc_integer_rounding(acc, layer):
    """The same rounding without floats, as the core does it: (acc * M + 2^(t-1)) >> t."""
    t = 31 - int(layer.shift[0])
    return (np.asarray(acc, dtype=np.int64) * layer.multiplier[0] + (np.int64(1) << (t - 1))) >> t


def fully_connected(x, layer):
    acc = fc_accumulators(x, layer)
    return np.clip(fc_float_rounding(acc, layer) + layer.output_zp, -128, 127)


def run(x, layers):
    """x: 490 int8 values. Returns {layer id: int64 array} for layers 1..10 and 12."""
    out = {}
    v = np.asarray(x, dtype=np.int64)
    for layer in layers.values():
        if layer.id == 1:
            v = first_conv(v, layer)
        elif layer.kind == "depthwise":
            v = depthwise(v, layer)
        elif layer.kind == "conv":
            v = pointwise(v, layer)
        elif layer.kind == "pool":
            v = average_pool(v)
        elif layer.kind == "fc":
            v = fully_connected(v, layer)
        else:
            continue                         # RESHAPE does no work; SOFTMAX is not run
        out[layer.id] = v
    return out
