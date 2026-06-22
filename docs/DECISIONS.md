# 决策 & 已完成实践日志 (DECISIONS)

> 增长型日志：定下的选型/参数/结论 + 已完成功能 + 关键踩坑。带日期，别删历史。
> 当前快照看 [STATE.md](STATE.md)。

---

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
