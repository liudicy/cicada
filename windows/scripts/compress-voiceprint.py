# Shrinks the WeSpeaker ResNet34-LM voiceprint model (VoxCeleb, CC BY 4.0) for the Windows app:
# every conv and dense weight becomes int8 with one scale per output channel, turned back into float by a
# Cast and a Mul when the model loads. Only opset-12 ops, so Windows' built-in Windows ML on
# Windows 10 2004 runs it; inference stays float32. 26.5 MB → 6.7 MB.
# Developer-only, run once; the app needs no Python. Needs: onnx numpy (onnxruntime to check).
# The source is the file the Mac's scripts/convert-voiceprint.py starts from
# (sha256 7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068).
# usage: python3 scripts/compress-voiceprint.py voxceleb_resnet34_LM.onnx src/Cicada/Assets/voiceprint.onnx
import sys, hashlib, numpy as np, onnx
from onnx import helper, numpy_helper as nh, TensorProto

src, out = sys.argv[1], sys.argv[2]
# --bits 4 packs two weights per byte (unpacked with Floor/Mul/Sub/Concat, still opset 12).
bits = int(sys.argv[sys.argv.index("--bits") + 1]) if "--bits" in sys.argv else 8
levels = 127 if bits == 8 else 7
assert hashlib.sha256(open(src, "rb").read()).hexdigest() == "7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068", "not the pinned WeSpeaker model"
m = onnx.load(src)
g = m.graph
# Conv weights (out, in, kh, kw) and the embedding layer's Gemm weight (out, in; transB=1): both
# have output channels first, so one scale per row.
gemm_ok = all(any(a.name == "transB" and a.i == 1 for a in n.attribute) for n in g.node if n.op_type == "Gemm")
assert gemm_ok, "expected Gemm with transB=1"
conv_weights = {n.input[1] for n in g.node if n.op_type in ("Conv", "Gemm")}
inits = {i.name: i for i in g.initializer}
new_inits, new_nodes = [], []
for name in conv_weights:
    w = nh.to_array(inits[name]).astype(np.float32)
    flat = np.abs(w.reshape(w.shape[0], -1)).max(axis=1)
    scale = np.where(flat > 0, flat / levels, 1.0).astype(np.float32)
    shaped = scale.reshape(-1, *([1] * (w.ndim - 1)))
    q = np.clip(np.round(w / shaped), -levels, levels).astype(np.int8)
    g.initializer.remove(inits[name])
    row = int(np.prod(w.shape[1:]))
    group = 32
    if bits == 4 and row % group == 0:
        # 4-bit, one scale per 32 weights of a row (fp16 scales): fine enough to keep the voice.
        G = w.reshape(w.shape[0], row // group, group)
        gs = np.abs(G).max(axis=2, keepdims=True); gs = np.where(gs > 0, gs / 7, 1).astype(np.float16)
        q4 = np.clip(np.round(G / gs.astype(np.float32)), -7, 7).astype(np.int16) + 8
        u = q4.reshape(-1).astype(np.uint8)
        packed = (u[0::2] << 4 | u[1::2]).astype(np.uint8)
        n = name
        new_inits += [nh.from_array(packed, n + "_p"), nh.from_array(gs, n + "_s16"),
                      nh.from_array(np.array([16.0], np.float32), n + "_16"), nh.from_array(np.array([8.0], np.float32), n + "_8"),
                      nh.from_array(np.array([w.shape[0], row // group, group], np.int64), n + "_g"), nh.from_array(np.array(w.shape, np.int64), n + "_shape")]
        new_nodes += [
            helper.make_node("Cast", [n + "_p"], [n + "_pf"], to=TensorProto.FLOAT),
            helper.make_node("Div", [n + "_pf", n + "_16"], [n + "_d"]),
            helper.make_node("Floor", [n + "_d"], [n + "_hi"]),
            helper.make_node("Mul", [n + "_hi", n + "_16"], [n + "_hi16"]),
            helper.make_node("Sub", [n + "_pf", n + "_hi16"], [n + "_lo"]),
            helper.make_node("Unsqueeze", [n + "_hi"], [n + "_hiu"], axes=[1]),
            helper.make_node("Unsqueeze", [n + "_lo"], [n + "_lou"], axes=[1]),
            helper.make_node("Concat", [n + "_hiu", n + "_lou"], [n + "_pair"], axis=1),
            helper.make_node("Reshape", [n + "_pair", n + "_g"], [n + "_grp"]),
            helper.make_node("Sub", [n + "_grp", n + "_8"], [n + "_c"]),
            helper.make_node("Cast", [n + "_s16"], [n + "_sf"], to=TensorProto.FLOAT),
            helper.make_node("Mul", [n + "_c", n + "_sf"], [n + "_w"]),
            helper.make_node("Reshape", [n + "_w", n + "_shape"], [n]),
        ]
        continue
    if bits == 8 or row % group != 0:
        if bits == 4:  # rows that don't split into groups (the first conv): 8-bit
            scale = np.where(flat > 0, flat / 127, 1.0).astype(np.float32); shaped = scale.reshape(-1, *([1] * (w.ndim - 1)))
            q = np.clip(np.round(w / shaped), -127, 127).astype(np.int8)
        new_inits += [nh.from_array(q, name + "_q"), nh.from_array(shaped, name + "_s")]
        new_nodes += [helper.make_node("Cast", [name + "_q"], [name + "_f"], to=TensorProto.FLOAT),
                      helper.make_node("Mul", [name + "_f", name + "_s"], [name])]
    else:
        u = (q.reshape(-1).astype(np.int16) + 8).astype(np.uint8)          # 1…15
        if u.size % 2: u = np.append(u, np.uint8(8))
        packed = (u[0::2] << 4 | u[1::2]).astype(np.uint8)
        n = name
        new_inits += [nh.from_array(packed, n + "_p"), nh.from_array(shaped, n + "_s"),
                      nh.from_array(np.array([16.0], np.float32), n + "_16"), nh.from_array(np.array([8.0], np.float32), n + "_8"),
                      nh.from_array(np.array([-1], np.int64), n + "_flat"), nh.from_array(np.array(w.shape, np.int64), n + "_shape"),
                      nh.from_array(np.array([0], np.int64), n + "_0"), nh.from_array(np.array([q.size], np.int64), n + "_len")]
        new_nodes += [
            helper.make_node("Cast", [n + "_p"], [n + "_pf"], to=TensorProto.FLOAT),
            helper.make_node("Div", [n + "_pf", n + "_16"], [n + "_d"]),
            helper.make_node("Floor", [n + "_d"], [n + "_hi"]),
            helper.make_node("Mul", [n + "_hi", n + "_16"], [n + "_hi16"]),
            helper.make_node("Sub", [n + "_pf", n + "_hi16"], [n + "_lo"]),
            helper.make_node("Unsqueeze", [n + "_hi"], [n + "_hiu"], axes=[1]),
            helper.make_node("Unsqueeze", [n + "_lo"], [n + "_lou"], axes=[1]),
            helper.make_node("Concat", [n + "_hiu", n + "_lou"], [n + "_pair"], axis=1),
            helper.make_node("Reshape", [n + "_pair", n + "_flat"], [n + "_all"]),
            helper.make_node("Slice", [n + "_all", n + "_0", n + "_len"], [n + "_cut"]),
            helper.make_node("Sub", [n + "_cut", n + "_8"], [n + "_c"]),
            helper.make_node("Reshape", [n + "_c", n + "_shape"], [n + "_w"]),
            helper.make_node("Mul", [n + "_w", n + "_s"], [n]),
        ]
g.initializer.extend(new_inits)
nodes = list(g.node)
del g.node[:]
g.node.extend(new_nodes + nodes)
# Unsqueeze took its axes as an attribute before opset 13: move them back from the input.
consts = {n.output[0]: nh.to_array(n.attribute[0].t) for n in g.node if n.op_type == "Constant"}
consts.update({i.name: nh.to_array(i) for i in g.initializer})
for n in g.node:
    if n.op_type == "Unsqueeze" and len(n.input) == 2:
        axes = [int(x) for x in np.atleast_1d(consts[n.input[1]])]
        del n.input[1]
        n.attribute.append(helper.make_attribute("axes", axes))
# Every other op here is unchanged since opset 12 (ReduceMean keeps its axes attribute until 18).
del m.opset_import[:]
m.opset_import.extend([helper.make_opsetid("", 12)])
m.ir_version = 7
onnx.checker.check_model(m)
onnx.save(m, out)
print(f"{src}: {sum(nh.to_array(i).nbytes for i in onnx.load(src).graph.initializer) / 1e6:.1f} MB of weights → {out}")

try:
    import onnxruntime as ort
    rng = np.random.default_rng(0)
    feats = rng.standard_normal((1, 300, 80)).astype(np.float32)
    a = ort.InferenceSession(src).run(None, {"feats": feats})[0][0]
    b = ort.InferenceSession(out).run(None, {"feats": feats})[0][0]
    print(f"cosine to the original on noise: {np.dot(a, b) / np.linalg.norm(a) / np.linalg.norm(b):.5f}")
except ImportError:
    pass
