#!/usr/bin/env python3
"""sherpa-onnx 说话人分割快验：固定 num_clusters，对 ground-truth 算发言级准确率。
复刻 Swift diarizeEval 的逻辑：每条 GT 发言取时间戳 → 落在哪个 diar 簇 → 簇按多数投票映射到 GT 说话人 → 准确率。
"""
import sys, time, argparse
import soundfile as sf
import sherpa_onnx as so

HERE = "/Users/wb.chen/Documents/Project/Resound/experiments/diar-py/models"

# 用户钉死：CR 是转写误标，实为 GGbond
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
            t = int(tc[0]) * 3600 + int(tc[1]) * 60 + int(tc[2])
            spk = parts[1].strip()
            spk = SPEAKER_FIX.get(spk, spk)
            out.append((float(t), spk))
    return out


def build(seg_model, emb_model, num_clusters, threshold, provider="cpu"):
    cfg = so.OfflineSpeakerDiarizationConfig(
        segmentation=so.OfflineSpeakerSegmentationModelConfig(
            pyannote=so.OfflineSpeakerSegmentationPyannoteModelConfig(model=seg_model),
            provider=provider,
        ),
        embedding=so.SpeakerEmbeddingExtractorConfig(model=emb_model, provider=provider),
        clustering=so.FastClusteringConfig(num_clusters=num_clusters, threshold=threshold),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    if not cfg.validate():
        raise SystemExit("config 校验失败")
    return so.OfflineSpeakerDiarization(cfg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", required=True)
    ap.add_argument("--gt", required=True)
    ap.add_argument("--emb", required=True, help="声纹模型文件名(在 models/ 下)")
    ap.add_argument("--num-clusters", type=int, default=-1)
    ap.add_argument("--threshold", type=float, default=0.5)
    args = ap.parse_args()

    seg = f"{HERE}/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
    emb = f"{HERE}/{args.emb}"

    gt = parse_gt(args.gt)
    gt_speakers = sorted(set(s for _, s in gt))
    print(f"📄 GT: {len(gt)} 条发言, {len(gt_speakers)} 人: {'/'.join(gt_speakers)}")

    audio, sr = sf.read(args.wav, dtype="float32")
    assert sr == 16000

    print(f"⚙️  num_clusters={args.num_clusters} threshold={args.threshold} emb={args.emb}")
    sd = build(seg, emb, args.num_clusters, args.threshold)
    t0 = time.time()
    result = sd.process(audio).sort_by_start_time()
    elapsed = time.time() - t0
    segs = [(s.start, s.end, s.speaker) for s in result]
    diar_speakers = sorted(set(s for _, _, s in segs))
    print(f"🗣  diar 检出 {len(diar_speakers)} 簇, {len(segs)} 段, 耗时 {elapsed:.1f}s "
          f"(RTF={elapsed/(len(audio)/sr):.3f})")

    def diar_at(t):
        hit = [s for s in segs if s[0] <= t <= s[1]]
        if hit:
            return hit[0][2]
        if not segs:
            return None
        return min(segs, key=lambda s: abs((s[0]+s[1])/2 - t))[2]

    pairs = [(spk, diar_at(t)) for t, spk in gt if diar_at(t) is not None]
    diar_to_gt = {}
    for gtspk, d in pairs:
        diar_to_gt.setdefault(d, {})
        diar_to_gt[d][gtspk] = diar_to_gt[d].get(gtspk, 0) + 1
    mapping = {d: max(c, key=c.get) for d, c in diar_to_gt.items()}
    correct = sum(1 for gtspk, d in pairs if mapping[d] == gtspk)
    acc = 100*correct/len(pairs) if pairs else 0
    print(f"✅ 发言级准确率: {acc:.1f}%  ({correct}/{len(pairs)})")
    print("--- 簇→人 映射 ---")
    for d, c in sorted(diar_to_gt.items(), key=lambda kv: -sum(kv[1].values())):
        tot = sum(c.values())
        detail = " ".join(f"{k}:{v}" for k, v in sorted(c.items(), key=lambda x: -x[1]))
        print(f"  diar[{d}] → {mapping[d]}  ({tot} 条: {detail})")


if __name__ == "__main__":
    main()
