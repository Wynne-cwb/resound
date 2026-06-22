#!/usr/bin/env python3
"""冷启动自动分堆验证：在线增量聚类(leader-follower)。
不预先注册任何人，按时间顺序逐窗：和已见过的"堆"比 cosine，像就归入并更新质心，不像就开新堆。
用的是强的两两比对(注册匹配同款)，对比失败的全局盲聚类。
最后把堆→GT说话人(多数投票)算纯度，看自动分堆能否替代"全局聚类"。
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
    ap.add_argument("--thresholds", default="0.4,0.45,0.5,0.55,0.6")
    args = ap.parse_args()

    ex = so.SpeakerEmbeddingExtractor(so.SpeakerEmbeddingExtractorConfig(
        model=f"{HERE}/{args.emb}", provider="cpu", num_threads=4))
    audio, sr = sf.read(args.wav, dtype="float32"); assert sr == 16000

    gt = parse_gt(args.gt); gts = [t for t, _ in gt]
    def gt_at(t):
        i = bisect.bisect_right(gts, t) - 1
        return gt[i][1] if i >= 0 else gt[0][1]

    # ASR 段 → 合并 ≥merge_to 窗口
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

    items = []
    for t0, t1 in merged:
        v = emb(t0, t1)
        if v is not None: items.append((t0, t1, gt_at((t0+t1)/2), v))

    n_real = len(set(s for _,_,s,_ in items))
    print(f"📄 {len(items)} 窗，真实说话人 {n_real} 人")

    for th in [float(x) for x in args.thresholds.split(",")]:
        # 在线 leader-follower
        cents, counts, labels = [], [], []
        for (_, _, _, v) in items:
            if not cents:
                cents.append(v.copy()); counts.append(1); labels.append(0); continue
            sims = [float(np.dot(v, c)/(np.linalg.norm(c))) for c in cents]
            j = int(np.argmax(sims))
            if sims[j] >= th:
                n = counts[j]; cents[j] = (n*cents[j] + v)/(n+1); counts[j] += 1; labels.append(j)
            else:
                cents.append(v.copy()); counts.append(1); labels.append(len(cents)-1)
        # 堆→人 多数投票，算纯度(准确率)
        k = len(cents)
        clus_to_gt = {}
        for (_, _, truth, _), lab in zip(items, labels):
            clus_to_gt.setdefault(lab, {})[truth] = clus_to_gt.setdefault(lab, {}).get(truth, 0)+1
        mapping = {c: max(d, key=d.get) for c, d in clus_to_gt.items()}
        correct = sum(1 for (_,_,truth,_), lab in zip(items, labels) if mapping[lab] == truth)
        acc = 100*correct/len(items)
        print(f"  th={th}: 自动分出 {k} 堆(真{n_real}人)，纯度 {acc:.1f}%")


if __name__ == "__main__":
    main()
