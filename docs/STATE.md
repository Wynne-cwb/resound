# 当前状态 (STATE)

> "现在的快照"。过时就改。细节查 [DECISIONS.md](DECISIONS.md)。
> 最近更新：2026-06-22

## 一句话现状

CLI 全链路 + macOS App 已通。**本轮：按 Claude design 设计稿全量还原 SwiftUI UI** —— 原生窗口 + MenuBarExtra 菜单栏驻留、侧栏导航三页(Ask/Library/Settings)、浅深双主题、会议摘要+模板、专有词表、说话人命名→声纹注册、导入、时间感知问答。已编译 + 打包 + 启动无崩溃。**待用户实机截图验收视觉细节。**

## ✅ 已完成且验证（细节见 DECISIONS）

- **检索/问答**:transcribe→繁简归一+glossary→切块→contextual→embed(qwen3-8b)→SQLite(FTS5+sqlite-vec)→RRF→LLM rerank→带引用问答。CLI 全套。
- **说话人识别**:弃盲聚类,走「ASR段合并≥4s窗→CAM++声纹→注册匹配」。同会议89-92%、跨录音88%、Swift 复现82-85%。接入检索(search/ask 显示👤)。冷启动在线分堆(命名~6次覆盖92%)。sherpa-onnx 静态库(`scripts/build-sherpa-onnx.sh`)。
- **App**(SPM 应用+`scripts/bundle-app.sh`打签名 .app):
  - Ask Resound 页(接真实 ask)、Settings 页、Library 录音库(列表+播放条+带👤转录+点句跳播放+重命名/删除+拖拽进度条+识别说话人)
  - Meet 检测→弹窗→双路录音(麦克风+ScreenCaptureKit对方音)→转录→**自动索引这一条**→可搜
  - 样式:磨砂玻璃+冷蓝点缀+背景淡蓝辉光+自定义分段切换器,浅深双模式,图标已接
  - **用户实测过**:问答、Meet弹窗、录音都正常
- **时间感知检索 + AI 摘要(后端,本轮新增,CLI 实测通过)**:
  - chunk 加 `recording_date`、recordings 加 `summary`(旧库 ALTER 迁移);`search/vectorSearch/ftsSearch` 支持 `dateRange` 过滤;引用带日期。
  - `QueryPlanner`:LLM 抽时间范围+判 qa/digest(实测"上周四"→6/18、"6月18号"→digest 走摘要、"昨天"无录音优雅空)。
  - `Summarizer` + 模板列表(通用/1-on-1/团队会/头脑风暴,存 App Support `summary-templates.json`),写 `summary.md`+入索引。CLI:`summarize`、`ask` 默认带规划。
  - 录音自动闭环已串上摘要(RecordingController:index→summarize)。
- **UI 全量还原(本轮,编译+打包+启动验证)**:Claude design 设计稿 → SwiftUI。原生窗口(hiddenTitleBar 自绘顶栏,留交通灯位)+ MenuBarExtra;侧栏三页;`Palette` 浅深双 token + 主题开关;Ask(空态 6 chips/流式回答/时间范围徽标/引用·汇总来源,接 `pipeline.answer`);Library(列表+导入+播放器+摘要/转录 Tab+模板菜单+说话人名册命名+逐句高亮);Settings(就绪/权限/开关/模板 CRUD/词表 CRUD);全套模态(命名/改名/删除/模板/词表/导入)+ toast。
- **两块后端打通(本轮)**:`GlossaryStore` 读写 vault/glossary.txt;`renameSpeakerInRecording` 改 diarization.json + 重打 index chunk 真名 +（勾「记住」）提声纹 upsert speaker_refs（越用越准闭环)。

## 🎯 当前焦点 / 下一步

- **第二轮优化已做(编译+打包+启动通过)**:①**转写改在线 aihubmix whisper-large-v3-turbo**(默认 TRANSCRIBE_ONLINE=true,已 curl 实测端点;本地 WhisperKit 仅 fallback);②菜单栏型 App(关窗不退出+退出 Dock,菜单栏图标下拉打开/录音/退出);③弹窗阴影裁切修复;④摘要可选中复制;⑤说话人名册行加试听按钮。
- **后续轮已做**:摘要模板名显示修复;⌘F 查找/替换(高亮+滚动到首个命中);播放卡顿修复(计时器 0.25s+摘要解析缓存+转录 LazyVStack);说话人命名加进度反馈 + 已标注人名模糊选择;**重新识别**(用已记住声纹合并重复匿名说话人/自动套真名);新图标接进侧栏+Ask hero,Ask 去掉示例卡,模态去阴影;**Library 文件夹+搜索+折叠**(vault/library.json);词表内置 27 个团队术语;Markdown 渲染换 MarkdownUI 库(嵌套列表/表格/代码块完备);主题色改赤陶橙(浅 #bd6a2e)/暖金(深 #e3a35f);侧栏折叠按钮改圆形浮在右边框上(圆心与 Logo 中心齐平 y=21)。
- **微调轮已做(本轮)**:①圆形折叠按钮 y 对齐 Logo 中心;②Library 录音行 pencil/trash 仅 hover 出现(选中态不再常驻遮挡);③进度条拖拽不再带动整窗(`WindowDragBlocker` NSView `mouseDownCanMoveWindow=false` 垫底);④详情标题/日期/「会议摘要」标题加 `.textSelection(.enabled)` 可选中复制;⑤**全局按钮命中区修复**:自定义 `PlainHitButtonStyle`(`.plainHit`)给 label 加 `contentShape(Rectangle())`,全 App 41 处 `.buttonStyle(.plain)`→`.plainHit`,解决「只有点到文字才响应」(透明背景 Tab/按钮)。
- **等用户实机截图验收**视觉 + 实测在线转写一整条录音 + ⌘F 替换 + 真 Meet 标题抓取。我看不到 GUI,靠截图迭代。
- 仍待:开机自启/菜单栏开关目前仅持久化偏好,未真接 SMAppService。

## ⚠️ 未提交（本轮，用户未要求 commit）

UI 还原 + 二轮优化:App 新增 AppModel/LibraryModel/SettingsModel/SettingsView/Overlays/MeetingPanel.swift + AppDelegate,重写 Theme/RootView/ChatView/LibraryView/ResoundApp/RecordingController;Core 新增 GlossaryStore/SpeakerNaming/OnlineTranscriber.swift + Index 加 `recordingSummaryInfo` + Config 加 `transcribeModel/transcribeOnline`。会议弹窗=屏幕级浮窗。docs 两份已同步。

## 📌 运行 / 测试要点

- App 配置:`.env` 复制到 `~/Library/Application Support/Resound/.env` + 补 `VAULT_PATH`、`SPEAKER_MODEL`(已帮用户写好)。
- 改完样式必须 `killall Resound` 再 `open build/Resound.app`(旧实例在跑则 open 只切前台)。
- GUI 渲染我看不到 → 靠用户截图迭代。权限(麦克风/屏幕录制/自动化)需用户授权。
- 测试数据(ground truth)在 `~/Downloads`:GGbond 2人会议、OS 6人会议(+vault 已有这两条+用户App实录一条)。
- 实验脚本 `experiments/diar-py/`(venv/模型 gitignored)。

## 待办/提醒

- 标注落 vault:diarization.json 已做(Library 识别说话人时写);声纹向量在 index。
- 加音频进真 vault 前装 git-lfs;synthesis pro/flash A/B 未做;拒识阈值 τ 待调。
