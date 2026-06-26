# 决策 & 已完成实践日志 (DECISIONS)

> 增长型日志：定下的选型/参数/结论 + 已完成功能 + 关键踩坑。带日期，别删历史。
> 当前快照看 [STATE.md](STATE.md)。

---

## Markdown 渲染器原生化 + 去 keep-alive + 一组性能修复（用户实测「好很多了」）（2026-06-26）

设计 [spec](superpowers/specs/2026-06-26-native-markdown-renderer-design.md)。用户反馈 Ask/转录/切页一系列卡顿，**全程先埋点（Perf.swift 卡顿看门狗+body 计数+measure）再改，数据驱动**——印证「性能优化先埋点别猜」原则：前几轮我猜的根因（替换字符串处理、reindex 阻塞主线程）都被数据否掉，真凶靠日志逐个揪出。

**埋点定位到的真凶链**（按发现顺序）：
1. 转录页替换/交互卡：`transcriptRow` 重渲 ~597 次/秒（157 行转录全列表重渲）——根因=行是 LibraryView 内联方法、读 vm.@Published，任何无关变更都全量重渲。`findMatchCount` 每次 body 重拼全文+不敏感扫描 4~9ms。→ **转录行抽成 `TranscriptLineRow: Equatable`**（值字段不变即剪枝）+ **findMatchCount 缓存**（lines/summaryText 变才失效）+ 查找跳转**去动画**（长转录里动画 scrollTo 会强制 LazyVStack 一次性实例化沿途所有行＝最早那 14s 冻结元凶之一）。
2. 「先进 Documents 再回 Library 查找」必卡（用户给的 A/B 实锤：A 不进 Documents 顺、B 进了卡）：根因=keep-alive 的 `pageVisible` 用 opacity 0 常驻，**SwiftUI 对 opacity 0 视图仍布局**，Library 查找触发布局时反复重排隐藏 DocumentsView 那篇整文 MarkdownUI（多秒冻结，且开销不在任何 body=纯布局）。
3. 即使加了「隐藏不布局」gate + Markdown 解析缓存，**切页仍 300~890ms**：残余是 **MarkdownUI 的布局**——它每块一棵嵌套 SwiftUI 视图树，整篇几百节点一次性布局。这是结构性瓶颈。

**根治（用户拍板：原生自绘替换 MarkdownUI；嵌套列表硬需求；解析器选 swift-markdown）**：
- 新增 [MarkdownNative.swift](../Sources/ResoundApp/MarkdownNative.swift)：`swift-markdown`（Apple 官方 cmark-gfm 包装，纯解析）解成 AST → 递归自绘原生 SwiftUI。**段落塌缩成单个 `Text(AttributedString)`**（MarkdownUI 每段几十个嵌套视图 → 1 个）；**顶层块装进 LazyVStack 虚拟化**（大文档只布局可见 ~15 块，不再一次性 100+）；Document 按原文缓存。覆盖标题 h1–h4/粗斜删/行内码/链接/**多级嵌套列表（逐层缩进 18pt + •◦▪）**/有序/任务列表 ☐☑/引用/代码块/**GFM 表格**，观感对齐原 resound 主题。`SummaryMarkdown` 内部换实现，7 处调用点零改；`Package.swift` 依赖 `gonzalezreal/swift-markdown-ui` → `apple/swift-markdown`。
- **去掉 keep-alive**：渲染够快后，`RootView` 从「懒挂载+常驻 ZStack（opacity 切换）」回归「只渲染当前页」条件渲染；删 `pageVisible` 环境键/gate/`mounted`。隐藏页根本不存在 → 跨页布局干扰类问题（含上面 #2）从根上消失。代价：切页丢失视图本地 @State（滚动位置回顶），数据由 app 级 @StateObject 保活不丢——用户认可。
- 实测：切页卡顿从 500~890ms（偶发 3~14s 冻结）→ 多数无卡顿条目（<100ms）、零星 100~312ms，长冻结消失。

**踩坑**：①`swift-markdown` 的 `Text`/`Table`/`Link`/`Image` 节点名与 SwiftUI 冲突 → 一律 `Markdown.` 限定。②`plainText` 只在 `PlainTextConvertibleMarkup` 上，`any Markup` 要 `as?` 转。③节点 children 的 Element 类型（`Markup` 存在类型 vs `InlineMarkup`）不能直接喂泛型 `Sequence`，统一 `Array(node.children)`（[Markup]）。④keep-alive 的「切页重解析」曾是当初引入它的理由——现 Markdown 解析已缓存 + Ask 早已 LazyVStack，重解析成本没了，故能安全回退条件渲染。

**另修：本场/文档提问追问不带上下文**。`answerInRecording`/`answerInDocument` 原检索用追问原文（「时间线呢」嵌入差→空命中→「没有相关内容」），历史只喂了综合层。修=检索前先 `condensedQuery`（有历史则复用 `QueryPlanner` 带历史改写成可独立检索的查询，只取其 query；无历史原样），与全局 Ask 一致。CLI/实测：「时间线呢」→检索「客户迁移 时间线」hits=6。

## 录音浮窗（屏幕级可拖动指示器）落地（编译+打包+启动通过，待实机）（2026-06-26）

**来源**：Claude Design handoff（`Resound.dc.html`）。原型里浮窗是 App 窗口内的绝对定位药丸（脉冲红点 + 计时 + 停止方钮，底部居中，可在窗口内拖拽），并在「设置 › 通用」给了 `recBadge`「录音浮窗」开关（默认开）。

**关键设计决策——做成屏幕级浮动 NSPanel，而非窗口内覆盖层**。原型受限于单一 HTML 画布只能画在窗口内，但这个功能的本意是「录音时（人在 Meet/Chrome 里、Resound 主窗常被最小化/关闭，App 仅在菜单栏后台）也要持续可见并能一键停录」。所以唯一有用的原生形态是**跨 App、跨 Space、全屏可见**的浮动面板。仓库已有 [MeetingPanel.swift](../Sources/ResoundApp/MeetingPanel.swift) 同样的成熟范式（borderless + nonactivatingPanel + `.floating` + canJoinAllSpaces），直接同构复用，不另造轮子。

**实现**（新增 [RecBadgePanel.swift](../Sources/ResoundApp/RecBadgePanel.swift)）：
- `RecBadgePanelController` 单例，App 启动 `configure(recorder:app:)` 一次（在 [ResoundApp.swift](../Sources/ResoundApp/ResoundApp.swift) onAppear，紧跟 MeetingPanel）。订阅 `recorder.$phase` 显隐、`app.$isDark` 主题重建。
- `RecBadgeCard`（SwiftUI）= 脉冲红点 + 计时 + 停止方钮，外形按原型（Capsule、pal.elev 底、borderStrong 描边、大阴影）。**计时靠 `@ObservedObject var rec` 自动刷新，浮窗 NSHostingView 只建一次不重建**（避免每秒重建丢动画/抖动）。停止钮调 `recorder.stopAndIngest()`。
- 拖拽=`isMovableByWindowBackground=true`（药丸主体即拖拽区，停止按钮自吃点击不触发拖窗）；位置记忆=`setFrameAutosaveName`；首次默认主屏底部居中略高于 Dock。
- 开关：键 `resound.toggle.recbadge`（`RecBadgePanelController.recBadgeKey`，默认开），SettingsModel 加 `@Published recBadge`，didSet 写 UserDefaults + 发 `RecBadgePanelController.toggleChanged` 通知 → 录音中切换即时显隐；SettingsView「通用」加 toggleRow。
- 显示条件：`recorder.isRecording && badgeEnabled`（读 UserDefaults 取最新值，与 RecordingController 读 autoDetect 等开关同模式）。

**零回归**：纯新增独立面板 + 一个开关，不碰录音/转写/检索任何既有路径；关掉开关行为同现状。

## Ask 统一检索架构 · 第一批地基（落地+CLI 全绿，待 App 重建）（2026-06-26）

**背景**：Ask 原只有 qa/digest 两形状，擅长小窗口回顾/具体事实，但跨长时间主题回顾撞墙（digest 无上限塞全库摘要+主题盲；qa 仅 top-8 太浅），且缺人物/时间线/对比维度。设计见 [spec](superpowers/specs/2026-06-26-ask-scenarios-unified-retrieval-design.md)。

**架构决策**：检索 = **过滤层（圈子集，可 AND 组合）× 综合层（选一种输出形状）** 两个正交维度。这是"7 场景不互斥"的根本——多数是同一引擎换收尾。②长跨度/⑦演变/⑧对比**共用一台引擎**（主题检索圈子集→综合），只换形状。综合数据源=**混合**（录音摘要 + 语义命中片段；用户拍板，不只读摘要也不全量原文 map-reduce）。

**第一批实现（覆盖 ①②③④⑤ + 顺带 ⑦）**：
- **QueryPlanner v2**：单次 LLM 输出 `{query, shape∈qa/digest/timeline/compare, filters{date_from,date_to,speakers,source}, recency, compare_sets}` + 意图分类规则（含上轮"时间是过滤 vs 话题"的区分）。`dropFutureRange` 防御保留。
- **过滤层零 schema 改**：`chunks` 已有 `recording_date`/`person_id`/`source_kind`/`doc_id` 四列全可查。新增 `Index.Filters` 结构 + 统一 `filterClause` 拼 SQL（vector/FTS 共用），speaker→`person_id in (...)`、source→`source_kind`。
- **检索宽度随 shape 自适应**：qa 保持 final≈8（防稀释）；digest pool 放大到 120、候选 60、片段 40、子集最多 60 条录音——目的是**找全相关录音**而非挑 8 段。
- **digest 引擎重构**：短跨度（≤40 天，这周/这个月）= 只喂范围内全部录音摘要（**零回归** ≈ 旧 digestAnswer）；长跨度 / 无时间范围 = 主题检索定子集 + 每条录音附命中片段佐证。超 12 条或 24k 字 → **map-reduce**（分批 map 出局部要点 → reduce 合并）。彻底替掉 `recordingsInRange` 无 LIMIT 全拼的隐患。
- **qa 安全兜底（根治"没有录音"挡死）**：带过滤检索为空 → 按 speaker→time→source 顺序逐步放宽再试，最后无过滤兜底。**绝不空手挡死**。

**踩坑**：规划器对"**我和 Jerry**""**Jerry 和我**"会把说话人整个丢空——因为它把"我"也当成一个待筛说话人后犯晕。`person_id` 里"我"=提问者本人根本不是可筛项。**对策（prompt）**：明确"我/我们/自己=提问者本人，不是可筛说话人，只筛另一方"，补例后两种措辞都正确抽出 ["Jerry"]。又一次印证 LLM 抽取的杠杆在 prompt。

**CLI 实测全过**：③"OS 最新迁移策略"→qa+识别近因；④"这个月开了哪些会"→digest 短窗口只摘要；②"我做了哪些管理改进"→无范围走主题子集；⑤"我和 Jerry 聊过什么"→👤Jerry 过滤；⑦"OS 迁移怎么演变的"→真按 2025-12→2026-06 时序串叙事且跨越全史（证明绕开了 8 段限制）；兜底"上周 Zhang2333 聊火星殖民"→放宽后诚实答"无此内容"而非挡死；普通无过滤 qa 零回归。

**残留（已在同日批2+批3 补完，见下）**。

## Ask 统一检索架构 · 批2 近因加权 + 批3 compare + App 意图 chip（落地+CLI 全绿+已重建，待实机）（2026-06-26）

- **批2 近因加权（③）**：`applyRecency` 把 rerank 名次（相关度 rel）与录音日期的时间衰减（半衰 120 天、文档中性 0.5）融合 `0.6·rel + 0.4·rec` 重排取 topK。仅 `recency=true` 触发（"最新/目前/现状"），并先多取候选（fetchK=max(topK,24)）再加权，避免污染普通检索。
- **批3 compare（⑧）**：`compareAnswer` 对 `compareSets` 两个集合各自带过滤检索（各 10 段），喂"分两栏概述各自要点 + 一段点明差异"的 prompt。判不出两集合则返 nil 落 qa 兜底。
- **踩坑：flash 不认 compare**："这周和上周的1on1有什么不同"先被判成 qa。加规则没用，**加 few-shot 示例**（compare/我和X/下半年/最新 四条 input→JSON）后立刻正确判 compare 且不破坏"下半年"回归。再次印证 flash 的强杠杆是 few-shot，不是堆规则。
- **App 意图 chip**：`ChatVM.intentChip(plan)` 生成"汇总/时间线/对比 · 👤人 · 仅文档/仅录音 · 最新优先"（qa 无过滤返 nil 不打扰），`Msg`/`StoredMsg` 加 `intent` 字段持久化，渲染成 scope 图标药丸（让用户看见系统怎么理解了问题、便于发现误判）。`.emptyTime` 文案改成"放宽筛选后仍无相关内容"（兜底后空只意味着真没匹配，不再是"这段时间没录音"）。
- **CLI 复验**：⑧→双栏对比 + 两周日期正确；③→qa+近因；"下半年规划"仍 qa 不误筛。编译+`bundle-app.sh release`+启动通过。

---

## 踩坑：时间感知问答把「话题里的时间词」误当录音筛选（已修，编译+CLI 实测）（2026-06-26）

**现象**：问「AfterShip OS **下半年**的规划是什么」→ App 显示「🗓 时间范围 7月1日–12月31日」+「（这段时间没有录音）」。明明 vault 里有大量相关录音/文档，却被一句话挡死。

**根因**：`QueryPlanner`（LLM 抽时间范围）把「下半年」解析成了**录音发生的时间**（Jul1–Dec31）去过滤 `recording_date`，但这里「下半年」其实是**被讨论话题的一部分**（问的是"关于下半年规划的内容"，不是"在下半年录的音"）。原 prompt 没区分这两种语义 → digest 路径按这段日期查录音 → 空 → 兜底文案。叠加一个巧合：相对今天（2026-06-26）「下半年」整段都在**未来**，录音不可能存在，必空。

**修复**（两道，`QueryPlanner.swift`）：
1. **改 prompt（主修，杠杆所在）**：明确「date_from/date_to 仅用于按**录音发生的时间**筛选」，并给出区分规则 + 正反例——时间词修饰"录音/会议/对话发生在何时"才填日期（"昨天的1on1""上周开了哪些会""6月有哪些会议"）；时间词若是话题名词的一部分（修饰"规划/计划/目标/预算/路线图"，问内容而非录音时间）则两端必须 null、时间词保留在 query（"下半年的规划""Q3 目标""明年的计划""2025年的预算"）。
2. **加防御 `dropFutureRange`**：`date_from` 字典序严格晚于今天 ⇒ 整段在未来（date_to≥date_from）⇒ 录音不可能在未来 ⇒ 丢弃范围退回无过滤问答。纯未来窗口做录音筛选必空，安全网不会误伤任何合法过去/含今天的范围。

**CLI 实测**：①「AfterShip OS 下半年的规划」→ 不再出时间范围，正常 qa 检索给出带引用真实答案（混引 📄 文档 + 🎙️ 录音）；②回归——「上周开了哪些会」→ 仍抽 06-15~06-21 digest ✓、「这个月录的会议都聊了什么」→ 仍抽 06-01~06-26 digest ✓，合法录音时间筛选无误伤。

**教训**：时间表达天生歧义（修饰录音事件 vs 修饰话题）。LLM 抽取类逻辑的杠杆还是 **prompt**（给清区分规则 + 正反例），与上一条 tidy「真正杠杆是 prompt」同源。代码侧只补"物理不可能"的硬防御（未来录音）。

**待实机**：App 需重建才生效（改在 ResoundCore），与 P3 等同批——**录音结束后**再 `killall Resound`+`bundle-app.sh release`+`open`。重建后在 Ask 里复测这条问句即可。

---

## 文档 P3 增强：PDF/图片 OCR 提取后 LLM 排版整理（编译+CLI 实测，已重启待实机）（2026-06-25）

**诉求**：用户传 PDF 后提取出文本但 markdown 排版乱（标题被拆成多行、每页重复 Notion 页眉页脚/页码、表格挤成一行）不可读。要在文本识别后用 LLM 保语义整理排版。

**做了什么**：新增 [MarkdownTidier.swift](../Sources/ResoundCore/MarkdownTidier.swift)——`tidy()` 按行分批（≤4000 字/批、限并发 4）调 ChatClient 整理，严格 reflow prompt（保全部实质信息、删重复页眉页脚页码、合并拆行标题、重建 markdown 表格；禁改写/总结/翻译）；双重安全闸（单批输出<原 50% 回退该批 / 全局<原 50% 回退原文）+ 异常回退，**绝不丢内容**。`tidiedExtraction(result:config:model:)` 仅对 `sourceFormat ∈ {pdf,image}` 生效，接在 extractDocument 之后、写 content.md 之前（App `ingestFile` + CLI `import-doc` 共用）。新增 `.tidying`「整理排版中…」进度档；CLI `extract-doc --tidy [--model X]` 供无头调试。

**关键决策与依据（含一次自我纠错）**：默认模型 = **`config.correctModel`（v4-flash）**，即用户原意「沿用转录校对那套」。
- **踩坑+纠错**：我一度误判「flash 整理不动、必须上 pro」。真相是**第一次测 flash 用的是保守版 prompt**（"不准删任何内容+拿不准就原样保留" 与 "去页眉页脚" 自相矛盾→模型选择不动）。我随后**同时**改强 prompt 又换 pro，把功劳错记到模型上。用户质疑后**重新公平对比**：同一版强 prompt 下，**flash 连跑 3 次都能正确整理**（标题合并/删页眉页脚/重建表格，14243→~13.5k），与 pro 基本同档。**真正的杠杆是 prompt（给够"删噪声/合并/重建表"的明确授权），不是模型**。故默认回 flash；`--model`/`tidiedExtraction(model:)` 仍可覆盖成强模型。
- **教训**：A/B 一次只改一个变量。同时改 prompt + 模型，把 prompt 的功劳错算给了模型，差点把默认模型钉错。

**旧文档回溯**：tidy 只在导入时跑 → 上线前导入的旧文档不会自动整理。新增 CLI **`retidy-doc <docDir>`**（从 original.* 重提取→整理→重写 content.md→重建该文档索引）补这个缺口；已对用户那份 AfterShip OS doc 跑过（14243→13309、33 chunks 重建）。

**取舍/残留**：分批拼回可能跨批标题层级略不一致（可接受）；flash 偶发一次性"原样回吐"过（多次未复现，安全闸不拦"原样"但不丢内容，重导即可）。

---

## 踩坑：会议录音转写失败重试后「丢会议名、id 变文件名」（已修，编译通过待实机）（2026-06-25）

**现象**：用户报「录音本来拿 Google Meet 名字，转换后名字变了」。查真实 vault：有条 `source:meeting` 录音 `id=2026-06-25-1912-1782385867-resound-meeting-<uuid>`（文件夹名是抢救音频的临时文件名）而非会议名 slug，旁边还有条同会议、id 正常的 `…-platform-department-weekly-meeting`。

**根因**：`LibraryModel.ingestOne`（导入/重试/会议失败兜底重试**共用**路径）**写死 `title: nil`** 调 `IngestPipeline.ingest` → `displayTitle` 落回 `defaultTitle(from: audioPath)` = 抢救音频文件名 `<ts>-resound-meeting-<uuid>`。而 `recordFailedRecording` 明明把会议名存进了 `ImportItem.name`（仅用于显示），却没传给 ingest。直录成功路径（`RecordingController.stopAndIngest` 直接调 ingest 带 title）不受影响——**仅"会议录音转写失败→重试"这条会中招**：重试后 title+id 都变成文件名乱码（用户多半事后手动 `renameRecording` 改回 title，故 manifest.title 看着对、但文件夹 id 仍是乱码）。

**修复**：`ImportItem` 加独立 `title: String?`；`recordFailedRecording` 写 `item.title = 会议名`；`ingestOne` 改传 `title: p.title`；`startImport` 重建 ImportItem 时保留 `source/title`。普通文件导入仍 `title:nil` 走 `defaultTitle`（文件名去扩展名）——**零回归**。已坏的历史文件夹 id 不迁移（只是目录名，功能无碍）。

**教训**：共用 ingest 辅助函数图省事写死 `title:nil`，把上游辛苦保留的标题在汇聚点丢了。多入口共用的辅助函数，**该透传的字段要透传到底**，别在中途硬编码默认值。

---

## 文档模块 P3：富格式解析（PDF/docx/pptx/HTML/图片）—— 自研零依赖（M1 CLI 验证全绿，M2 待实机）（2026-06-25）

**背景/诉求**：导入只吃 md/txt；用户要导入真实会议材料（PDF/Word/PPT/HTML/图片含扫描件）。spec [specs/2026-06-25-documents-p3-rich-formats-design.md](superpowers/specs/2026-06-25-documents-p3-rich-formats-design.md) / 计划 [plans/…-p3-…-plan.md](superpowers/plans/2026-06-25-documents-p3-rich-formats-plan.md)。

**关键决策与依据**：
1. **选「自研零依赖」而非用库**。调研最优库 **SwiftText**（MIT，自带标题推断+表格、macOS 26 自动升级结构化 OCR），但它用 **Swift package traits（SE-0450）需 tools-version 6.1**；而升 6.1 要么升 macOS 15（Xcode 16.3 要求；用户在 14.5，**动静太大**），要么装独立 toolchain（build/打包要切 `TOOLCHAINS`、SwiftPM 无完整 Xcode 有小毛病）。用户原选「升级用库」，确认要升系统后改判 → **退回自研**。底层能力同源（都是 PDFKit/Vision），自研只多写标题推断/表格/mini-zip 代码，换来**零升级零依赖**，当前 Swift 6.0.3/macOS 14.5 直接可跑。`Package.swift` 不动、不加 SPM/C 依赖（系统框架 import 即自动链接）。
2. **PDF 不直接 OCR**：数字版用 PDFKit `attributedString` 取文本+字号（字号/加粗→`#`/`##` 排版推断标题），**仅扫描件**（文本层近空）才渲染每页走 Vision OCR——直接 OCR 数字 PDF 反而丢真字、引识别错。
3. **OCR 范围/语言**：图片必走 + 扫描型 PDF 回退；`recognitionLanguages=["zh-Hans","zh-Hant","en-US"]`、accurate。
4. **mini-zip 用 Apple Compression 框架**：docx/pptx 是 zip+XML，手写 ~150 行最小 zip 读取器，`compression_decode_buffer(COMPRESSION_ZLIB)` 正好解 zip 条目的 raw deflate（Apple 的 COMPRESSION_ZLIB = 无头 raw deflate），**不 shell out、不加依赖**。
5. **架构=单一入口 + 一处接入**：新增 `DocumentExtractor.extractDocument(url)→ExtractResult{markdown,sourceFormat,warnings}`（**失败不抛**，空正文+warnings，原件照常留档）；`DocumentStore.importDocument` 加 `originalFileURL`（拷贝真原件为 `original.<ext>`，nil 时与现状逐字节一致）；下游切块/embedding/检索/问答/纪要纳入**零改**。

**做了什么**：新增 [DocumentExtractor.swift](../Sources/ResoundCore/DocumentExtractor.swift) + [MiniZip.swift](../Sources/ResoundCore/MiniZip.swift)；改 `Document.swift` importDocument；CLI `import-doc` 接 extractDocument + 新增 `extract-doc` 调试命令；App 侧 `importFiles/importFile/ingestFile`（后台 Task.detached 解析 + 真原件 + warnings→toast）、`DocImportItem.Status.parsing`、文件选择器 `docImportContentTypes()`。

**踩坑**：①HTML 粗体正则 `<(?:strong|b)[^>]*>` 把 **`<body>`** 当成 `<b>`（b+"ody"）→ 开头多 `**`、错位。**对策**：标签名后须接 `>` 或 `\s` 属性（`<(?:strong|b)(?:\s[^>]*)?>`），同样修 h1-6/li/a。②自制测试 PDF（headless swift 渲染）PingFang 被替换成 Times → 中文标点落私用区乱码——**是造样例的副作用，非提取器问题**（真 Word/Pages PDF 正常），但提醒：测 PDF 解析要用真实/嵌字体 PDF。

**验证**：CLI `extract-doc` 无头实测 md/txt/html/docx/pptx/pdf/png 全过（docx 表格、pptx 分页、pdf 字号标题、png OCR 均正确），broken.docx 兜底告警不崩，完整 `import-doc` 落 content.md + 真 original.pdf + 建索引全绿。**M2 App 仅编译验证**（用户录音中，未 `killall` 重建）。

**未做/留后续**：macOS 26 的 Vision `RecognizeDocumentsRequest`（结构化表格/列表，以后 `#available` 接）；Excel；P4 在线源；内嵌图片图注 OCR。PDF 表格/多列在 14.5 受 PDFKit 文本层限制偏弱（已记取舍）。

---

## 文档模块 P2：纪要生成纳入关联文档（编译通过，待实机验收）（2026-06-25）

**背景**：P1 把文档做成与录音平级的检索/问答来源后，用户的原始诉求「文档辅助 LLM 生成」进入 P2。经三轮澄清锁定**最小形态**：录音侧「会议摘要」生成时自动把本场关联文档当背景。spec [specs/2026-06-25-documents-p2-summary-with-docs-design.md](superpowers/specs/2026-06-25-documents-p2-summary-with-docs-design.md)。

**三个定调决策**：①核心形态=增强现有录音侧纪要（非独立生成新文档）；②文档注入=**全文 + 字数上限兜底**（非检索式裁剪）；③可见性=**自动用 + 可见**（复用 P1 的「相关文档」卡 + 摘要区一行提示）。

**做了什么**：
- Core：`Document.swift` 加 `linkedDocumentTexts(vaultRoot:recordingId:)`（按 document.yaml.links 反查关联文档正文）；`Prompting` 加 `maxReferenceDocChars=16000`；`Summarizer` 加 `buildReferenceDocsBlock`（拼「参考文档」块，顶部消歧提示，超限边界截断+标注「已截断」/「其余 N 篇未纳入」）；`summarize(referenceDocs:)` 加 `{documents}` 占位符（模板含则用、不含但有文档则注入到 `{transcript}` 前——镜像现有 `{transcript}` 兜底）。
- **关键决策：gather 放在 Core 的 `IndexPipeline.summarizeRecording`**（从 `config.vaultPath` 反查 + 传 referenceDocs），而非 App 各处——所有摘要触发路径（手动生成 / 重新生成 / 录音入库后自动摘要）**一处改、全路径生效**，比原 plan 的「App 侧 gather(T2.1)」更省更不易漏。
- App：`LibraryView` 摘要区加可点提示「本场关联的 N 篇文档已作为背景纳入」（点击滚到上方「相关文档」卡，复用 ScrollViewReader + `id("rs-related-docs")`）；空状态加「将纳入 N 篇文档」提示。Templates 页占位符说明 + 插入 chip + `SummaryTemplate` 注释加 `{documents}`。README 双语 + STATE/DECISIONS 同步。

**取舍**：
1. **不持久化「本次实际用了哪几篇」**：提示由当前 links 实时推导，事后改关联会轻微不一致——可接受，省存储 schema。
2. **全文+上限**而非检索式裁剪：会议文档多为中等体量，全文最忠实；检索式留作后续可选。
3. **零回归是硬约束**：referenceDocs 为空时 `summarize` 组出的 prompt 与改动前逐字节一致（{documents} 不注入、replace 为 no-op）。
4. **消歧提示**写进块顶（「文档是背景、请优先以转录为准，别当成会上说过的话」），降低 LLM 把文档内容误当作发言。

**未做（仍留后续独立 spec）**：Documents 页独立「生成新文档」(手选多来源)、Ask 答案存成文档、P3 富格式、P4 在线源。

**待实机验收**：①给录音关联文档→生成摘要应体现文档背景+提示出现；②无关联→同今天（零回归）；③超长文档→截断不崩；④模板手写 `{documents}`→位置正确。

## 文档模块 P1 UI 接线落地（M3，App 编译通过）（2026-06-25）

**做了什么（Wave 3，按用户的 Claude Design handoff 设计稿 `Resound.dc.html` 落地）**：
- **主题/导航**：Theme 加 `doc`/`docSoft` 蓝色 token（浅 `#3f72b8` / 深 `#7aa7e0`，取自设计稿），与录音橙、警示色并列；`AppModel.Page` 加 `.documents`；RootView 主导航入口（侧栏 `doc.text` + 角标）、TopBar 标题、content 懒挂载常驻；ResoundApp 注入 `DocumentsModel` 并启动即 `load()`（录音详情「相关文档」反查依赖它，不能等进 Documents 页才加载）。
- **文档主面** [DocumentsView.swift](../Sources/ResoundApp/DocumentsView.swift)：左列表（标题/导入按钮、搜索、标签筛选 chips、导入进度行、文档行带标签+日期+关联数、空态）；右详情（header+编辑/查看原件/删除、元数据标签、关联录音卡、tab=文档/向本文档提问）。正文用 `SummaryMarkdown` 渲染；「向本文档提问」镜像 recAskTab（打字机+本篇引用折叠）。
- **导入/关联弹窗**（DocumentsView 内两个 struct，自带 @State 表单）：`DocImportModal`（选择文件/粘贴文本切换 + 标题 + 标签 chips）；`DocLinkPickerModal`（两模式 staged：fromDoc 选录音 / fromRec 选文档，复选 + 「完成」才落盘；fromRec 还有「导入新文档…」自动回关）。编辑/删除模态在 Overlays。
- **关联双向**：DocumentsModel 重构 link picker 为 `LinkPickerMode{fromDoc,fromRec}` + `linkWorking` 工作集 + `applyDocLinks`/`applyRecLinks`（后者对受影响的每篇文档增删 `recording:<id>`）；`relatedDocuments(forRecording:)` 给录音详情反查。录音详情 [LibraryView.swift](../Sources/ResoundApp/LibraryView.swift) 加「相关文档」卡（PlayerBar 与 tabBar 之间）。
- **Ask 跨源引用** [ChatView.swift](../Sources/ResoundApp/ChatView.swift)/[ChatStore.swift](../Sources/ResoundApp/ChatStore.swift)：`Cite` 加 `isDoc/docId/docTitle`（StoredCite 同步、缺省 false 向后兼容）；`ask()` 按 `hit.isDocument` 分流；MessageRow 引用卡分「🎙️录音(橙、点击跳录音)」「📄文档(蓝、点击跳文档)」；点文档引用→`DocumentsModel.openFromCite(docId:snippet:)` 切到 Documents、选中、正文 tab、`docHighlight` 在正文上方显示被引原文高亮卡。

**取舍**：
1. **正文渲染复用 MarkdownUI（`SummaryMarkdown`）**，不照搬设计稿的手写 markdown block 渲染器——保持全 App 一致、复用既有高质量渲染。代价：无法精确高亮「被引的那一段」，故文档引用跳转改为「正文上方一张高亮卡展示被引原文」，达成「看到被引内容」的意图。后续若要精确段落高亮需引入带 anchor 的 block 渲染器（留作 P 后续）。
2. **DocumentsModel 启动即全量 `load()`**（不像 Library 的 prefetchCount 懒加载）——因为录音详情「相关文档」要随时反查，文档扫盘很轻（小 yaml），值得。
3. **改关联不重 embedding**（沿用 M2 决策）；关联事实源是各 document.yaml 的 links，`doc_links` 表只是检索镜像。

**待实机验收**：侧栏入口/角标、导入(文件+粘贴)→建索引→入列表、详情正文/编辑/删除/查看原件、关联双向(三入口)、全局 Ask 文档引用+跳转高亮、向本文档提问。

## 开源：repo 设为 public + 体检（2026-06-25）

**做了**：把 `Wynne-cwb/resound` 设为公开前的安全体检 + 收尾。结论：代码与全部 git 历史**无任何 key/token 泄露**，`.env`/`*.sqlite`/`vaults/` 从未进过 git。处理项：①`experiments/diar-py/*.py` 写死的 `/Users/wb.chen/...` 绝对路径 → `os.path.dirname(__file__)`（不再泄露用户名）；②README 拆**英文为主双语**（[README.md](../README.md) + [README.zh-CN.md](../README.zh-CN.md)），顶部互切；③`.gitignore` 补 `__pycache__/`。**坑/取舍**：提交者邮箱（QQ）在全 commit 上，公开即永久——用户判断可接受，**不改写历史**（改写会变所有 SHA、收益低）。私有 vault repo `wayne-resound` 含个人数据，**不应在公开文档当模板**：删掉 README 的模板 TIP，改成「从零建自己 Vault」可复制脚手架；data-contract/DECISIONS/CLAUDE 里的具体引用泛化为 `<你>/my-resound-vault`（名字仍残留在旧 commit 历史里，但私有 repo 名≠访问权，无实际风险）。

## 文档模块 P1 视图模型落地（M2，App 编译通过）（2026-06-25）

**做了什么（Wave 2，无 UI 依赖，为 M3 接线准备）**：
- Core 补 [Document.swift](../Sources/ResoundCore/Document.swift)：`DocumentSummary`(Identifiable/Hashable) + `listDocuments`/`loadDocumentSummary` + `DocumentStore.updateManifest`（就地重写 document.yaml 改标题/标签/关联，保留 id/format/importedAt）。
- App 新增 [DocAskStore.swift](../Sources/ResoundApp/DocAskStore.swift)：doc-chats.json 按 docId 分桶（镜像 RecAskStore；文档 cite 只有 snippet，无说话人/时间）。
- App 新增 [DocumentsModel.swift](../Sources/ResoundApp/DocumentsModel.swift)（@MainActor ObservableObject，镜像 LibraryModel）：列表/搜索、导入（文件 NSOpenPanel + 粘贴文本，异步 importDocument+indexDocument，进度 DocImportItem）、编辑元数据、删除、**关联录音双向**（改关联只重写 yaml + `Index.setDocLinks` 镜像，不重 embedding）、**向本文档提问**（answerInDocument + 打字机 reveal + 按 docId 持久化）。

**取舍**：①改关联不重新 embedding——关联是元数据，重写 document.yaml + 更新 doc_links 镜像即可，省去整篇重嵌入。②DocumentsModel 与 LibraryModel 各自持有私有 cfg()/vaultURL()/dim()（轻量重复，避免耦合，与现有风格一致）。③M2 视图模型暂为「未接 UI 的就绪件」，待 M3 拿设计稿后绑定 + 注入 app 环境 + 加主导航入口。

## 文档模块 P1 后端落地（M1，CLI 验证通过）（2026-06-25）

**做了什么（Wave 1 后端，UI 无关）**，按 [plans/2026-06-25-documents-p1-plan.md](superpowers/plans/2026-06-25-documents-p1-plan.md)：
- **T1.1** 新增 [Document.swift](../Sources/ResoundCore/Document.swift)：`DocumentManifest`（resound.document/1：id/title/source_format/imported_at/tags/links）+ `DocumentStore`（写 documents/YYYY/MM/<id>/ 的 document.yaml+content.md+original；日期-slug id，冲突追加序号）+ `parseDocumentManifest`/`documentContent`/`findDocuments` 自由函数。复用既有 `slugify`/`iso8601`（删了重复定义）。
- **T1.2** [Index.swift](../Sources/ResoundCore/Index.swift)：`chunks` 加 `source_kind`('recording'|'document', default recording) + `doc_id`（`addColumnIfMissing` 增量迁移）；新增 `documents`/`doc_links` 表；`insertChunk` 的 recordingId 改可空 + 加 sourceKind/docId；`SearchHit` 加 sourceKind/docId/docTitle；`vector/ftsSearch` select 出新列 + left join documents 取标题 + 加 docId scoping；新增 upsertDocument/deleteChunks(docId:)/setDocLinks/documentsLinked(toRecording:)/deleteDocument。
- **T1.3** Chunker 加 `chunk(text:)`（无时间轴：空行/Markdown 标题分块，累积到 targetChars 切，超 maxChars 硬切，start/end=0）；IndexPipeline 加 `indexDocument`/`indexOneDocument`（读 yaml+content→切块→enrichment+embedding 复用→insertChunk(document)+镜像 doc_links；recording_date=null 故不参与时间过滤），`build` 加 documents/ 并行循环。
- **T1.4** CLI 新增 `import-doc <file> --vault [--title --tags --link --index --no-context]`（无头验证主入口）；注册进 subcommands。
- **T1.5** IndexPipeline `search` 加 docId 参数；新增 `answerInDocument`（按 docId scoping）；Synthesizer 与 CLI Ask「来源」按 sourceKind 区分 `📄文档：标题` / `🎙️录音 日期 id @时间 👤人`。

**验证（CLI，真跑 embedding + chat；临时 vault/index 不污染真实数据）**：
1. 导入一篇含独有事实的 md（--no-context）→ vault 结构正确、1 chunk 入库 source_kind=document；
2. 纯文档问答 → 答案命中 + 来源标 `📄`；
3. 真实旧 index 打开自动迁移出 source_kind/doc_id 两列，录音问答零回归（🎙️ 引用含说话人+时间完好）；
4. **真·跨源**（复制真实 index + 加该文档）问横跨问题 → 一段答案里同时引用 📄文档[1] 与 🎙️录音[2-8]，正确区分。

**坑/取舍**：①`slugify`/`iso8601` ResoundCore 里已有（IngestPipeline），首版重复定义致编译冲突 → 删重复、复用现有（slug 加 60 字上限）。②文档块 `recording_date=null`：有意为之——避免「上周导入的文档」污染「上周的会议」这类时间过滤查询；文档仍进全局/无时间过滤问答。③`insertChunk` recordingId 由 String 改 String?，旧录音调用（传 String）隐式兼容、零改。

## 文档模块 P1 设计（地基）（2026-06-25）

**背景**：Resound 定位「会议知识库」，会议常伴文档做信息同步，需支持文档上传并与录音结合、辅助 LLM 检索与生成。整体是大方向（3 类生成诉求 + md/PDF/docx/PPT/在线多格式），故**分期**，本轮只设计 **P1 地基**。spec：[superpowers/specs/2026-06-25-documents-p1-design.md](superpowers/specs/2026-06-25-documents-p1-design.md)。

**关键决策（与用户对齐）**：
- **D1 文档=wiki 一等公民，可关联 0~N 场录音、也可不关联**（不是「会议附件」）。最 wiki-native，现有 `notes/`+`chunks` 几乎已备好。
- **D2 主干方案 A：边缘归一化**——各格式入库转纯文本/markdown，下游只认归一化文本、原件留档；结构感知（页码/页号）作后续增量增强（方案 B），外部转换器/LLM（方案 C）仅难格式局部兜底、默认本地优先。
- **D3 分期 P1→P4**：P1 地基（md/txt 一等公民+跨源检索问答+手动关联）/ P2 生成 / P3 富格式抽取(PDF/PPT/docx，OCR 最后) / P4 在线集成(Google Docs/Notion/URL)。第一期即可用，不必等所有格式做完。
- **D4 `documents/` 与 `notes/` 分两个实体**：notes=app 内手写自由笔记；documents=导入的外部文档（带原件/格式/导入溯源）。P1 都是 md 但语义与未来不同。

**技术地基（已核对现状）**：检索/问答管线（hybrid→RRF→rerank→synthesize）是 **source-agnostic** 的——文档切块进 `chunks` 即自动可检索/问答；`chunks` 的 source 本就是个 `recording_id` 文本列、`start/end/person_id` 可空。P1 后端改动仅三处：① vault 新增 `documents/<id>/`(document.yaml + content.md + original) ② `chunks` 加 `source_kind`('recording'|'document') + `doc_id` 两列（`addColumnIfMissing` 增量迁移）+ `doc_links` 镜像表 ③ 复用 Chunker/embedding 的文档 ingest 循环。问答引用按 `source_kind` 区分 🎙️录音(跳时间轴)/📄文档(跳原文段落)。

**UI（功能定，视觉交 Claude Design）**：5 个功能面=文档主面/导入流程/文档详情(含「向本文档提问」)/关联录音(双向)/问答跨源引用区分。spec §8.1 附**不预设视觉方向**的 handoff prompt，用户拿去让 Claude Design 出图。

**下一步**：用户 review spec → 转 writing-plans 出实现计划。

## 会议自动开始/停止录音（对称双开关 + 起止弹窗）（2026-06-25）

**需求**：①会议结束自动停录；②设置里加「会议开始自动开录」开关。追加：自动停录也做成开关，且**会议结束时弹「停止录音？」一键弹窗**（关掉自动停时）。

**最终模型（对称）**——通用区两个新开关，行为左右对称：
- **自动开始录音**（`resound.toggle.autostart`，默认关）：检测到会议→ON 直接开录 / OFF 弹「会议已开始」卡片由用户确认。
- **自动停止录音**（`resound.toggle.autostop`，默认关）：会议结束→ON 直接停录+转写 / OFF 弹「会议已结束 · 停止录音？」一键卡片（录音继续，用户点「停止录音」才停）。
- 顺手把原本**未接线**的「自动检测会议」(`autodetect`) 真正接上：`.started` 时若它为 false 则既不提示也不录。删掉原同样未接线、且与「自动开始」语义矛盾的「显示录音提醒」开关。

**实现要点**：
- `MeetWatcher.watch` 加 `endConfirmations`（连续 N 轮检测不到才判 `.ended`，默认 1；RecordingController 传 2≈10s）——Chrome 标签轮询/麦克风占用会瞬时抖动，自动停录依赖 `.ended`，误触发会把录音中途掐掉，故防抖。
- `RecordingController`：`startRecording(fromMeeting:)` 标记录音是否会议触发（手动工具栏录音 `fromMeeting=false`，**会议结束不影响手动录音**）；保留零参 `startRecording()` 给工具栏按钮（避免方法引用 + 默认参数歧义）。新增 `@Published promptStop`（结束待确认）+ `confirmStopFromPrompt`/`dismissStopPrompt`。开关值用 `UserDefaults` 直接读（SettingsModel 写、Controller 读，始终最新，免耦合）。
- `MeetingPanel`：浮窗改为同时订阅 `$phase` 与 `$promptStop`→`refresh()` 决定显示开始卡/停止卡/隐藏；`MeetingPopupCard` 泛化成 headline/subtitle/primary/secondary + `isStop`（停止态主按钮用录音红 `pal.rec` + stop 图标）。
- **仅会议触发的录音**才会自动停/弹停止窗；停止弹窗出现时录音仍继续，点「继续录音」只关弹窗。

**待验收**：①设置通用区出现「自动开始/自动停止录音」两开关；②开自动开始→进 Meet 自动开录；③开自动停止→离会自动停+转写；④关自动停止→离会弹「停止录音？」，点停止即停、点继续录音继续；⑤手动工具栏录音不被会议结束影响；⑥短暂网络/标签抖动不会误停（10s 防抖）。

---

## 「向本场提问」：录音详情新增第三 Tab，检索限定单条录音（2026-06-25）

**需求**：用户想针对**某一条录音**做 Ask（不是全库）。Claude Design 出了设计稿（handoff `Resound-handoff (1).zip` → `Resound.dc.html`）。录音详情区从两个 Tab（会议摘要 / 逐句转录）增加第三个 **向本场提问**。

**设计要点（照还原）**：空态只一个输入框「就这场会议提问…」+ 脚注「仅检索本场会议 · 本地模型生成，请核对引用。」；有对话时右上「重置对话」+ 消息流（用户右气泡、助手左带波形头像）+ loading 文案「正在检索这场会议… / 正在阅读相关片段…」+ 打字机光标 + 可折叠「本场引用 · N」（每条引用=说话人+时间+斜体原文，点击跳到逐句转录对应时间）；每轮用户提问前有时间分隔（首条显示时间、间隔>20min 显「继续对话 · 时间」）。

**实现**：
- **检索限定单录音**：`Index.vectorSearch/ftsSearch` 加 `recordingId: String?` 过滤（`and c.recording_id = ?`；vec 的 KNN 不支持前置过滤→限定时把候选放大到 4000 再过滤，同 dateRange 的处理）。`IndexPipeline.search` 透传 `recordingId`；新增 `answerInRecording(question:recordingId:…)`——**不走 QueryPlanner**（单录音无需时间范围/digest 判定），直接 hybrid+rerank→Synthesizer。
- **持久化**：新增 [RecAskStore](../Sources/ResoundApp/RecAskStore.swift) 落盘 `~/Library/Application Support/Resound/rec-chats.json`，按 `recId` 分桶（切录音/重启各自保留，不进 vault）。与全局 Ask 的 `conversations.json` 分开。
- **Model**：`LibraryModel` 加 `DetailTab.ask` + `RecAskMsg`/`RecCite` + `recChats[recId]`/`recAskBusy`/`recCiteOpen`；`askRecording`/`clearRecChat`/`toggleRecCite`/`openRecCite(time:)`（切到逐句转录+定位+跳播）；打字机 `recReveal` 计时器（同 ChatVM 节奏）；引用说话人用 `hit.personId ?? speakerAt(start)`（从已载入 lines 映射）；删录音连带删本场对话。
- **View**：`recAskTab` + `recMsgView`/`recAssistantBody`/`recCitesView` + 文件作用域 `RecAskInputBar`（本地 @State，键入不写 LibraryModel.@Published、不波及详情）；detailScroll 在 `recMsgs.count` 变 / `recAskBusy` 转 false 时滚到底部锚点 `recAskBottom`。
- 复用既有 `SummaryMarkdown`（done 富文本）、`WaveMark`/`Spinner`/`mmss`/`card`/`stroke` 等。

**待验收**：①详情区出现第三 Tab，空态/有对话态视觉对；②就某条录音提问能返回**只基于该录音**的答案 + 本场引用，点引用跳到逐句转录对应时间；③切到别的录音是各自独立的对话、重启后仍在；④「重置对话」清空。

---

## 踩坑：录音后在 Library「找不到」——keep-alive 下 reloadLibrary token 丢失（2026-06-25）

**现象**：用户录了一场会议、转录也成功，但 Library 里找不到。排查：磁盘 38 条录音、App 只显示 37，缺的正是最新这条（`2026-06-25-1002-os-migration-regroup...`，audio/transcript/diarization/summary/git 提交**全在**，`recording.yaml` 干净可解析、`listRecordings` 重扫必返回它）。即数据没丢，是**内存列表漏掉了**。

**根因**：录音落库后 `RecordingController` 只 `app.reloadLibrary()` bump `libraryReloadToken`，靠 `LibraryView.onChange(of: token){ vm.refresh() }` 去重扫。但性能优化那轮把页面改成**懒挂载 + keep-alive**（[RootView](../Sources/ResoundApp/RootView.swift) 的 `mounted` 集合 + `pageVisible`）：录音时若用户还没进过 Library 页，LibraryView 没挂载 → `.onChange` 不存在 → token bump 直接丢；而 `.onAppear{ vm.load() }` 又幂等（`didInitialLoad` 只跑一次），切页回来也不再扫盘。于是这条永远进不了 `recordings`。**对比**：导入流程（`LibraryModel.ingestOne`）一直是直接 `insertRecording(sum)` 塞进数组、不依赖 token，故从不丢——录音流程没对齐这套，就是 bug。

**修复**：新增 `LibraryModel.addRecorded(sum)`（= `insertRecording` + `enqueueSpeakerID`），`RecordingController` 成功分支改为直接 `library?.addRecorded(sum)`（仍保留 `reloadLibrary()` bump 给已挂载的 LibraryView 顺带全量刷新，幂等）。和导入同样稳，与 LibraryView 是否挂载无关。**老的那条**靠重启冷启动全量扫盘即恢复（已重启验证）。**教训**：keep-alive 懒挂载后，任何「靠某页 `.onChange`/`.onAppear` 才生效」的副作用都可能在该页未挂载时丢失——跨页状态更新应直接打到 model，别绕 view 的生命周期。

**同源 bug（同日，紧接着发现）**：进 Library → 关主窗口 → 菜单栏重开 → 内容区**全白**。根因同样是 keep-alive 的 `mounted` @State：关窗再开会**重建 RootView**，`mounted` 复位成 `[.ask]`，但 `app.page`（App 级 @StateObject 不重建）仍是 `.library` → `mounted.contains(.library)` 为 false 故不渲染，而 `.ask` 又被 `pageVisible` 隐藏 → 啥都不显示。`.onChange(of: app.page)` 只在 page **变化**时插入，重开时 page 没变所以补不上。修复：`content` 加 `.onAppear { mounted.insert(app.page) }`，RootView 一出现就确保当前页在挂载集合里。**教训补充**：用 @State 缓存「挂载过哪些页」时要记住它会随 view 重建丢失，凡当前必须可见的状态都要在 onAppear 兜底重建。

---

## Settings 重设计（Claude Design handoff 还原）（2026-06-25）

**触发**：Settings 功能越堆越多、一条长滚动太挤。用户在 Claude Design 重做了设计稿（handoff zip：`Resound.dc.html`），让我还原。

**设计要点（照还原）**：
- 整页 = 固定 **header**（标题「设置」+ 本地处理副标题）+ 下方 **左侧子导航栏(206px) + 右侧单区内容**。子导航五项：AI 服务 / 存储与同步 / 权限 / 通用 / 专有词表；选中态 = accentSoft 底 + accent 字；AI 项/权限项带 warn 圆点（providers.needsOnboarding / vm.needsAttention）；栏底「全程本地 · 即时生效」小卡。右侧内容 maxWidth 680 居中、每次只显示选中区。
- **AI 服务区 = 三张手风琴卡**（最大改动）：收起只显示 图标 + 标题 + 必填/可选标 + 「服务商 · 模型」摘要 + 验证状态药丁（未验证/测试中/已验证/验证失败）+ 旋转 chevron；展开露出表单。**服务商、模型预设由原横向芯片改成下拉菜单**（SwiftUI `Menu`），API Key 加显示/隐藏眼睛，转写区「在线服务 / 本地 Whisper」分段切换（本地显示 whisper-large-v3 内置卡）。设置页单卡展开（手风琴，点另一张收起当前），首启引导里 `collapsible:false` 常驻展开——同一个 `CapabilityCard` 复用。
- 存储区：录音库目录卡（文件夹图标 + 路径/未设置 warn + 选择目录）+ 版本同步卡（git 开关）+ 保存。权限/通用：单卡分隔行。词表：标题+新增、智能建议收件箱（accentSoft 头）、>8 条出搜索、列表卡、空态。

**补漏（用户发现）**：旧 UI 一直没暴露**转录后 AI 校对**（`transcribeCorrect` 默认开 + `correctModel`，跑在 chat 服务商上、迁移默认 flash 省成本）。按用户选择放进**对话模型卡**底部：开关 + 校对模型框（默认跟随对话模型，可填更便宜的）。`transcribeCorrect` 提升进 `ProvidersConfig`（原只在 .env），`toConfig` 优先用它否则回退 .env/true。另：用户发现对话模型被手滑改成了 flash（非 bug，.env 原值 pro），UI 改回即可。

**后续打磨（同日）**：①「预设/服务商」下拉原用原生 `Menu`，与设计稿不一致 → 改成**自定义下拉**（字段正下方整宽面板、等宽模型名、选中打勾，inline 展开不浮层，靠单一 `openMenu` 状态切换）。②删掉 Settings 左导航底部 + 主侧栏底部两张「全程本地」凑数卡片。③**验证状态持久化**：原 `probe` 仅内存，重启变「未验证」。改为把验证指纹（`baseURL|apiKey|model`）按能力存进 `providers.json` 的 `verified`，启动/导入时指纹一致即恢复「已验证」；`set()` 一旦改了 Provider/BaseURL/Key/模型指纹不匹配即失效。④**侧栏 Library 角标启动即正确**：性能优化后 Library 懒加载，没进过就显示 0；新增 `prefetchCount()` 启动时后台只数 `listRecordings().count`（不加载详情/声纹/sqlite），`recordingCount` 由 `recordings.didSet` 同步为权威值。

**实现**：纯重皮 + 重排，ProvidersModel/SettingsModel 逻辑零改（仅新增 setCorrection / 验证指纹持久化 / prefetchCount）。[SettingsView.swift](../Sources/ResoundApp/SettingsView.swift) 重写为 header+rail+content（Tab 枚举 + 本地 @State），StorageContent/VocabContent 各自本地 @State（沿用性能约定不每键失效整页）；[ProvidersView.swift](../Sources/ResoundApp/ProvidersView.swift) 的 CapabilityCard 重写成手风琴 + 下拉。主题 token 与现有 Palette 一一对应，无需新增颜色。编译+打包+启动通过，待实机验收。

## 开源化第一步：AI Provider 配置 + 验证 + 首启引导（2026-06-25）

**触发**：要把 Resound 做成开源可下载软件。原配置为个人写死（chat=DeepSeek、embedding=AIHUBMIX），无 provider 概念、不能验证、新用户无从下手。

**用户拍板（AskUserQuestion）**：① provider 范围 = **OpenAI 兼容预设 + 自定义**（不做原生 Anthropic，Claude 经 AIHUBMIX/OpenRouter 兼容端点用）；② 首启 = **引导页 + 强制门禁**，但**转写是可选 Provider，不配则兜底本地 WhisperKit**（只有 chat+embedding 强制）；③ 验证 = **chat+embedding 实时验证**，**填了转写也要验证**。

**架构决策**：`Config` 作为运行时契约**不动**（CLI+App 20+ 处零改动），背后换数据源——新增 `providers.json`（App Support）作为 GUI 真源，`Config.load()` **优先读它（chat+embedding 配齐时）、否则回退旧 `.env`**（dev/CLI 无缝）。vault 路径等非 provider 项仍留 `.env`。**能力中心式**建模（不做"provider 池+指派"那套）：chat/embedding/转写三个能力各管一条专属 provider（id `p-chat`/`p-embed`/`p-transcribe`），契合用户"至少一个 chat、一个 embedding"的原话、UI 最简。

**落地**：
- Core 新增 [Providers.swift](../Sources/ResoundCore/Providers.swift)（`AIProvider`/`ModelRef`/`ProvidersConfig`/`ProvidersStore` + `ProviderPreset.all` 七个预设：OpenAI/DeepSeek/OpenRouter/Groq/SiliconFlow/AIHUBMIX/Ollama，各带 baseURL+建议模型+取 key 链接 + `.env→providers.json` 一次性迁移）、[ProviderProbe.swift](../Sources/ResoundCore/ProviderProbe.swift)（chat/embedding/transcribe 三种实时探测；统一把 401/404/超时/TLS 翻译成中文；embedding 顺带返回真实维度取代写死 4096；transcribe 在内存合成 0.3s/16k WAV 测 `/audio/transcriptions`，零打包资源）。改 [Config.swift](../Sources/ResoundCore/Config.swift)：`load()` 加 providers.json 优先分支，旧逻辑抽成 `loadFromEnv`。
- App 新增 [ProvidersModel.swift](../Sources/ResoundApp/ProvidersModel.swift)（能力增删改/验证/落盘/导入导出 providers.json/`needsOnboarding`）、[ProvidersView.swift](../Sources/ResoundApp/ProvidersView.swift)（可复用 `CapabilityCard`：预设芯片+Base URL+Key+模型下拉+测试✓✗，本地 @State 草稿仅在提交点回写——沿用性能约定 + 设置页 `ProvidersSection`）、[OnboardingView.swift](../Sources/ResoundApp/OnboardingView.swift)（单页三卡，chat+embedding 验证通过才解锁"进入"）。Settings 旧"连接与模型"裸字段 → `ProvidersSection`+`StorageSection`（vault 仍走 .env）。RootView 加 `app.showOnboarding` 门禁。
- **迁移保真踩坑**：旧 `loadFromEnv` 里 `correctModel`/`rerankModel`/`contextModel` 缺省硬编码 `deepseek-v4-flash`（省成本），.env 没这些键 → 初版迁移回退到 `chat.model`(pro)= 把 AI 校对偷偷升级、更贵更慢。修：迁移时精确补回 flash 默认，零行为变更。

**验证**：编译通过；删旧 providers.json 后重启实测——迁移正确生成（chat=DeepSeek/deepseek-v4-pro、embedding=AIHUBMIX/qwen3-embedding-8b 维度 4096、transcribe=AIHUBMIX/whisper-large-v3-turbo、correctModel/rerankModel=flash、summaryModel=nil→回退 pro），老用户 isComplete=true 故不弹引导。**待用户实机验收**：①Settings 三张能力卡是否正确预填+「测试连接」对各 provider 真能报通/报错；②临时删 providers.json 重启是否进引导、配 OpenAI 等异构 provider 能否走通；③embedding 验证后维度是否自动写对。

## 性能审计 #2：三页卡顿根因 + 深度优化（2026-06-25）

**触发**：用户报 Ask 折叠按钮折叠时卡、切 Library 卡、Settings 偏卡。用 workflow（`resound-perf-audit`）并行审计四区（Ask/Library/Settings/公共层）→ 逐条敌对验证 → 统合，确认 7 条真卡点，找到跨页**共同根因**。

**共同根因（最高优先，亲自核对属实）**：`Palette` 是**非 Equatable** struct（Theme.swift），且 `AppModel.palette` 每次访问都 `.make(dark:)` 现造新实例（AppModel.swift），`RootView.body` 又把它 `.environment(\.palette,)` 注入全树。SwiftUI 对非 Equatable 的 environment 值无法判等 → 每次注入都当变更 → 所有读 `@Environment(\.palette)` 的子视图（几乎整棵树）失效。RootView 同时观察 AppModel + RecordingController，于是**侧栏折叠动画（每帧改 sidebarCollapsed）/ toast / 录音计时器**都会每帧重建 Palette → 整棵树（含 Ask 的 Markdown）重渲染。**这正是「折叠按钮折叠时很卡」的元凶**（折叠按钮= RootView 里的侧栏 toggle，带 withAnimation）。

**修复（7 项，按优先级）**：
1. **Palette: Equatable + AppModel 缓存**（共同根因，几行）：`struct Palette: Equatable`（成员全 Bool/Color 自动合成）；AppModel 把 palette 存成 `@Published private(set)`，仅 isDark.didSet 时重建。→ 折叠/toast/录音时即便 RootView.body 重算、注入的 Palette 相等，SwiftUI 跳过全树环境失效。**单点掐断三页放大器**。
2. **录音计时器相等守卫**（RecordingController.swift）：`if v != recSeconds { recSeconds = v }`，4×/s → 1×/s 的 @Published 通知。
3. **Ask 消息行抽 `MessageRow: View, Equatable`**（ChatView.swift）：打字机 ~60fps 改 `@Published msgs` + 折叠 `expandedCites` 都会重算 ChatView.body，原 messageRow 是 @ViewBuilder 函数无法剪枝 → 每次重求值所有历史消息（含 SummaryMarkdown 重跑 cmark）。改 `.equatable()`（比较 id/phase/revealed/full/cites.count/expanded/pal）→ 只重渲染变化的那一行，其余整片剪枝。
4. **Ask 输入栏抽 `InputBar: View, Equatable`**（本地 @State 文本）：键入不再写 `$vm.input`（@Published）→ 不失效消息列表；resetToken=currentId 切换对话时清草稿。
5. **Settings 抽 `ConnectionSection` + `VocabBrowser` 子视图**（各持本地 @State）：原 API Key/URL 字段绑 `$vm.editConfig.*`（整 @Published struct）、搜索框绑 `$vm.vocabFilter`，每敲一字重算整页（权限/通用/词表 ScrollView）。下沉到本地草稿，仅「保存」时回写 vm（`saveConfig(_:)`），导入/选路径经 `onChange(of: vm.editConfig)` 同步。`EditConfig: Equatable`；删掉 vm 上的 vocabFilter/filteredVocab 死代码。子视图自带精简 helper 与父视图隔离（不动父视图既有 helper，最低风险）。
6. **Library 切页幂等**（LibraryModel.swift）：`load()` 加 `didInitialLoad` 守卫——切到 Library 不再无条件 `reload→refreshDetail`（原会先把转录/名册塌空再后台重解码 JSON+flatten+roster，啥都没改也重算两轮）。拾取新录音改由 `libraryReloadToken` → `refresh()`。
7. **Library 日期格式化器单例化**（LibraryView.swift）：ISO8601/DateFormatter 提为文件级 `let` 单例（创建昂贵），原每行每次重绘现建 3 个。

**追加修复（用户反馈「打开对话后频繁切 Ask↔Library 仍很卡」）**：上面 7 项降的是「重渲染」成本，没动「重建」成本。根因在 [RootView.swift](../Sources/ResoundApp/RootView.swift) 的 `content` 用 `switch app.page` 返回不同视图类型 → **每次切页旧页整个销毁、新页从零重建**：打开了对话的 Ask 切回来要把整段对话所有 Markdown 重新解析+重新布局（`MessageRow.equatable` 只在「已存在视图重渲染」时剪枝，对「从零创建」无效）。**修复**：改成「懒挂载 + 保活」——`mounted: Set<Page>`（只增不减，默认含 .ask），content 用 ZStack 把**访问过的页面常驻**，切页只切 `pageVisible`（opacity + allowsHitTesting + disabled + zIndex），不再销毁重建。`disabled(!visible)` 同时屏蔽隐藏页的快捷键（防隐藏 Library 抢 ⌘F）。懒挂载避免启动即扫盘 Library / 全载 Settings。注：模型都是 App 根级 @StateObject（[ResoundApp.swift](../Sources/ResoundApp/ResoundApp.swift)），保活的是视图树、状态本就持久。SettingsView 不观察 app 故切页不重算；ChatView/LibraryView 观察 app 切页会重跑 body，但有 equatable/sections 缓存兜底只构造结构、不重渲 Markdown，成本可接受。

**再追加修复（用户反馈「切导航/折叠仍卡，且都发生在 Ask、Library 显示 Markdown 时」）**：定位到真正的大头——**MarkdownUI 在 body 里解析 cmark，而 ChatView/LibraryView 都 `@EnvironmentObject var app`，于是 app 上任意 @Published 变化（尤其侧栏折叠动画每帧改 `sidebarCollapsed`、toast 显隐）都让两页 body 频繁重跑**。Library detail 的 `SummaryMarkdown`（[LibraryView.swift](../Sources/ResoundApp/LibraryView.swift):491）**没有 Equatable 边界** → 每帧重新解析整段摘要 = 卡（Ask 的消息行有 MessageRow.equatable 保护，但 `==` 里比较整个 Palette 25 个 Color、×N 条也有成本）。**修复**：①`SummaryMarkdown: View, Equatable`（比较 text+highlight+pal.isDark；text 同实例时 == 走 O(1) 缓冲区判等）+ 调用处加 `.equatable()` → 容器 body 重跑也不重解析；②所有 Equatable 视图（MessageRow/InputBar/SummaryMarkdown）的 `==` 一律用 `pal.isDark`（O(1)）而非整个 Palette。**关键认知**：keep-alive 解决了「切页重建」，但没解决「容器因观察 app 而 body 频繁重跑时，内部重内容（Markdown）被重新构造解析」——重内容必须有自己的 Equatable 边界才能在父 body 重跑时被剪枝。

**最终修复（埋点实测后定位，推翻前几轮猜测）**：前几轮（Equatable/keep-alive/瞬时折叠）凭推理改，用户反馈「反而更卡」。遂加性能埋点 [Perf.swift](../Sources/ResoundApp/Perf.swift)（主线程卡顿看门狗 + 各 view body 计数 + 关键块计时 → 写 resound.log，`Perf.enabled` 开关；排查完置 false），让用户复现后读数据。**数据结论（颠覆性）**：①body 重算次数全程个位数、`SummaryMarkdown(parse)` 每秒 0~2 → Equatable 优化早已生效，**根本没在疯狂重渲染**；②但主线程卡顿高达 500ms~1.8s，**与 body 次数无关** → 真凶是 **MarkdownUI「构建+布局一篇文档」单次就要 500ms~1s**（主线程），keep-alive/瞬时折叠只是挪动「何时布局」、没减少布局本身。**真正的大杀器**：Ask 消息列表是**饿汉 `VStack`**——打开长对话时**一次性给每一条消息的 Markdown 做布局**（N×单篇成本，叠成几秒）。改成 **`LazyVStack`** 后只渲染屏幕内可见的几条 → 切换 Ask↔Library 从 460~950ms 卡顿降到多数 0、偶尔 100~300ms。配套保留：keep-alive（切页不重建视图状态）+ 瞬时折叠（避免动画逐帧重排）。残留：停在 Library 摘要页折叠时，那**一篇**摘要仍重排一次（~300~600ms 单次 hitch），用户拍板可接受、暂不处理（彻底解需让内容区宽度不随折叠变，或换原生 AttributedString 渲染——有取舍）。**最大教训：性能优化必须先埋点测量，不要凭 SwiftUI 直觉猜——这轮前三次改动方向基本都偏了，数据一上来 5 分钟定位。**

**方法论沉淀**：SwiftUI 卡顿五大反模式（第 4、5 条为本轮追加）：⑤**饿汉 VStack 装可变长列表**——尤其每行含重内容（Markdown）时，一次性布局全部 = 卡；列表一律用 LazyVStack（只渲染可见）。④用 `switch` 做主导航 → 切页销毁重建重内容页。前三条——④用 `switch` 做主导航 → 切页销毁重建重内容页（Markdown/长列表从零重解析）。修法：访问过的页面用 ZStack + opacity 常驻保活，别用 switch 换 identity。前三条————①非 Equatable 的 environment 值注入全树（每注入即全树失效）；②单个大 ObservableObject 承载高频/输入状态（一字一失效全页）；③重内容（Markdown/大列表）所在视图不是 Equatable 子视图、无法被 diff 剪枝。修法对应：environment 值 Equatable + 缓存、状态下沉到本地 @State 子视图、重内容抽 `Equatable` struct 用 `.equatable()`。

全部编译+打包（Resound Dev 签名）+启动通过。**待用户实机验收**：①侧栏折叠是否顺；②切 Library 是否不再卡；③Settings/Ask 输入是否跟手；④Ask 折叠「来源」是否顺。

---

## 转写失败兜底：可诊断 + 不丢音频 + 可重试（2026-06-25）

**背景**：用户昨晚一条导入转写失败，无报错、无重试、无法取回音频，重新导入才成功，现已无法复现。来查日志。

**排查结论（重要踩坑）**：**查不到原因**——根因三连：①失败处理是 `catch { setPendingStatus(.failed) }`，**把 error 直接吞了**；②App 全程 `print` 输出，而 `open` 启动的 GUI App 的 stdout **不进系统统一日志、关掉即丢**（`log show --predicate 'process=="Resound"'` 零条），代码里也无 `os_log`/文件日志；③崩溃报告显示昨晚无 crash → 是流程内部抛错被吞。**教训：关键失败必须落盘，否则不可复现 = 抓瞎。**

**决策：全套兜底（用户选）**，覆盖导入与录音两条路径。

**实现**：
1. **持久化日志** 新增 [AppLog.swift](../Sources/ResoundCore/AppLog.swift)：追加到 App Support `resound.log`，串行队列线程安全，超 1MB 截前半。`AppLog.error(ctx, err)` 带 NSError domain/code。所有 ingest 失败都 `AppLog.error` 落盘。
2. **导入失败可恢复**：`ImportItem` 加 `error`/`source` 字段；抽出 `ingestOne(_:)` 复用（startImport 批量 + 重试 + 录音兜底都走它）；失败行 UI（[LibraryView.swift](../Sources/ResoundApp/LibraryView.swift) `importingRow`）显示**具体原因**（截断+`.help` tooltip 看全文）+ 三个按钮：**重试**（原地重跑）/ **在 Finder 中显示音频**（`NSWorkspace.activateFileViewerSelecting`）/ 移除。
3. **录音(Meet)失败不丢音频**（最危险的洞）：[RecordingController.swift](../Sources/ResoundApp/RecordingController.swift) `stopAndIngest` 重构成两段 do/catch——收尾(混音)失败=无音频可救只报错；转写/入库失败则 `library.recordFailedRecording(url:title:error:)` 把抢救出的临时音频**搬到 App Support/Resound/failed-recordings/**（`preserveFailedAudio`，系统不会清）并登记成失败占位，复用导入失败行的重试/Finder UI。未设 VAULT_PATH 也走同路径（不再静默丢录音）。入库成功则清临时混音。
4. `ingestOne` 对缺 vault 显式置失败带提示（重试无 vault 时也优雅）。

**设计取舍**：录音兜底**复用 `pendingImports` 失败行**而非另造 UI——一套重试/取回交互覆盖两条路径，最省。"下载"在 Mac App 等价于"在 Finder 中显示"（文件就在本地）。

编译+打包+启动通过。**待验收**：制造一次失败（如断网导入）看是否显示原因+能重试+能在 Finder 取回；`resound.log` 是否落下报错。

---

## 5 项 UI/逻辑小优化（2026-06-25）

用户列了 5 个体验问题，一并实现。决定**自己逐个改、不开 subagent/workflow 并行**——4/5 改动集中在 [LibraryModel.swift](../Sources/ResoundApp/LibraryModel.swift) 同一文件，并行 worktree 只会撞合并冲突，串行更干净。

1. **窗口只能从标题栏拖动**。现象：主窗口空白处拖拽会带着整窗跑。根因 `window.isMovableByWindowBackground = true`（[ResoundApp.swift](../Sources/ResoundApp/ResoundApp.swift)）让整个内容背景都可拖窗，之前靠到处贴 `WindowDragBlocker` 打地鼠。**改**：置 `false`（内容区默认不拖窗），自绘顶栏背后加 `TitlebarDragArea`（NSView `mouseDownCanMoveWindow=true`，[LibraryView.swift](../Sources/ResoundApp/LibraryView.swift)）→ 只有这条 46pt 顶栏能拖。系统真标题栏区一直可拖不受影响。残留的 `WindowDragBlocker` 变成无害冗余，留着不动（低风险）。

2. **⌘F 查找替换统一大小写不敏感**。现象：高亮大小写不敏感、替换却敏感，口径不一致。根因 `replacingOccurrences`/`components(separatedBy:)` 默认大小写敏感，而高亮用 `.caseInsensitive`。**改**：新增 `LibraryModel.ciCount`（`.caseInsensitive` 计数），`replaceAll`（转录段+词级、摘要）与 `findMatchCount` 全改 `.caseInsensitive`。`firstMatchLineID` 本就是不敏感。

3. **说话人头像配色稳定 + 按说话占比排序**。现象：同一个人头像底色时而这色时而那色。根因 `speakerColor(index:)` 按**本条录音内首次出现顺序** `index` 取色 → 跨录音/重识别顺序变 → 同一人变色。**改**：`speakerColor(for name:anon:)` 改用名字 **djb2 确定性哈希**取色——同一人无论哪条录音、跨重启都恒定。**关键坑**：不能用 `String.hashValue`，Swift 它每次进程启动带随机种子，会导致每次开 App 都变色。匿名说话人仍统一 `pal.inset` 灰。排序：`makeRoster` 末尾按 `lineCount` 降序（说得多的排前），`index` 字段保留作兼容、已不参与配色。

4. **多录音并发重新生成摘要各自独立状态**。现象：A 正在重生成，切去重生成 B，A 的 loading 状态没了（但后台 A 其实还在跑）。根因 `summarizingId: String?` 单值被 B 覆盖。**改**：`summarizingId: String?` → `summarizingIds: Set<String>`；`runSummary` insert/remove 各自 id（`defer { summarizingIds.remove(rec.id) }`），`summarizing` 计算属性看 `selectedId` 是否在集合内；列表行 `vm.summarizingIds.contains(r.id)`。每条录音独立显示 loading，互不冲掉。

5. **文件夹展开/折叠持久化**。现象：重进 App 折叠状态丢失。**决策**：折叠是**机器本地 UI 偏好、非 vault 事实**，存 `UserDefaults`（key `resound.collapsedFolders`）而非 `library.json`（守数据契约：vault 只放事实）。`toggleCollapse` 即时 `saveCollapsed`，`reload` 的主线程块里 `loadCollapsed` 沿用上次。

验收见 STATE。编译+打包（Resound Dev 稳定签名）+启动通过。

---

## 转录前 VAD 门控：剪静音/噪声减 whisper 幻觉（2026-06-24）

**背景**：用户复盘录音发现很多段没人说话（背景音/杂音）。whisper 这类模型「必须吐字」，在静音/噪声段上三种典型翻车：①**幻觉**——凭空编训练语料高频套话（「谢谢观看」「字幕由…提供」）；②**重复**——decoder 卡循环刷同句；③**时间戳漂移**——长静音把后续段落 start/end 整体推偏。杂音还会污染说话人识别（噪声窗提出垃圾声纹→幽灵「说话人N」）。

**现状盘点**：silero VAD 当时**只用在说话人识别**那条线（切窗给 CAM++），**没用在转录前**；转录是整段原样上传在线 whisper。事后只有 LLM 校对能补救一部分明显幻觉，兜不干净。

**方案对比**：A 转录前 VAD 预切（根治、附带修时间戳漂移+省 token）；B whisper 解码参数收紧（aihubmix OpenAI 兼容端点旋钮有限、效果存疑）；C 后处理幻觉黑名单（治标）。**决策：A 为主**，C 留作后续兜底，B 不碰。

**实现**（新增 [VADGate.swift](../Sources/ResoundCore/VADGate.swift)，接入 [IngestPipeline.swift](../Sources/ResoundCore/IngestPipeline.swift) 在线分支）：
- 复用 `DiarModelCache.shared.vad()` + `AudioConverter` → 取语音区间；每块前后 padding 0.2s（防削软起音）、间隙 <0.5s（`bridge`）的近邻并块（保自然停顿不切碎）。
- `AVMutableComposition` 只把人声块按序拼接（**保原音质**，不走 16k 重采样上传），块间留 0.35s（`gapPad`）静音给 whisper 断句锚点 → 导出小 m4a（AppleM4A preset）。
- 返回 `spans`（压缩轴↔原始轴映射），转录回来后 `VADGate.remap` 把段落/词时间戳映回原始轴 → 与原音频、说话人分割（在原始音频独立算）对齐。
- **跑在响度归一之前**（先剪后归一）；只作用于在线转录上传副本，存储/播放 `audio.m4a` 不动。
- **自限定**（同 AudioNormalizer 思路）：预计可剪静音 <3s（`minCutSavings`，人声占比高）/VAD 无语音/导出失败 → 返回 nil 退回原文件，零风险。

**实测验证（CLI 跑临时 vault，2026-06-24）**：
- Jerry 1-on-1（2268s）：剪 111s（4.9%）静音；末段 end 2268.4s（映射回原始轴 ✓）、时间戳 0 非单调、0 幻觉、最长段 14.2s（正常）。
- Annual Review（1782s，杂音多）：剪 **340s（19%）**；转录耗时 13s（垃圾没上传，省时省 token）；0 套话幻觉。

**踩坑 + 修复（关键）**：起初 `remap` 把段落 start/end **独立映射**回原始轴。Annual Review 里开场闲聊（~77s）到正式开会（~297s）之间约 3.6min 是等待/静音（被 VAD 剪掉），whisper 在压缩音频里把这段零星嘟囔归并成一个段「我现在要来我耶」——独立映射把它的 start→77.6、end→296.8，**段被拉成横跨死区的 219s**（其余段最长才 15s）。
- **根因**：跨被剪静音的段，end 落到死区另一侧的块里 → 映射后横跨几分钟。gapPad 0.35s 对"零星嘟囔被归并"这种拦不住。
- **修复**：end 不独立映射，改为 **end = 映射后 start + whisper 在压缩轴的原始时长**（`ns + (s.end - s.start)`，词级同理）。块内映射是平移、dur 不变 → 对不跨界段**完全精确**；跨界段则收缩回它真实说话的那一小段、不再横跨死区。复跑确认「我现在要来我耶」从 219s→2s，开场「哈啰」仍精确落 296.8s，末段仍 1775≈1782、0 非单调。

**待用户验收**：实机导入杂音多的录音，看幻觉/重复是否变少、逐句点跳是否对齐（尤其原本有大段等待/静音的录音）、说话人贴标是否仍准。不行→调 `minCutSavings`/`bridge`/`gapPad`；漏网幻觉再上 C（后处理黑名单）。

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
- repos：App=`Wynne-cwb/resound`(公开)，Vault=用户自配的私有数据 repo(起始含 resound.yaml/people.yaml/glossary.txt/.gitattributes)。

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

## Onboarding 自动建 Vault（2026-06-26）

**需求**：用户在 Onboarding 选好本地存储地址后，自动帮他创建 vault 数据结构（不再要求用户手动 `mkdir`+写 `resound.yaml`）。

**两个决策（用户拍板）**：
1. **录音库必填**——未设合法 vault 不能进主界面（与 chat+embedding 同级门禁）。理由：没 vault 主功能（录音/索引/问答）全都没法落地，引导期一次配齐最干净。
2. **只建数据结构，不做 git init**——脚手架只创建文件/目录，git 同步交给用户自行 `git init`+关联远端（与「git 自动推送是可选项」一致，避免替用户决定 remote）。

**落地**：
- `Vault.ensureScaffold(timezone:language:)`（[Vault.swift](../Sources/ResoundCore/Vault.swift)）：**幂等**——根目录已有 `resound.yaml` 直接返回 `false`（采用现有 vault、绝不覆盖）；否则按数据契约 §2/§3 建最小结构（`resound.yaml` + `people/people.yaml` + `recordings`/`documents`/`notes`(各放 `.gitkeep`) + `glossary.txt` + `.gitattributes`(m4a/flac/wav 走 LFS) + `.gitignore`(.DS_Store)），返回 `true`。timezone 默认取系统、language 默认 zh。错误统一包成 `VaultError.ioFailure`。
- `AppModel`（[AppModel.swift](../Sources/ResoundApp/AppModel.swift)）：`vaultReady`/`vaultPath` 状态；`refreshVaultReady()` 读 `Config.load().vaultPath` 并用 `Vault.validate()` 校验；`chooseVault()` 走 NSOpenPanel（`canCreateDirectories`）→ `ensureScaffold` → `ConfigStore.save(["VAULT_PATH":…])` → toast「已创建/已使用现有录音库」。
- `OnboardingView`：新增「录音库位置」卡片（folder 图标，已设显示路径+「更换」，未设显示「选择文件夹…」），`canEnter = chatOK && embeddingOK && vaultReady`，statusHint 加录音库状态点。
- `ResoundApp.onAppear`：`refreshVaultReady()` 后 `showOnboarding = providers.needsOnboarding || !vaultReady`（老用户已配 vault 不受影响）。
- `SettingsModel.pickVaultPath`：选目录时也调 `ensureScaffold`，所以「设置›存储›录音库目录」改路径同样自动建库——也是老用户的验证入口。
- README 双语「建一个属于自己的 Vault」段顶加 `[!TIP]`：应用内选文件夹即自动建库，手动脚手架步骤改定位为「CLI 用户/想预配 git 的人」。

**零回归**：`ensureScaffold` 对已有 vault 是 no-op；CLI 走 `.env` 的 `VAULT_PATH` 路径不变。
