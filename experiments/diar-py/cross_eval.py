#!/usr/bin/env python3
"""跨录音认人验证（产品核心承诺「标几次变准」）。
在「注册会议」用 GT 标注建每人参考声纹 → 到「测试会议」识别同一批人。
- 共同说话人(Wynne/GGbond 两段都有)：测能否跨录音认出。
- 测试会议里的其他人：应被拒识为 unknown(开集)。
"""
import argparse, time
import numpy as np
import soundfile as sf
import sherpa_onnx as so

import os
HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")
SPEAKER_FIX = {"CR": "GGbond"}


def parse_gt(path):
    out = []
    for line in open(path, encoding="utf-8"):
        p = line.strip().split(" ", 1)
        if len(p) != 2: continue
        tc = p[0].split(":")
        if len(tc) != 3 or not all(x.isdigit() for x in tc): continue
        t = int(tc[0])*3600+int(tc[1])*60+int(tc[2])
        out.append((float(t), SPEAKER_FIX.get(p[1].strip(), p[1].strip())))
    return sorted(out)


def windows_from_gt(gt, audio, sr, maxwin=15.0):
    """每条 GT 发言 → [t, next_t] 窗口(capped)，返回 (t0,t1,speaker)。"""
    out = []
    for i, (t, spk) in enumerate(gt):
        end = gt[i+1][0] if i+1 < len(gt) else len(audio)/sr
        end = min(end, t+maxwin)
        if end - t < 0.5: end = min(t+1.0, len(audio)/sr)
        out.append((t, end, spk))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--enroll-wav", required=True); ap.add_argument("--enroll-gt", required=True)
    ap.add_argument("--test-wav", required=True); ap.add_argument("--test-gt", required=True)
    ap.add_argument("--emb", default="campplus_zhen.onnx")
    ap.add_argument("--per", type=int, default=3, help="每人注册窗口数")
    ap.add_argument("--tau", type=float, default=0.35, help="开集拒识阈值")
    args = ap.parse_args()

    ex = so.SpeakerEmbeddingExtractor(so.SpeakerEmbeddingExtractorConfig(
        model=f"{HERE}/{args.emb}", provider="cpu", num_threads=4))

    def load(w): a, sr = sf.read(w, dtype="float32"); assert sr == 16000; return a
    def emb(audio, t0, t1, sr=16000):
        a = audio[int(t0*sr):int(t1*sr)]
        if len(a) < int(0.3*sr): return None
        s = ex.create_stream(); s.accept_waveform(sr, a); s.input_finished()
        v = np.array(ex.compute(s), dtype=np.float32); n = np.linalg.norm(v)
        return v/n if n > 0 else None

    # 注册会议：每人最长 per 条建 centroid
    ea = load(args.enroll_wav)
    ew = windows_from_gt(parse_gt(args.enroll_gt), ea, 16000)
    by = {}
    for (t0, t1, spk) in ew: by.setdefault(spk, []).append((t1-t0, t0, t1))
    refs = {}
    for spk, lst in by.items():
        lst.sort(reverse=True); vs = []
        for _, t0, t1 in lst[:args.per]:
            v = emb(ea, t0, t1)
            if v is not None: vs.append(v)
        if vs:
            r = np.mean(vs, axis=0); refs[spk] = r/np.linalg.norm(r)
    names = list(refs.keys()); R = np.stack([refs[n] for n in names])
    print(f"📌 注册会议建参考声纹: {names}")

    # 测试会议
    ta = load(args.test_wav)
    tw = windows_from_gt(parse_gt(args.test_gt), ta, 16000)
    enrolled_speakers = set(names)
    # 共同说话人识别准确率 + 其他人拒识率
    known_tot = known_hit = 0
    other_tot = other_rej = 0
    conf = {}
    for (t0, t1, truth) in tw:
        v = emb(ta, t0, t1)
        if v is None: continue
        sims = R @ v; j = int(np.argmax(sims)); s1 = float(sims[j])
        pred = names[j] if s1 >= args.tau else "unknown"
        if truth in enrolled_speakers:
            known_tot += 1; known_hit += (pred == truth)
            conf.setdefault(truth, {}); conf[truth][pred] = conf[truth].get(pred, 0)+1
        else:
            other_tot += 1; other_rej += (pred == "unknown")
            conf.setdefault(f"[其他]{truth}", {}); conf[f"[其他]{truth}"][pred] = conf[f"[其他]{truth}"].get(pred, 0)+1

    print(f"⚙️  emb={args.emb} per={args.per} tau={args.tau}")
    if known_tot:
        print(f"✅ 跨录音【共同人】识别准确率: {100*known_hit/known_tot:.1f}% ({known_hit}/{known_tot})")
    if other_tot:
        print(f"🚪 测试会议【其他人】拒识为 unknown 率: {100*other_rej/other_tot:.1f}% ({other_rej}/{other_tot})")
    print("--- 真人→预测 ---")
    for k in sorted(conf):
        c = conf[k]; t = sum(c.values())
        detail = " ".join(f"{n[:6]}:{v}" for n, v in sorted(c.items(), key=lambda x: -x[1]))
        print(f"  {k:12} ({t}: {detail})")


if __name__ == "__main__":
    main()
