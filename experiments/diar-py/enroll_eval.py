#!/usr/bin/env python3
"""声纹注册匹配快验（产品真实流程「标几次变准」）。
每个说话人挑最长的 N 条发言当注册声纹 → 其余发言取窗口 embedding → 最近邻匹配。
绕开聚类，直接测：同一人在不同时刻的声纹是否够近、跨人是否够远。
"""
import argparse, time
import numpy as np
import soundfile as sf
import sherpa_onnx as so

HERE = "/Users/wb.chen/Documents/Project/Resound/experiments/diar-py/models"
SPEAKER_FIX = {"CR": "GGbond"}


def parse_gt(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split(" ", 1)
            if len(parts) != 2:
                continue
            tc = parts[0].split(":")
            if len(tc) != 3 or not all(x.isdigit() for x in tc):
                continue
            t = int(tc[0])*3600 + int(tc[1])*60 + int(tc[2])
            spk = SPEAKER_FIX.get(parts[1].strip(), parts[1].strip())
            out.append([float(t), spk])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", required=True)
    ap.add_argument("--gt", required=True)
    ap.add_argument("--emb", required=True)
    ap.add_argument("--enroll", type=int, default=3, help="每人用几条最长发言注册")
    ap.add_argument("--maxwin", type=float, default=15.0, help="单条发言取样窗口上限秒")
    args = ap.parse_args()

    cfg = so.SpeakerEmbeddingExtractorConfig(model=f"{HERE}/{args.emb}", provider="cpu", num_threads=4)
    ex = so.SpeakerEmbeddingExtractor(cfg)

    audio, sr = sf.read(args.wav, dtype="float32")
    assert sr == 16000

    gt = parse_gt(args.gt)
    # 每条发言的窗口 = [t_i, t_{i+1}]，capped
    spans = []
    for i, (t, spk) in enumerate(gt):
        end = gt[i+1][0] if i+1 < len(gt) else len(audio)/sr
        end = min(end, t + args.maxwin)
        if end - t < 0.5:   # 太短的窗口给个最小 1s（短附和本就难）
            end = min(t + 1.0, len(audio)/sr)
        spans.append((t, end, spk))

    def emb_of(t0, t1):
        a = audio[int(t0*sr):int(t1*sr)]
        if len(a) < int(0.3*sr):
            return None
        s = ex.create_stream()
        s.accept_waveform(sr, a)
        s.input_finished()
        v = np.array(ex.compute(s), dtype=np.float32)
        n = np.linalg.norm(v)
        return v/n if n > 0 else None

    # 按说话人收集，挑最长 N 条注册
    by_spk = {}
    for idx, (t0, t1, spk) in enumerate(spans):
        by_spk.setdefault(spk, []).append((t1-t0, idx))
    enroll_idx = set()
    refs = {}
    print(f"⚙️  emb={args.emb}  enroll/人={args.enroll}  maxwin={args.maxwin}s")
    t_start = time.time()
    for spk, lst in by_spk.items():
        lst.sort(reverse=True)  # 最长在前
        vs = []
        for _, idx in lst[:args.enroll]:
            t0, t1, _ = spans[idx]
            v = emb_of(t0, t1)
            if v is not None:
                vs.append(v); enroll_idx.add(idx)
        if vs:
            r = np.mean(vs, axis=0); refs[spk] = r/np.linalg.norm(r)
    names = list(refs.keys())
    R = np.stack([refs[n] for n in names])

    # 参考声纹两两 cosine（看人和人到底分不分得开）
    print("--- 注册声纹两两相似度（越低越易分）---")
    for i in range(len(names)):
        row = " ".join(f"{names[j][:6]}:{float(R[i]@R[j]):+.2f}" for j in range(len(names)))
        print(f"  {names[i][:6]:7} {row}")

    # 测试集：非注册发言
    correct = tot = 0
    conf = {}
    for idx, (t0, t1, spk) in enumerate(spans):
        if idx in enroll_idx:
            continue
        v = emb_of(t0, t1)
        if v is None:
            continue
        pred = names[int(np.argmax(R @ v))]
        conf.setdefault(spk, {}); conf[spk][pred] = conf[spk].get(pred, 0)+1
        tot += 1; correct += (pred == spk)
    acc = 100*correct/tot if tot else 0
    el = time.time()-t_start
    print(f"✅ 注册匹配准确率: {acc:.1f}%  ({correct}/{tot})  耗时 {el:.0f}s")
    print("--- 真人→预测 混淆 ---")
    for spk in sorted(conf):
        c = conf[spk]; t = sum(c.values())
        detail = " ".join(f"{k[:6]}:{v}" for k, v in sorted(c.items(), key=lambda x: -x[1]))
        hit = c.get(spk, 0)
        print(f"  {spk:8} {100*hit/t:5.1f}%  ({t} 条: {detail})")


if __name__ == "__main__":
    main()
