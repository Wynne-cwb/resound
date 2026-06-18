# 当前状态 (STATE)

> 这是"现在的快照"。过时就改。细节查 [DECISIONS.md](DECISIONS.md)。
> 最近更新：2026-06-18

## 一句话现状

检索/问答主线**已完整可用**；正在做**说话人识别(diarization + 声纹)**，但卡在 diarization 质量——FluidAudio 三条路都不行，正在**调研替代方案**。

## ✅ 已完成（可用）

完整 RAG 链路 + CLI：
```
transcribe → 繁简归一+glossary 别名纠正 → 切块 → contextual 增强 → embed(8B) → SQLite(FTS5 trigram + sqlite-vec 4096) → RRF → LLM rerank → 带引用问答
```
- CLI：`transcribe` / `record` / `normalize` / `index` / `search` / `ask` / `doctor` / `diarize` / `diarize-eval`
- 真实会议(21.6min)验证过：检索命中相关、`ask` 输出结构化带引用答案。
- 两个 GitHub repo：App=`Wynne-cwb/resound`(本仓库)，Vault=`Wynne-cwb/wayne-resound`(private)。

## 🚧 进行中：说话人识别(diarization)

- **结论**：FluidAudio diarization 在中文会议上**不达标**(已用 ground truth 钉死，eval 对齐已验证可信)：
  - DiarizerManager：2人会议把 99% 时长归一个簇，准确率 55.8%≈基线
  - Offline VBx：Bus error 崩溃
  - Sortformer：57.4%≈基线，且慢(cpuAndGPU 7min/26min)
- **已就位**：`diarize-eval <audio> <transcript>` 评测命令(发言级准确率+簇→人映射) + `DiarBackend` 后端抽象(换库可秒级验)。
- **person_id 已在 chunk schema 预留**，speaker-ID 以后补不返工。

## 🎯 调研已完成 → 方案已定（待实测）

7方案 workflow + Kaldi agent 都跑完了。排序/细节见 [DECISIONS.md](DECISIONS.md#说话人识别方案调研结论2026-06-18)。结论：

- **首选：sherpa-onnx（pyannote-seg-3.0 ONNX 分割 + 3D-Speaker CAM++/ERes2NetV2 zh-cn 声纹 + 内置 SpeakerEmbeddingManager 注册/检索）**。中文声纹 CN-Celeb EER 6%级、内置跨录音注册(正合"标几次变准")、本地、C API+Swift 桥、~5min/26min。
- **风险**：分割模型与 FluidAudio 同源(pyannote ONNX)，可能同样"全归一簇"(issue #1708)。**解药：已知人数时强制 `num-clusters=N`**。
- **次选**：FunASR+3D-Speaker(AISHELL-4 DER 10.30% 胜 pyannote)；声纹层两条路共用同一批 3D-Speaker 模型，是确定资产。
- Kaldi 3/10 不推荐(老一代、集成 High、无 ANE)；LS-EEND/NeMo/云 API 各有硬伤(详见 DECISIONS)。

### 下一步（明确）
1. **先用 Python 快验** sherpa-onnx：pyannote-seg-3.0 + 3D-Speaker zh-cn，**固定 `num-clusters=2`**，在 GGbond 2人会议上看能否把 Wynne/GGbond 分开(对比 ground truth)。
2. 验证能分开 → 走 C API 桥进 Swift(build dylib/xcframework + bridging)，替换 FluidAudio diarizer，保留 `DiarBackend` 抽象。
3. 声纹注册/跨录音识别用 sherpa-onnx EmbeddingManager 或导裸 embedding 自建 sqlite-vec 声纹库 → 填 chunk.person_id。
4. 全程用 `diarize-eval` 在两段 ground truth 上量化。

## 📌 测试数据(ground truth，在 ~/Downloads)

- `2026-06-10 月度 1 on 1 会议 with GGbond.mp3` + `...-transcript.txt`：**2 人**(Wynne+GGbond；转录里的 CR 是误标=GGbond)。1736s。
- `06-15 ...会签平台OS迁移...mp3` + `...-transcript.txt`：**6 人**(Wynne/GGbond/Carlos/Sierra/ZiYang/Sara)。1296s。已转录入 vault。
- **Wynne+GGbond 两段都出现** → 跨录音认人基准。
- transcript 格式：`HH:MM:SS 说话人` 行 + 文本行；diarize-eval 直接吃。

## 下一步选项（主线已通，speaker-ID 受阻）

1. 等调研结果 → 实现最优 diarizer（首选）。
2. 暂缓 speaker-ID → 做 SwiftUI 包壳 / workflow 多 query 检索质量评测。

## 待办/提醒

- 加音频到真 vault 前装 git-lfs(`.gitattributes` 已声明 *.m4a LFS)。
- app 首启需模型预热(large-v3 首次 Metal 编译 ~13min) + 转录做后台任务(~1.7x 实时)。
- 待办对比：contextual 的 pro/flash 已比(打平选 flash)；synthesis 的 pro/flash A/B 还没做。
