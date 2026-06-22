# 当前状态 (STATE)

> 这是"现在的快照"。过时就改。细节查 [DECISIONS.md](DECISIONS.md)。
> 最近更新：2026-06-18

## 一句话现状

检索/问答 + 说话人识别已打通接入检索(👤)。**App 套壳进行中(SPM 应用+打包脚本路线)**:阶段1 会议录音器`record-meeting`(用户实测录音成功)、阶段2 Meet 检测`watch-meet`、阶段3 **SwiftUI App 骨架已能编译+打包成签名 .app**(Chat 页接真实 ask 管线;录音库/设置占位)。**下一步:Chat 页用户实测 + 把录音/Meet检测/说话人命名接进 UI。**

## ✅ 已完成（可用）

完整 RAG 链路 + CLI：
```
transcribe → 繁简归一+glossary 别名纠正 → 切块 → contextual 增强 → embed(8B) → SQLite(FTS5 trigram + sqlite-vec 4096) → RRF → LLM rerank → 带引用问答
```
- CLI：`transcribe` / `record` / `normalize` / `index` / `search` / `ask` / `doctor` / `diarize` / `diarize-eval`
- 真实会议(21.6min)验证过：检索命中相关、`ask` 输出结构化带引用答案。
- 两个 GitHub repo：App=`Wynne-cwb/resound`(本仓库)，Vault=`Wynne-cwb/wayne-resound`(private)。

## ✅ 说话人识别路线已定（Python 实测验证，2026-06-18）

详见 [DECISIONS.md](DECISIONS.md#说话人识别--决定性结论2026-06-18-python-快验)。要点：

- **盲聚类失败**(FluidAudio 和 sherpa-onnx 都栽在聚类这步)：GGbond 55%=基线、OS 38.5%。强制 `num_clusters=N` 后两簇仍随机混 → 不是声纹问题，是聚类在真实会议(重叠/短附和/远场)上分不开。
- **注册匹配成功**：每人标几条最长发言当参考声纹 + 最近邻 → **GGbond 89.4% / OS 92.3%**(CAM++)。参考声纹两两 cosine 0.24~0.66 → 声纹区分力强。**这正是"标几次变准"。**
- **选定声纹模型：CAM++ `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced`(28MB)** — 准确率打平 ERes2NetV2 但快 5x、区分更干净、中英夹杂专训。
- **person_id 已在 chunk schema 预留**；`diarize-eval` + `DiarBackend` 抽象已就位。
- Python 实验环境：`experiments/diar-py/`(gitignored，含 venv+模型+eval.py/enroll_eval.py)。

- 落地参数(拒识双门 τ_abs≈0.35/margin、短段处理、注册聚合、增量更新)见 [DECISIONS 工程参数速查](DECISIONS.md#工程参数速查2026-06-18-业界最佳实践调研落-swift-时照此)。业界先例 `whisper-diarization`。

### ✅ 已完成并验证(2026-06-18 夜) — 全部 swift build 通过
- **库**:sherpa-onnx 纯静态库 vendor 到 `Vendor/sherpa-onnx/{lib/libsherpa-onnx.a 14MB + libonnxruntime.a 62MB, include/}`，`scripts/build-sherpa-onnx.sh` 可重建(lib gitignored)。
- **代码**:`Sources/CSherpaOnnx/`(C target + **相对符号链接 include/sherpa-onnx→Vendor**)、`SherpaSpeaker.swift`(SpeakerEmbedder)、`SpeakerID.swift`(mergeASRSegments / SpeakerMatcher 双门+在线均值守门 / SpeakerStore JSON 持久化 / enrollFromLabeled / recognizeWithStore / speakerIDEval)。链接 flag 已在 Package.swift(`-lsherpa-onnx -lonnxruntime -lc++ -framework Foundation`)。CAM++ dim=192。
- **CLI**:`speaker-eval`(评测 82.5%/85%复现 Python)、`speaker-enroll`(注册到JSON库,增量累积)、`speaker-recognize`(跨录音识别)。
- **跨录音闭环冒烟通过**:注册GGbond会议→识别OS会议,Wynne/GGbond 认出、4个陌生人全归 unknown。

### ✅ 接入检索索引完成并验证(2026-06-22)
- `speaker_refs` 表(声纹向量存 index)；`speaker-enroll --index` 注册;`speaker-label --vault --index` 就地填 person_id(不重嵌入);`index` build 时若配 SPEAKER_MODEL+有声纹则自动标注;search/ask 显示 👤。
- 验证:OS会议 25/25 chunk 标注、speaker_refs 6人、search 输出带人名且语义一致。代码零改动首编过。
- Config 加 `SPEAKER_MODEL`(.env);Index 加 speaker_refs + person_id 进检索;SpeakerID 加 recognizeSpans/personFor/enrollToIndex;IndexPipeline 加 labelExisting。

### 下一步 —— UX 与打磨（核心链路已完整）
1. **冷启动接入标注流**:`speaker-cluster` 自动分堆已就绪,缺"命名→自动归并到 speaker_refs"的交互闭环(CLI 或等 App UI)。
2. **数据契约**:把 person 标注写 vault(labels.json,事实源,使 index 可重建);diarization.json / people.yaml schema。现状声纹向量在 index、标注源还没落 vault。
3. **调参**:开集拒识 τ_abs/margin 在标注集上扫(现默认 0.35/0);chunk 粒度 person 是"该 chunk 多数说话人"(Sara 等少量发言者会被并掉)。
4. **运维**:加音频到真 vault 前装 git-lfs;App 首启模型预热;SPEAKER_MODEL 需写进 .env(现靠 --model/inline env)。

## 📌 测试数据(ground truth，在 ~/Downloads)

- `2026-06-10 月度 1 on 1 会议 with GGbond.mp3` + `...-transcript.txt`：**2 人**(Wynne+GGbond；转录里的 CR 是误标=GGbond)。1736s。
- `06-15 ...会签平台OS迁移...mp3` + `...-transcript.txt`：**6 人**(Wynne/GGbond/Carlos/Sierra/ZiYang/Sara)。1296s。已转录入 vault。
- **Wynne+GGbond 两段都出现** → 跨录音认人基准。
- transcript 格式：`HH:MM:SS 说话人` 行 + 文本行；diarize-eval 直接吃。

## 待办/提醒

- 加音频到真 vault 前装 git-lfs(`.gitattributes` 已声明 *.m4a LFS)。
- app 首启需模型预热(large-v3 首次 Metal 编译 ~13min) + 转录做后台任务(~1.7x 实时)。
- 待办对比：contextual 的 pro/flash 已比(打平选 flash)；synthesis 的 pro/flash A/B 还没做。
