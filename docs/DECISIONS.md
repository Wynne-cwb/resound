# 决策 & 已完成实践日志 (DECISIONS)

> 增长型日志：定下的选型/参数/结论 + 已完成功能 + 关键踩坑。带日期，别删历史。
> 当前快照看 [STATE.md](STATE.md)。

---

## 架构 & 数据契约

- **三边界**：App(本仓库，纯实现) / Vault(用户自配的数据 repo，事实源) / Index(本地 SQLite，派生物可重建)。不变量：删 Index 能从 Vault 完整重建。
- **Vault 可配置**：App 不写死数据 repo，用户在设置里指定；App 操作本地工作副本，git 当同步层。音频走 Git LFS。
- 完整契约见 [data-contract.md](data-contract.md)。源 vs 派生分四档：纯事实 / 昂贵可修正(转录、diarization) / 免费可重算(embedding、FTS) / LLM 派生(必须缓存)。
- repos：App=`Wynne-cwb/resound`，Vault=`Wynne-cwb/wayne-resound`(private，已有起始 resound.yaml/people.yaml/glossary.txt/.gitattributes)。

## 核心原则

- **质量 > 速度**(用户定)：个人自用，凡"快 vs 准"默认选准，宁慢宁多花点 API 钱也要准。

## 模型选型(已定 + 实测依据)

| 用途 | 选定 | 依据 |
|---|---|---|
| 转录 ASR | **WhisperKit large-v3** | 比 small 强(Resound/scope/术语都对)；small 转录糙但检索召回≈持平(6x快)。turbo 本机编译死锁不可用；降 fallback 不提速(瓶颈在解码本身)。**默认 large-v3 + 转录后台化**，`--model small` 留快速通道。 |
| 文本 embedding | **aihubmix `qwen3-embedding-8b`**(4096维,cosine,query 侧加 instruction) | 中文强；质量优先顶格选 8B。OpenAI 兼容，base_url `https://aihubmix.com/v1`。专用 key 仅授权这一模型。 |
| rerank | **DeepSeek `deepseek-v4-flash`** | A/B：flash≈pro(3查询 top 高度一致)，flash ~3x 快(5s vs 15s)→ 默认 flash。 |
| contextual 增强 | **`deepseek-v4-flash`** | A/B：flash 41s vs pro 66s，质量打平→默认 flash。 |
| 最终综合(ask) | **`deepseek-v4-pro`** | 综合重推理、每问一调量小，用 pro。pro/flash A/B 待做。 |

- DeepSeek base_url `https://api.deepseek.com/v1`；v4-pro 是推理模型(返回 content+reasoning_content，max_tokens 给足)。模型配置在 `.env`：EMBEDDING_MODEL/RERANK_MODEL/CONTEXT_MODEL/ANSWER_MODEL。

## 检索链路(已完成)

```
transcribe → 繁简归一(ZhConverter) → glossary 别名纠正 → 切块(Chunker) → contextual 增强(ContextualEnricher, enrichment_cache 按 hash 缓存) → embed(8B) → SQLite[FTS5 trigram + sqlite-vec 4096, L2归一化≈cosine] → RRF 融合 → LLM rerank → Synthesizer 带引用作答
```
- **sqlite-vec**：amalgamation 编进 CSQLiteVec C target(`-DSQLITE_CORE` 静态链系统 libsqlite3，绕开扩展加载限制)。`resound doctor` 自检。
- **FTS5 trigram** tokenizer：中文子串匹配。
- **glossary**：`vault/glossary.txt`(规范词=变体)，偏置(promptTokens)+确定性别名纠正，改写 transcript.json。
- **繁→简**：ZhConverter 用 OpenCC TSCharacters 表(打包资源)，字符级；`resound normalize` 可对已有转录重做。
- 真实会议(21.6min/539段→25chunk)实测：检索命中相关、ask 输出结构化带引用答案。

## 关键踩坑

- **WhisperKit ANE**：默认 ANE 计算单元加载 small/large-v3 首次**卡死**(进程睡眠、CPU 极低)→ 改默认 `.cpuAndGPU` 绕过。tiny 中文不可用(误判语言+翻译成英文)。中文词级时间戳是短语级非逐字。
- **large-v3 首次 Metal 编译 ~13min**(一次性，之后缓存)→ app 必须首启预热。
- **转录速度 ~1.7x 实时**(large-v3 质量模式，多人会议触发大量温度回退)→ 转录必须后台任务。
- **AudioConverter 撞名**：FluidAudio 模块里有同名 `AudioConverter` + 命名空间类型 `FluidAudio`，故 `FluidAudio.AudioConverter` 解析失败。把自有的改名 **M4AExporter**，diarizer 里用 FluidAudio 的 `AudioConverter`(不加前缀)。
- 真实会议转录质量：清晰单人段好；会前闲聊/抢话/远场碎成乱码；繁简混输(已归一)。

## 说话人识别(diarization) — 进行中，结论见下

- **FluidAudio 不达标**(ground truth 钉死，eval 对齐已验证)：DiarizerManager 2人会议 99%归一簇/55.8%；Offline VBx Bus error 崩；Sortformer 57.4%≈基线且慢。根因：纯聚类无 EEND，分不开相似嗓音/重叠。
- **eval 工具**：`diarize-eval <audio> <transcript>` 解析 `HH:MM:SS 说话人` 算发言级准确率+簇→人映射。`DiarBackend` 抽象(manager/sortformer)，换库可秒级验。
- **Kaldi 评估(2026-06-18 agent 调研)**：3/10 不推荐——无开箱中文模型(CN-Celeb x-vector EER 14.24%)、聚类不处理重叠、macOS/Swift 集成 High(官方对嵌入消极)、无 ANE。**其现代后代是出路**。
- **当前最强线索**：**sherpa-onnx**(next-gen Kaldi，官方 Swift/C API + speaker-identification API)+ **3D-Speaker ERes2Net/CAM++**(CN-Celeb EER 6.11%) + **pyannote segmentation-3.0**(powerset 抗重叠，中文 AISHELL/AliMeeting 训练)。混合(聚类+EEND)是 SOTA。
- **待**：实现 Top 方案 + diarize-eval 实测定夺。

### 说话人识别方案调研结论(2026-06-18)

workflow(7方案) + Kaldi agent 调研排序(契合分)：

| 排名 | 方案 | 中文 | 跨录音声纹注册 | Swift/Mac 集成 | 速度(26min/M3) | 分 |
|---|---|---|---|---|---|---|
| 1 | **sherpa-onnx + 3D-Speaker zh-cn** | 声纹 CN-Celeb EER 6.1-6.8%；分割训练含 AISHELL/AliMeeting | **强(内置 EmbeddingManager 注册+检索)** | medium(自 build dylib+C 桥) | ~5min(CPU RTF≈0.2) | 7 |
| 2 | FunASR/3D-Speaker/CAM++ | **最强(AISHELL-4 DER 10.30% 胜 pyannote)** | 支持但要自拼 | high(无 Swift 封装) | 几分钟 | 7 |
| 3 | WhisperX→只取 pyannote 分割 | pyannote 系 | 导 embedding 自匹配 | high(Python sidecar) | 仅分割可几分钟 | 6 |
| 4 | pyannote.audio 3.1 | 最透明中文 benchmark(AISHELL-4 12.2/AliMeeting 24.4) | 导 embedding 干净 | high(无 Swift，CoreML 移植即已否的 FluidAudio) | M3 慢 10min+，MPS 不稳 | 5 |
| 5 | FluidAudio LS-EEND | 弱(训练全英文/电话域) | 不出 embedding | low(同库) | 最快 1-2min | 5 |
| 6 | NVIDIA NeMo(Sortformer) | 分割最强(SF v2 Mandarin DER 9.2%)但 TitaNet 声纹英文 | 不出 embedding | high(CUDA-first，M3 不可行) | M3 不可行 | 4 |
| 7 | 云 API | 中文 STT 有但无重叠 DER 公开数 | 多数不提供注册/embedding | medium(REST) | 数十秒-2min | 4 |

**决定：走首选 sherpa-onnx + 3D-Speaker zh-cn**。
- 价值点：中文声纹 + **内置跨录音注册**(EmbeddingManager Add 按名注册/同名自动平均/Search cosine 检索)，正合"标几次变准"；本地离线；C API 可桥 Swift(官方 ios-swiftui 示例范式)。
- **核心风险**：分割模型与 FluidAudio 同源(pyannote ONNX)，issue #1708 报告"全归一簇"=我们 99% 归一簇同病。**换框架不自动治病**，解药是 sherpa-onnx 暴露 `num-clusters/cluster-threshold` 可调，已知人数强制 `num-clusters=N`。
- **铁律：上 Swift 前先用 Python API 在中文会议样本固定人数验证能否分开**，再投集成。
- Kaldi 3/10(老一代研究工具、聚类不处理重叠、集成 High、无 ANE)；其现代后代就是 sherpa-onnx，方向正确。
- 声纹模型选 CAM++(性价比) / ERes2NetV2(最佳 6.14%) / `campplus_sv_zh_en_advanced`(中英夹杂)。

## 待办对比/实验

- synthesis(ask) 的 pro vs flash A/B 还没做。
- diarization 选型实测(workflow 结果回来后)。
