# 决策 & 已完成实践日志 (DECISIONS)

> 增长型日志：定下的选型/参数/结论 + 已完成功能 + 关键踩坑。带日期，别删历史。
> 当前快照看 [STATE.md](STATE.md)。

---

## Sortformer 提速：ANE + highContext（2026-06-23）

**背景**：说话人识别慢(1-on-1 也走 Sortformer，28min 录音 ~7min)、质量没明显提升。深挖发现两个可叠加旋钮。

**实测**（机器 M3/16G；CLI 临时 `sortformer-bench`，已用完删除）：
- **computeUnits**（692s 1-on-1，默认档）：`.cpuAndGPU`(现状) 推理 186s / RTF 3.7x；**`.all`(含 ANE) 73s / 9.5x**；`.cpuAndNeuralEngine` 85s。→ ANE 推理快 ~2.5x。
- **ANE 编译缓存**：首次 `.all` 加载含 ~150s ANE 编译，但**落盘缓存、跨进程持久**，后续加载 ~6s（偶发被系统回收会重编译一次，因后台跑可忍）。
- **配置档**（均 .all）：default(chunk6) 推理 91s；**highContextV2_1(chunk340) 推理 12s / RTF 59x**（推理调用 ~437→~8）；balancedV2_1 反而更慢。
- **质量代理（簇数）**：6 人 OS 会 default 与 highContext **都检出 4 簇** → ≥4 回退逐窗法路由不变、**多人会零风险**（不用 Sortformer 输出）；2 人 Hydra 1-on-1 default 检出 **4 簇**、highContext **3 簇**——highContext 更接近真实 2，过检更少、下游幽灵说话人更少。

**决策**：production 改用 **`.all`(ANE) + `highContextV2_1`**。1-on-1 识别从 ~7min 级直奔 ~30s 级。理由：多人会路由不变零风险；1-on-1 不只快 ~8x 且更干净。单一出处 `sortformerConfig`/`sortformerComputeUnits`（[Diarizer.swift](../Sources/ResoundCore/Diarizer.swift)），DiarModelCache 加载与 runDiarization 推理一致。编译+打包+启动通过。
**待用户验收**：实机重识别一条 1-on-1（如 Hydra/GGbond），肉眼确认最后干净落成 2 个说话人、贴得对；不对则回退到只用 `.all`（改 `sortformerConfig = .default`）。残留风险=highContext 大块边界更粗、无 ground truth 实测准确率（OS 文件已从 Downloads 删除）。

---

## 换人处切句：一句横跨两人 → 按词切成多行（2026-06-24）

**现象**：转录一句里同时包含两人对话（Whisper 按停顿/长度断句，不按说话人），整句只能贴一个说话人。

**前提验证**：在线转写原只要 `timestamp_granularities[]=segment`、`words:[]`。改成**也要 `word` 粒度**并解析顶层 `words`（[OnlineTranscriber.swift](../Sources/ResoundCore/OnlineTranscriber.swift)）。实测 aihubmix whisper-large-v3-turbo **返回字级时间戳**（690/698 段有词，每个汉字独立 start/end，比本地 WhisperKit 的短语级更细）。

**实现**（显示层切分，不动 transcript.json/索引，安全可逆）：
1. 识别时把**细粒度命名 diar 轮次**写 sidecar `diar_turns.json`（[SpeakerDiarize.swift](../Sources/ResoundCore/SpeakerDiarize.swift)，每个原始 diar 轮次→合并簇名，合并相邻同名）。diarization.json（一句一标）保持不变向后兼容。
2. 显示层 `LibraryModel.buildLines`：每句若有词 + 有轮次，逐词查所属轮次说话人，连续同说话人合成子句 → 一句横跨两人就切成多行；首子句保留原段 id（引用跳转仍能定位），后续子句 id=`1_000_000+段id*100+k`。英文词间补空格、中文直接拼。
3. 有轮次时**不再二次 `smoothSpeakers`**（会把切出的短插话并回邻居、抵消切分）；旧录音无 sidecar 仍走整句+平滑兜底。

**实测**（Jerry 59min 1-on-1）：698 段中 **90 段被正确切开**（如"现在它还是,只是内部在用的创改是吧?"→[Wynne,说话人1]）。识别 4 簇→合并 3：Wynne + 说话人1(Jerry 475s) + 说话人2(7s 碎片,瑕疵)。
**过碎修复（同日）**：diar 轮次在换人/卡顿附近亚秒级抖动 → 把「文飞」切成「文」+「飞…」、单字「他」蹦独立行。`buildLines` 加**双闸去毛刺**：一段说话人翻动满足「时长 < 1.2s **或** 字数 ≤ 2」任一即判毛刺、并入更长的相邻 run（句内词级 + 跨句小段两层都做）。字数闸专治"卡顿时单字被拉成长时长"（如「效」横跨 1.16s 躲过时长闸）。阈值 **1.2s / ≤2 字**（用户定，3 字以上短回应保留）。实测 Jerry 切分段 90→约 33，单字碎片消失。
**遗留**：极短簇（7s）合并阈值没收住 → 冒一个幽灵说话人2（可加"短簇并入最近"）；旧录音要重转才有词级时间戳；中文字级粒度下切点偶尔差一两字。

**⛔ 决定回退、暂不做（2026-06-24，用户+我一致判定净负优化）**：根因——切分质量的**天花板=diar 准确度**，而 diar 在难场景（相似嗓音如 Tao/Wynne、highContext 粗边界、卡顿）本就不准；切错的碎片"显得很笃定"反而比"整句归主讲者"更误导。收益面仅 ~5%（Jerry 698 段中约 33 段是真混合句），却让**整条转录**暴露在切错风险下；且 deflicker 去毛刺与切分本身相互抵消（越去噪越接近老行为）。**结论：句级归属（一句=主讲者）更诚实稳定。** 已回退 4 处改动：OnlineTranscriber 词粒度请求、SpeakerDiarize 的 `diar_turns.json` sidecar、VaultBrowser.loadDiarTurns、LibraryModel.buildLines（恢复整句按中点贴标签 + smoothSpeakers）。其余无关改动（ANE 提速、簇合并+命名互斥、列表徽标换行、导入弹窗高度）保留。若日后重启：天花板仍是 diar，应先解决相似嗓音可分性。

---

## 说话人过检 → 全员误配修复：簇合并 + 命名互斥（2026-06-23）

**现象**：新导入「2025-11-26 with Tao」1-on-1（2 人）被识别成单一一人（全 Wynne）。

**诊断**（CLI `speaker-identify` 带日志 + `diarize`）：
1. Sortformer（**default 与 highContext 都一样**，与配置无关）把这条 2 人会**过检成 4 簇**；
2. 4 ≥ saturationLimit(4) → 误触发「多人会回退逐窗法」（本是给真·多人会的）；
3. 逐窗回退不可靠：App 跑→全 Wynne，CLI 跑→GGBond(没在场!)+Wynne+4 匿名，**还不稳定**。
- 深挖：Tao 4 簇两两 cos **全 0.70~0.96**——Tao/Wynne 两男声压缩音频**声纹本就相似**（跨人 cos 高达 0.70~0.75），但同人簇 cos 0.86~0.96，**中间有缝**。

**修法**（[SpeakerDiarize.swift](../Sources/ResoundCore/identifySpeakersByDiarization)）——把"先路由后提声纹"改成"先提声纹、合并、再路由"：
1. **簇级声纹提前**：每个原始簇先提 CAM++ 质心。
2. **凝聚式合并**：质心 cos > `mergeTau=0.80` 视为同一人被切开 → 并（union-find）。0.80 落在"跨人 0.75 ↔ 同人 0.86"的缝里：过检的 1-on-1 收敛、相似的两人不被并。
3. **路由用合并后簇数**：`mergedSegs.count >= saturationLimit` 才回退逐窗法 → 过检 1-on-1 不再误入坏回退。
4. **命名互斥**：同一注册者只认领得分最高的那个簇，其余命中同名的降级匿名（相似嗓音会让陌生人也命中 Wynne，cos 0.53>τ0.5——互斥后落匿名）。

**实测**：Tao 4 簇→合并 2→**Wynne + 说话人1(Tao)** ✓；GGbond 本就 2 簇→**Wynne(0.90)+GGBond(0.90)** 零回归 ✓。这也顺带根治了"过检冒幽灵说话人"和旧的"陌生人误配已注册者(Ben→GGBond 那类)"。
**遗留**：相似嗓音下时长分配可能偏（Tao 这条 Wynne 1808s vs Tao 398s，疑似部分 Tao 段并进 Wynne 簇）；无 ground truth，靠实机肉眼 + 手动重分配兜底。highContext 边界更粗对 1-on-1 逐句归属的精度影响仍待实机看，不行则 `sortformerConfig` 退回 `.default`（保留 ANE）。

---

## Sortformer 提速：ANE + highContext（2026-06-23）

**动机**：用户手动判断「哪个词该进词表」是重操作。改成「系统观察 ⌘F 错词替换 + 一键确认」。

**设计决策**（与用户讨论后定）：
- **计数维度=不同录音数**：一次 `replaceAll` 把当前转录里所有 `q` 一次换掉只算 1；反复跨会议出现才是系统性 ASR 错误，值得进表。`recordingIds` 去重累计。
- **已知词 vs 新词阈值**：`to` 已是词表规范词（已知术语被听错）→ **第 1 次**就提示；全新词 → 攒够 **2** 条不同录音再提示（用户选 2 次）。仅在「刚跨过阈值」当下提示一次，避免重复打扰；后续仍留收件箱。
- **⚠️ 关键坑：短中文变体子串替换会污染未来转录**（如「学」→Share）。**按安全度分流**（用户选）：`isHardReplaceSafe`=含 ASCII 字母数字 或 长度≥4 → 硬（进 glossary 变体，确定性子串替换）；否则软（只把规范词加进偏置 + 错听例子 few-shot 喂 [TranscriptCorrector]，靠上下文判断，不做子串替换）。这是本系统「智能」的真正含金量：把学到的更正路由到正确的修正机制。
- **过滤非术语更正**：`shouldObserve` 挡掉整句改写（任一侧 >32 字）、纯空格/盘古之白差异（去空白后相同）。
- **dismiss 不再打扰**；观察日志放 App Support（`correction-observations.json`，派生/机器本地/噪声大），只有确认结果才落 vault 的 glossary.txt。
- **提示方式**（用户选）：即时 toast 只做提醒（无动作按钮、3.2s 消失，不适合决策）+ 设置页「待确认词表建议」收件箱做一键加入/忽略。

**落地**：新增 [CorrectionLearner.swift](../Sources/ResoundCore/CorrectionLearner.swift)（record/pending/accept/dismiss/mishearExamples + 安全分流）；[TranscriptCorrector](../Sources/ResoundCore/TranscriptCorrector.swift) 加 `mishearExamples` few-shot；[IngestPipeline](../Sources/ResoundCore/IngestPipeline.swift) 两处校对器传入；[LibraryModel](../Sources/ResoundApp/LibraryModel.swift) `replaceAll` 后 `observeCorrection`；[SettingsModel](../Sources/ResoundApp/SettingsModel.swift)+[SettingsView](../Sources/ResoundApp/SettingsView.swift) 收件箱 UI。编译+打包+启动通过，待实机验收。

---

## 性能审计：批量导入卡顿 & 长转录滚动卡顿（perf-audit workflow，2026-06-23）

**背景**：用户反馈 ①导入 ~10 文件、后台转写+识别说话人时整个 UI 卡；②长转录滚动明显卡。起 4 维并行 workflow（主线程阻塞/SwiftUI 渲染/ingest 管线/数据状态），每条发现对抗式验证，得 29 条确认问题。

**症状①(批量卡) 因果链**（主线程被 stall）：
1. **`startImport` 每文件 `load()` 全量重扫盘**（[LibraryModel.swift:671](../Sources/ResoundApp/LibraryModel.swift) **critical**，首要根因）——10 文件=10 次主线程全扫+manifest 解析+开 sqlite，逐次更大。
2. `load()` 本身同步在 @MainActor（:149-167）放大上条。
3. **模型每文件冷加载**（[Diarizer.swift:33-35](../Sources/ResoundCore/Diarizer.swift)）——~30 次 CoreML/ONNX 冷编译抢 GPU/CPU，与 WindowServer 合成器争用 → **系统级**卡（非仅本 app）。
4. `sections()` body 内算两遍（[LibraryView.swift:59,81](../Sources/ResoundApp/LibraryView.swift)）+ `recordingRow` 每行 `fileExists` syscall（:190）+ 巨型 `LibraryModel` ~50 @Published fan-out（任一变更失效整 body）。
5. 次要：worker 每条全扫库取一条（:489）、转录单/双 16k 解码（[SpeakerDiarize.swift:27,30](../Sources/ResoundCore/SpeakerDiarize.swift)）、index 阶段标注被 diarize 覆盖的冗余 embed（[IndexPipeline.swift:76-89](../Sources/ResoundCore/IndexPipeline.swift)）。

**症状②(长转录卡) 因果链**：
1. **0.25s 播放计时器把 `currentTime` 设 `@Published`**（[LibraryModel.swift:751-754](../Sources/ResoundApp/LibraryModel.swift) **high**，首要根因）——4×/s 失效整 `LibraryView.body` 重算转录 ForEach（**仅播放中触发**，静止滚动不受此影响）。
2. `Line`/`Block` 非 Equatable + UUID 每次重载重生（:13-25）——行无法 prune、全量重建、丢滚动位置。
3. LazyVStack 不回收行（[LibraryView.swift:640-651](../Sources/ResoundApp/LibraryView.swift)）——滚越远常驻越多，每次失效成本随之涨。

**落地顺序（分组，每组独立可 ship+测）**：
- **A 批量主线程扫盘**（症状① 主攻，收益最大）：`startImport` 去每文件 `load()`→增量插单条 + 末尾一次 reconcile；`load()` 迁 `Task.detached`；worker 队列改存 `RecordingSummary`。
- **B 模型缓存+解码去重**：进程级 `actor DiarModelCache`（N 冷加载→1）；`runDiarization(samples:)` 消双解码；`indexRecording(labelSpeakers:false)` 导入时跳冗余标注。
- **C 列表渲染廉价热点**（纯 view 层、低风险）：`RecordingSummary.identified` 预算去行内 stat；`sections()` 提取单次复用。
- **D 长转录稳态**（症状② 主攻，step 9→10→11 有序）：发布 `activeLineID`（仅跨行变）；抽 `TranscriptRow`(取 `isActive:Bool`)+`Line`/`Block` 合成 Equatable+稳定 id；抽 `PlayerBar`/`PlayheadModel` 让计时器只刷播放条。
- **E 收尾(可选)**：缓存 `findMatchCount`；评估转录迁 `List`/拍平 block→lines；拆巨型 `LibraryModel`/迁 `@Observable`。

**关键注意**（验证时踩坑预防）：sqlite 写**不要**挪进 `Task.detached`（并发损坏风险）；`listColumn` 是 `some View`，提取 `sections()` 复用需显式 return；E 的 `List` 迁移要先验完 D 再决定是否需要。

---

## 性能优化 A–D 落地（编译+打包+启动通过，待实机验收，2026-06-23）

用户拍板做 **A+B+C+D**（E 结构性重构暂不做）。实现要点：

**A 批量导入主线程扫盘**（症状①主因）
- `startImport`：删每文件 `load()`，改 `insertRecording(_:)` 增量插入单条（按 `recordedAt` 倒序就位、按 id 去重）。文件夹/声纹库导入时不变，无需重扫。
- `load()` → 私有 `reload(reselect:then:)`：`listRecordings`+`LibraryStore.load`+`loadSpeakerRefs` 全进 `Task.detached(.userInitiated)`，算完回主线程一次性发布。保留 `pendingCiteTime` guard 与 selectedId 选择逻辑。
- `openCitation`：列表已含该录音→直接 `applyCitation`；否则 `reload(then:)` 异步就绪后再 select+seek+定位（不再同步卡主线程；引用跳转 seek 仍 work）。
- 说话人 worker：`speakerQueue` 由 `[String]`→`[RecordingSummary]`，`enqueueSpeakerID(_ rec:)` 入队，worker 直接用 rec，**不再每条 `listRecordings().first{id}` 全扫库**。`RecordingController`/`startImport` 都用 `loadRecordingSummary(dir:)` 建 summary 入队。
- `saveRenameRec`/`confirmDeleteRec` 改 `reload(reselect:)`/`reload()`。

**B 模型缓存 + 解码/标注去重**（症状①系统级抢占）
- 新增 `public actor DiarModelCache.shared`：懒缓存 `SortformerModels`/`DiarizerModels`/`VadManager`/`[model:SpeakerEmbedder]`。`runDiarization(samples:)`/`SpeakerDiarize` 改用缓存（N 文件 ~30 次 CoreML/ONNX 冷加载→1 次）。worker 串行执行，单实例复用安全。
- `runDiarization` 拆成 `audio:`（解码后转发；offline 仍走 URL）+ `samples:`（已解码 16k）两版；`identifySpeakersByDiarization` 单次解码后传 samples，**消除同文件二次解码**。
- `IndexPipeline.indexRecording(labelSpeakers:Bool=true)`：导入(`startImport`)与录音(`RecordingController`)路径传 **false**，跳过随后会被 diarization 覆盖的整段提声纹标注；手动改文本 reindex 仍 true。

**C 列表渲染廉价热点**（症状①放大器）
- `RecordingSummary` 加 `let identified: Bool`，`listRecordings`/`loadRecordingSummary` 扫描时一次性 `fileExists(diarization.json)`；列表行读内存标志，**去掉每行每次重绘的 syscall**。worker 完成调 `markIdentified(id:)` 即时翻标志（「待识别」徽标消失，免重扫）。
- `LibraryView.listColumn`：`let secs = vm.sections()` 提取一次复用（原 body 内跑两遍 O(folders×recordings)），`some View` 故显式 `return`。

**D 长转录稳态**（症状②主因）
- 拆 `@MainActor final class Playhead: ObservableObject { @Published var time }`，`LibraryModel.playhead`；`currentTime` 改为代理 `playhead.time` 的计算属性——**不再触发 LibraryModel.objectWillChange**。`PlayerBar` 独立子视图 `@ObservedObject playhead`，0.25s 跳动只重绘播放条，父视图（观察 LibraryModel）不读 `playhead.time` 故不重绘 → 长转录列表不再每秒 4 次重算。
- 转录高亮：新增 `@Published activeLineID:Int?`，计时器二分算当前行、**仅跨行时发布**；`transcriptRow.active = vm.activeLineID == ln.id`（不再读每秒跳动的 currentTime）。`scrub`/`scrubEnded` 同步 `activeLineID`。
- `Line`/`Block` 改 `Identifiable, Equatable`，`Line.id` 用 transcript 段 id（稳定，非每次新 UUID）、`Block.id` 取首行 id；`scrollToLine`/`firstMatchLineID`→`Int?`。重载/识别完成不再全量重建行、不丢滚动位置；`proxy.scrollTo(Int)` 正常。

**验证**：`swift build -c release` 通过（仅 v5 下的 Swift6-mode 非 Sendable 警告，语言模式 v5 不报错）；`RESOUND_SIGN_ID="Resound Dev"` 打包+启动通过。待用户实机验四个验收点（见 STATE）。

**录音按「真实会议日期」排序（方案 B 治本，同日）**：问题=`recordedAt` 一直写的是**入库时刻**（`iso8601(now)`），导入的旧录音（如 6/10 的 1on1 在 6/23 导入）排序/详情/Ask 全用导入日，错位；真实会议日只在标题里（「2026-06-10 月度 1on1」）。决策（用户拍板 B、不做 C 手动菜单）：
- 新建 [TitleDate.swift](../Sources/ResoundCore/TitleDate.swift) `parseTitleDate`：多格式（`yyyy-MM-dd`/`/`/`.`、`yyyy年M月d日`、`M月d日`、`MM-dd`/`M/d`，任意位置），无年按「不晚于今天」推断年份；回读校验拒非法日期；`MM-dd` 仅认 `-`/`/`（避开 v3.2/GPT-4）。
- 导入时 `recordedAt = parseTitleDate(title) ?? 文件 mtime ?? now`（[IngestPipeline.swift](../Sources/ResoundCore/IngestPipeline.swift)）；**id/目录仍用 now 保唯一**（解耦：id 是内部标识、recordedAt 是会议日）。排序/详情/Ask 口径统一。
- 已有录音一次性修正：CLI `resound redate`（默认 dry-run，`--apply` 落盘），改 recording.yaml `recorded_at` + 索引 `recordings.recorded_at` & `chunks.recording_date`（[Index.setRecordingDate](../Sources/ResoundCore/Index.swift)，不重嵌入）。已对 14 条 1on1 apply 成功（年份含 2025 正确）。App 列表本就按 recordedAt 倒序，无需改、自动生效。

**摘要/问答 prompt 完善（同日）**：①摘要 system prompt 写入会议日期为权威事实（不依赖模板 `{date}` 占位符）——修「LLM 不知日期把 2026 年事写成 2025」。②Ask 的 qa 综合回答 + digest 汇总回答 system 加「今天」锚点（QueryPlanner 本就有）。③新建 [Prompting.swift](../Sources/ResoundCore/Prompting.swift) 共享常量：`zhWritingStyle`（盘古之白：中↔英字母/数字间加空格，Q2/v3/GPT-4 不拆、中文标点旁不加）+ `todayAnchor()`，摘要/qa/digest 三处复用避免漂移。

**踩坑：引用跳转能跳但不滚动（同日修）**——`openCitation` 在用户**还在 Ask 页**时就触发后台 `refreshDetail`，转录载入很快、常在 `LibraryView` 挂载**之前**就设好 `scrollToLine` → 原来只用 `.onChange(of: scrollToLine)` 监听，挂载前的那次变更被错过 → 永不滚动（但选中+切转录页正常，所以"能跳不滚"）。对策：待定滚动改由三处触发——`onAppear` + `.onChange(of: blocks.count)`（转录载入后）+ `.onChange(of: scrollToLine)`，滚完清空 `scrollToLine`、并 `guard scrollToLine == id` 防被新跳转串扰（[LibraryView.swift](../Sources/ResoundApp/LibraryView.swift) `scrollToCitation`）。教训：跨页跳转时，依赖"目标视图 onChange"接收挂载前设的状态不可靠，要在目标视图 onAppear 也消费一次。

---

## 转录质量评测：根因=中英混说的领域专名漏出词表（2026-06-23）

**背景**：用户给一条 29min 真实 1-on-1（中英混杂，GGbond）+ 商用参考转写做基准，问当前转录能否优化（并附知乎文推荐 FunASR/Paraformer）。

**实跑**（`resound transcribe` 进临时 vault，真实链路：在线 `whisper-large-v3-turbo`@aihubmix + glossary 偏置/别名 + DeepSeek 校对；RTF≈0.05~0.09，速度非瓶颈）：
- **常见短英词正确**：skill/OS/PR/memory/GSD 等基本无误。
- **glossary 真的有效**：词表里有的词被修正——`Tracking = checking` 别名把 "checking notification"→"Tracking notification"；"PM" 偏置把 "片说了"→"PM 说了"。
- **仍错的全是没进词表的领域专名**：Share→"学一下屏幕"、platform notification→"Premium/Plan Phone Notification"、Polaris→"Paris13"、AfterShip OS→"AOS"。
- 对照实验证伪了"换引擎才行"：**错误强相关于"是否在词表"，与引擎关系小**。参考转写之所以好，也是同类原因（商用服务有 hotword/术语注入），且它自己也错了 Mailcraft/anypoe 等没注入的词。

**结论（优化优先级）**：
1. **立刻、最高性价比**：扩充 glossary——把高频领域专名 + 实测误转写法补进去（platform notification = Premium Notification/Plan Phone；Polaris = Paris；Share；AfterShip OS = AOS；Mailcraft；Flow v3；email/SMS editor…）。直接喂给 whisper prompt 偏置 + 别名纠正 + 校对器，零改码、已验证有效。
2. **中等**：强化 AI 校对——把领域术语表 + 常见英文专名误听模式显式传给 corrector（现在拿到 glossaryTerms 但不够激进，误转写仍漏过）。
3. **可选、较大**：引擎 spike。文章推的 FunASR/Paraformer 杀手锏正是 **hotword 强偏置**，但我们 whisper+glossary 已能做到同类效果；真要离线/省 API，**走已链接的 sherpa-onnx（CAM++ 同款依赖）跑 Paraformer-zh + hotwords，纯 C++ 不需 Python/torch**——比 FunASR 的 Python 路径更契合本仓。"快 170×"对我们无意义（在线已够快）。
**FunASR/Paraformer 活体实测（2026-06-23 补，清华镜像装 torch 才成）**：在同一条音频上真跑了 `paraformer-zh`（SeACo-Paraformer，vocab8404）+ VAD + 标点，无 hotword 与带 hotword 两轮：
- **对中英混说明显比 whisper 差**：platform notification→"protiplfication"/"pronotification"（乱码）、AfterShip OS→"approach OS"、Share→"需要"、PM→"天"。根因=**中文模型小词表(8404)**，英文专名被音译成中文乱码；whisper-large-v3 多语种、英文底子强，至少吐可读英文（Premium Notification）可纠。
- **hotword 几乎没救回英文专名**（SeACo hotword 偏中文词/人名，对英文短语在小词表里无力）。
- **速度也不占优**：本机 CPU 实跑 RTF 0.21~0.32，比我们在线 whisper(0.05~0.09)还慢。文章"170×"是 GPU 理想值，且全篇只比速度、零准确率对比。
- **定论**：我们场景（zh-en 混说 + 英文术语密集）**不该换 Paraformer-zh，whisper-large-v3 是更优底座**。真正杠杆仍是扩 glossary（已证：词表里的 PM/Tracking 都修对）。实验产物在 `/tmp/resound-cmp/`（funasr_base.txt / funasr_hot.txt / resound2_full.txt），venv 在 `/tmp/resound-cmp/funasr-venv`。

## 踩坑：录在线会议「屏幕录制权限被拒」反复出现（2026-06-23）

**现象**：系统设置里 Resound 的「屏幕录制」明明已勾，录在线会议仍报「用户拒绝 TCC / 捕获启动失败」；权限列表还有两个残留的「AfterShip Meeting」。

**根因**：`bundle-app.sh` 用 **ad-hoc 签名**（`codesign --sign -`）。**屏幕录制权限(TCC)对 ad-hoc 应用是按 cdhash(可执行哈希)记的**——每次重新打包代码变 → cdhash 变 → 系统里那条 grant 绑的是旧 cdhash，当前启动的二进制对不上 → 被拒。开关看着是亮的（按 bundle id+路径留着），但授权实质失效。残留的「AfterShip Meeting」是更早不同 bundle id/名的旧 grant。

**对策**：用**稳定的代码签名证书**签 → Designated Requirement 稳定 → 屏幕录制授权一次后所有重新打包长期有效。
- 本机的 `Developer ID Application: AfterShip Limited` **不可用**：`codesign` 报 `unable to build chain to self-signed root` + `errSecInternalComponent`（证书链不完整；且公司证书不宜用于个人项目）。
- 方案=**自签名「代码签名」证书**（无证书链问题、最适合本地）。`bundle-app.sh` 已改：读环境变量 `RESOUND_SIGN_ID`，存在则用它签（失败稳妥回退 ad-hoc，不会把 app 留成坏签名），未设则 ad-hoc + 提示。
- 一次性设置：钥匙串访问 › 证书助理 › 创建证书 → 自签名根 + 代码签名类型 → `export RESOUND_SIGN_ID="证书名"` → 重新打包 → 授权一次永久生效。
- **已落地（2026-06-23）**：用户建了自签名「Resound Dev」。脚本检测从 `find-identity -v` 改为 **`-p codesigning`（不带 -v）**——自签名根未受信(`CSSMERR_TP_NOT_TRUSTED`)会被 `-v` 过滤掉，但本地签名/TCC 用途不需受信。现签名后 DR=`identifier "com.wynne.resound" and certificate leaf = H"92bf0e…"`，跨重打包稳定。切到稳定签名后需**再授权一次屏幕录制**（签名变了），之后永久有效；旧的 ad-hoc / 残留「AfterShip Meeting」TCC 记录可在系统设置删掉。

## 导入耗时占比实测 + 转录优化落地（2026-06-23）

**29min 录音全链路实测（M3/16G，CLI 分段计时）**：导出 ~4s／转录(在线 whisper-v3-turbo) ~85s／AI 校对(v4-flash) ~35s／切块入库+embedding ~38s／摘要 ~15s／**说话人识别(Sortformer+回退) ~707s(11m47)**。**说话人识别独占 ~80%**，其余全部加起来 ~3min。
- 这条是 4 人会 → 检出 ≥4 簇触发回退逐窗法，等于 **Sortformer 整跑一遍被丢弃 + 逐窗法重算**（`user 6m11/real 11m47`，差值=ANE 推理等待，不计 CPU%）。
- **但双跑只发生在 ≥4 人会**；用户常见的 1-on-1（≤3 簇）不回退，成本=Sortformer 本身(~5–6min 估)。故"去双跑"对常见场景收益小（上轮"省 40%"说法已修正）。
- **优化定调**：① 砍回退会掉多人会质量（不做）；② **真正零质量损失的是"说话人识别后台化/可延后"**——转录+入库(~2min)就绪即可用，说话人名字后台补，Sortformer+回退逻辑不动。Sortformer 慢是 ANE 固有成本。

**说话人识别后台化（编译通过，待实机验收）**：导入/录音不再等 ~6–12min 的说话人识别。
- 流程改成：转写+入库(~2min)一完成就**露出录音**（可读/可搜/可问答），说话人识别(Sortformer)+摘要进 `LibraryModel` 的**后台串行 worker**（`enqueueSpeakerID`/`runSpeakerWorker`，一次一条避免多 Sortformer 抢 ANE）。摘要放识别之后→自带真名。
- UI 提示：列表行显示「识别说话人中…」(spinner)；摘要 Tab 显示「正在识别说话人，完成后自动生成带姓名的摘要」；逐句 Tab 顶部 identifying 卡片。`identifyingIds: Set` 驱动。
- **顺带修了潜在 bug**：直播录音(RecordingController)原来 `procStep=1「识别说话人」`只闪标签、**根本没调 identify**（现场录音从来没说话人、摘要也没真名）。现在录完经 `recorder.library?.enqueueSpeakerID` 走同一后台路径，真正补上识别+带名摘要。procLabels 改为 2 步「转写/加入录音库」。

**转录优化已落地（编译通过，待打包实机验收）**：
1. **扩 glossary**（vault/glossary.txt）：加 `platform notification = Premium Notification, Plan Phone notification, Planet phone`、`Polaris = Paris`、`AfterShip OS = AOS`（无歧义→别名纠正）+ `Mailcraft/Flow v3/Share/SMS editor/Email editor`（易误伤→仅偏置）。同时喂 whisper 偏置 + 别名纠正 + 校对器术语表。注意 `Glossary.apply` 是字面子串替换、大小写敏感、无词边界，故易误伤的词坚决不做别名。
2. **校对器(v4-flash)增强**（[TranscriptCorrector.swift](Sources/ResoundCore/TranscriptCorrector.swift)）：temperature 0→**0.3**（纯 0 太死、不敢碰可疑专名）；prompt 显式加"**英文专名读音错听**"指令——让模型用它对英文发音的了解，把读音接近术语表某词、上下文也对得上的错听（Premium Notification→platform notification、Paris→Polaris、学→Share）纠回，拿不准就保持原样。靠覆盖率闸 + "拿不准别改"兜对齐。

## 说话人「重分配」+ 单注册者误配治理（2026-06-23，编译+打包+启动通过，待实机验收）

**现象**：Ben 的录音（删除后重导仍）被误识别成 GGBond，且用户感觉无从纠错。

**根因**：`identifySpeakersByDiarization` 簇级匹配用 `SpeakerMatcher(tauAbs: 0.45)`，而声纹库里**只注册了 GGBond 一个人**——没有竞争者，margin 门（tauMargin=0）形同虚设。CAM++ 同语种跨人 cosine 常达 0.45~0.55，0.45 太松，于是陌生人 Ben 的簇质心被这唯一的参考"吸"成 GGBond。重导也一样，因为库没变。

**对策（两条线）**：
1. **准度**：簇级绝对门 0.45→**0.5**（真同人 cosine 通常 0.6+，0.5 仍宽松；宁可陌生人落匿名也别误配）。并在每簇匹配处**打印 cos/margin**（命中）或最近参考 cos（落匿名），CLI `speaker-identify` 日志里能看到真实数字，便于按 Ben 这条真实录音再调门限。
2. **重分配交互**：`renameSpeakerInRecording` 的 enroll **只 upsert 新名字的 ref，从不动原来那个人（GGBond）的声纹**——机制本就安全，缺的是 UX：
   - `LibraryModel.openRenameSpeaker`：纠正已识别者时 `remember` 默认由**关→开**（重分配的本意就是"登记成新说话人，下次自动认出"；纯改错别字用户可手动取消勾）。这关键修复了"重分配后下次仍误配"——一旦把 Ben 登记，他自己的质心（≈0.7）会压过 GGBond（≈0.48）。
   - 命名弹窗（Overlays.swift）按 `isAnon` **分文案**：匿名→"认领并命名"；已命名→"**重新分配说话人**"，明确"只改这条标注、**不会改动「GGBond」已记住的声音**"、并把 TA 登记为**新**说话人。

**为何重分配能根治复发**：误配的本质是"库里只有 A、陌生人 B 离 A 不够远"。把 B 登记后，下条录音 B 的簇对 B 自己的质心 cosine 远高于对 A 的 → 正确归 B。即"标一次就收敛"。

## UI 全量还原 Claude design 设计稿(2026-06-22，编译+打包+启动验证)

设计稿 `Resound.dc.html`(Claude design 导出的 HTML/CSS/JS mock)→ 按视觉 1:1 还原成 SwiftUI。

- **两处岔路（用户拍板）**:①**窗口外壳=原生窗口 + 菜单栏驻留**(不复刻 mock 里的假交通灯/假系统菜单栏/壁纸相框)。用 `.windowStyle(.hiddenTitleBar)` + 自绘 46px 顶栏(左留 78pt 给真交通灯)+ `WindowConfigurator`(NSViewRepresentable 设 titlebarTransparent/movableByWindowBackground/背景色)+ `MenuBarExtra`(状态/录音开关/模拟会议/主题/退出)。②**两块缺口后端都打通**(见下)。
- **架构**:四个 App 级 `@MainActor ObservableObject`,经 environmentObject 注入,以便在全窗范围渲染模态——`AppModel`(导航/主题/toast/`libraryReloadToken`)、`RecordingController`(录音引擎,toast 改走 app)、`LibraryModel`、`SettingsModel`。模态浮层全部挂 `OverlayHost`(RootView 顶层 ZStack),`ModalScrim` 半透明背景覆盖侧栏+内容。
- **配色**:`Palette` struct 把设计稿浅/深两套 token 全量落地(bg/sidebar/elev/inset/text 三档/border 两档/accent·rec·ok·warn + soft 变体),经 `\.palette` Environment 注入;主题开关存 UserDefaults,`preferredColorScheme` 强制。
- **三页**:Ask(空态 hero+6 chips、流式逐字回答+光标、时间范围徽标、qa 引用/digest 来源卡,全接 `IndexPipeline.answer` 的 `AnswerResult`:digest→sources、hits 空+有 dateRange→emptyTime、否则 cites);Library(列表+导入+自绘 `Scrubber` 播放器+摘要/转录 Tab;摘要读 `summary.md` 用 `SummaryMarkdown` 渲染+模板菜单+重新生成;转录页说话人名册+逐句高亮+点名册/点行命名);Settings(就绪状态/权限[AVCaptureDevice+CGPreflightScreenCaptureAccess]/通用开关/模板 CRUD/词表 CRUD)。
- **可选模型字段绑定**:模态 TextField 直接 `Binding(get:{model.x?.field ?? ""}, set:{model.x?.field=$0})` 用 Swift 可选链赋值(nil 时 no-op)。**踩坑**:一开始想用 `KeyPath<OverlayHost,_>` 泛型 helper 包装,但那些字段在 env model 上、不在 View 上,编译不过 → 退回内联 Binding。
- 验证:`swift build` 全过、`bundle-app.sh release` 打包、`open` 后进程存活无崩溃。**视觉细节(像素/间距/手感)待用户实机截图验收**——我看不到 GUI。

### 打通：说话人命名 → 声纹注册（2026-06-22）

- `SpeakerNaming.swift::renameSpeakerInRecording`:①改写该录音 `diarization.json`(oldLabel→真名);②对 index 里**该说话人在 chunk 内占主导**(`personFor` 判定 == 新名)的 chunk `setChunkPerson` 打真名(让问答引用也显示真名,且不覆盖其他说话人/已有声纹标);③勾「记住」时:`mergeASRSegments` 把该说话人的转录段并成窗口→取最长 5 个 `SpeakerEmbedder.embed`→`SpeakerMatcher` setReference/enroll→`Index.upsertSpeakerRef`,以后新录音 `recognizeSpansFromFile` 自动认出(越用越准闭环)。**依据**:diarization.json(匿名 N) 与 index chunk persons(声纹名/nil) 是两套独立标注,所以命名时两边都要动。

### Library 文件夹 + 检索 + 词表内置项（2026-06-22）

- **内置词表**:往 vault/glossary.txt 批量加了 27 个团队/产品术语(AfterShip/Notification/Flow/Shopify/MF/ARR/GSD…),均为裸规范词(只偏置不纠正)。脚本读旧表→去重→追加,保留原条目。
- **Library 文件夹**:新增组织层 `vault/library.json`(`LibraryStore` + `LibraryFolder`/`LibraryOrganization`:folders[] + assign{recId→folderId}),**不动录音目录/契约**(纯 sidecar)。`LibraryModel` 加 folders/assign/collapsed/query + CRUD/move/sections()。
- **左列改造**:顶部「新建文件夹 + 导入」图标 + **搜索框**(按标题过滤,带清除);列表按**文件夹分组**(folder.fill 组 + 末尾「未分类/全部录音」托盘组),组头 chevron **可折叠**(搜索时强制展开);组头右键重命名/删除文件夹;录音行右键「移动到 ▸ 文件夹/未分类/新建」。删文件夹→内部录音回未分类(不删录音)。
- **决策**:文件夹放 Library 左列分组(Apple Notes/语音备忘录式),不放主导航侧栏——主导航保持 3 项简洁;"左侧栏展开折叠"理解为左列文件夹组的折叠。检索 v1 只按标题(快);全文语义检索本就是 Ask Resound 的职责。

### 第三轮优化 + Meet 名称调研（2026-06-22）

1. **摘要模板名没显示**:`templateMenu` 之前 `.menuStyle(.borderlessButton)` 吞了 label 文本/叠了两个箭头。改:label 改成「📄 模板 · <名称> ⌄」单行,加 `.menuIndicator(.hidden)` 去掉系统箭头。
2. **Cmd+F 查找/替换**(修识别错误):录音详情按 ⌘F 弹查找条,作用于当前 Tab(转录/摘要)。`LibraryModel.replaceAll` 全部替换并写回事实源(transcript.json / summary.md + index summary),刷新展示。**注**:替换 transcript.json 不重嵌入 index chunk(检索向量仍旧);够用于改显示+摘要,要彻底进检索得重建索引。Line.text 改 var。
3. **Google Meet 会议名(调研 + 落地)**:之前只拿 URL id。**结论:最划算是读 Chrome 标签标题** —— 日历预订的会议,标签标题通常就是事件名(形如 "(3) 团队周会 - Google Meet")。已实现:`MeetWatcher.chromeMeeting()` 同时取 URL+title,`cleanMeetingTitle` 去未读数前缀/「Google Meet」装饰;`Event.started(url,title,mic)`;`RecordingController.meetingTitle` → 入库时作录音标题(替代 UUID),并显示在弹窗副标题。**更准但更重的方案(未做,留备选)**:Google Calendar API(OAuth)按 `conferenceData.entryPoints` 的 meet id 匹配当前事件取 summary —— 能拿到准确事件名+参与者,但要 OAuth+联网+权限,过重;标签标题已覆盖绝大多数日历会议场景。备选②:Chrome「允许 Apple 事件执行 JS」后 `execute javascript` 读 Meet DOM 标题,比标题更脏,不如直接用 tab title。

### 一批 UI/后端优化（2026-06-22，用户反馈第二轮）

1. **转写改在线 turbo**（核心）:本地 WhisperKit 太慢 → 默认改走 aihubmix `whisper-large-v3-turbo`。`OnlineTranscriber.swift` 多部分 POST `{AIHUBMIX_BASE_URL}/audio/transcriptions`(verbose_json + segment 时间戳,复用 embedding 同域同 key),上传 ingest 已导出的 `audio.m4a`(压缩,绕 25MB 限)。Config 加 `transcribeModel`(TRANSCRIBE_MODEL,默认 whisper-large-v3-turbo)+ `transcribeOnline`(TRANSCRIBE_ONLINE,默认 true;设 false 回退本地)。**已用 `say` 生成短 clip curl 实测端点**:返回 `{language,duration,segments:[{start,end,text}]}` 与解码结构吻合。CLI/App 入库都自动走在线。
2. **菜单栏型 App**:`AppDelegate`(NSApplicationDelegateAdaptor)`applicationShouldTerminateAfterLastWindowClosed=false`;监听 `NSWindow.willCloseNotification`,关掉主窗后若无可见主窗 → `setActivationPolicy(.accessory)`(退出 Dock,只剩菜单栏图标);`WindowConfigurator` 窗口出现时设 `.regular`(恢复 Dock);菜单栏「打开主窗口」先 `.regular` 再 `openWindow("main")`。**澄清**:窗口内顶栏只是自绘标题栏(录音/主题按钮),不是菜单 —— 下拉菜单是系统菜单栏的 `MenuBarExtra` 图标。
3. **弹窗阴影裁切**:之前 padding(16) < shadow radius(30) → 阴影被 panel 边界裁成硬矩形(看着像半透明渐变底)。改 padding(24) + shadow(radius16,y6),panel 贴 visibleFrame 右上角(留白即视觉边距)。
4. **摘要可选中复制**:`SummaryMarkdown` 加 `.textSelection(.enabled)`。
5. **说话人试听**:`LibraryModel` 存 `diarSpans` + `playSpeakerSample(label)`(取该说话人最长 diar 段,seek+play,`stopAt` 到点自停;再点暂停),名册行加播放按钮 —— 标注前快速辨认谁是谁。

### 会议检测弹窗改为屏幕级浮窗（2026-06-22，用户反馈）

- **现象/诉求**:初版把弹窗做成主窗口内的 SwiftUI overlay(OverlayHost),贴 App 右上角;但用户要它贴**屏幕**右上角,且窗口最小化/关闭(App 仍在菜单栏后台)时也要弹。
- **方案**:`MeetingPanel.swift::MeetingPanelController`(单例)持一个独立 `NSPanel`(`.borderless+.nonactivatingPanel`、`level=.floating`、`collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]`、透明背景由 SwiftUI 卡片自绘),贴 `NSScreen.main.visibleFrame` 右上角。内容 `MeetingPopupCard`(从 OverlayHost 抽出复用)。
- **关键**:用 **Combine 订阅 `recorder.$phase`**(不是 View 的 onChange)来 show/hide —— 窗口关了 View 不渲染,但单例订阅和 `RecordingController`(App 级 @StateObject)都活着,所以后台仍能弹。`nonactivatingPanel` 让后台点按钮不抢焦点也能用。
- 顺带:`WindowGroup(id:"main")` + 菜单栏 `openWindow("main")`,窗口被关后能从菜单栏重新打开。

### 打通：专有词表读写（2026-06-22）

- `GlossaryStore.swift`:`GlossaryEntry{canonical,variants}` 结构化读写 `vault/glossary.txt`(沿用 `Glossary` 的 `规范词 = 变体1, 变体2` 格式)。`save` 覆盖写+保留头注释(词表已由 App「设置›专有词表」接管,丢弃用户手写注释)。`Glossary`(消费:偏置+纠正)保持只读不变,本类型只管 CRUD。
- `Index.recordingSummaryInfo(id:)` 新增:读已存摘要正文+模板 id,供录音库摘要页展示。

---

## App 套壳阶段决策(2026-06-22，开工前定)

- **形态**:不只是 Chat——三块。①Chat 页(问答,答案带可点引用:录音/时间点/说话人,= `ask`);②录音库页(列表+带说话人标注全文+播放跳转);③录音采集(菜单栏/悬浮窗 + Meet 弹窗);④设置(vault repo/说话人命名/密钥)。心智模型="只懂你自己录音的私人 ChatGPT"。
- **Meet 检测**(用户选):轮询 Chrome 标签 URL(AppleScript/Apple Events 匹配 `meet.google.com/xxx-xxxx-xxx` 会议室)+ 麦克风占用(CoreAudio 输入设备 running)确认在通话 → 弹窗。**无需 Chrome 扩展**,只要自动化权限(TCC)。以后要更准可加扩展+原生消息。
- **录音范围**(用户选):**麦克风 + 会议对方音双路** → 用 **ScreenCaptureKit**(macOS 13+,抓 Chrome/系统音频)+ 麦克风,混音。需屏幕录制权限。**现 CLI Recorder 只录麦克风,会议录音要新写采集器。**
- **待定结构岔路**:GUI+TCC 权限(麦克风/屏幕录制/自动化)需要正式 .app bundle。SPM CLI 现状 → 要么建 Xcode app 工程(依赖本地 SPM 包 ResoundCore),要么 SPM+手动打 .app bundle。Claude 不能开 Xcode GUI,影响谁来 build/授权。

### App 阶段1：会议录音器(2026-06-22，代码完成待实测)

- `MeetingRecorder.swift`:系统音频用 **ScreenCaptureKit**(SCStream `capturesAudio`→AVAssetWriter,直接 append CMSampleBuffer 免手动音频格式转换)+ 麦克风用 **AVAudioEngine** input tap→AVAudioFile;停止后两路各用 `AudioConverter().resampleAudioFile` 重采样到 16k 单声道 → 相加(0.8 增益+硬限幅)→ 写 wav。CLI `record-meeting --vault`→混音→走 IngestPipeline.ingest 入库(source 默认 meeting)。
- **为何后混而非实时混**:避开 SCStream 缓冲实时进 AVAudioEngine 的格式/同步复杂度;复用现成 resampleAudioFile;混音是纯数组运算易正确。代价:16k 单声道存档(够转录/检索,非高保真)——后续要高保真再改实时混/离线 AVMutableComposition。
- macOS 14:SCStream 抓系统音(13+)、麦克风单独抓(SCStream 抓麦是 15+)。
- 验证:编译过;沙箱无屏幕录制权限→优雅报 `screenPermission` 错+指引,不崩。**实测待用户授权屏幕录制(系统设置→隐私→屏幕录制 勾选终端)后跑 `record-meeting`**。

### App 阶段3-1：SwiftUI 骨架(2026-06-22，编译+打包通过)

- **工程结构(用户选)**:SPM 应用 + 打包脚本(非 Xcode 工程)。新增 `ResoundApp` executableTarget(SwiftUI,依赖 ResoundCore),product `ResoundApp`。`resound` CLI 与 `ResoundApp` GUI 共存同一包。
- **界面**:`ResoundApp.swift`(@main App/WindowGroup)、`RootView.swift`(TabView:问答/录音库/设置;后两者占位)、`ChatView.swift`(ChatViewModel 接真实管线:IndexPipeline.search+rerank → Synthesizer,答案带可点来源含 👤说话人)。
- **打包**:`scripts/bundle-app.sh [debug|release]` → `build/Resound.app`(gitignored):组装 Contents/{MacOS/Resound,Resources/资源bundle,Info.plist} + ad-hoc 签名。**坑**:资源 bundle 放 Contents/Resources(非 MacOS)、签名**去掉 --deep**(纯数据 bundle 不可 --deep 签),否则 codesign 报 "bundle format unrecognized"。Info.plist 含 NSMicrophoneUsageDescription / NSAppleEventsUsageDescription。
- **配置发现**:Config.loadDotEnv 加 `RESOUND_ENV` 环境变量 + `~/Library/Application Support/Resound/.env`(.app 启动 cwd=/ 找不到仓库 .env)。**用户需把 .env 复制到 App Support**。
- 验证:swift build 全过、bundle-app.sh 产出的 .app `codesign --verify` 通过。**GUI 渲染/Chat 实际问答待用户运行(我看不到渲染)**。
- 待:Chat 实测;录音库页(列表+带说话人转录+播放跳转);设置页(可视化 vault/密钥/说话人);把 record-meeting/watch-meet 接进 UI(菜单栏 + Meet 弹窗);说话人命名 UI。

### App 阶段3-5：录音库页(2026-06-22，编译+打包通过，用户迭代中)

- `VaultBrowser.swift`(ResoundCore 公开):`RecordingSummary` / `listRecordings(vault)` / `loadTranscript` / `renameRecording`(改 recording.yaml title 行) / `deleteRecording`(删目录) / `SpeakerSeg`+`loadDiarization` / `analyzeSpeakers`(冷启动 onlineCluster→匿名「说话人N」→按段标注→缓存 vault `diarization.json`)。
- Index 加 `chunkPersons(recordingId)`(段级 person)、`deleteRecording(id)`。
- `LibraryView.swift`:左录音列表 + 右详情(播放条 + 转录)。AVAudioPlayer 播 audio.m4a。
  - 用户反馈 4 项已做:① 整卡可点(contentShape+onTapGesture,非只文本) ② 右键重命名/删除(alert 确认,删连索引) ③ hover 变手型(`hoverCursor()`=onHover+NSCursor.pointingHand,Theme.swift) ④ 可拖拽进度条(Slider+scrubbing 标志防 timer 抢)+ 转录标 👤说话人(来源:diarization.json>index person;无则「识别说话人」按钮触发 analyzeSpeakers)。
- 说话人来源优先级:diarization.json(缓存) → index chunk person → 「识别说话人」现算。匿名「说话人N」待命名 UI 改真名+存声纹。

### App 阶段3-4：样式重构 v2(2026-06-22，用户认可方向)

- **方向**(ui-ux-pro-max skill 印证):磨砂玻璃 + 冷蓝点缀(品牌色=waveform蓝+recording红)+ 通透冷调近白底。玻璃拟态要诀:磨砂材质需"可模糊的底"才不发灰 → **背景加极淡蓝色辉光(呼应图标涟漪)治"太闷"**。
- `Theme.swift`:`accent`冷蓝/`accentGradient`、`AppBackground`(渐变+双辐射辉光,双模式)、`SoftCard`(.ultraThinMaterial+细边+柔光)、`WaveMark`(波形标识)、`hoverCursor()`。
- 自定义**顶部分段切换器**(磨砂胶囊+matchedGeometry 滑动白药丸)替代系统 TabView tab(用户嫌默认 tab 没设计感)。标签英文:**Ask Resound / Library / Settings**。
- ChatView:用户气泡蓝渐变+白字+柔光、发送按钮蓝、**输入框实心白底**(.textBackgroundColor,用户嫌磨砂太透)、助手卡片磨砂+波形头像、来源带👤。
- 双模式:靠系统语义色(.textBackgroundColor/.controlBackgroundColor)+材质自动适配。
- **坑**:`open build/Resound.app` 若旧实例在跑只切前台不重启 → 改样式看不到,需 `killall Resound` 再 open。

### App 阶段3-3：闭环 — 录完自动索引(2026-06-22)

- IndexPipeline 抽出 `indexOneRecording`(build 与单条共用),新增公开 `indexRecording(recDir:indexPath:)` 只索引一条(chunk→说话人标注→上下文→embed→入库,幂等)。
- RecordingController.stopAndIngest:ingest 后调 `indexRecording(out.recordingDir)` → 录完即可在问答搜到、带 👤(若已 enroll)。不重嵌全部录音。
- 验证:`resound index`(走重构后的 indexOneRecording)对 vault 2 条录音(含用户 App 实录的会议)正常入库 26 chunks。**用户实测:问答/Meet弹窗/录音全通过。**
- 注:用户那条测试录音是在加自动索引前录的,未自动进索引;新版起自动。large-v3 首次 ~13min 编译仍未预热。

### App 阶段3-2：Meet 检测→弹窗→录音 旗舰功能(2026-06-22，编译+打包通过)

- `MeetingRecorder` 重构出 `startCapture()`/`finishCapture()`(GUI 用开始/停止分离,`record(maxSeconds:)` CLI 便利方法基于其上)。
- `RecordingController`(@MainActor ObservableObject):App 启动后台 `MeetWatcher.watch` 监听 → 进会议置 `.meetingDetected` → RootView `.alert` 弹"开始录音?" → `startRecording()`(startCapture)→ 横幅"录音中[停止并转录]" → `stopAndIngest()`(finishCapture → IngestPipeline.ingest 入 vault)。
- RootView 加录音横幅(红/处理中)+ Meet `.alert` 弹窗 + toast;ResoundApp `@StateObject` 控制器 + onAppear startWatching。
- Config 加 `vaultPath`(VAULT_PATH);App 录音入库需要 → 用户须在 .env 配 VAULT_PATH。
- 验证:swift build 全过、bundle-app.sh 产 .app 签名校验通过。**GUI 运行/权限流/Meet 实际弹窗待用户测**。
- 已知:转录 large-v3 ~1.7x 实时 + 首次 Metal 编译 ~13min(App 需预热,暂未做);录完需手动 `resound index` 重建索引才进检索(后续自动化)。

### App 阶段2：Meet 检测器(2026-06-22，代码完成)

- `MeetWatcher.swift`:`chromeMeetingURL()` 用 NSAppleScript 轮询 Chrome 标签(先判 `is running` 不启动 Chrome),正则 `meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}` 匹配会议室(排除落地页);`micInUse()` 用 CoreAudio 查默认输入设备 `kAudioDevicePropertyDeviceIsRunningSomewhere`;`watch()` 状态机进/离会议触发 `started/ended`(requireMic 默认 true=需会议室URL+麦克风占用)。
- CLI `watch-meet [--interval 4] [--no-require-mic]`:命中打印(App 里改弹窗)。无权限/无 Chrome → 优雅返回 nil 当无会议。
- 验证:编译过;无 Meet 时跑 7s 无误报、无崩溃、干净停。**检测真实 Meet 待用户授权「控制 Google Chrome」(首次弹 TCC)+ 开个会测**。
- 录音器与检测器独立;App 阶段3 由 UI 把"检测→弹窗→录音"串起来。

### App 阶段1：会议录音器(2026-06-22，代码完成待实测)

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

## 说话人识别 — 决定性结论(2026-06-18 Python 快验)：弃聚类，走「分割+注册匹配」

**实测翻盘**：sherpa-onnx 盲聚类同样失败，但**声纹注册匹配大获成功**。两段 ground truth(GGbond 2人 / OS 6人)：

| 方法 | GGbond(2人) | OS(6人) | 速度 |
|---|---|---|---|
| **盲聚类**(seg + FastClustering，强制 num_clusters=N) | 55% **=基线**(两簇都随机混) | 38.5%(基线29%) | CAM++ RTF0.22 / ERes RTF1.02 |
| **注册匹配** CAM++(每人挑最长3条发言注册 + 最近邻) | **89.4%** | **92.3%** | 14-16s |
| **注册匹配** ERes2NetV2 | 87.8% | 93.4% | 73-84s(慢5x) |

- **根因诊断**：`num_clusters=2` 强制分簇后，两簇仍是 Wynne/GGbond 随机混合 → 不是声纹不行，是**聚类那一步**在真实会议(重叠/短附和/远场单麦)上分不开。**而参考声纹两两 cosine 仅 0.24~0.66(CAM++)→ embedding 区分力很强**。换言之 FluidAudio/sherpa 都栽在同一步：聚类。
- **决定 1：架构弃用盲聚类 diarization，改「分割定边界 + 逐段声纹注册匹配」**。这正好是产品要的「标几次变准」：用户标几条 → 存参考声纹 → 其余段最近邻匹配 → 填 person_id；无匹配(低于阈值)进 unknown 待标。
- **决定 2：声纹模型选 CAM++ `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced`(28MB)**。准确率与 ERes2NetV2(71MB)打平但快 5x、人间区分更干净(ERes 的 GGbond↔Carlos 高达 0.83，余量小)；中英夹杂专训，正合我们语料。质量>速度在此不冲突——快的反而更准更稳。
- **决定 3：声纹窗口必须 ≥~4s，不能用原始 ASR 碎片**(2026-06-18 实测修正)。用 vault 真实 ASR 边界(539 段，均 2.4s)跑注册匹配只有 **53.5%**(vs GT 纯轮次长窗口 92%)——碎片太短、跨说话人，声纹被污染。**把相邻 ASR 段(gap<1s)贪婪合并成 ≥4s 窗口 → 回到 85.3%**(≥6s 84.7%、≥8s 83.8%，4s 是甜点)。85% vs 92% 的剩余差距=naive 合并会跨说话人;未来加说话人变化点检测/pyannote-seg 可补回。**工程流程:ASR 段 → 合并 ≥4s 窗口 → 逐窗提声纹 → 匹配 → 把人贴回该窗内所有 ASR 子段**。验证脚本 `asr_enroll_eval.py --merge-to 4`。
- **决定 4：跨录音注册用 sherpa-onnx `SpeakerEmbeddingManager`**(add 按名注册/同名自动平均、search cosine 检索)或导裸 embedding 自建 sqlite-vec 声纹库(与现有 vec 设施一致)。
- **误差集中**：短附和("嗯/哦"<1s，GGbond→Wynne 11条)、相似嗓音对(GGbond↔Carlos)。对策：太短的段不强判、可并入相邻同人段；可调匹配阈值，低置信进 unknown。
- **环境**：`experiments/diar-py/`(gitignored venv)，sherpa-onnx 1.13.3 pip 装；模型在 `experiments/diar-py/models/`；脚本 `eval.py`(盲聚类) / `enroll_eval.py`(GT边界注册) / `asr_enroll_eval.py`(ASR边界+合并)。音频用 macOS `afconvert` 转 16k 单声道(无 ffmpeg)。release tag 拼写是 `speaker-recongition-models`(打错的)。

### 工程参数速查(2026-06-18 业界最佳实践调研，落 Swift 时照此)

业界先例:`whisper-diarization`(MahmoudAshraf97)正是"Whisper 段→逐段提声纹→打标",路线是正路。参数:

| 项 | 推荐值 | 依据 |
|---|---|---|
| 声纹窗口 | **合并相邻 ASR 段(gap<1s)到 ≥4s** | 我们实测:碎片53%→合并85% |
| cosine 绝对拒识门 τ_abs | 起步 **0.35**，标注集扫 0.30–0.45 | EER 阈值经验区间 0.2–0.5，须自标定(我们参考间 cosine 0.24–0.66) |
| 相对 margin 门 (s1−s2) | **0.06–0.10**，小于判模糊→unknown | 治相似嗓音对(GGbond↔Carlos) |
| 可信段下限 | **1.5s**(独立打标 + 可更新质心) | <2s SV 显著退化 |
| 弱段 0.5–1.5s | 降权、**不更新质心** | x-vector 短时退化陡 |
| 过短段 <0.5s | 不独立判，前后同人→继承标签；异人→时间加权+邻段多数票 | VBx 风格"剔除-重插入" |
| 注册量 | 每人 3–5 条、单条尽量 ≥3s、累计 ≥10–15s | 多会话 centroid 标配 |
| 聚合 | **L2归一后求均值(centroid)**；难例可试 keep-all + max | GE2E centroid |
| 增量更新 | 在线均值 μ_new=(n·μ_old+e_new)/(n+1) 再 L2 归一 | 不必存全部 embedding |
| 合并守门 | cosine(e_new,μ_old)≥0.45 才并入；<τ_abs 拒并并提示重注册 | 防坏样本污染质心 |
| score norm | 暂用"减去对其余参考均值"的简化 S-Norm；正式 AS-Norm(top-300 cohort)后置 | 小规模不值得 full AS-Norm |
| 段内跨人护栏 | 长段(>8s/跨明显停顿)切 1.5–2s 子窗，子窗标签不一致则标"可能跨人"降信度/拆段 | 零成本 |
| 评测 | 主:段/词级 identification accuracy + 混淆矩阵；补 WDER、按段时长分桶 | DER/JER 是 diarization 指标，confusion 子项最该盯 |

### ✅ Swift 集成完成并验证(2026-06-18 夜)

sherpa-onnx 声纹 C API 已桥进 Swift,`resound speaker-eval` 复现 Python 结论。

- **库构建**:为 macOS arm64 构建 sherpa-onnx **纯静态** C API 库(裁掉 TTS、仅 arm64、deploy 14.0、`BUILD_SHARED_LIBS=OFF`)→ libtool 合并成 `libsherpa-onnx.a`(14MB) + 独立 `libonnxruntime.a`(62MB，cmake 自动下 csukuangfj/onnxruntime-libs 预编译静态库 v1.24.4)。脚本 `scripts/build-sherpa-onnx.sh` 可重建;产物 vendor 到 `Vendor/sherpa-onnx/`(lib gitignored,header 留作 API 契约)。**选静态:免 rpath/dylib 加载/code-signing,单可执行自包含,与 CSQLiteVec 风格一致**。
- **桥接**:`Sources/CSherpaOnnx` C target(modulemap `header "shim.h"`,shim.h `#include "sherpa-onnx/c-api/c-api.h"`)。**坑:`-I` cSettings 不传播到 Swift importer 触发的 clang module 编译** → 用**相对符号链接** `Sources/CSherpaOnnx/include/sherpa-onnx → ../../../Vendor/sherpa-onnx/include/sherpa-onnx` 让头文件在 target 自己的 include/ 下可见(SPM 只可靠搜 target 自身 include)。
- **链接 flag**:`-lsherpa-onnx -lonnxruntime` + `.linkedLibrary("c++")` + `.linkedFramework("Foundation")`(onnxruntime 引用了 CF/NSLog 符号,**必须 Foundation**;不需要 Accelerate)。
- **Swift 封装**:`SherpaSpeaker.swift` 的 `SpeakerEmbedder`(config 4 扁平字段 model/num_threads/debug/provider;`embed([Float])` 提 L2 归一声纹,内存契约 defer 释放)。`SpeakerID.swift`:`mergeASRSegments`(合并≥4s)、`SpeakerMatcher`(centroid + 双门拒识 + 在线均值守门更新)、`speakerIDEval`。音频复用 FluidAudio `AudioConverter().resampleAudioFile`→[Float]@16k。
- **验证**:`resound speaker-eval` OS 6人会议 **82.5%**(th=0.3→84.4%、0.4→85%、0.5→87.6%、0.6→94.6%),复现 Python merge-to-4 的 85.3%。我写的 Swift 源码**零改动**编译通过。CAM++ dim=192。
- **混淆**:ZiYang 87.5%/Carlos 72.6% 担主量,Carlos↔Sierra 是主混淆;GGbond 50% 是 n=8 噪声非系统失败。

### ✅ 跨录音认人验证(2026-06-18，产品核心承诺「标几次变准」)

在一段会议用 GT 标注建参考声纹 → 到另一段识别同一批人(Wynne/GGbond 两段都出现)。`cross_eval.py`：

| 方向 | 共同人识别准确率 | 备注 |
|---|---|---|
| 注册 GGbond会议 → 测 OS会议 | **88.2%**(15/17) | Wynne 9/10、GGbond 6/7；陌生人(Carlos等)72.8% 被 τ=0.35 拒识为 unknown |
| 注册 OS会议 → 测 GGbond会议 | 74.4%(96/129) | Wynne 90%(64/71)；GGbond 弱(OS里仅7句短附和→参考声纹差) |

- **结论：跨录音识别成立,Wynne 稳定 ~90%**。弱点=用稀疏/短发言注册时参考差——正是「标几次变准」要解的(累积标注→在线均值更新质心变准)。
- **开集拒识**：τ=0.35 漏进 ~27% 陌生人(多因 GGbond↔Carlos 相似 0.66)。对策:加相对 margin 门(s1−s2)、或注册质量变好后提高 τ。SpeakerMatcher 已实现双门,默认 margin=0 待调。
- 验证脚本均在 `experiments/diar-py/`：eval.py(盲聚类)/enroll_eval.py(GT边界)/asr_enroll_eval.py(ASR边界合并)/cross_eval.py(跨录音)。

### ✅ 冷启动自动分堆验证(2026-06-22，解"不能一开始就标所有人")

问题：实际使用时没法预先给每人注册。解法=渐进式(每人首次出现标一次，非预先标全部) + 冷启动靠自动分堆。
测了**在线增量聚类(leader-follower)**：按时间逐窗，和已见"堆"比 cosine，像就归入更新质心、不像开新堆——用强两两比对(非失败的全局 FastClustering)。`online_eval.py`，OS 6人会议(236窗)：

| 阈值 | 分出堆数 | 纯度 |
|---|---|---|
| 0.4 | 15 | 90.7% |
| 0.5 | 37 | 91.9% |
| 0.6 | 83 | 95.3% |

- **纯度高(90-95%)=几乎不把不同人混进一堆**(安全错误)；但**过分裂**(6人→15~83堆，同一人拆多堆)。
- 错误方向是"安全的":不会犯"两人当一人"(不可补救)，只犯"一人拆多堆"(可补救)。
- **冷启动 UX 决定**：①在线分堆(不混人)→②把最大几堆给用户命名→③剩余小堆用 enrollment matcher 自动归并到已命名的人，只有真新声音再问。→ 不需预先标全部，也不会被错分坑。
- 待办：过分裂的归并步(命名后自动吸收 / 合并近质心)；阈值调参(0.4~0.5 堆数较少)。

**冷启动闭环数字(coldstart_eval.py / Swift coldStartEval，OS 6人会议)**：命名最大 K 堆→其余按质心归并到已命名人(absorb-th)→算最终。

| 命名次数 K | 覆盖率 | 整体准确率 | 已识部分准确率 | 认出人数 |
|---|---|---|---|---|
| 1 | 43% | 42% | 97% | 1 |
| 3 | ~83% | 72% | 86% | 3 |
| **6** | **~92%** | **83%** | **~90%** | **6(全)** |
| 10+ | ~93% | ~84% | ~90% | 6 饱和 |

- **结论:第一条录音点 ~6 次名(≈一人一次)→ 覆盖 92%、命名部分 ~90% 准**。虽自动分 38 堆,但按时长命名,前 6 大堆即含全部 6 人,余 32 小堆自动归并,无需逐堆命名。"命名了就准、不确定留 unknown 问用户"。后续录音这些人已注册→近零点击。
- **Swift 已复现**(K=6:覆盖93%/整体83.3%/认出6人,≈Python)。

### ✅ 冷启动引擎 Swift 化(2026-06-22)
- `SpeakerID.swift` 加 `onlineCluster`(leader-follower)、`clusterRecording`(录音→合窗→提声纹→分堆,按时长排序)、`coldStartEval`(命名K vs 准确率闭环评测)。
- CLI `speaker-cluster <audio> <asr> --model ...`:列出匿名说话人堆(含样例试听时间戳供命名);带 `--ground-truth` 跑闭环评测。
- 至此 Swift 引擎件齐全:提声纹/合窗/匹配双门/JSON声纹库/注册/识别/在线分堆/冷启动评测。**缺的只是交互命名 UX + 接入 ingest 持久化 person_id**(有设计岔路待用户)。

### ✅ 接入检索索引(2026-06-22)：search/ask 显示说话人

把验证好的说话人识别接进 RAG 检索,enroll→打标→落库→检索展示端到端打通。

- **架构(按用户决策)**:标注=源(应落 vault,待做)；**声纹向量=派生→存 index** 的 `speaker_refs(name, count, vec)` 表。chunks 表 `person_id` 列早已预留。
- **打标与嵌入解耦**:新 `speaker-label --vault --index` 用声纹库给已有索引**就地 UPDATE person_id,不重跑 embedding**(注册新人后重打标很便宜)。`index` build 时若配 SPEAKER_MODEL + 有声纹库也会自动标注。
- **person 粒度**:chunk 的 person_id = 该 chunk 时间区间内**重叠时长占多数**的说话人(`personFor`);unknown/无匹配则 nil。代价:少量发言者(如 Sara)会被同 chunk 的主导者并掉——chunk 比说话人轮次粗。
- **新增**:Config.speakerModel(env SPEAKER_MODEL);Index speaker_refs CRUD + person_id 进检索 SQL + SearchHit.personId;SpeakerID recognizeSpans/recognizeSpansFromFile/personFor/enrollToIndex;IndexPipeline labelExisting + build 内标注;CLI speaker-enroll --index / speaker-label / search·ask 显示 👤。
- **验证**:OS会议(真实索引副本)enroll 6人→speaker-label→**25/25 chunk 落 person_id**、person 分布 ZiYang11/Carlos9/GGbond2/Sierra2/Wynne1、`search` 输出每条带 👤人名且语义一致。swift 源码**零改动首编过**。
- **待**:标注写 vault(labels.json)闭合"index 可重建"不变量;冷启动命名→归并交互闭环;τ 调参;SPEAKER_MODEL 入 .env。

## 说话人识别(diarization) — 早期：FluidAudio 阶段(已被上面取代)

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

## 时间感知检索 + AI Summary（2026-06-22 决策）

**背景**：检索链路里录音时间是"死数据"——`recordings.recorded_at` 已入库但 chunk 表无时间列、检索 SQL 不按时间过滤、问答引用不带日期，LLM 不知道某条是哪天说的。"汇总昨天的 1-on-1" 这类查询本质是 **recording 级时间筛选**，不是 chunk 级语义检索。

**决策**：
- **时间索引**：`chunks` 加 `recording_date`（本地 `yyyy-MM-dd`，denormalized 便于单表 WHERE）；`recordings` 加 `summary` 列。旧库 `ALTER TABLE ADD COLUMN` 迁移（pragma 检测列是否存在）。
- **时间检索**：`vectorSearch/ftsSearch/search()` 加 `dateRange` 过滤；`SearchHit` 带 `recordingDate`；`Synthesizer` 引用格式带日期，LLM 看得到时间。vec0 KNN 不支持前置过滤 → 有日期范围时把内部 k 放大（个人 wiki 规模可接受）。
- **查询规划（LLM 抽取，非规则）**：问答前一步 `QueryPlanner` 让 LLM（传入今天日期+星期）从问题抽出 dateFrom/dateTo + 判定 mode=qa/digest，解析 JSON，失败回退普通问答。能处理"上周三/这个月/五月初"等任意表达。
- **AI Summary**：转写后生成；**模板列表**（不同场景不同 prompt：1-on-1/团队会/头脑风暴/通用），JSON 存 `~/Library/Application Support/Resound/summary-templates.json`，占位符 `{date}{weekday}{title}{speakers}{transcript}`，传入录音时间作锚点。写 `summary.md`（事实源在 vault）+ 入 `recordings.summary`（可检索）。"汇总昨天"走 summary 合并而非碎片。
- **依据**：summary 与时间检索咬合——digest 模式直接取范围内录音的 summary，又快又准。模板列表满足"不同场景不同摘要重点"。
- **顺序**：先做后端链路（Core + CLI + index），UI 展示等新设计回来再接。

## UI 微调：选中遮挡 / 进度条拖窗 / 文本可选中（2026-06-22）

- **Markdown 渲染换库**：自制解析器搞不定嵌套列表层级/表格 → 改用 `gonzalezreal/swift-markdown-ui`（MarkdownUI），以 `.gitHub` 主题为底叠 Resound 调色板。`Package.swift` 加依赖 + ResoundApp 加 product。
- **主题色**：浅色 accent `#bd6a2e`（赤陶橙，accentSoft α0.10）、深色 `#e3a35f`（暖金，α0.18）。
- **侧栏折叠按钮**：从头部移出，改圆形浮在侧栏右边框上——`.overlay(alignment:.topLeading)` 加 `offset(x: 侧栏宽-半径, y: 21)`，圆心 x 落边框、y 与 Logo 中心齐平（14 sidebar pad + 4 header pad + 15 半图标 = 33；按钮半高 12 → y=21）。
- **录音行操作图标遮挡**：原 `if on || hover` 导致选中态 pencil/trash 常驻盖住标题尾巴 → 改 `if hover` 仅悬停出现。
- **拖进度条带动整窗**：根因 `window.isMovableByWindowBackground=true`，自绘 Scrubber 的 mouseDown 被 AppKit 当成拖窗。**对策**：`WindowDragBlocker`（NSViewRepresentable，内部 NSView `override mouseDownCanMoveWindow { false }`）`.background()` 垫在 Scrubber 下——它是该处最深的 hit NSView，AppKit 据此放弃拖窗，而 SwiftUI 的 DragGesture 仍由 hosting view 处理不受影响。比全局关 movableByWindowBackground 更稳（不牺牲其它区域拖窗）。
- **文本可选中**：摘要正文早已 `.textSelection`，但标题/日期/「会议摘要」标题是裸 `Text` 不可选 → 各自加 `.textSelection(.enabled)`，与摘要一致可复制。

## 全局按钮命中区：`.plainHit`（2026-06-22）

- **现象**：`.buttonStyle(.plain)` 的 Tab/按钮，若 label 背景透明（如未选中的「会议摘要/逐句转录」背景 `.clear`），macOS 上只有不透明文字/图标可点，padding 空白点不动。
- **根因**：SwiftUI 在 macOS 下 plain button 的命中区取 label 的不透明内容，透明区不计入。
- **统一对策**：自定义 `PlainHitButtonStyle`（`extension ButtonStyle ... static var plainHit`），`makeBody` 把 `configuration.label` 加 `.contentShape(Rectangle())` + 按下变暗 0.55。全 App 41 处 `.buttonStyle(.plain)` 一次性 sed 换 `.plainHit`。比逐处补 `contentShape` 更彻底，新按钮统一用它。

## Ask 聊天历史 + 多轮上下文（2026-06-22）

- **现状确认**：此前 Ask 每次提问完全独立——`answer()`→`QueryPlanner.plan(question)`/`Synthesizer.answer(query:hits:)` 都只看当前一轮，不带历史；且 ChatVM 是 ChatView 内 `@StateObject`，切页/重启即丢。追问「他还说了啥」无法解析指代。
- **持久化**：新增 `ChatStore`，对话存 `~/Library/Application Support/Resound/conversations.json`（本地 App 状态，**不进 vault**——vault 数据契约只收音频/转录/标注/人物/笔记，聊天记录是便利日志、非事实源，且非可重建派生物，故独立放 App Support）。模型 `Conversation{id,title,createdAt,updatedAt,messages:[StoredMsg]}`，StoredMsg 连引用/来源一并存，重开可点。
- **ChatVM 升 App 级**：移到 `ResoundApp` 的 `@StateObject` + environmentObject，切页不丢；新增 conversations/currentId + newChat/open/delete/saveCurrent。每轮提问前存一份（留痕），回答 finalize 后再存一份。title 取首条用户问题截断 30 字。
- **多轮上下文**：Core 加 `ChatTurn` + `renderHistory`（助手回答截 600 字控 token）。`plan/answer/Synthesizer.answer/digestAnswer` 均加 `history: [ChatTurn] = []`（默认空 → CLI `ask` 不受影响）。规划器用历史补全 query 指代（提升追问检索召回），综合器用历史让答案接上文。ChatVM 取最近 8 条已完成消息为历史。
- **UI**：Ask 页改双列（仿 Library）：左 240pt 对话列表（新对话按钮/选中高亮/hover 删除/相对时间），右聊天区。

## 转录更正同步进检索（2026-06-22）

- **现象/疑问**：用户在 Library ⌘F 替换错字后，Ask 是否用更正后的数据？
- **查明**：**摘要**替换会写 `Index.setRecordingSummary` → digest/汇总答案用更正后内容 ✅；**转录**替换只写 vault `transcript.json` + 刷新 UI 行，**不动索引** → qa 检索与引用片段仍是旧错字 ❌（chunk 文本与 embedding 都没更新）。
- **对策**：转录 `replaceAll` 后调 `scheduleReindex(rec)` —— 防抖 1.5s（连续多次替换合并一次），到点 `IndexPipeline.indexRecording` 幂等重建该条（重切块→上下文(命中缓存只重算变化块)→重 embed），`reindexing` 标志驱动 findBar「同步检索…」spinner + 完成 toast。这样 Ask 的 qa 检索/引用都用更正文本。
- **取舍**：重建会顺带重跑说话人标注（有声纹库时），比纯改文本重，但只在用户显式改字时触发、单条耗时可接受；防抖避免逐次重嵌入。

## 第二版设计稿还原（2026-06-22）

Claude design 重做了「侧栏折叠按钮 / Library 文件夹 / Ask 历史」三块 + 亮色主题色，按新 `Resound.dc.html` 还原：

- **亮色 accent**：`#bd6a2e` → **`#e85f2c`**（accentSoft α0.10）。深色不变 `#e3a35f`。其余 token 与现状一致。
- **侧栏折叠按钮**：26px 圆形，`top:22 / right:-13`（圆心压在侧栏右边框，比 Logo 中心略低 2px——设计如此）；折叠态导航图标 40×40 r10、icon 17、间距 6。
- **Library 文件夹**：
  - 行内「移动到」浮层：行 hover 出 文件夹/改名/删除 三图标，点文件夹图标弹 186pt 浮层（列全部文件夹+未分类+✓当前+「新建文件夹…」）。`moveMenuFor` 控制；行 zIndex 提升避免被下一行盖住。
  - **拖拽**：行 `.onDrag`(置 `dragRecId`，拖拽中 opacity .4)；每个文件夹组 `.dropDestination(for:String)` 接收 → `move`，`isTargeted` 高亮组头（accentSoft + 虚线 accent）。`dragRecId` 在 move/select 时清，规避取消拖拽残留半透明。
  - 空文件夹占位「该文件夹暂无录音 · 可拖拽录音到此」；文件夹头 hover 用改名/删除图标替换计数。
  - 「新建文件夹…」带 `pendingMoveRecId`：建完把该条移入。
- **Ask 历史**：对话行两行（标题+相对时间 / 首条回答预览 38 字）；hover 出改名/删除；会话**重命名**弹窗 + **删除确认**弹窗（移到 OverlayHost，注入 `ChatVM`）。`Conversation.customTitle` 标记手动改名，`saveCurrent` 不再用首条提问覆盖。列宽 240→236。

## 声纹/分段「散」诊断 + 逐句行合并·标签平滑（2026-06-22）

**用户反馈**：声纹识别仍有较大问题，逐句转录「分段特别散」；问参考 `yeyupiaoling/VoiceprintRecognition-Pytorch` 是否有帮助；并提议音频预处理（降噪/提人声）。

**诊断（根因，反直觉）**：production 录音库展示的说话人分段**根本没跑真 diarization**。`Diarizer.swift` 里的 Sortformer/DiarizerManager 只在 CLI `diarize`/`diarize-eval` 用。实际链路（`IndexPipeline.swift:74`）是「ASR段(~2-4s)→`mergeASRSegments` 贪婪并≥4s窗→逐窗 CAM++ 声纹→注册库双门匹配→`personFor` 按重叠多数」。「散」有两个独立病因：
- **A 显示层**：`transcriptLines` 一条 ASR 段渲染一行、每行都重复贴名字 → 同一人连说几分钟变几十行。
- **B 标签抖**：每个 4s 窗**各自独立**匹配、各自过阈值，相邻同人窗一个匹中真名一个掉 unknown/说话人N → 标签逐窗闪烁；且窗边界由 ASR 停顿决定，可能跨说话人切换。
两者都是**架构问题，不是声纹模型不好**。

**对参考项目的判断**：`VoiceprintRecognition-Pytorch` 是声纹**训练框架**，印证我们已用其一线模型 **CAM++**（换模型无质变），它**没有 diarization**，治不了「散」。可选边际升级：ERes2NetV2/ECAPA-TDNN 的 ONNX（sherpa-onnx 可直接换）。

**对「音频预处理」的判断**：方向对但有坑——**重降噪反而削弱声纹**（抹掉说话人特征），最佳实践是轻降噪 + **VAD 去静音/非人声**。更大的杠杆被浪费：`MeetingRecorder` 录的是 mic(=你)/sys(=对方) **两条独立轨**，`mixTo16k` 却混成单声道——保留双轨 = 「我」零成本精确定位（仅 Meet 录音适用，导入历史文件不适用）。

**本轮决策（用户在 ①②③④ 中只选 ① 最小改）**：纯 App 层修「散」，不动后端识别：
- `LibraryModel.smoothSpeakers`：扫描 runs，把**被前后同一人夹住、且时长 <3s** 的小段并入两侧（反复到稳定，最多 6 趟）。保守——仅两侧确为同一人且与本段不同才改，绝不凭空并不同人。压病因 B 的逐窗抖动。
- `LibraryModel.Block` + `groupBlocks`：连续同一(平滑后)说话人的行合并成块；`buildRoster` 用平滑后标签统计；`replaceAll` 改字后重 `groupBlocks`。
- `LibraryView`：逐句转录改按 `vm.blocks` 渲染，**说话人名每块只贴一次**（`transcriptRow` 保留逐行时间戳/点击跳播/播放高亮/查找滚动）。压病因 A。

**待推进（按性价比，已记 STATE 待办）**：②production 换真 diarization（Sortformer 拿干净轮次→声纹按簇映射真名，治本）；③Meet 双声道分离 + 每窗 silero VAD；④升声纹模型 + 轻降噪（边际）。

## 声纹「完全没识别」根因 = 接线 bug，非模型质量（2026-06-22）

**现象**：用户给 Wynne/GGBond 标注过声纹后，导入一条新的 Wynne+GGBond 1-on-1，**完全没识别出来**（diarization.json 全是「说话人1/2」），由此怀疑声纹准确度差。

**实验（决定性）**：导出 index 的 6 人声纹 → `/tmp/refs.json`，对新录音跑 `resound speaker-recognize ... --tau 0.35`：
```
识别 190 窗：Wynne 120 / GGBond 67 / Sara 2 / unknown 1
```
**声纹本身近乎完美**（τ=0.35 生产阈值下只有 1 窗未过门）。所以不是模型问题，不需要换模型/做预处理——参考的 PyTorch 项目对此无意义。

**根因（接线 bug，两处）**：
1. 首次「识别说话人」按钮 `analyze()` → `analyzeSpeakers`（`VaultBrowser.swift`）是**纯冷启动在线聚类**，`winToSpk = "说话人\(rank+1)"`，**从不加载/查询已注册声纹库**。只有「重新识别」`reidentifySpeakers` 才查库——但那是按**簇质心**匹配（受聚类过分裂/误并影响），不如逐窗直接匹配准。用户点的是前者 → 永远匿名。
2. **导入路径不写 diarization.json**。`indexOneRecording` 用 `recognizeSpansFromFile` 填的是 **index chunk 的 person_id**（仅供 search/ask 引用），而录音库逐句转录 UI 读的是 **diarization.json**（`loadDiarization`）。导入后 UI 看不到任何说话人，逼用户手点「识别」→ 触发上面的纯聚类。

**修复**：
- 新增 `identifySpeakers(rec, model, indexPath, embeddingDim)`（`SpeakerNaming.swift`）：**已注册声纹逐窗直接匹配**（实验同款，最准）→ 命中真名；没匹中的窗（库里没有的人）再 `onlineCluster` 成匿名「说话人N」；写 diarization.json + 同步 index 真名。库为空时自动退化为纯聚类（兼容旧冷启动）。
- `LibraryModel.analyze()` 改调 `identifySpeakers`（首次识别就吃声纹库，toast 报「自动认出 N 人」）。
- `startImport`：indexRecording 后、summarize **前**自动调 `identifySpeakers`（导入即显真名，摘要也带名）。
- 新增 CLI `speaker-identify --vault [--id]`：注册新人后批量重标旧录音。已用它把问题录音就地修成 **Wynne 240 / GGBond 115 / Sara 5 / 说话人1 1**（5 Sara+1 匿名是零星误标，前一轮的逐行平滑会在展示时吸收掉大部分短抖）。

**结论**：先前「准确度差」的判断是误诊——错在没把已注册声纹接到首次识别/导入路径。真 diarization（Sortformer）、双声道、换模型等仍在 STATE 待办，但已非当务之急。

## 转场边界「幽灵说话人」清理：ephemeral-speaker 平滑（2026-06-22）

**现象**：声纹接线修好后，导入 1-on-1（如 04-08 与 GGBond）逐句转录的说话人名册仍混进 Sara(6)、说话人1-4(10) 等幽灵人，给人「识别出很多错误的人」的观感。Wynne/GGBond 本身占 ~98%（307/304）。

**根因**：strays 全是**转场边界的短窗**——`mergeASRSegments` 把 ASR 段贪婪并成 ≥4s 窗，跨 Wynne→GGBond 切换的窗拿到**混合声纹**，要么误配到某个登记人（Sara），要么分数低被聚成匿名「说话人N」。一个坏窗会把落在其中的几条 ASR 段全标错。它们都很短(0.6–6.2s)、夹在两个真实说话人之间。

**为什么旧平滑没治住**：旧规则只处理「被**同一个人**夹住的 <3s 掉点」，而这些 strays 多被**两个不同**的真实说话人夹住（Wynne | stray | GGBond）。

**关键判据**：真实说话人一定在某处**说满过一整段**；边界噪点说话人**只会以零碎短段出现**。→ 定义 established = 该说话人最长单段 ≥ `ephemeralMax`(7s)。

**对策（`LibraryModel.smoothSpeakers`，display-only）**：
- 规则 A（保留）：同一人夹住的 <3s 掉点并入两侧。
- 规则 B（新）：**ephemeral 说话人**（最长段 <7s，含匿名「说话人N」）的短段 → 并入相邻 established 说话人（优先 established 邻居，都满足取较长一侧）；established 说话人永不被吸收。反复扫到稳定。
- **不改 diarization.json/index**，纯展示层；名册/分块用平滑后标签。阈值 7s 可调。

**验证（Python 复刻跑真实数据）**：
- 04-08 1-on-1：`Wynne307/GGBond304/Sara6/说话人1-4(10)` → **Wynne321 / GGBond306**（幽灵全清）。
- 06-18 六人会：`ZiYang246/Carlos144/Sierra88/GGBond28/Sara23/Wynne4 + 5匿名blip` → **ZiYang/Carlos/Sierra/Sara24/GGBond30**（**5 个真人全保留**；仅匿名 blip + Wynne 那 4 段「从未持续」被吸收）。

**取舍**：多人会议里若某人**真的只说过一两句且都 <7s**，会被并入邻居（如本例 Wynne 的 4 段）。对个人 1-on-1/小会场景可接受，且 display-only 可逆、阈值可调。更根治仍是 STATE 待办的②真 diarization / ③双声道。

## 转录后 AI 校对（保持原意纠错）（2026-06-22）

**需求**：用户觉得 ASR 转录错别字仍多，希望转录后结合术语表 + AI 上下文，让 DeepSeek-flash 跑一轮「保持原意」的检验修复。

**核心约束**：转录不是纯文本，是**带时间戳的段(segments)**，逐句 seek / 说话人映射 / 查找都依赖段边界。Whisper 直接给段，没有「分片前的完整文本」中间态（全文=段拼接）。全文重写再回切对齐很脆。

**方案（`TranscriptCorrector`）**：把段以**「带行号的有序列表」整批**送 LLM（模型仍看到上下文），逐行返回 `[行号] 修正文本`，按行号回填——**段边界/时间戳完全不变**。
- 批大小 40 段/次；temperature 0；system 严令只改同音/形近错别字+分词+术语、**禁止**改写/增删/合并拆分/动口语词。
- 术语表(glossary.terms)注入 system，作为规范写法权威。
- **安全闸**：某批返回覆盖 <3/4 → 整批回退原文，宁可不改也不错位。失败批/网络错 → 静默保留原转录，不丢转录。
- 模型 `CORRECT_MODEL`(默认 deepseek-v4-flash)；开关 `TRANSCRIBE_CORRECT`(默认 true)。

**接入**：`IngestPipeline.ingest` 在 繁简归一+别名纠正之后、写盘之前跑（新导入/录音自动校对，且在摘要前→摘要也吃到正确文本）；`correctExisting(id:)` + CLI `transcribe-correct --vault [--id]` 批量修旧录音（改完需 `resound index` 重建检索）。

**实测（04-08 1-on-1，627 段）**：段数 627→627 不变，改 31 段，全是真错：`rvanced→advanced`、`方架→框架`、`数结构→树结构`、`实际势力→实际实例`、`开始病情任务→开始并行任务`、`偷看→Token`、`丢age→丢edge`、`sharp store→shared store`、`很难找权→很难找全`、`取求→需求`，以及术语表生效的 `Reswantz/瑞赛→Resound`、`Dungle→Jungle`（全篇统一）。语义/口语风格保持。已对该条重建索引。

**取舍**：每条多 ~16 次 flash 调用(40段/批)、约 1-2 分钟，放后台 ingest 可接受（质量>速度）。词级 words[] 不随文本改（本就多为空，不影响展示/检索）。

## 摘要两个 bug：全局 loading + 摘要仍含幽灵说话人（2026-06-22）

**Bug 1：点「重新生成」摘要，所有录音都进入 loading。**
根因：`summarizing`/`analyzing` 是 LibraryModel 上的**全局 @Published bool**，详情页 `summaryTab`/roster 直接读它；正在给 A 生成时切到 B，B 的详情也读到 true → 显示「正在生成」。
对策：改为 `summarizingId`/`analyzingId: String?`，计算属性 `summarizing { id != nil && id == selectedId }`（只当前选中那条显示 loading）；`runSummary` 完成后仅当 `selectedId == rec.id` 才更新详情（切走则 summary.md 已落盘，回来重载）；defer 仅在 id 仍等于自己时清空，避免并发互相清。

**Bug 2：04-08 逐句转录已只剩 Wynne/GGBond，但摘要里仍列一堆 speaker。**
根因：上一轮的「幽灵说话人」平滑是 **display-only**（只在 `LibraryModel` 渲染时跑），**没有改 diarization.json**；而 `summarizeRecording` 读 `loadDiarization(recDir)` 取 `meta.speakers` 喂给摘要 LLM → 摘要照列幽灵。Ask 的 chunk person_id 同理仍脏。
对策：**把平滑持久化到源头**。`smoothSpeakerSegs([SpeakerSeg])` 提升到 Core（SpeakerNaming.swift，"?" 视为未知不可成真人/不作目标）；`identifySpeakers` 与 `reidentifySpeakers` 写 diarization.json **前**调用，并据平滑结果同步 index person_id；`LibraryModel.smoothSpeakers` 改为 nil↔"?" 映射后**委托同一 Core 函数**（消除两处算法漂移）。
修复存量：`resound speaker-identify --id 04-08` 重写 diarization.json → **Wynne321/GGBond306**；`resound summarize --rec … --force` 重生成摘要 → 只剩 Wynne/GGBond。

**结论**：平滑从「展示层补丁」升级为「源头事实」，逐句/名册/摘要/检索四处口径一致。阈值仍 7s 可调、diarization.json 可由 speaker-identify 重建（可逆）。

## 踩坑：替换后「同步检索失败: cancelled」（2026-06-22）
连续替换/多次触发时，`scheduleReindex` 用 `reindexTask?.cancel()` 取消上一次防抖重建，被取消的那次在 `indexRecording`（网络 embedding）中抛 `CancellationError`/`URLError.cancelled`，落进 catch → 弹「同步检索失败: cancelled」。其实是被新一次替换取代，非失败。对策：catch 分支单独吞掉 `CancellationError` 与 `URLError.cancelled`，且成功 toast 前加 `guard !Task.isCancelled`。最终那次（不被取消）正常完成，结果最终一致。

## 摘要模板独立 Nav 页 + 模板 AI 协助（第三版设计稿，2026-06-22）

用户把摘要模板从 Settings 提到左侧导航，Claude design 重绘（Resound-handoff.zip → Resound.dc.html），按稿还原：

- **导航/页面**：`AppModel.Page` 加 `templates`；侧栏 `navRow(.templates,"Templates","square.grid.2x2", count)`（展开+折叠共用 navRow）；TopBar 标题补 `Templates`；内容路由加 `TemplatesView`。`ResoundApp.onAppear` 提前 `settings.load()` 让侧栏计数即时正确。
- **TemplatesView（新）**：900 宽居中，2 列卡片网格。每卡=图标+名称+「默认」徽标 + 提示词等宽预览(120 高，底部 LinearGradient 渐隐) + 使用到的占位符 chips + 编辑/设为默认/删除；末尾「新增模板」虚线卡。CRUD 仍复用 `SettingsModel`（与设置页同一份状态）。Settings 里的 `templatesSection` 删除。
- **模板编辑器加「AI 协助」**：编辑器底部加 accentSoft 区块——用途 textarea + 「生成提示词」/「润色当前」+ busy spinner。`SettingsModel.aiAssist(mode)` 用 `cfg.correctModel`(deepseek-v4-flash) 调用新 Core `assistTemplatePrompt(mode,intent,base,chat)`。
- **内置占位符注入（用户强调）**：`assistTemplatePrompt` 的 system 硬性要求「末尾原样包含 会议:{title}({date}) / 参与者:{speakers} / 转录:{transcript}」；**返回后兜底**——若结果不含 `{transcript}` 就自动补一段标准占位符块；模型/网络失败走本地 `templateAssistFallback`（也含占位符）。保证 AI 产出的模板一定能被 `Summarizer` 正确填充。
- **摘要模板选择器**：对齐设计稿，从「模板 · name ▾」改成描边下拉「模板：name ▾」(去掉前置 doc 图标，elev 底+borderStrong 边)。
- **「设为默认」生效**：原 `LibraryModel.currentTemplateId()` 回退用 store.first；改为回退读 `UserDefaults["resound.defaultTemplate"]`（Templates 页设默认写的同一 key），默认模板真正驱动摘要生成。

**取舍**：`SummaryTemplate` 模型未加 `kind`/`isDefault` 字段（默认仍由 UserDefaults 单独存，卡片图标统一用 doc.text），避免改数据格式；AI 协助用 flash 走 .env 的 CHAT_API_KEY/CHAT_BASE_URL（DeepSeek）。

## 摘要失败「请提供原始会议文本」+ 承接语 + 模板丢失（2026-06-22）

**现象 1**：05-13 与 GGBond 的 1-on-1 摘要失败，AI 回「请提供原始会议文本，以便我整理纪要」。
**根因**：存储的 `one-on-one` 模板**丢了 `{transcript}` 占位符**（旧版内置模板，加占位符前就被持久化了），于是转录从未被填进 prompt → AI 反问要原文。
**对策**：① `Summarizer.summarize` 兜底——模板若不含 `{transcript}` 自动追加「转录：\n{transcript}」再填充；② `SummaryTemplateStore.load()` 自愈——缺 `{transcript}` 的模板在内存里补回（任何脏模板都不会再产出无转录的 prompt）。

**现象 2**：另外两条 GGBond 摘要带承接语「好的，这是根据您提供的转录内容整理的会议纪要。」
**对策**：`Summarizer` system prompt 明确「直接输出纪要正文，不要任何开场白/承接语/客套话（如『好的』『以下是』『这是根据您提供的…』），不要复述提示、不要代码块包裹」。

**踩坑（数据丢失）**：第一版自愈把 `save(healed)` **写在了 `load()` 里**。`load()` 调用极频繁，且此时后台还跑着旧的 App 实例同样在读写同一个 templates.json → 并发存盘相互覆盖，把 `team-meeting` 模板冲掉了（4→3）。
**修正**：`load()` 只在内存自愈、**绝不写盘**（文件在用户下次保存模板时自然落正）；并手动把 `team-meeting` 从内置恢复进文件。**教训：纯读取函数不要有写文件副作用**，尤其有多进程/实例并发时。

已对三条 GGBond 录音重生成摘要（均正常、无承接语、含真实内容），05-13 顺带重跑 speaker-identify → 参与者干净（Wynne/GGBond）。

## 摘要模板下拉改自绘（2026-06-22）
原生 SwiftUI `Menu`（即便 `.menuStyle(.borderlessButton)+.menuIndicator(.hidden)`）在 macOS 上渲染不出设计稿那种干净胶囊（系统会加自己的按钮 chrome/箭头）。改为**自绘下拉**：胶囊按钮（模板：name ⌄，elev 底+borderStrong 边）toggle `tplMenuOpen`，`.overlay` 弹自绘列表（210 宽、圆角 11、阴影、行 hover 高亮 + 选中勾）。给摘要头部 HStack 加 `.zIndex(1)` 让下拉浮在摘要卡之上；选项/切录音/切 tab 关闭。关闭沿用现有 move 菜单的「点 toggle/选项即关」模式，不加全局 scrim。

## 摘要模板名显示错 + Library 点开性能优化（2026-06-22）

**现象 1（模板名）**：选「1-on-1」点重新生成，下拉胶囊与 loading 文案却显示「通用」。
**根因**：`LibraryModel.currentTemplateId()` 优先级是 `summaryTemplateId`（已有摘要当初用的模板）> `chosenTemplateId`（用户本次选的）。选录音时会从 index 读出旧摘要的模板填进 `summaryTemplateId`（=通用）；用户改选 1-on-1 只写了 `chosenTemplateId`，于是显示仍取旧值。**生成本身没错**——`chooseTemplate`/`regenerate` 把正确 id 显式传给 `runSummary`，只是 UI 显示滞后到下一轮完成。
**对策**：调换优先级——`chosenTemplateId`（用户最新意图）优先于 `summaryTemplateId`。新选录音时 `chosenTemplateId=nil`，仍正确回退到旧摘要模板名；一旦用户选了就立刻反映。

**现象 2（卡顿）**：点开 Library / 切录音响应慢，录音越多越慢。
**根因**：`refreshDetail()` 在主线程**同步**做全部重活：读 transcript.json/diarization.json + JSON 解码 + 8 趟标签平滑 + 开 SQLite 查模板 id + **`AVAudioPlayer(contentsOf:)`+`prepareToPlay` 解码整段长音频**（28 分钟录音尤甚）。每次选中都把这些堆在主线程 → 卡。
**对策**：
1. **重活全进后台**：`refreshDetail` 立即清状态 + 用 `rec.durationSec` 占位时长，然后 `Task.detached(.userInitiated)` 做文件读/解码/平滑/索引查询，算完 `await MainActor.run` 一次性发布。引入 `detailToken`（每次切录音自增），回主线程前比对，**用户已切走就丢弃过期结果**（防快速切换错配）。
2. **播放器懒加载**：新增 `ensurePlayer()`，按下播放/跳转时才解码音频；`togglePlay/seek/playSpeakerSample` 改用它。时长先用元数据，解码后用真实 `p.duration` 校正。
3. 把 `smoothSpeakers`/`groupBlocks`/`isAnon` 标 `nonisolated`，新增 `nonisolated static makeRoster(from:known:)`，使平滑/分块/名册可在 detached 任务里跑（语言模式 v5，结构体跨 actor 不报 Sendable）。

**另**：用户提出「不要限制用户 prompt，缺 `{transcript}` 就在摘要时兜底补」——核对已满足：`saveTemplate()` 原样存用户 prompt 无校验，`Summarizer.summarize()` 运行时缺占位符自动追加转录块。无需改动。

## 声纹/分段三块后续——性价比评估（2026-06-22，待用户拍板）

之前列的 ②③④ 现在是否还要做，结论：
- **当前已够用**：①行合并+平滑（已持久化进 diarization.json）+ `identifySpeakers` 注册匹配，实测 1-on-1 干净到只剩两人、6 人会真人全保留。日常 1-on-1 / 小会基本不需要再投入。
- **② 真 diarization（Sortformer）**：治本，但工程量最大（要把 `Diarizer.swift` 的 Sortformer 从 CLI 接进 production 流程、再把注册声纹按簇映射真名）。**建议仅当出现「平滑治不好的多人重叠/抢话」误配时再做**；否则边际收益有限。
- **③ Meet 双声道 + 每窗 silero VAD**：性价比最高的一块。麦克风轨=「我」零成本精确，对方轨单独分割能显著减少跨人误配；VAD 去静音也直接提声纹质量。**建议只在 Meet 实时录音路径做**（导入的单轨文件用不上双声道）。
- **④ 升声纹模型(ERes2NetV2/ECAPA)+降噪**：边际。CAM++ 实验已近完美，**暂不做**，除非换更嘈杂场景。

**建议落地顺序**：③（仅 Meet 路径）> ②（按需）> ④（搁置）。等用户确认。

## Library 加载态（2026-06-22）
配合 `refreshDetail` 异步化补两个 loading（用户要求）：①**点开录音**——`loadingDetail` 在 refreshDetail 起手置 true、后台算完回主线程置 false，详情正文区显示「正在载入…」卡片（标题/日期/播放条用元数据即时渲染，不等）。②**首次播放解码**——把懒解码从同步 `ensurePlayer` 改为异步 `withPlayer(_:)`：`decodingAudio=true` 后台 `AVAudioPlayer(contentsOf:)+prepareToPlay`，完成回主线程比对 detailToken 再播；播放键解码期间转圈并禁用。切录音时 `decodingAudio=false` 复位，避免旧解码留转圈。

## 声纹/分段三块——最终拍板（2026-06-22）

经讨论确认实际场景：用户日常多为「同一会议室开会、Meet 仅投屏无音频，全场共用其录音设备」。
- **「麦克风轨=我」前提崩**：该场景下麦克风轨=全场所有人、系统音频轨≈静音；硬判 mic=我会把所有人标成用户，比现状更糟。且用户常在 Meet 内静音——但录音走 `AVAudioEngine` 直抓硬件输入，与 Meet 静音无关，真正问题是「共用单麦」。
- **决定**：
  - **② 做**——production 接真 diarization(Sortformer)。对「一屋子人单麦」主场景最对症，且可用 `~/Downloads` 多人会议**离线验证**，不依赖实机录 Meet。
  - **③ 只做 silero VAD**（每窗去静音/噪声再提声纹，声道无关、普遍提质量）。**「麦克风轨=我」彻底不做，连自动判别也不做**（用户明确）。
  - **④ 搁置**。

## ② 真 diarization + ③ silero VAD —— 实现 + 离线验证 + 混合路由（2026-06-22）

**实现**：Core `identifySpeakersByDiarization`（[SpeakerDiarize.swift](../Sources/ResoundCore/SpeakerDiarize.swift)）。流程：真 diarization 拿干净「谁何时说」轮次 → 每个 diar 簇汇总其轮次音频、**silero VAD（FluidAudio VadManager）清掉静音/噪声**后提 CAM++ 簇级声纹质心 → 去注册库匹配真名（否则匿名「说话人N」）→ ASR 段按所在轮次贴标签 → `smoothSpeakerSegs` 平滑 → 写 diarization.json + 同步 index。diar 后端 `Diarizer.swift` 加 `.offline`（OfflineDiarizerManager）。加 CLI `diarize-compare`（旧 vs 新，不落盘）+ 两个 identify 函数的 `dryRun`。

**离线验证（`diarize-compare`，vault 实录，silero VAD 开）**：
- **2 人 GGbond 1-on-1**：旧逐窗法 raw 认出 3 人（GGBond/Sara/**幽灵**/+1 匿名）靠平滑救回 2 人；**新法 Sortformer 4 簇 → 精确映射 GGBond/Wynne，0 匿名**。新法源头更干净（不靠平滑兜底）。
- **6 人 OS 会**：旧法 raw 6 人 +13 匿名 → 5 人；**新法被 Sortformer 4-cap 并掉**，6→4 簇丢了 GGBond/Wynne（只剩 Carlos/Sara/Sierra/ZiYang）。

**踩坑**：① `OfflineDiarizerManager`（pyannote community-1，本可任意人数）**在本机 M3/16G segfault（exit 139）**，处理到 chunk 0 就崩，不可用。② Sortformer 处理 28min 录音约 **~7 分钟**（cpuAndGPU，~4x RTF），是明显的速度代价。

**决策——混合路由**：`identifySpeakersByDiarization` 内 `saturationFallback`：Sortformer 检出 **≥4 簇视为多人会且 4-cap 已饱和 → 回退旧逐窗法**（多人场景旧法反而保得住小发言者）；**≤3 簇（1-on-1/三方，用户主场景）走干净的 diar 优先**。production `analyze()`/导入/CLI `speaker-identify` 全切到此（带回退）。`diarize-compare` 传 `saturationFallback:false` 看纯 diar 行为。

**遗留/待用户拍板**：① ~7min 等待是否可接受（质量>速度按原则选了质量，但 UX 偏慢）；② offline segfault 若修好可去掉 4-cap 回退、多人会也走 diar——属后续。

## 六项批量：配置化 / 转录提速 / 纠错 / UI（2026-06-23）

用户一次性提了 6 项，休息前确认了 3 个分歧点后开工。

**#2 Settings 全量配置化 + 导入导出 + git 自动推送**（用户意图：App 后续可能分享，不该让人改代码重 build；导入导出为方便迁移）：
- `ConfigStore`（Config.swift）读写 **App Support `.env`**：`current()` 回填、`save([k:v?])` 合并写回（空值=删键）、`export(to:)`/`importFrom(:)`。运行时即时生效（Config.load 每次现读）。Settings 加「连接与模型」段：Chat/Embedding Key+BaseURL、在线转写开关+模型/Key/URL、录音库路径选择器、git 自动推送开关、导入/导出按钮。Config 加 `transcribeBaseURL/transcribeKey`（缺省同 embedding）、`vaultAutoPush`；OnlineTranscriber 改用独立转写端点。
- **自动推送=仅文本派生物**（用户选）：`Git.syncTextOnly` 先把音频写进 `.gitignore`（`*.m4a/wav/mp3/...`）再 `add -A`→有改动 commit→push；非 git 区/无改动安静跳过。接到 import 完成、录音完成、改名、摘要、查找替换之后（`LibraryModel.autoPushVault`）。

**#1 转录耗时定位 + 优化 + 人声归一**：
- ingest 各阶段加 `⏱` 计时日志（导出/转录/AI校对）定位瓶颈。
- **AI 校对批次并发**（`TranscriptCorrector.correct` 用限流 TaskGroup，maxConcurrent=5）：批次互相独立，长录音从「串行 16 次 LLM」降到「约 3-4 轮」。安全闸/回退原文逻辑不变。
- **响度归一**（`AudioNormalizer.normalizedM4A`）：测峰值→增益（封顶 +18dB）→用 `AVAssetExportSession` 套 `audioMix` 增益导出**压缩 m4a**（关键：不导 WAV，否则上传暴涨反而更慢）。仅作用于**上传转录的临时副本**，存储/播放的 audio.m4a 不变；已够响（增益≤1.05）直接跳过用原文件，自限定只救小声场景。

**#3 说话人纠错（Ben 被误识别成 GGBond，且没法纠错）**：
- 根因：Ben 未注册声纹，其簇在 τ_abs=0.35 下误配到已注册的 GGBond。**对策**：diar 簇级匹配门提到 **0.45**（簇质心更稳，可严格），宁可让没注册的人落「说话人N」（一键命名）也不误配成别人。
- 改名交互本就可用（名册「改名」+ 逐句胶囊点击）。用户倾向「纠错只改这条显示名、不动 GGBond 声纹」→ `openRenameSpeaker` 的「记住声音」默认改为**随场景**：命名匿名者=开（教 App），纠正已识别名字=关（多半误配，别拿误配音频污染声纹库；要记仍可手动勾）。

**#4/#5/#6（UI/杂项）**：#4 列表录音标题 `.semibold`→`.medium`（去杂乱）；#5 权限/就绪状态原只在启动算一次→Settings `onAppear` + `NSApplication.didBecomeActiveNotification` 重算（从系统设置授权回来即时反映，不再卡「打开系统设置…」）；#6 菜单栏删 simulateMeeting debug 按钮。

## 再修 offline diarizer（pyannote+VBx）—— 仍崩，定性为库 bug（2026-06-23）

目标：修好 offline 后端去掉 Sortformer 4 人上限。三次尝试均在 **embedding 提取 chunk 0**（segmentation 出 `[0, N, M]` 后）硬崩：
1. `process(audio: samples)`（自动 prepare + 数组源）→ **SIGSEGV(139)**。
2. CLI 同款 `OfflineDiarizerModels.load` + `initialize` + `process(url:)` 磁盘源 → **SIGBUS(138)**，同一处。
3. **自建 cpuOnly 加载**（公开 `DownloadUtils.loadModels(computeUnits:.cpuOnly)` + 公开 `OfflineDiarizerModels.init` + 自读 `plda-parameters.json` 还原 pldaPsi，绕开官方 `load()` 硬编码的 `.all`/ANE）→ **仍 SIGBUS(138)**，同一处。

**结论**：原以为是 ANE 崩，**cpuOnly 证伪**——CPU 也崩，是 FluidAudio 0.15.4 离线 embedding extractor 的内存 bug（SIGBUS=非法/未对齐访问），与算力无关。库已是最新版（0.15.4，无更新可升）。硬崩是 signal、**无法 try/catch**，接 production 会拖垮整个 App。
**决策**：offline 后端**保持禁用/仅 CLI 实验**（代码留 `loadOfflineModelsCPUOnly` + 醒目警告注释）；production 维持 **Sortformer(≤4，干净) + 逐窗回退(>4)**。真要去 4 人上限只能 **vendor/fork FluidAudio 打补丁**（工作量+维护成本大）——等用户拍板是否值得。
