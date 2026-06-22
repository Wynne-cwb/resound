#!/usr/bin/env python3
"""完整冷启动闭环：自动分堆 → 给最大的 K 堆命名 → 其余小堆自动归并 → 算最终准确率。
回答："点几次名(K) 换来多少准确率、多少覆盖率(非 unknown)"。
命名用 GT 多数票模拟用户操作。
"""
import argparse, json, bisect
import numpy as np
import soundfile as sf
import sherpa_onnx as so

HERE = "/Users/wb.chen/Documents/Project/Resound/experiments/diar-py/models"
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", required=True); ap.add_argument("--asr", required=True); ap.add_argument("--gt", required=True)
    ap.add_argument("--emb", default="campplus_zhen.onnx")
    ap.add_argument("--merge-to", type=float, default=4.0)
    ap.add_argument("--cluster-th", type=float, default=0.5, help="在线分堆阈值")
    ap.add_argument("--absorb-th", type=float, default=0.5, help="小堆归并到已命名人的阈值")
    args = ap.parse_args()

    ex = so.SpeakerEmbeddingExtractor(so.SpeakerEmbeddingExtractorConfig(
        model=f"{HERE}/{args.emb}", provider="cpu", num_threads=4))
    audio, sr = sf.read(args.wav, dtype="float32"); assert sr == 16000
    gt = parse_gt(args.gt); gts = [t for t, _ in gt]
    def gt_at(t):
        i = bisect.bisect_right(gts, t) - 1
        return gt[i][1] if i >= 0 else gt[0][1]

    raw = [(float(s["start"]), float(s["end"])) for s in json.load(open(args.asr))["segments"]]
    merged, cur = [], None
    for t0, t1 in raw:
        if cur is None: cur = [t0, t1]
        elif t0 - cur[1] < 1.0 and cur[1]-cur[0] < args.merge_to: cur[1] = t1
        else: merged.append(tuple(cur)); cur = [t0, t1]
    if cur: merged.append(tuple(cur))

    def emb(t0, t1):
        a = audio[int(t0*sr):int(min(t1, t0+15)*sr)]
        if len(a) < int(0.3*sr): return None
        s = ex.create_stream(); s.accept_waveform(sr, a); s.input_finished()
        v = np.array(ex.compute(s), dtype=np.float32); n = np.linalg.norm(v)
        return v/n if n > 0 else None

    items = []  # (dur, truth, emb)
    for t0, t1 in merged:
        v = emb(t0, t1)
        if v is not None: items.append((t1-t0, gt_at((t0+t1)/2), v))
    n_real = len(set(t for _, t, _ in items))

    # 1) 在线分堆
    cents, counts, durs, labels = [], [], [], []
    for (d, _, v) in items:
        if not cents:
            cents.append(v.copy()); counts.append(1); durs.append(d); labels.append(0); continue
        sims = [float(np.dot(v, c)/np.linalg.norm(c)) for c in cents]
        j = int(np.argmax(sims))
        if sims[j] >= args.cluster_th:
            n = counts[j]; cents[j] = (n*cents[j]+v)/(n+1); counts[j] += 1; durs[j] += d; labels.append(j)
        else:
            cents.append(v.copy()); counts.append(1); durs.append(d); labels.append(len(cents)-1)
    cents = [c/np.linalg.norm(c) for c in cents]
    k = len(cents)
    # 堆的 GT 多数票（模拟"用户命名时会按堆里主要的人命名"）
    clus_gt = {}
    for (_, truth, _), lab in zip(items, labels):
        clus_gt.setdefault(lab, {})[truth] = clus_gt.setdefault(lab, {}).get(truth, 0)+1
    clus_name = {c: max(d, key=d.get) for c, d in clus_gt.items()}
    # 堆按总时长排序（用户先命名大的）
    order = sorted(range(k), key=lambda c: -durs[c])

    print(f"📄 {len(items)} 窗，真{n_real}人 → 自动分 {k} 堆 (cluster-th={args.cluster_th}, absorb-th={args.absorb_th})")
    print(f"{'命名次数K':>8} {'覆盖率':>7} {'准确率(全部)':>12} {'准确率(已识)':>12} {'认出的人数':>9}")

    for K in range(1, min(k, 12)+1):
        named_clusters = order[:K]
        # 命名的堆 → 该人参考声纹（同名堆质心平均）
        refs = {}
        for c in named_clusters:
            nm = clus_name[c]
            refs.setdefault(nm, []).append(cents[c])
        ref_names = list(refs.keys())
        R = np.stack([np.mean(refs[n], axis=0)/np.linalg.norm(np.mean(refs[n], axis=0)) for n in ref_names])
        # 每个堆的最终预测：命名过的直接用名；其余按质心归并(≥absorb-th)否则 unknown
        cluster_pred = {}
        for c in range(k):
            if c in named_clusters:
                cluster_pred[c] = clus_name[c]
            else:
                sims = R @ cents[c]; j = int(np.argmax(sims))
                cluster_pred[c] = ref_names[j] if sims[j] >= args.absorb_th else "unknown"
        # 逐窗算
        tot = len(items); known = correct = correct_known = 0
        for (_, truth, _), lab in zip(items, labels):
            pred = cluster_pred[lab]
            if pred != "unknown":
                known += 1; correct_known += (pred == truth)
            correct += (pred == truth)
        cov = 100*known/tot
        acc_all = 100*correct/tot
        acc_known = 100*correct_known/known if known else 0
        print(f"{K:>8} {cov:>6.0f}% {acc_all:>11.1f}% {acc_known:>11.1f}% {len(ref_names):>9}")


if __name__ == "__main__":
    main()
