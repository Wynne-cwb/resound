# 当前状态 (STATE)

> "现在的快照"。过时就改。细节/历史查 [DECISIONS.md](DECISIONS.md)。
> 最近更新：2026-07-07（**录音日期解析成 2026-01-08 修复**：GGBond 那条 1-on-1 recorded_at 错成 01-08。根因=会议曾失败重试→丢会议名→id 落 UUID 乱码→`defaultTitle` 拿 UUID 当标题→`parseTitleDate` 正则4 从 `…9e1-8c1e…` 抠出 `1-8`→当 1月8日；后手动改名不回填 recorded_at。两修：①数据 `resound redate --apply` 已改回 07-07（索引同步）②代码 [TitleDate.swift](../Sources/ResoundCore/TitleDate.swift) 裸 MM-dd 正则边界收紧 `[\d.]`→`[\w.-]`（UUID/版本号不再误抠，合法 6-10 仍命中）。App 已重建重启。详见 DECISIONS 2026-07-07。**待 commit**）
> 最近更新：2026-07-07（**Embedding 429 限流无重试修复**：Ask「正在阅读相关片段…」报 `embedding HTTP 429 cluster_rate_limit_exceeded`——[EmbeddingClient](../Sources/ResoundCore/EmbeddingClient.swift) 对非 200 一律立即抛、零重试。已给 `embed` 加指数退避重试（429/5xx/网络错误重试，遵守 Retry-After，1→2→4→8s+抖动上限30s；401/400 立即失败）。另修同日第二个报错——aihubmix 临时路由不到模型返回的是 **HTTP 400 + `no_available_channel`**（伪装成 400 的瞬时错误），已按 body 关键字特判也纳入重试。查询+文档两侧都受益。**App 已重建+重启（14:xx）**，待实机验证下次撞限流/路由错时自动退避重试。ChatClient 同类隐患未扩范围，留后续。详见 DECISIONS 2026-07-07。**待 commit**）
> 最近更新：2026-07-03（**手动识别说话人后列表仍「待识别」修复**：`analyze()`/`reidentify()` 创建了 diarization.json 且刷新了详情，但漏调 `markIdentified` → 列表徽标不清（只有后台 worker 调了）。已补。详见 DECISIONS 同日条目。**待 commit**）
> 最近更新：2026-07-03（**转录 prompt 超长 HTTP 500 修复**：说话人名字进词表把 aihubmix whisper 的 prompt 顶破 896 **字节**上限（中文 3 字节/字，843 字符=915 字节）→ 一直转录失败。[OnlineTranscriber](../Sources/ResoundCore/OnlineTranscriber.swift) `cappedPrompt` 按 UTF-8 字节截到 880、词边界切、优先保用户手写词。**第一版按字符数截错了、要按字节**。已修+重转录「Group Round 3」成功入库。详见 DECISIONS 2026-07-03。**待 commit**）
> 上轮更新：2026-07-02（**说话人归属三档改进**：深度调研后确认全行业用「词级×轮次重叠时长最大」归属、我们却用段中点。按 1→3→2 落地：①段级重叠投票取代中点（ggbond 验证 2% 纠正无回归）②CAM++ 段级声纹重验做第二票（保守,RMA 上 0 改判无回归）③重开词级时间戳+句级众数平滑+按句重组（补上 2026-06-24 缺的护栏,合成 selftest 通过）。**编译全绿；诚实结论：≤3人会实打实改进,RMA 类≥4人会走逐窗回退法受益有限（Sortformer ≤4人天花板未破）**。待 App 重建+真实录音验收。详见 DECISIONS 2026-07-02「说话人归属三档改进」+ [research](../superpowers/specs/2026-07-02-speaker-attribution-research.md)。**待 commit**）
> 上轮更新：2026-07-02（**会议录音质量三连修**：RMA 混合会录音转录极差 → 实测定位两根因（前 4 分钟 -28dB 近静音 + 双链路直接相加混音）。修复①麦克风 AEC ②归一化改分窗自适应增益（调试 CLI `normalize-audio`）③分轨保留+分开转录合并去重（spec [dual-track](../superpowers/specs/2026-07-02-meeting-dual-track-design.md)，Segment 加可选 track 字段）。RMA 录音已用新归一重转录回填+重跑说话人+重生成摘要（前 4 分钟救回）。**编译全绿；App 打包+重启被阻塞——用户当时正在录音，不能 killall**。录音结束后需：`killall Resound && ./scripts/bundle-app.sh release && open build/Resound.app`，再实机验收分轨（下场会议看 track-*.m4a/track 字段/重影去重）。详见 DECISIONS 2026-07-02 条目。**待 commit**）
> 上轮更新：2026-07-01（**富文本加两档复制**：SwiftUI 的 `.textSelection` 无法跨块选择（每个块是独立 Text），故给 `SummaryMarkdown` 底部加复制条——「复制文本」写 RTF（粘 Notion/Word 保样式）+「复制 Markdown」写原始源码；5 处富文本点一次生效。新增 [MarkdownAttributed.swift](../Sources/ResoundApp/MarkdownAttributed.swift)（AST→NSAttributedString + RichCopy 写剪贴板）+ LibraryView `MarkdownCopyBar`。编译+打包通过、App 已重启，待实机验收。**待 commit**）
> 上轮更新：2026-06-29（**内置来源精简至 Notion + Jira/Confluence**：Figma 移除（服务端对第三方封闭）、Google 移除（企业账号无法自建 OAuth 客户端 + 无 Developer Preview 资格）；手动凭证 + loopback OAuth 骨架保留待用。编译+打包通过、App 已重启。详见 [DECISIONS](DECISIONS.md) 2026-06-29 条目）
> 上轮更新：2026-06-26（**MCP 双向接入 Wave 0–4 全部落地、编译+打包通过，App 已可开测**。模块 A 消费 + 模块 B 提供，含 App UI（两设置区 + 3 modal + 录音相关外部文档）+ 本地 stdio 自定义来源。待用户经 UI 实测 OAuth/取回/安装。详见 [DECISIONS](DECISIONS.md) 2026-06-26 MCP 条目）
> 上轮更新：2026-06-26（**智能推算文件夹/Tag 已实机验收 OK**：路径 2 独立分类器 `AutoClassifier` + 调试 CLI + 派生存储 `SuggestionStore` + 列表角标 `.popover` 确认 + 入库自动算 + 右键重算（带「推算中…」转圈反馈）。修了 3 个验收问题：重算无角标→显示判据改「建议≠当前文件夹」、浮层遮盖→改原生 popover、tag 偶发空→prompt 收紧+空结果重试一次。待 commit+push）
> 上轮更新：2026-06-26（**Token 优化 P0：embedding 内容缓存**：`embedding_cache(hash,vec,model)`，重建索引/改错字只重嵌变化 chunk。已 commit `1e0d207`+push）
> 再上轮：2026-06-26（**Onboarding 自动建 Vault**：选文件夹自动建 vault 结构、录音库设为必填。已 commit `d5dda92`+push）
> 上轮更新：2026-06-26（**Markdown 渲染重构 + 性能**：原生渲染器替换 MarkdownUI（swift-markdown 解析+自绘+LazyVStack 虚拟化）→ 去 keep-alive；修追问不带上下文、转录行 Equatable、findMatchCount 缓存。用户「好很多了」，已 commit `02148df`）
> 再上轮：2026-06-26（**录音浮窗**：录音时屏幕级可拖动小药丸[脉冲红点+计时+停止]，设置「通用」加开关。用户已验收 OK）
> 再上轮：2026-06-26（修时间感知问答误判「下半年的规划」被误当录音筛选；Ask 统一检索架构 7 场景）
> 上轮更新：2026-06-25（📄 文档模块 P3 富格式解析 M1+M2 编译过，实机验收待录音结束后重建）
> 上一轮：文档模块 P1 全链路（M1 后端 + M2 视图模型 + M3 UI）；再上轮：已开源 repo 设为 public

## 一句话现状

CLI 全链路 + macOS App 已通且用户实测过（问答 / Meet 弹窗 / 录音 / 导入 / 摘要 / 说话人识别 / VAD 门控），**仓库已开源公开**。**当前焦点：文档大模块 P1 已端到端打通（M1 后端 + M2 视图模型 + M3 UI 全落地、编译通过）**，待实机验收。

## ✅ 能力总览（细节全在 DECISIONS）

- **检索/问答**：transcribe→繁简归一+glossary→AI 校对→切块→contextual→embed(qwen3-8b)→SQLite(FTS5+sqlite-vec)→RRF→LLM rerank→带引用+时间感知问答（QueryPlanner 抽时间范围/判 qa·digest）。CLI 全套。
- **说话人识别**：弃盲聚类，走「ASR段合并≥4s窗→CAM++声纹(sherpa-onnx)→注册库双门匹配→真名，未匹中在线分堆成匿名」。平滑(`smoothSpeakerSegs`)清转场幽灵说话人并**持久化进 diarization.json**（转录/名册/摘要/Ask 一致）。CLI `speaker-identify` 批量修旧录音。
- **App**：原生窗口(自绘顶栏)+MenuBarExtra 驻留；侧栏五页 Ask/Library/Documents/Templates/Settings；浅深双主题(赤陶橙)；Library(列表+文件夹+搜索+折叠+播放器+摘要/转录 Tab+⌘F 查找替换+说话人命名→声纹注册+导入)；Templates 卡片页(CRUD+AI 协助生成/润色提示词+设默认)；Ask(聊天历史+多轮上下文+引用)；Meet 检测→弹窗→双路录音→转录→自动索引+摘要闭环。
- **摘要**：模板(通用/1-on-1/团队会/头脑风暴，存 App Support `summary-templates.json`)；占位符 `{date}{weekday}{title}{speakers}{transcript}`，缺 `{transcript}` 由 `summarize()` 运行时兜底补上（不限制用户 prompt）；system prompt 禁开场白/承接语。

## 🚨 三个事故已定位并修复（2026-07-02，App 已重建启动 19:58）

**事故1：AEC 产出 7 声道怪异格式（已回退 AEC）**。`setVoiceProcessingEnabled(true)`（VPIO）在本机把麦克风输入变成 **7 声道 48kHz Float32**（→ 2.5h 达 11GB）。**注意：音频本身是好的**（7 声道内容一致、RMS 0.05 健康人声）——不是 AEC 让它静音（此前误判，已更正）。仍回退 AEC：7 声道 48k 太臃肿（录制中就 11GB，磁盘 96% 满危险）+ 脆弱，而回声本就该由分轨分别转录去重（[TranscriptMerge](../Sources/ResoundCore/TranscriptMerge.swift)）解决。已从 [MeetingRecorder.swift](../Sources/ResoundCore/MeetingRecorder.swift) `startMic` 移除。⚠️**采集路径无法离线验证，重建后仍建议先短录确认 mic 有声。**

**事故2：StreamingMix 多声道下混吐静音（已修）**。抢救那场会时发现「救出来是静音」的真凶：`AVAudioConverter` 对**离散多声道布局（7ch discrete）没有下混系数 → 直接吐全零**。已改 [AudioMix.swift](../Sources/ResoundCore/AudioMix.swift) `StreamResampler16k`：**自己手动平均各声道成单声道**，转换器只做 rate。验证：修复后对 7 声道源混音 RMS=0.041（修前 0.000）。

**事故3：finishCapture 整读大文件 OOM 卡死整机（已修）**。旧 `mixTo16k`/我的 alignAndMix 把整条 mic（11GB）`resampleAudioFile` 读进 `[Float]` → 交换区 24.8GB 卡死。改为流式 [AudioMix.swift](../Sources/ResoundCore/AudioMix.swift)（`StreamingMix`）边读边重采样边混音写出。**真 11GB 文件验证峰值内存 498MB**。新增离线抢救 CLI `recover-meeting`。

- **✅ froze 那场会已抢救回来**：取 7 声道之一（内容一致）→ transcribe 入库 `2026-07-02-2003-group1-讨论-round-2`（1530 段、内容连贯、已进索引 32 chunks）。App 需刷新/重启库才看得到。
- **临时残留**：原 11GB 源（7A813940）会已入库后**冗余可删**（磁盘 96% 满，建议删，待用户确认）；我的中间文件已清。
- **⚠️ 待办：重建后先短录测试 mic**；有空重启电脑清掉陈旧 swap。

## 🎯 当前焦点 / 下一步

- **🆕 说话人名字自动进偏置词表（2026-07-02，已回填验证）**：命名说话人时真名自动写进 glossary.txt 偏置小节（[Glossary.syncSpeakerNames](../Sources/ResoundCore/Glossary.swift) + `renameSpeakerInRecording` 钩子），转录更易把人名拼对。CLI `sync-speaker-names` 已把现有 27 个说话人回填进词表（转录已生效，因词表转录时读）。命名自动加入的钩子需 App 重建生效。详见 DECISIONS 同名条目。

- **🆕 说话人归属三档改进（2026-07-02，编译全绿，待 App 重建+真实录音验收）**：①`overlapRep` 段级重叠投票（[SpeakerDiarize.swift](../Sources/ResoundCore/SpeakerDiarize.swift)）②`reassignBySpeakerprint` CAM++ 声纹重验第二票（[SpeakerNaming.swift](../Sources/ResoundCore/SpeakerNaming.swift)，两路径都接）③[SpeakerAttribution.swift](../Sources/ResoundCore/SpeakerAttribution.swift) 词级+句级众数平滑+重组 + [OnlineTranscriber](../Sources/ResoundCore/OnlineTranscriber.swift) 重开 word 粒度。**天花板未破**：RMA 类 ≥4 人会走逐窗回退，第一/二档只在 diar 路径，受益有限——要破需换 diar 模型或重做逐窗法（下一步候选）。细节+验收点见 DECISIONS 同名条目。

- **🆕 会议录音质量三连修（2026-07-02，编译全绿，App 重建被录音阻塞）**：①AEC ②分窗归一 ③分轨转录（细节见 DECISIONS 同日条目 + dual-track spec）。**下一步（录音结束后）**：`killall Resound` → `./scripts/bundle-app.sh release` → `open build/Resound.app`；实机验收=下一场会议录音目录出现 `track-mic.m4a`/`track-system.m4a`、transcript 段带 `track`、混合会重影不再重复、纯手动录音零回归。RMA 那条已抢救回填（转录/说话人/摘要都已重生成，App 重开即见）。

- **✅ MCP 双向接入 Wave 0–4 全部落地（编译+打包通过，待用户经 UI 实测）**。设计稿 [spec](superpowers/specs/2026-06-26-mcp-bidirectional-design.md) / [计划](superpowers/plans/2026-06-26-mcp-bidirectional-plan.md)，忠实还原。范围：**不做 Cursor；本地 stdio 入 v1**。SDK=官方 `modelcontextprotocol/swift-sdk` 锁 `"0.9.0"..<"0.10.2"`→0.10.1（0.10.2+ 要 Swift 6.1，本机 6.0.3）。
  - **Wave 1 模块B服务器**（CLI selftest 全绿）：[MCPServer.swift](../Sources/ResoundCore/MCPServer.swift)（`Server`+`StdioTransport`，4 工具 search_meetings/get_recording/get_document/list_recordings 复用 `IndexPipeline.search`/`Index.Filters`）+ [MCPServerSettings.swift](../Sources/ResoundCore/MCPServerSettings.swift)（`mcp-server.json` 内容策略 full/link/summary）+ [MCPInstall.swift](../Sources/ResoundCore/MCPInstall.swift)（claude/codex `mcp add` 命令+检测+装卸+`isServerInstalled`+`appResoundPath`）。
  - **Wave 2 模块A后端**（离线 CLI 验绿）：[MCPSource.swift](../Sources/ResoundCore/MCPSource.swift)（来源模型+4内置预设+`mcp-sources.json`+host 匹配）、[MCPClient.swift](../Sources/ResoundCore/MCPClient.swift)（`Client`；远程 HTTP+Bearer / 本地 stdio 双路 `MCPClientSession.make(for:)`；适配器先 Resources 后 fetch 工具；`ExternalLinkResolver` URL 四路）、[MCPOAuth.swift](../Sources/ResoundCore/MCPOAuth.swift)（PKCE/DCR/token/刷新/Keychain）、[MCPIngest.swift](../Sources/ResoundCore/MCPIngest.swift)（imported 入库+索引 / link-only / resync）、[Document.swift](../Sources/ResoundCore/Document.swift) `external` 块 + `DocumentSummary.external`。
  - **Wave 3 App UI**（本轮，编译+打包通过）：[MCPModel.swift](../Sources/ResoundApp/MCPModel.swift)（@MainActor 视图模型：来源/OAuth 连接[ASWebAuthenticationSession]/添加自定义源/粘贴链接四路/服务开关/内容策略/助手检测+一键装卸）+ [MCPSettingsViews.swift](../Sources/ResoundApp/MCPSettingsViews.swift)（设置「外部 MCP 接入」+「Resound MCP」两区）+ [MCPModals.swift](../Sources/ResoundApp/MCPModals.swift)（OAuth 连接 / 添加自定义来源[远程·本地两 tab] / 粘贴链接[resolving·resolved·unconnected·unknown·noperm] 三模态）。SettingsView 加 `.sources`/`.developer` 子导航；OverlayHost 挂 `MCPModalsHost`；ResoundApp 注入 `MCPModel`；LibraryView「相关文档」区加「关联链接」按钮 + 外部文档行（form 角标 + 同步/打开/移除）。
  - **Wave 4 本地 stdio**：[MCPStdioProcessTransport.swift](../Sources/ResoundCore/MCPStdioProcessTransport.swift)（符合 swift-sdk `Transport` 协议的子进程传输：起 `command args env`，换行分隔 JSON-RPC 读写其 stdin/stdout）；添加自定义源「本地 · stdio」分支接通。
  - **打包**：`bundle-app.sh` 现一并构建 + 随包分发 `resound-cli`（**不能叫 resound——macOS 大小写不敏感会撞 App 主可执行 `Resound`**，见 DECISIONS）；一键安装把 `<app>/Contents/MacOS/resound-cli mcp serve` 写进助手配置。
  - **待用户 UI 实测**：①设置›Resound MCP 一键装到 Claude Code/Codex→进真 agent 查会议；②设置›外部 MCP 接入连一个来源（走 OAuth 浏览器授权）；③录音详情「关联链接」粘贴该源 URL→取回入库→「相关文档」出现外部行→Ask 能引用；④粘贴未连/未知/无权限三种提示对；⑤内容策略切换。**OAuth 浏览器授权 + 真取回需用户账号。**
  - **🆕 内置来源精简（2026-06-29，编译+打包通过、App 已重启，待 commit）**：内置预设现仅 **Notion + Jira/Confluence**。移除 Figma（服务端 `mcp:connect` 对第三方封闭）+ Google（用户企业账号无法自建 OAuth 客户端、无 Developer Preview 资格——非代码问题）。**手动凭证 + loopback OAuth 全套骨架保留待用**（`needsClientSecret`/MCPLoopbackOAuth/credsModal/OAuthServerMetadata.google），IT 配合后恢复一个预设即恢复 Google。详见 DECISIONS 2026-06-29 条目。**企业 Drive 文档替代路径**=Resound 现成「文档导入」入同一知识库。

- **✅ 智能推算文件夹/Tag（已实机验收 OK，已 commit `0330a5b`+push）**。spec [specs/2026-06-26-auto-classify-folder-tag-design.md](superpowers/specs/2026-06-26-auto-classify-folder-tag-design.md) / 计划 [plans/2026-06-26-auto-classify-folder-tag-plan.md](superpowers/plans/2026-06-26-auto-classify-folder-tag-plan.md)（已 commit `c43299d`/`41ba814`）。共识：建议+确认、优先复用现有可提新建、入库自动+重新推算、录音 1 文件夹 / 文档 1-2 tag、**列表角标**呈现、路径 2 独立分类器。
  - **Wave 1 Core（CLI 验绿）**：[AutoClassifier.swift](../Sources/ResoundCore/AutoClassifier.swift)（`suggestFolder`/`suggestTags` 纯函数，优先现有、可提新建、无合适返回 nil/空，用 `correctModel`/flash，JSON 输出+大小写归一去重）；调试 CLI `suggest-folder`/`suggest-tags`。**真实数据实测**：Jerry/Tao→命中现有 1-on-1、OS migration→命中「AfterShip OS」、文档空库→提 2 个相关新 tag。**踩坑**：文件夹 prompt 初版「宁缺勿滥」过头，OS 那条该命中却返回 none → 改成「明显吻合现有就果断选」后修正。
  - **Wave 2 App**：[SuggestionStore.swift](../Sources/ResoundApp/SuggestionStore.swift)（App Support 派生存储，folder/tag 两文件，不进 vault）；LibraryModel 摘要后自动算文件夹建议（未归类才给）+ accept/dismiss/recompute；DocumentsModel 导入后自动算 tag（无 tag 才给）；列表角标「建议：X」点开确认浮层（采纳/忽略）+ 右键「重新推算」。采纳才写 library.json / document.yaml。
  - **待实机验收点**：①新录音入库后列表出现「建议：文件夹」角标、点采纳归入正确/忽略消失；②新导入文档出现「建议 tag」角标、采纳写入；③右键「重新推算」对已归类/已忽略的能重跑；④分类失败→无角标、入库照常。README 双语已同步。

- **Token 优化 P0：embedding 内容缓存（已 commit `1e0d207`+push）**。背景：审计发现 LLM 派生的上下文已缓存（`enrichment_cache`），但 embedding 没缓存——而 ⌘F 改一个错字就 `scheduleReindex`→整条录音全部 chunk 重新 embedding（aihubmix qwen3-8b，无服务端缓存只能客户端按内容哈希省）。落地：[Index.swift](../Sources/ResoundCore/Index.swift) 加 `embedding_cache(hash,vec,model)` 表 + `cachedEmbedding`/`setCachedEmbedding`（存原始向量 JSON，归一化仍由 insertChunk 统一做）+ `parseVectorJSON`（坏数据→nil 安全重嵌）；[IndexPipeline.swift](../Sources/ResoundCore/IndexPipeline.swift) 新增 `embedAll(texts:index:embedder:log:)`（key=`chunkHash(model=embeddingModel,text)`，只对未命中文本调 API），两处 embed 调用点（录音/文档）改用它。**验过**：vectorJSON↔parseVectorJSON bitwise 无损、坏数据安全退化。**待 commit**（其余 P1 记 usage / P2 缓存搬离 index.sqlite 未做）。

- **🆕 Onboarding 自动建 Vault（编译通过，待实机验收，已 commit）**。需求：用户在引导时选好本地存储地址 → 自动帮他创建 vault 数据结构（决策：vault **必填**才能进主界面；只建数据结构、不做 git init）。落地：[Vault.swift](../Sources/ResoundCore/Vault.swift) 新增 `ensureScaffold(timezone:language:)`（幂等——已有 resound.yaml 则采用返回 false，否则按数据契约建 resound.yaml/people/people.yaml/recordings·documents·notes(.gitkeep)/glossary.txt/.gitattributes(LFS)/.gitignore）；[AppModel](../Sources/ResoundApp/AppModel.swift) 加 `vaultReady`/`vaultPath`/`refreshVaultReady()`/`chooseVault()`；[OnboardingView](../Sources/ResoundApp/OnboardingView.swift) 加「录音库位置」卡片 + 状态点，`canEnter` 含 `vaultReady`；[ResoundApp](../Sources/ResoundApp/ResoundApp.swift) 启动门禁 `needsOnboarding || !vaultReady`；[SettingsModel](../Sources/ResoundApp/SettingsModel.swift) `pickVaultPath` 也走同一脚手架。README 双语「建 Vault」段加 TIP 说明应用内自动建库。**验收点**：老用户走「设置›存储›选录音库」选个空文件夹→toast「已创建录音库」+ Finder 看结构齐全；新用户首启引导必须先选录音库才能进；选已有 vault 不被覆盖。

- **⚡ Markdown 渲染重构 + 一组性能修复（用户实测「好很多了」，已 commit `02148df`）**。设计 [specs/2026-06-26-native-markdown-renderer-design.md](superpowers/specs/2026-06-26-native-markdown-renderer-design.md)。
  - **原生 Markdown 渲染器替换 MarkdownUI**：新增 [MarkdownNative.swift](../Sources/ResoundApp/MarkdownNative.swift)（`swift-markdown` 解析 AST → 递归自绘原生 SwiftUI；段落塌缩成单个 `Text(AttributedString)`；顶层块装进 **LazyVStack 虚拟化**只布局可见块；解析结果按原文缓存）。覆盖标题/粗斜删/行内码/链接/**多级嵌套列表**/任务列表/引用/代码块/**GFM 表格**。`SummaryMarkdown` 内部换实现，7 处调用点零改。`Package.swift` 依赖 `swift-markdown-ui` → `apple/swift-markdown`。
  - **去掉 keep-alive**：`RootView` 从「懒挂载+常驻 ZStack」回归「只渲染当前页」条件渲染；删 `pageVisible` 环境/gate。原 keep-alive 是为绕 MarkdownUI 切页重建慢，现渲染够快不再需要，且消除隐藏页被布局引发的跨页卡顿。
  - **本场/文档提问追问带上下文**：`answerInRecording`/`answerInDocument` 检索前先用 `QueryPlanner`（带历史）把追问（如「时间线呢」）改写成可独立检索的查询（`condensedQuery`，无历史则原样）；综合仍用原问+全量历史。修了「追问被当孤立查询→空结果」。
  - **转录页性能**：转录行抽成 `TranscriptLineRow: Equatable`（无关 vm 变更不再全列表重渲）；`findMatchCount` 加缓存（不再每次重拼全文扫描）；查找跳转去动画（长转录不再强制 LazyVStack 全实例化）。
  - **埋点**：[Perf.swift](../Sources/ResoundApp/Perf.swift) `enabled=false` 已关；调试用 AppLog 已清。

- **✅ 录音浮窗（用户已验收 OK）**，源自 Claude Design handoff（`Resound.dc.html` 浮动录音指示器 + Settings「录音浮窗」开关）。原型把药丸画在 App 窗口内，但本意是录音时（人在 Meet/Chrome、Resound 主窗常被隐藏/最小化）也要可见 → 落地为**屏幕级浮动 NSPanel**，与既有 [MeetingPanel.swift](../Sources/ResoundApp/MeetingPanel.swift) 同构。新增 [RecBadgePanel.swift](../Sources/ResoundApp/RecBadgePanel.swift)（`RecBadgePanelController` 单例 + `RecBadgeCard`）：脉冲红点+实时计时(@ObservedObject 自动刷新不重建浮窗)+停止方钮；`isMovableByWindowBackground` 拖拽、`setFrameAutosaveName` 记忆位置、默认底部居中；跨 Space/全屏可见。受「设置›通用›录音浮窗」开关控（默认开，键 `resound.toggle.recbadge`），录音中切换经 NotificationCenter 即时显隐。**验收点**：①录音时屏幕出现小药丸、计时走动、红点脉冲；②可拖到任意位置、停录再录回到上次位置；③点药丸停止按钮能停录+转写；④设置里关掉开关→录音时不再出现，开则出现；⑤主窗最小化/关闭(仅菜单栏)时浮窗仍在。

- **✅ Ask 统一检索架构（批1+2+3 全落地，编译+打包+启动通过，CLI 全绿，待 App 实机验收）**。设计 [specs/2026-06-26-ask-scenarios-unified-retrieval-design.md](superpowers/specs/2026-06-26-ask-scenarios-unified-retrieval-design.md)：Ask = 「过滤层(时间/说话人/来源/单条目,可组合)×综合层(qa/digest/timeline/compare)」统一内核，覆盖 7 场景(⑥行动项不在本期)。综合=混合(摘要+命中片段)，量大 map-reduce，检索宽度随 shape 自适应。细节见 DECISIONS 2026-06-26 同名条目。
  - **已实现全部**：QueryPlanner v2(shape/filters/recency/compareSets + 意图分类 + few-shot 示例 + 未来范围防御) + 过滤层(`Index.Filters`,speaker=person_id/source=source_kind,零 schema 改) + digest 引擎(短跨度只摘要零回归/长跨度+无范围=主题子集+片段;超 12 条或 24k 字 map-reduce) + **近因加权**(recency 时相关度×时间衰减,半衰 120 天) + **compare 引擎**(两组各检索→对比综合) + **qa 安全兜底**(空则 speaker→time→source 逐步放宽,**根治"没有录音"挡死**) + App 意图 chip(scope 图标:汇总/时间线/对比·👤人·来源·最新优先)+ `.emptyTime` 文案改。
  - **CLI 验过 7 场景**：①单条目(原路径不变) ②无范围主题子集✅ ③qa+近因加权✅ ④小窗口只摘要(零回归)✅ ⑤说话人筛✅("我和X"prompt 坑已修) ⑦timeline 真按时序串叙事✅ ⑧compare 双栏对比✅(few-shot 后正确判 compare) 兜底✅ "下半年规划"不误筛回归✅。
  - **App 实机验收点**：在 Ask 里跑这 7 类问句，看 ①意图 chip 是否正确显示(汇总/时间线/对比/👤人/最新优先) ②②⑦能否给出跨全史的回顾/时间线 ③⑤按人筛是否准 ④故意问会过滤到空的→是否诚实答(非"没有录音") ⑤普通问答零回归。

- **🐛 时间感知问答误判已修（编译+CLI 实测，待 App 重建）**，详见 DECISIONS 2026-06-26 同名条目。问「下半年的规划」时"下半年"被 QueryPlanner 误当**录音发生时间**(Jul1–Dec31)去过滤→「这段时间没有录音」。两道修复（[QueryPlanner.swift](../Sources/ResoundCore/QueryPlanner.swift)）：①**改 prompt** 区分"时间修饰录音事件"(该过滤) vs "时间是话题名词一部分"(不过滤，保留在 query)；②`dropFutureRange` 防御——纯未来日期范围必非录音时间，丢弃退回无过滤问答。CLI 实测：「下半年的规划」正常出带引用答案、「上周/这个月的会」仍正确抽范围(零误伤)。**App 需重建生效**(改在 ResoundCore)，与 P3 同批待录音结束后重建。

- **📄 文档模块 P3（富格式解析）M1+M2 代码完成,M2 实机验收待录音结束**。spec [specs/2026-06-25-documents-p3-rich-formats-design.md](superpowers/specs/2026-06-25-documents-p3-rich-formats-design.md) / 计划 [plans/2026-06-25-documents-p3-rich-formats-plan.md](superpowers/plans/2026-06-25-documents-p3-rich-formats-plan.md)。范围(锁定)=导入 **PDF/Word(.docx)/PowerPoint(.pptx)/HTML/图片** → 解析成结构化 markdown 进 `content.md`(下游检索/问答/纪要纳入零改)、真实原件留档 `original.<ext>`。**全自研零依赖**(macOS 原生:PDFKit `attributedString`+排版推断标题、Vision OCR、Compression 手写 mini-zip、XMLParser)。
  - **M1 后端(CLI 验证全绿)**:新增 [DocumentExtractor.swift](../Sources/ResoundCore/DocumentExtractor.swift)(`extractDocument(url)→ExtractResult{markdown,sourceFormat,warnings}`,失败不抛;PDF/图片/docx/pptx/HTML/直通各提取器,扫描PDF渲染页走OCR) + [MiniZip.swift](../Sources/ResoundCore/MiniZip.swift)(Compression raw-deflate 解 OOXML) + `DocumentStore.importDocument` 加 `originalFileURL`(拷贝真原件,nil 时逐字节同现状) + CLI `import-doc` 接 extractDocument + 新增调试命令 `extract-doc`(只解析打印,无需配置)。**CLI 无头实测**:md/txt 零回归、html(标题/列表/粗体/链接/实体)、docx(标题/列表/表格)、pptx(按页)、pdf(字号推断标题)、png(Vision OCR)、broken 兜底不崩、完整 import-doc 落 content.md+真 original.pdf+建索引 全过。
  - **M2 App 接线(已编译,未实机)**:`DocImportItem.Status` 加 `.parsing`;`importFiles`/`importFile`/`startFileImport`/`ingestFile` 走 `extractDocument`(后台 Task.detached)+ `originalFileURL`,warnings→toast;文件选择器 `docImportContentTypes()`(pdf/html/image/docx/pptx)两处共用;进度行文案「解析中…/建立索引中…」;粘贴路径 `ingest`(文本版)不变。
  - **⚠️ 实机验收阻塞=用户在录音**:`swift build` 已过(不碰运行中 App),但 `killall Resound`+`bundle-app.sh release`+`open` 要等**录音结束**再做。验收点见 spec §8(1–7:各格式导入/OCR/兜底/零回归)。
  - **增强:PDF/图片 OCR 排版整理**(已落地+CLI 实测,已重启待实机)。提取后用 LLM 保语义重排成可读 markdown(合并拆行/删重复页眉页脚/重建表格),接在写 content.md 之前。新增 [MarkdownTidier.swift](../Sources/ResoundCore/MarkdownTidier.swift)、`.tidying` 进度档、CLI `extract-doc --tidy [--model]`。**默认模型=`config.correctModel`(v4-flash,沿用转录校对)**——曾误判"flash 不行须上 pro",纠错:真正杠杆是 prompt(给够删噪声/合并/重建表的授权),同 prompt 下 flash 连跑 3 次都 OK,故默认回 flash(`--model` 可覆盖)。双重字数安全闸+异常回退,绝不丢内容。**旧文档回溯**:新增 CLI `retidy-doc <docDir>`(重提取→整理→重写 content.md→重建索引),已对那份 AfterShip OS doc 跑过(14243→13309、33 chunks),App 已重启会读到整理版。详见 DECISIONS 同日条目。
  - **M3 文档已同步**:data-contract(source_format 扩展+真原件+排版整理)、README 双语、本 STATE、DECISIONS。
  - P1(M3)/P2 仍待实机验收(用户暂无真实案例可测)。

- **📄 文档模块 P2（纪要纳入关联文档）已落地（编译通过，待实机验收）**。spec [specs/2026-06-25-documents-p2-summary-with-docs-design.md](superpowers/specs/2026-06-25-documents-p2-summary-with-docs-design.md) / 计划 [plans/2026-06-25-documents-p2-summary-with-docs-plan.md](superpowers/plans/2026-06-25-documents-p2-summary-with-docs-plan.md)。范围(锁定)=**录音侧增强纪要**：生成会议摘要时自动把本场关联文档全文当背景喂 LLM（全文注入+字数上限兜底；自动用+可见）。落地：Core `linkedDocumentTexts`(反查关联文档正文) + `Summarizer.summarize(referenceDocs:)` + `{documents}` 占位符(缺省自动注入,镜像 `{transcript}`) + `buildReferenceDocsBlock`(超 `maxReferenceDocChars`=16000 截断标注) + 顶部消歧提示;**关键简化**:gather 放在 `IndexPipeline.summarizeRecording`(从 config.vaultPath 反查),所有触发路径(手动/重生成/入库自动)零改自动生效,plan 原 T2.1 App-gather 免了;App 仅加摘要区「N 篇文档已纳入」可点提示(点击滚到「相关文档」卡)+ Templates/占位符 chip 加 `{documents}`。**零回归**:无关联文档时 referenceDocs=[]、行为逐字节同现状。**待实机验收**:①关联文档的录音生成摘要→纪要体现文档背景+提示出现;②无关联→同今天;③超长文档→截断不崩;④模板手写 `{documents}`→位置对。**P2 后续/独立生成文档、Ask 存文档、P3 富格式、P4 在线源 仍不在本期。**

- **📄 文档模块 P1：M1 后端 + M2 视图模型 + M3 UI 全部落地（编译通过，待实机验收）**。spec [specs/2026-06-25-documents-p1-design.md](superpowers/specs/2026-06-25-documents-p1-design.md) / 计划 [plans/2026-06-25-documents-p1-plan.md](superpowers/plans/2026-06-25-documents-p1-plan.md)。
  - **M1 后端**（CLI 验收全绿）：[Document.swift](../Sources/ResoundCore/Document.swift)（DocumentManifest+DocumentStore+解析/扫描）；Index 加 `source_kind`/`doc_id` 列 + `documents`/`doc_links` 表 + 检索按 docId scoping；Chunker `chunk(text:)`；IndexPipeline `indexDocument`/`answerInDocument` + build 纳入 documents/；Synthesizer/CLI 引用区分 📄/🎙️；CLI `import-doc`。
  - **M2 视图模型**：[DocumentsModel.swift](../Sources/ResoundApp/DocumentsModel.swift) + [DocAskStore.swift](../Sources/ResoundApp/DocAskStore.swift)。
  - **M3 UI（本轮）**：按用户 Claude Design 设计稿落地——新增 [DocumentsView.swift](../Sources/ResoundApp/DocumentsView.swift)（文档主面：列表+搜索+标签筛选+导入进度行+空态；详情：md 正文/元数据/关联录音卡/「向本文档提问」tab；+ 导入弹窗/关联选择器弹窗两 struct）；Theme 加 `doc`/`docSoft` 蓝色 token；AppModel.Page 加 `.documents`；RootView 主导航入口 + TopBar 标题 + 懒挂载；ResoundApp 注入 DocumentsModel 并启动即 `load()`；Overlays 加文档编辑/删除模态；**Ask 跨源引用区分**（ChatView/ChatStore：Cite 带 isDoc/docId/docTitle，文档引用蓝卡、点击跳转到文档并高亮被引段落 `docHighlight`）；**录音详情「相关文档」区**（LibraryView 反查 + 「管理」双向关联选择器，fromRec 模式还能「导入新文档」自动回关）。
  - **关联双向**：事实源是各 `document.yaml` 的 `links`，索引 `doc_links` 仅镜像；改关联只重写 yaml+刷镜像不重 embedding。
  - **取舍**：正文复用 `SummaryMarkdown`(MarkdownUI) 渲染，不照搬设计稿的手写 block 渲染器（保持全 App 一致）；故 Ask 文档引用跳转用「内容上方高亮卡展示被引原文」代替「精确高亮某段」。
  - **待实机验收点**：①侧栏 Documents 入口+角标；②导入(文件/粘贴)→建索引→出现在列表；③详情正文/编辑/删除/查看原件；④关联录音双向（文档侧选录音 / 录音详情「相关文档」管理 / 导入即关联）；⑤全局 Ask 出现 📄 文档引用且点击跳转高亮；⑥向本文档提问带本篇引用。**P2 生成 / P3 富格式 / P4 在线集成 不在本期。**

- **Settings 页重设计已落地（编译+打包+启动通过，待实机验收）**，细节见 DECISIONS 2026-06-25「Settings 重设计」：按 Claude Design handoff 还原——顶部 header + **左侧子导航(AI 服务/存储与同步/权限/通用/专有词表)+ 右侧单区**(不再一条长滚动);**AI 服务区改三张手风琴卡**(收起显示「服务商·模型」摘要 + 验证状态药丸,展开编辑);服务商/模型由横向芯片改为**下拉菜单**(`Menu`);转写区「在线服务/本地 Whisper」分段切换。逻辑(ProvidersModel/SettingsModel)不变,纯重皮+重排。CapabilityCard 复用于设置(collapsible)与首启引导(常驻展开)。**验收点**:①子导航切换流畅、AI 卡折叠/展开/摘要正确;②服务商下拉、模型预设下拉、测试连接、密钥眼睛切换都正常;③存储/权限/通用/词表(含智能建议收件箱)四区视觉与功能正常。

- **开源化第一步：AI Provider 配置已落地（编译+打包+启动+迁移实测通过，待实机验收）**，细节见 DECISIONS 2026-06-25「开源化第一步」：从个人写死(DeepSeek+AIHUBMIX) → 用户可设置任意 OpenAI 兼容 provider（七预设+自定义）、chat/embedding/转写三能力各管一条、每项可「测试连接」实时验证（embedding 顺带探测维度、转写内存合成 WAV 测端点），首启未配齐 chat+embedding 走强制引导（转写可留空兜底本地 Whisper）。`Config` 不动、新增 `providers.json` 真源、`Config.load()` 优先读它否则回退旧 `.env`（CLI 无缝）。老用户 .env 自动迁移、不弹引导。**验收点**：①Settings「AI Provider」三张卡预填对、各自「测试连接」能真报通/报错；②临删 `~/Library/Application Support/Resound/providers.json` 重启 → 进引导 → 配个 OpenAI/Ollama 异构 provider 能否走通+验证；③embedding 验证后维度自动写对。**下一步候选**（开源化后续）：README/LICENSE/打包分发、首启权限引导文案、Provider 配错时主功能的报错兜底体验。

- **性能审计 #2 + 深度优化已落地（编译+打包+启动通过，待用户实机验收）**，细节见 DECISIONS 2026-06-25「性能审计 #2」：workflow 审计三页卡顿，确认**共同根因=Palette 非 Equatable + 每帧现造**（侧栏折叠/toast/录音计时器都每帧重建 Palette → 整树含 Markdown 重渲染，正是「折叠很卡」元凶）。7 项修复：①Palette Equatable+AppModel 缓存（掐断全树放大器）②录音计时器相等守卫 4×→1×/s ③Ask 消息行抽 MessageRow:Equatable（折叠/打字机只重渲变化行）④Ask 输入栏 InputBar 本地 @State ⑤Settings 抽 ConnectionSection+VocabBrowser 本地 @State（键入不再失效整页）⑥Library 切页幂等（不再无脑 refreshDetail）⑦Library 日期格式化器单例。**追加**（用户反馈「打开对话后频繁切 Ask↔Library 仍卡」）：根因=RootView 用 `switch app.page` 每次切页**销毁重建整页**（重解析全部 Markdown），改成 ZStack「懒挂载+保活」（mounted 集合，切页只切 opacity 不销毁）。**埋点实测后定位真凶并修复（已验收：用户「好挺多的」）**：加 [Perf.swift](../Sources/ResoundApp/Perf.swift)（卡顿看门狗+body 计数→resound.log，已置 `enabled=false`）实测发现——body 重算全程个位数（Equatable 早生效），但主线程卡顿 500ms~1.8s 且与 body 无关 → 真凶是 **MarkdownUI 单篇文档布局就要 500ms~1s**。**关键修复=Ask 消息列表 `VStack`→`LazyVStack`**（长对话只渲染可见几条，不再一次性布局全部）→ 切换从 460~950ms 降到多数 0/偶尔 100~300ms。配套：keep-alive（切页不重建）+ 瞬时折叠。残留：Library 摘要页折叠那一篇仍重排一次（~300~600ms 单次），用户认可可接受、暂不处理。**教训：性能优化先埋点，别凭直觉猜（前三轮方向都偏，数据一上来即定位）。**

- **转写失败兜底已落地（编译+打包+启动通过，待验收）**，细节见 DECISIONS 2026-06-25「转写失败兜底」：用户一条导入转写失败、无报错/无重试/无法取回音频。**排查结论=查不到原因**：error 被 `catch` 吞 + GUI App 的 print 不进系统日志 + 无文件日志。全套修复：①新增 [AppLog.swift](../Sources/ResoundCore/AppLog.swift) 把失败落盘 `resound.log`；②导入失败行显示原因 + 重试 + 在 Finder 显示音频（`ingestOne` 抽出复用）；③**录音(Meet)失败不再丢音频**——抢救到 App Support/failed-recordings/ 并登记成可重试失败项（复用导入失败行 UI）。**验收点**：断网制造一次失败→看是否显示原因/能重试/能 Finder 取回，`resound.log` 是否落报错。

- **5 项 UI/逻辑小优化已落地（编译+打包+启动通过，待用户实机验收）**，细节见 DECISIONS 2026-06-25：
  1. **窗口只能从标题栏拖动**：`isMovableByWindowBackground=false` + 自绘顶栏背后加 `TitlebarDragArea`（mouseDownCanMoveWindow=true）。内容区空白处不再拖整窗。
  2. **⌘F 查找替换统一大小写不敏感**：新增 `LibraryModel.ciCount`；`replaceAll`/`findMatchCount` 改 `.caseInsensitive`（之前高亮不敏感、替换敏感，口径不一）。
  3. **说话人配色稳定 + 按占比排序**：`speakerColor(for:anon:)` 用名字 djb2 确定性哈希（不用 `String.hashValue`——它每次进程随机种子→开 App 变色）；`makeRoster` 按 lineCount 降序。
  4. **多录音并发重新生成摘要各自独立状态**：`summarizingId: String?` → `summarizingIds: Set<String>`（之前 A 跑着切 B 重生成会把 A 的 loading 状态冲掉，但后台 A 仍在跑）。
  5. **文件夹折叠状态持久化**：`collapsed` 存 UserDefaults（`resound.collapsedFolders`，UI 偏好不进 vault），reload 时 `loadCollapsed` 沿用上次。
  - **验收点**：①只有顶栏能拖窗；②查找替换对大小写混排词命中一致；③同一人跨录音/重启同色、多人会按说话多少排序；④同时重生成多条摘要互不冲掉状态；⑤折叠某文件夹后重开 App 仍折叠。

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

- **🐛 会议录音转写失败重试后丢会议名（已修，编译通过待实机）**：`LibraryModel.ingestOne` 共用路径写死 `title:nil` → 会议失败重试落回 `defaultTitle(文件名)`，id 变 `<ts>-resound-meeting-<uuid>` 乱码。修=`ImportItem` 加 `title`、`recordFailedRecording` 存会议名、`ingestOne` 传 `p.title`（普通导入仍 nil→defaultTitle，零回归）。详见 DECISIONS 同日条目。**与 P3 同批等录音结束后重建验收**（重录一场会议→故意/自然触发转写失败→重试→看 id/标题是否保留会议名）。

## ✅ 提交状态

文档模块 P1-M3 + P2 + P3 + 智能分类 + **MCP 双向接入 Wave 0–4**（`29e3e95`）已 commit+push。**本轮「富文本两档复制」（MarkdownAttributed.swift + MarkdownCopyBar）未 commit**（按规矩等用户发话）。

## 📌 运行 / 测试要点

- App 配置：`.env` 复制到 `~/Library/Application Support/Resound/.env` + 补 `VAULT_PATH`、`SPEAKER_MODEL`（已写好）。
- 改完样式必须 `killall Resound` → `./scripts/bundle-app.sh release` → `open build/Resound.app`。
- GUI 我看不到 → 靠用户截图迭代。测试数据在 `~/Downloads`（GGbond 2人会 / OS 6人会）。实验脚本 `experiments/diar-py/`。

## 待办/提醒

- 开机自启仅持久化偏好，未真接 SMAppService；拒识阈值 τ 待调；加音频进真 vault 前装 git-lfs。
