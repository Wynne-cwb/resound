#!/usr/bin/env python3
"""真实端到端验证：用 ASR(Whisper)分段边界做声纹注册匹配（不再用 GT 边界）。
- 边界来自 vault 的 transcript.json（539 段 ASR 分段）
- 每段的真值说话人 = GT 时间线在该段中点处的活跃说话人
- 每人挑最长 N 段注册 → 其余段最近邻匹配 → 算准确率
回答："复用 ASR 边界" 是否还能维持 ~90%（vs 用 GT 边界的 92%）。
"""
import argparse, json, time
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
            out.append((float(t), spk))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", required=True)
    ap.add_argument("--asr", required=True, help="transcript.json (ASR 分段)")
    ap.add_argument("--gt", required=True, help="ground-truth 说话人时间线 txt")
    ap.add_argument("--emb", required=True)
    ap.add_argument("--enroll", type=int, default=3)
    ap.add_argument("--maxwin", type=float, default=15.0)
    ap.add_argument("--mindur", type=float, default=0.0, help="过滤掉短于此秒数的段")
    ap.add_argument("--merge-to", type=float, default=0.0, help=">0 则把相邻 ASR 段贪婪合并到至少这么长(gap<1s),模拟轮次窗口")
    args = ap.parse_args()

    cfg = so.SpeakerEmbeddingExtractorConfig(model=f"{HERE}/{args.emb}", provider="cpu", num_threads=4)
    ex = so.SpeakerEmbeddingExtractor(cfg)
    audio, sr = sf.read(args.wav, dtype="float32"); assert sr == 16000

    gt = parse_gt(args.gt)
    gt_starts = [t for t, _ in gt]
    def gt_at(t):
        import bisect
        i = bisect.bisect_right(gt_starts, t) - 1
        return gt[i][1] if i >= 0 else gt[0][1]

    asr = json.load(open(args.asr))["segments"]
    raw = [(float(s["start"]), float(s["end"])) for s in asr]
    if args.merge_to > 0:
        merged = []
        cur = None
        for t0, t1 in raw:
            if cur is None:
                cur = [t0, t1]
            elif t0 - cur[1] < 1.0 and (cur[1] - cur[0]) < args.merge_to:
                cur[1] = t1
            else:
                merged.append(tuple(cur)); cur = [t0, t1]
        if cur: merged.append(tuple(cur))
        raw = merged
    segs = []
    for t0, t1 in raw:
        if t1 - t0 < args.mindur:
            continue
        mid = (t0 + t1) / 2
        segs.append((t0, min(t1, t0 + args.maxwin), gt_at(mid)))

    def emb_of(t0, t1):
        a = audio[int(t0*sr):int(t1*sr)]
        if len(a) < int(0.3*sr):
            return None
        st = ex.create_stream(); st.accept_waveform(sr, a); st.input_finished()
        v = np.array(ex.compute(st), dtype=np.float32); n = np.linalg.norm(v)
        return v/n if n > 0 else None

    by_spk = {}
    for idx, (t0, t1, spk) in enumerate(segs):
        by_spk.setdefault(spk, []).append((t1-t0, idx))
    print(f"⚙️  emb={args.emb} enroll/人={args.enroll} mindur={args.mindur}s  ASR段={len(segs)}")
    enroll_idx, refs = set(), {}
    t_start = time.time()
    for spk, lst in by_spk.items():
        lst.sort(reverse=True); vs = []
        for _, idx in lst[:args.enroll]:
            t0, t1, _ = segs[idx]; v = emb_of(t0, t1)
            if v is not None: vs.append(v); enroll_idx.add(idx)
        if vs:
            r = np.mean(vs, axis=0); refs[spk] = r/np.linalg.norm(r)
    names = list(refs.keys()); R = np.stack([refs[n] for n in names])

    correct = tot = 0; conf = {}; scores = []
    for idx, (t0, t1, spk) in enumerate(segs):
        if idx in enroll_idx: continue
        v = emb_of(t0, t1)
        if v is None: continue
        sims = R @ v; j = int(np.argmax(sims))
        pred = names[j]; scores.append((float(sims[j]), pred == spk))
        conf.setdefault(spk, {}); conf[spk][pred] = conf[spk].get(pred, 0)+1
        tot += 1; correct += (pred == spk)
    acc = 100*correct/tot if tot else 0
    print(f"✅ ASR边界 注册匹配准确率: {acc:.1f}%  ({correct}/{tot})  耗时 {time.time()-t_start:.0f}s")
    print("--- 真人→预测 混淆 ---")
    for spk in sorted(conf):
        c = conf[spk]; t = sum(c.values()); hit = c.get(spk, 0)
        detail = " ".join(f"{k[:6]}:{v}" for k, v in sorted(c.items(), key=lambda x: -x[1]))
        print(f"  {spk:8} {100*hit/t:5.1f}%  ({t} 条: {detail})")
    # 阈值扫描：若低于阈值判 unknown，能否提纯（开集拒识参考）
    print("--- cosine 阈值 vs 命中(供定 unknown 阈值参考) ---")
    for th in [0.0, 0.3, 0.4, 0.5, 0.6]:
        kept = [(s, ok) for s, ok in scores if s >= th]
        if kept:
            a = 100*sum(ok for _, ok in kept)/len(kept)
            print(f"  th={th}: 保留 {len(kept)}/{len(scores)} 段, 其中准确率 {a:.1f}%")


if __name__ == "__main__":
    main()
