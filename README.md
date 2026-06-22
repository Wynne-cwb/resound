<div align="center">

<img src="assets/AppIcon.png" alt="Resound" width="120" />

# Resound

**把每一场对话变成可检索的个人记忆。**

macOS 原生（Swift / SwiftUI · Apple Silicon）个人 wiki：
录音 → 转录 → 说话人识别 → 切块入库 → 检索与问答，全链路打通。

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)
![arch](https://img.shields.io/badge/arch-Apple%20Silicon-orange)
![swift](https://img.shields.io/badge/Swift-6%20(lang%20mode%205)-f05138)

</div>

---

Resound 帮你录下会议与一对一谈话，自动转成带说话人、带时间轴的逐句文稿，
生成结构化会议纪要，并把全部内容切块建索引——之后你可以像查个人知识库一样
**用自然语言提问，拿到带引用、带日期的答案**。

它会越用越懂你：给说话人命名一次，下次同一个声音自动认出；
把团队黑话加进词表，转录里就不再写错。

> [!NOTE]
> Resound 本身是**纯实现，不含任何个人数据**。你的音频、转录、标注都存在
> 你自己指定的、符合[数据契约](docs/data-contract.md)的 git 仓库（vault）中。

## 功能特性

- **会议录音** — 一键录制麦克风 + Google Meet 对方声音（ScreenCaptureKit 双路混音）；检测到 Meet 自动弹屏级提示。
- **转录** — 默认走在线 `whisper-large-v3-turbo`（快），本地 WhisperKit 作离线兜底；繁→简归一 + 词表纠错。
- **说话人识别** — 弃盲聚类，走「ASR 边界合并 → CAM++ 声纹 → 注册匹配」。命名一次即记住声纹，跨录音自动认人，标得越多越准。
- **AI 会议纪要** — 模板化摘要（通用 / 一对一 / 团队会 / 头脑风暴），写入可检索索引。
- **检索与问答** — FTS5 关键词 + 向量召回 + RRF 融合 + LLM 重排 + 综合，答案**带引用、带日期**；支持「上周四的一对一聊了啥」这类时间感知查询。
- **录音库** — 搜索、文件夹分组、⌘F 查找替换（修转录错字）、逐句点跳播放、说话人试听。
- **菜单栏驻留** — 关掉主窗口不退出，常驻菜单栏随时开录；浅 / 深双主题。

## 架构边界

Resound 把三样东西**物理分开**，互不混存：

| | 内容 | 位置 | 性质 |
|---|---|---|---|
| **App**（本仓库） | Swift / SwiftUI 实现 | `Wynne-cwb/resound` | 程序，不含数据 |
| **Vault** | 音频 / 转录 / 标注 / 人物 / 笔记 | 用户配置的 git repo | **事实源**，可移植 |
| **Index** | SQLite + FTS5 + sqlite-vec + 声纹向量 | 本地 App Support | **派生物**，可重建 |

> [!IMPORTANT]
> 核心不变量：**删掉整个 Index，App 能从 Vault 完整重建。**
> 这条决定了什么进 Vault、什么进 Index——详见[数据契约](docs/data-contract.md)。

## 快速上手

### 前置条件

- macOS 14+ / Apple Silicon
- Swift 6 工具链（Xcode 16+ 或 `swiftly`）
- 声纹依赖 sherpa-onnx 静态库（首次需本地编出，约百 MB，已 gitignore）

```bash
# 1. 编译 sherpa-onnx 声纹静态库（一次性）
scripts/build-sherpa-onnx.sh

# 2. 配置密钥：在仓库根目录创建 .env（见下方「配置」表）

# 3. 编译（首次会拉 WhisperKit / FluidAudio / MarkdownUI 等依赖）
swift build
```

### 跑 CLI

```bash
.build/debug/resound doctor                      # 自检关键依赖
.build/debug/resound record                      # 录音 → 转录 → 写入 vault
.build/debug/resound index                       # 从 vault 重建检索索引
.build/debug/resound ask "上周的一对一聊了什么"     # 带引用的问答
```

### 打包并运行 App

```bash
scripts/bundle-app.sh release    # 产物：build/Resound.app（含权限声明 + ad-hoc 签名）
open build/Resound.app
```

> [!TIP]
> 改完重新打包后，若旧实例还在跑，`open` 只会切前台。先 `killall Resound` 再 `open`。

## 配置

密钥与可调参数放仓库根目录 `.env`（已 gitignore，**绝不提交**）。接口均为 OpenAI 兼容：

| 变量 | 用途 |
|---|---|
| `AIHUBMIX_API_KEY` / `AIHUBMIX_BASE_URL` | Embedding（向量）+ 在线转录 |
| `EMBEDDING_MODEL` / `EMBEDDING_DIM` | 向量模型与维度 |
| `CHAT_API_KEY` / `CHAT_BASE_URL` | LLM（DeepSeek 官方，OpenAI 兼容） |
| `CONTEXT_MODEL` | 逐 chunk contextual 增强（高频，默认 flash） |
| `RERANK_MODEL` | 召回重排 |
| `ANSWER_MODEL` | 最终综合（每次提问一调，默认 pro） |

App 运行时会把根目录 `.env` 复制到 `~/Library/Application Support/Resound/.env`，并补 `VAULT_PATH`、`SPEAKER_MODEL`。

## CLI 命令

| 命令 | 说明 |
|---|---|
| `record` / `record-meeting` | 麦克风录音 / 会议双路录音 → 转录 → 写入 vault |
| `transcribe` | 把已有音频转录并写入 vault |
| `watch-meet` | 监听 Chrome 是否在开 Google Meet |
| `diarize` / `speaker-recognize` | 说话人分割 / 用声纹库识别说话人 |
| `speaker-enroll` / `speaker-label` | 注册声纹 / 给已有索引就地打标签 |
| `normalize` | 对已有转录重做繁→简归一 + 别名纠正 |
| `index` | 从 vault 重建检索索引（切块 → embedding → SQLite/FTS5/vec） |
| `search` | hybrid 检索（FTS5 + 向量 + RRF） |
| `summarize` | 为录音生成 AI 摘要（写 summary.md + 入索引） |
| `ask` | 问答：检索 + 重排 + LLM 综合，输出带引用的答案 |
| `doctor` | 自检 sqlite-vec 等关键依赖 |

## 工作原理

```
录音 ─► 转录(在线 whisper / 本地 WhisperKit) ─► 繁简归一 + 词表纠错
   └─► 说话人识别(ASR 段合并 → CAM++ 声纹 → 注册匹配)
                          │
切块 ─► contextual 增强 ─► embedding ─► SQLite(FTS5 + sqlite-vec)
                                              │
提问 ─► QueryPlanner(LLM 抽时间范围 / 判 qa·digest)
   └─► FTS5 + 向量召回 ─► RRF 融合 ─► LLM 重排 ─► 综合(带引用·带日期)
```

## 技术栈

- **本地**：AVAudioEngine · ScreenCaptureKit · WhisperKit · sherpa-onnx（声纹）· SQLite（FTS5 + sqlite-vec）
- **依赖**：[WhisperKit](https://github.com/argmaxinc/WhisperKit) · [FluidAudio](https://github.com/FluidInference/FluidAudio) · [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) · [swift-argument-parser](https://github.com/apple/swift-argument-parser)
- **API**：Embedding（向量）· rerank · DeepSeek（contextual 增强 / 元数据抽取 / 综合）

## 项目结构

```
Sources/
  ResoundApp/    SwiftUI App（窗口 / 录音库 / 设置 / 弹窗）
  ResoundCore/   核心逻辑（转录 / 声纹 / 切块 / 索引 / 检索 / 摘要）
  resound/       CLI 入口
  CSQLiteVec/    sqlite-vec C 桥接
  CSherpaOnnx/   sherpa-onnx 声纹 C API 桥接
scripts/         build-sherpa-onnx.sh · bundle-app.sh
docs/            data-contract.md · DECISIONS.md · STATE.md
```

## 文档

- [数据契约](docs/data-contract.md) — 项目地基，所有模块遵守
- [决策日志](docs/DECISIONS.md) — 选型、踩坑与已完成实践
- [当前状态](docs/STATE.md) — 进行中 / 下一步快照
