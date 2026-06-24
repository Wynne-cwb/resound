# 当前状态 (STATE)

> "现在的快照"。过时就改。细节/历史查 [DECISIONS.md](DECISIONS.md)。
> 最近更新：2026-06-24（转录前 VAD 门控落地+CLI 实测+修跨界映射 bug，待用户实机验收）

## 一句话现状

CLI 全链路 + macOS App 已通且用户实测过（问答 / Meet 弹窗 / 录音 / 导入 / 摘要 / 说话人识别）。本轮收尾两个体验问题：摘要模板名显示错 + 点开录音卡顿。**待用户实机验收。**

## ✅ 能力总览（细节全在 DECISIONS）

- **检索/问答**：transcribe→繁简归一+glossary→AI 校对→切块→contextual→embed(qwen3-8b)→SQLite(FTS5+sqlite-vec)→RRF→LLM rerank→带引用+时间感知问答（QueryPlanner 抽时间范围/判 qa·digest）。CLI 全套。
- **说话人识别**：弃盲聚类，走「ASR段合并≥4s窗→CAM++声纹(sherpa-onnx)→注册库双门匹配→真名，未匹中在线分堆成匿名」。平滑(`smoothSpeakerSegs`)清转场幽灵说话人并**持久化进 diarization.json**（转录/名册/摘要/Ask 一致）。CLI `speaker-identify` 批量修旧录音。
- **App**：原生窗口(自绘顶栏)+MenuBarExtra 驻留；侧栏四页 Ask/Library/Templates/Settings；浅深双主题(赤陶橙)；Library(列表+文件夹+搜索+折叠+播放器+摘要/转录 Tab+⌘F 查找替换+说话人命名→声纹注册+导入)；Templates 卡片页(CRUD+AI 协助生成/润色提示词+设默认)；Ask(聊天历史+多轮上下文+引用)；Meet 检测→弹窗→双路录音→转录→自动索引+摘要闭环。
- **摘要**：模板(通用/1-on-1/团队会/头脑风暴，存 App Support `summary-templates.json`)；占位符 `{date}{weekday}{title}{speakers}{transcript}`，缺 `{transcript}` 由 `summarize()` 运行时兜底补上（不限制用户 prompt）；system prompt 禁开场白/承接语。

## 🎯 当前焦点 / 下一步

- **转录前 VAD 门控（方案 A）已落地（编译+打包+启动通过，待用户上传音频验收）**，细节见 DECISIONS 2026-06-24「转录前 VAD 门控」：whisper 在静音/噪声段爱幻觉（「谢谢观看」套话/重复）+ 长静音致时间戳漂移。新增 [VADGate.swift](../Sources/ResoundCore/VADGate.swift)：转录前用 silero VAD 找人声块→`AVMutableComposition` 只拼人声（块间留 0.35s 静音供断句）→导出小 m4a 上传→返回段落/词时间戳从压缩轴映射回原始轴。只作用于在线转录上传副本，存储/播放 audio.m4a 不动；没多少可剪（人声占比高）/VAD 不可用/导出失败→退回原文件，零风险（同 AudioNormalizer 自限定）。在归一之前跑（先剪后归一）。
  - **已 CLI 实测**（详见 DECISIONS）：Jerry 剪 4.9%、Annual Review 剪 **19%**、0 套话幻觉、时间戳映射回原始轴正确。**修了一个跨界映射 bug**：start/end 独立映射会把"跨被剪静音的归并段"拉成横跨死区的畸形长段（实测 219s）→ 改 end=映射后 start+压缩轴原始时长，已复跑确认收缩正常。已重打包启动。
  - **验收点**：实机导入杂音多的录音→看幻觉/重复是否变少、逐句点跳是否对齐（尤其原本有大段等待/静音处）、说话人贴标是否仍准。不行→调 `minCutSavings`/`bridge`/`gapPad`。后续可加 C（后处理幻觉黑名单）兜底 VAD 漏网。

- **「换人处切句」已评估后回退、暂不做**（详见 DECISIONS 2026-06-24）：净负优化——切分天花板=diar 准确度，难场景下切错的碎片比"整句归主讲者"更误导，收益面仅 ~5%。已恢复句级归属。Jerry 这条仍在 Library（按一句一说话人展示）。

- **说话人过检→全员误配 已修（编译+打包+启动通过，待实机验收）**，细节见 DECISIONS 2026-06-23「说话人过检」：Sortformer 把 2 人 1-on-1 过检成 4 簇 → 误入多人会回退 → 全标成 Wynne。改 [SpeakerDiarize.swift](../Sources/ResoundCore/SpeakerDiarize.swift)：先提簇级声纹 → 按 cos>0.80 凝聚合并被切开的同一人 → 用合并后簇数路由 → 命名互斥(一个注册者只认领最佳簇)。实测 Tao 4→2(Wynne+说话人1)✓、GGbond 零回归(Wynne+GGBond 0.90)✓。
  - **验收点**：实机看 Tao 这条是否落成 2 个说话人(Tao=说话人1 可一键命名)；其它 1-on-1 仍正常。残留:相似嗓音时长分配可能偏、highContext 逐句归属精度待看，不行则 `sortformerConfig` 退 `.default`。

- **Sortformer 提速已落地（编译+打包+启动通过，待实机验收）**，细节见 DECISIONS 2026-06-23「Sortformer 提速」：production 改用 **`.all`(ANE) + `highContextV2_1`**（单一出处 `sortformerConfig`/`sortformerComputeUnits` in [Diarizer.swift](../Sources/ResoundCore/Diarizer.swift)）。实测 1-on-1 推理从 ~7min 级 → ~30s 级；多人会仍检出 4 簇→回退逐窗法路由不变（零风险）；2 人会 highContext 3 簇比默认 4 簇更接近真实。临时 CLI `sortformer-bench` 已删。
  - **验收点**：实机重识别一条 1-on-1（Hydra/GGbond），肉眼看是否干净落成 2 个说话人、贴得对。不对 → 退回 `sortformerConfig = .default`（仍保留 `.all` 提速）。残留风险=highContext 边界更粗、无 GT 实测准确率。

- **智能错词标注系统已落地（编译+打包+启动通过，待实机验收）**，细节见 DECISIONS 2026-06-23：⌘F 错词替换被 `observeCorrection` 跨录音去重累计（已知词1次/新词2次跨录音）→ 即时 toast 提醒 + 设置页「待确认词表建议」收件箱一键加入。变体按安全度分流：英文/长串→硬子串替换进 glossary 变体；模糊短中文→软（仅偏置+喂 AI 校对 few-shot，不子串替换，防「学→Share」污染）。观察日志在 App Support，确认才落 vault。新增 [CorrectionLearner.swift](../Sources/ResoundCore/CorrectionLearner.swift)。
  - **验收点**：在不同录音里对同一错词做 2 次替换 → 看是否弹建议 + 设置页收件箱出现；点「加入词表」后词表是否多出对应条目；短中文变体是否标「AI 校对」而非「自动替换」。

- **本轮后续小改（均编译+打包+启动通过，待实机验收）**，细节见 DECISIONS 2026-06-23：
  1. 引用跳转**能跳但不滚动** → 逐句转录拍平成单层 LazyVStack（`flatLines`），scrollTo 可寻址 + 三处触发兜底。
  2. 录音列表加**「生成摘要中…」**徽标（手动重新生成摘要时；接 `summarizingId`）。
  3. 摘要 system prompt 写入**会议日期为权威事实**（治 LLM 把 2026 写成 2025）；Ask qa/digest 加「今天」锚点；新建 [Prompting.swift](Sources/ResoundCore/Prompting.swift)（`zhWritingStyle` 盘古之白 + `todayAnchor`）三处复用。
  4. 摘要页顶部**纯展示**说话人徽标（不可点）。
  5. **录音按真实会议日期排序（方案 B）**：标题解析日期写入 recordedAt；CLI `resound redate` 已修正 14 条旧录音。新导入自动带正确日期。

- **🔥 专项性能优化 A+B+C+D 已落地（编译+打包+启动通过，待实机验收）**，细节见 DECISIONS 2026-06-23「性能审计」+「性能优化 A–D 落地」：
  - **A 批量主线程扫盘**：`startImport` 去掉每文件 `load()`→增量插入单条（`insertRecording`）；`load()`→后台 `reload()`（扫盘/manifest/sqlite 全 off-main）；说话人 worker 队列改存 `RecordingSummary` 不再每条全扫；openCitation 改 `reload(then:)` 异步定位（保跳转）。
  - **B 模型缓存+去重**：新增 `actor DiarModelCache` 缓存 Sortformer/Manager/silero-VAD/CAM++（N 次冷加载→1）；`runDiarization(samples:)` 重载消除同文件二次解码；`indexRecording(labelSpeakers:false)` 导入/录音路径跳过会被 diarize 覆盖的冗余标注。
  - **C 渲染廉价热点**：`RecordingSummary.identified` 扫描时算好，列表行去 `fileExists` syscall（worker 完成 `markIdentified` 即时消徽标）；`sections()` body 内单次复用。
  - **D 长转录稳态**：拆出 `Playhead`(ObservableObject) 只放高频 `currentTime`，`PlayerBar` 子视图独立观察→播放头 0.25s 跳动只重绘播放条、不再每秒 4 次失效整页；转录高亮改由 `activeLineID`(仅跨行变)驱动；`Line`/`Block` 用稳定段 id + Equatable（重载不再全量重建/丢滚动位置）。
  - **验收点**：①导入 ~10 文件时拖动列表/切页是否顺；②整机（含其他 app）导入期是否不再卡（模型缓存生效）；③长转录边播边滚是否流畅；④引用跳转(seek+定位)、查找替换、说话人命名/重分配仍正常。
  - E（找词框缓存 / 转录迁 List / 拆 LibraryModel）按用户选择**未做**，留作后续。

- **说话人「重分配」+ 单注册者误配治理（编译+打包+启动通过，待实机验收）**，细节见 DECISIONS 2026-06-23：Ben 误识别成 GGBond 的根因=库里只注册了 GGBond 一人、簇门 0.45 太松把陌生人吸成唯一参考。改了三处：①簇级 `tauAbs` 0.45→**0.5**；②每簇匹配**打印 cos/margin**（CLI `speaker-identify` 日志可见真实数字，便于按真录音再调）；③**重分配 UX**——纠正已识别者时「记住声音」默认**开**（登记成新说话人，下次自动认出，且 enroll 只动新名字、绝不碰 GGBond 声纹），弹窗按匿名/已命名分文案。
  - **待用户验收**：(a) 重导 Ben 这条录音，看是否落匿名/可正确重分配；(b) 跑一次后看 CLI 日志里 Ben 簇对 GGBond 的真实 cos，若仍 >0.5 则需进一步调门限或换更强声纹模型（④，原搁置）。

- **本轮六项批量已完成（编译+打包+启动通过，待用户实机验收）**，细节见 DECISIONS 2026-06-23：
  1. **#1 转录提速 + 人声归一**：ingest 各阶段加 ⏱ 计时日志；**AI 校对批次改并发**（限流 5，长录音从串行 N 次 LLM→约 N/5 轮）；转录前 `AudioNormalizer` 对**上传副本**做响度归一（压缩 m4a，不动存储/播放，已够响则跳过）。
  2. **#2 Settings 全量配置化**：Chat/Embedding 的 Key+BaseURL、在线转写开关+模型/Key/URL、录音库路径选择、git 自动推送开关、配置导入/导出。存 App Support `.env`（`ConfigStore`），运行时即时生效、无需重 build。自动推送=**仅文本派生物**（`Git.syncTextOnly`，audio 自动进 `.gitignore`）。
  3. **#3 说话人纠错**：diar 簇匹配门提到 0.45（未注册的人如 Ben 落匿名而非误配 GGBond）；改名「记住声音」默认随场景（命名匿名→开 / 纠正已识别→关，符合用户「误配≠移除 GGBond」）。
  4. **#4** 列表标题 semibold→medium。**#5** 权限状态在 Settings 出现 + app 变 active 时实时刷新。**#6** 菜单栏移除「模拟检测到会议」debug 按钮。
- **待用户验收/回复**：①新转录链路真实耗时（看日志 ⏱ 定位瓶颈是在线 whisper 还是别处）；②大会议室小声场景归一是否帮到识别；③Sortformer 说话人识别 ~7min 是否可接受（上一轮遗留）。

- 本轮已修（编译+打包+启动通过，待实机验收）：
  1. **摘要模板名显示错**：选 1-on-1 重新生成却显示「通用」。根因=`currentTemplateId()` 让旧摘要的 `summaryTemplateId` 优先于用户刚选的 `chosenTemplateId`；已**调换优先级**（用户选择优先）。生成本身一直用对的 id，只是显示滞后。
  2. **点开 Library/录音卡顿**：`refreshDetail` 原在主线程同步做文件读+JSON解码+平滑+索引查询+**AVAudioPlayer 解码整段长音频**。已改：重活全进后台 `Task.detached`，算完比对 `detailToken` 再回主线程发布（切走即丢弃）；**播放器懒加载**（`ensurePlayer`，按播放时才解码，时长先用元数据占位）。
  3. **加载态**（配合上面的异步化）：点开录音详情后台载入时正文区显示「正在载入…」卡片（`loadingDetail`）；首次播放音频后台解码时播放键转圈（`decodingAudio`，解码改 `withPlayer` 异步）。

- **②（真 diarization）+ ③仅 silero VAD 已落地并接入 production**（用户拍板：「麦克风轨=我」彻底不做，④搁置；编译+打包+启动通过，待用户实机验收）：
  - Core `identifySpeakersByDiarization`（[SpeakerDiarize.swift](Sources/ResoundCore/SpeakerDiarize.swift)）：Sortformer 拿干净轮次 → 每簇 silero VAD 清静音后提 CAM++ 簇级声纹 → 匹配注册库映射真名 → ASR 段贴标签 → 平滑写盘。
  - **混合路由**：Sortformer 上限 4 人——离线验证（CLI `diarize-compare`）证实：**2 人 GGbond 新法更干净**（旧法 raw 冒出幽灵 Sara+匿名靠平滑救回；新法 4 簇→精确 2 人 0 匿名），**6 人 OS 会新法被 4-cap 并掉 2 人**（丢 GGBond/Wynne）。故 `≥4 簇 → 回退旧逐窗法`（多人更稳），≤3 簇走干净 diar。`.offline` 后端（任意人数）**segfault 不可用**，暂用 Sortformer。
  - production `analyze()`/导入/CLI `speaker-identify` 已切到新法（带回退）。
  - **⚠️ 速度代价**：Sortformer 处理 28 分钟录音约 ~7 分钟（后台带 spinner）；1-on-1（≤4 簇）每次识别/导入都走它。质量>速度按用户原则取舍，但需用户确认这个等待可接受；若嫌慢可调回旧法或只在导入时跑。
  - 模型首跑会下载（Sortformer / silero VAD，已缓存）。

## ⚠️ 未提交（本轮及之前，用户未要求 commit）

App 全量 UI + Templates 页 + 转录 AI 校对 + 摘要修复 + 本轮两修；Core 新增 GlossaryStore/SpeakerNaming/OnlineTranscriber/QueryPlanner/Summarizer/TranscriptCorrector/TimeUtil/LibraryFolders。docs 两份已同步。

## 📌 运行 / 测试要点

- App 配置：`.env` 复制到 `~/Library/Application Support/Resound/.env` + 补 `VAULT_PATH`、`SPEAKER_MODEL`（已写好）。
- 改完样式必须 `killall Resound` → `./scripts/bundle-app.sh release` → `open build/Resound.app`。
- GUI 我看不到 → 靠用户截图迭代。测试数据在 `~/Downloads`（GGbond 2人会 / OS 6人会）。实验脚本 `experiments/diar-py/`。

## 待办/提醒

- 开机自启仅持久化偏好，未真接 SMAppService；拒识阈值 τ 待调；加音频进真 vault 前装 git-lfs。
