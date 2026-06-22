# 决策 & 已完成实践日志 (DECISIONS)

> 增长型日志：定下的选型/参数/结论 + 已完成功能 + 关键踩坑。带日期，别删历史。
> 当前快照看 [STATE.md](STATE.md)。

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
