<div align="center">

<img src="assets/AppIcon.png" alt="Resound" width="120" />

# Resound

**把每一场对话变成可检索的个人记忆。**

macOS 原生（Swift / SwiftUI · Apple Silicon）个人 wiki：
录音 → 转录 → 说话人识别 → 切块入库 → 检索与问答，全链路打通。

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)
![arch](https://img.shields.io/badge/arch-Apple%20Silicon-orange)
![swift](https://img.shields.io/badge/Swift-6%20(lang%20mode%205)-f05138)

[English](README.md) · **简体中文**

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

- **会议录音** — 一键录制麦克风 + Google Meet 对方声音（ScreenCaptureKit 双路捕获；两轨按真实起点对齐后混音存档，且**分轨同时保留**——各自独立转录再按时间合并去重，现场+线上混合会里同一句话走两条链路的「重影」不会污染转录）；检测到 Meet 自动弹屏级提示，可设为**会议开始自动开录 / 结束自动停录**（或弹一键确认窗），全程无需手动。录音时屏幕上常驻一颗**可拖动的小浮窗**（脉冲红点 + 计时 + 停止按钮），悬浮在其它 App 之上，让你随时知道正在录音、一键即可停——即使主窗口已隐藏也看得到。可在**设置 › 通用 › 录音浮窗**里开关。
- **转录** — 三种后端：**MOSS 云端（推荐）**、在线 whisper、本地 WhisperKit。MOSS（[MOSS-Transcribe-Diarize](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize)，Apache-2.0）是端到端「转录+说话人」联合模型——谁说了什么一次产出、说话人归属显著强于拼接式方案，设置里**一键部署到你自己的 Modal 账号**（免费额度内基本零成本），失败自动回退 whisper。超过 30 分钟的长录音**自动切块并行转写再拼接**——0.9B 模型在小时级输入上输出格式会劣化，分块同时保住质量和墙钟时间。whisper 路径默认在线 `whisper-large-v3-turbo`（快），本地 WhisperKit 作离线兜底；上传前用 silero VAD **剪掉长静音/噪声**（减 whisper「谢谢观看」类幻觉、省 token，时间戳映射回原始轴）再做**分窗自适应响度归一**（整条小声、前小后大都能救）。会议录音**两条分轨各自独立转录**再按时间戳合并去重——现场+线上混合会里同一句话走两条链路的「重影」不再互相污染。转录后繁→简归一 + 词表纠错 + **LLM 校对**（修同音错字、英文专名错听）。
- **说话人识别** — Sortformer 神经分割（跑 Apple Neural Engine）→ silero VAD 去静音 → CAM++ 声纹 → 注册库匹配真名；声纹相近时按簇合并 + 命名互斥防误配。命名一次即记住声纹，跨录音自动认人，标得越多越准。**命名的人名会自动加入专有词表做转录偏置**（会议里常念到人名，偏置后拼写更准）。
- **AI 会议纪要** — 模板化摘要（通用 / 一对一 / 团队会 / 头脑风暴），写入可检索索引；录音若有**关联文档**，会自动把文档全文当背景一起喂给模型（带字数上限），让纪要也吸收 PRD/议程/会议材料。**Templates 页**可增删改模板（占位符含 `{documents}`）、AI 协助生成 / 润色提示词、设默认。
- **检索与问答** — FTS5 关键词 + 向量召回 + RRF 融合 + LLM 重排 + 综合，答案**带引用、带日期**。规划器读懂每个问题并路由到合适的形状：精准事实、**汇总**（「这个月聊了啥」）、**时间线**（「迁移策略怎么一步步演变的」）、**对比**（「这周和上周的一对一差在哪」）。过滤条件可自由组合——按时间、**按说话人**（「我和 Jerry 都聊过什么」）、按来源——「最新/现状」类问题还会**近因加权**让最近的讨论优先。跨大范围的回顾会**检索整段历史**（量大走 map-reduce），不再只取零星几段；过滤到空时**自动放宽**而非直接挡死。引用**区分来源**——一段答案里可同时混引 🎙️ 录音和 📄 文档，各自可点（录音跳到时间点，文档打开并高亮被引段落）。也可**针对单条录音**提问（检索会连同它的**关联文档**一起纳入，让回答也吸收挂着的 PRD/议程/会议材料）或**针对单篇文档**提问（严格限定该篇文档）。
- **文档** — 把外部材料和录音一起导入：会前 PRD、会议纪要、合规要求…… 富格式用 macOS 原生框架解析成可检索文本（零依赖）：**PDF**（文本层 + 排版推断标题，**扫描件自动走 OCR**）、**Word(.docx)**、**PowerPoint(.pptx)**、**HTML**、**图片**（Vision OCR，中英），外加 Markdown / 纯文本。其中 PDF 和图片提取出的乱排版文本，会再由 **LLM 自动整理成干净可读的 Markdown**（严格保语义——接回错误断行、删重复页眉页脚、重建表格）。解析出的文本旁会留档**真实原件**。每篇文档建索引进同一知识库，**和录音一起参与全局问答**。文档与录音可**双向关联**（任一侧都能管理），每篇文档有独立的元数据、标签和「向本文档提问」标签页。导入时若文档没有标签，会**智能推算 1-2 个核心 tag**（尽量复用已有 tag），以列表角标形式给出，你采纳或忽略。
- **录音库** — 搜索、文件夹分组、⌘F 查找替换（修转录错字）、逐句点跳播放、说话人试听；反复改同一个错词会**自动建议加入词表**，一键确认。新录音还会**智能推算文件夹**——LLM 读摘要挑最合适的现有文件夹（或提议新建），以列表角标给出，你确认或忽略（不点头绝不擅自移动）。还能**合并录音**——多选 2 条以上，按创建时间首尾相接成一条新录音并重新完整转录（新标题由 AI 建议、可改）；被合并的原录音移到归档（可恢复，不删）。
- **外部知识接入（消费 MCP）** — 接入 Notion、Jira / Confluence，或任意 MCP 服务器（内置 OAuth 2.1 + PKCE + 动态客户端注册，或 API Token；令牌存 Keychain）。然后**把文档链接粘贴到某场录音上**——Resound 经 MCP 取回正文、入库到同一知识库，和录音 + 本地文档一起参与检索、问答、纪要。取不全时智能降级：来源未连接 → 提示去连接；无法识别 / 内网地址 / 无权限 → 存成可跳转的**仅链接**引用。自定义来源支持远程（HTTP）或**本地 stdio**（起子进程，如 `npx -y @org/mcp-server`，环境变量只留本机）。在 **设置 › 外部 MCP 接入** 配置。
- **Resound 作为 MCP 服务器（提供 MCP）** — 把你的会议知识库作为本地 stdio MCP 服务器暴露给编码助手（**Claude Code / Codex**），让它们查询你的会议与文档——全程在本机。一键安装会替你写好助手配置（附手动命令兜底）；全局**内容策略**（完整 / 摘要+链接 / 仅链接）控制对外提供多少**外部来源**文档内容（你自己的录音转录始终完整提供）。在 **设置 › Resound MCP** 配置。
- **自带 Provider 配置** — 接入任意 OpenAI 兼容服务（OpenAI / Claude / DeepSeek / Groq / AIHUBMIX / 本地 Ollama / 自定义）：对话、向量、转写三种能力分别配置，一键「测试连接」实时验证（验证状态持久化，改 Key/模型自动失效）；首次启动有引导，转写不配则自动兜底本地 Whisper。录音库路径 / git 自动推送也在应用内配，改完即时生效、无需重编。
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

### 建一个属于自己的 Vault

> [!TIP]
> 在应用内你不用手动建：首次启动引导（以及 **设置 › 存储 › 录音库目录**）会让你选一个文件夹，然后**自动创建好 vault 数据结构**（`resound.yaml`、`people/people.yaml`、`recordings/` `documents/` `notes/`、用于 LFS 的 `.gitattributes`）。选已有 vault 则原样采用。下面的手动步骤面向 CLI 用户，或想自己预先配好 git 的人。

Vault 就是一个你自己拥有的文件夹（一个 git repo），结构小而固定。最小可用的脚手架：

```bash
mkdir my-resound-vault && cd my-resound-vault && git init

# 音频走 Git LFS（让 repo 文本可 diff、可移植）
cat > .gitattributes <<'EOF'
*.m4a  filter=lfs diff=lfs merge=lfs -text
*.flac filter=lfs diff=lfs merge=lfs -text
*.wav  filter=lfs diff=lfs merge=lfs -text
EOF

# Vault 配置（schema 带版本号，保留 schema 行）
cat > resound.yaml <<'EOF'
schema: resound.vault/1
vault_name: my-wiki
timezone: Asia/Singapore
default_language: zh
EOF

# 人物注册表——先只有你自己；之后给说话人命名都记在这里
mkdir people && cat > people/people.yaml <<'EOF'
schema: resound.people/1
people:
  - id: p_self
    name: 我
    aliases: [本人]
EOF

mkdir recordings
git add -A && git commit -m "init vault"
```

然后在 **设置 › 存储 › 录音库目录** 里把 Resound 指向这个文件夹（CLI 则在 `.env` 设 `VAULT_PATH`）。App 会校验 `resound.yaml` + `recordings/` + `people/`，全程读写这份本地副本，并在开启 git 同步后 commit + push 回你的 repo。

> [!IMPORTANT]
> Vault 里是你的个人数据（音频、转录、谁说了什么）。**请 push 到你自己的「私有」repo**，绝不要用公开 repo。每个文件的完整 schema 见[数据契约](docs/data-contract.md)。

## 快速上手

### 前置条件

- macOS 14+ / Apple Silicon
- Swift 6 工具链（Xcode 16+ 或 `swiftly`）
- 声纹依赖 sherpa-onnx 静态库（首次需本地编出，约百 MB，已 gitignore）

```bash
# 1. 编译 sherpa-onnx 声纹静态库（一次性）
scripts/build-sherpa-onnx.sh

# 2. 配置密钥：在仓库根目录创建 .env（见下方「配置」表）

# 3. 编译（首次会拉 WhisperKit / FluidAudio / swift-markdown 等依赖）
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

**普通用户（应用内）**：首次启动按引导，在 **设置 › AI 服务** 里选服务商预设（或自定义）、填 Base URL / API Key / 模型，「测试连接」通过即用。至少需一个**对话模型** + 一个**向量模型**（可来自不同服务商）；转写可留空走本地 Whisper。配置存本机 `~/Library/Application Support/Resound/providers.json`，密钥不出本机，可导入导出，改完即时生效。

**CLI / 进阶**：也可用仓库根目录 `.env`（已 gitignore，**绝不提交**），接口均为 OpenAI 兼容。App 优先读 `providers.json`、缺失时回退 `.env`（已有 `.env` 的老用户首启会自动迁移）。下表为 `.env` 变量：

| 变量 | 用途 |
|---|---|
| `AIHUBMIX_API_KEY` / `AIHUBMIX_BASE_URL` | Embedding（向量），缺省也用于在线转录 |
| `EMBEDDING_MODEL` / `EMBEDDING_DIM` | 向量模型与维度 |
| `CHAT_API_KEY` / `CHAT_BASE_URL` | LLM（DeepSeek 官方，OpenAI 兼容） |
| `TRANSCRIBE_ONLINE` / `TRANSCRIBE_MODEL` | 在线转录开关与模型（关则走本地 WhisperKit） |
| `TRANSCRIBE_API_KEY` / `TRANSCRIBE_BASE_URL` | 转录端点，缺省同 Embedding |
| `TRANSCRIBE_BACKEND` | `moss` = 优先 MOSS 云端转写（失败回退 whisper） |
| `MOSS_SUBMIT_URL` / `MOSS_RESULT_URL` / `MOSS_API_KEY` | MOSS 服务端点与密钥（应用内一键部署自动写入） |
| `CONTEXT_MODEL` | 逐 chunk contextual 增强（高频，默认 flash） |
| `CORRECT_MODEL` | 转录 AI 校对（默认 flash） |
| `RERANK_MODEL` | 召回重排 |
| `ANSWER_MODEL` / `SUMMARY_MODEL` | 最终综合 / 摘要（默认 pro） |

App 运行时会把根目录 `.env` 复制到 `~/Library/Application Support/Resound/.env`，并补 `VAULT_PATH`、`SPEAKER_MODEL`。

## CLI 命令

| 命令 | 说明 |
|---|---|
| `record` / `record-meeting` | 麦克风录音 / 会议双路录音 → 转录 → 写入 vault |
| `transcribe` | 把已有音频转录并写入 vault |
| `transcribe-correct` | 对已有转录补做 AI 校对（修同音错字 / 术语） |
| `watch-meet` | 监听 Chrome 是否在开 Google Meet |
| `diarize` / `speaker-recognize` | 说话人分割 / 用声纹库识别说话人 |
| `speaker-identify` | 用注册声纹识别并写回（注册新人后批量修旧录音） |
| `speaker-enroll` / `speaker-label` | 注册声纹 / 给已有索引就地打标签 |
| `diarize-eval` / `diarize-compare` | 用 ground-truth 评测 / 对比说话人识别方案 |
| `normalize` | 对已有转录重做繁→简归一 + 别名纠正 |
| `redate` | 按标题里的日期修正录音的会议日期 |
| `normalize-audio` | 对音频跑分窗自适应响度归一（调试用；与转录前归一同一实现） |
| `recover-meeting` | 从残留 mic/sys 临时轨流式混音（内存安全）抢救卡死丢失的会议 |
| `sync-speaker-names` | 把已注册说话人名字加入 vault 词表做偏置（命名说话人时也会自动加入） |
| `import-doc` | 导入本地文档到 vault + 建索引（md/txt/pdf/docx/pptx/html/图片，与录音一起参与问答） |
| `extract-doc` | 解析文档为 markdown 并打印（调试用，无需索引/配置） |
| `suggest-folder` / `suggest-tags` | 打印某条录音/文档的智能文件夹/tag 建议（调试用，调分类器 prompt） |
| `retidy-doc` | 对已导入文档就地重提取 + LLM 重排版，并重建其索引 |
| `index` | 从 vault 重建检索索引（切块 → embedding → SQLite/FTS5/vec） |
| `index-prune` | 清掉索引里已不在 vault 的录音（手动归档/删目录后跑一次） |
| `search` | hybrid 检索（FTS5 + 向量 + RRF） |
| `summarize` | 为录音生成 AI 摘要（写 summary.md + 入索引） |
| `ask` | 问答：检索 + 重排 + LLM 综合，输出带引用的答案 |
| `mcp serve` | 把 Resound 作为 stdio MCP 服务器，供编码助手（Claude Code / Codex）检索你的会议与文档（通常由助手拉起，不手动跑） |
| `mcp selftest` | 无头自检 MCP 服务器的工具（search/get/list）与安装命令 |
| `mcp sources` / `mcp fetch` / `mcp sync` | 查看外部 MCP 来源、解析粘贴的链接、重新同步外部文档（外部接入功能的调试命令） |
| `doctor` | 自检 sqlite-vec 等关键依赖 |

## 工作原理

```
录音 ─► VAD 门控(剪静音/噪声) ─► 转录(MOSS 云端·转录+说话人一体 / 在线 whisper / 本地 WhisperKit) ─► 繁简归一 + 词表纠错 + LLM 校对
   └─► 说话人识别(MOSS: 标签→CAM++ 声纹命名；whisper: Sortformer 分割@ANE → VAD → CAM++ 声纹 → 注册匹配)
                          │
切块 ─► contextual 增强 ─► embedding ─► SQLite(FTS5 + sqlite-vec)
                                              │
提问 ─► QueryPlanner(LLM 抽时间范围 / 判 qa·digest)
   └─► FTS5 + 向量召回 ─► RRF 融合 ─► LLM 重排 ─► 综合(带引用·带日期)
```

## 技术栈

- **本地**：AVAudioEngine · ScreenCaptureKit · WhisperKit · FluidAudio（Sortformer 分割 / silero VAD）· sherpa-onnx（CAM++ 声纹）· SQLite（FTS5 + sqlite-vec）
- **依赖**：[WhisperKit](https://github.com/argmaxinc/WhisperKit) · [FluidAudio](https://github.com/FluidInference/FluidAudio) · [swift-markdown](https://github.com/apple/swift-markdown)（仅解析；渲染是自研原生 SwiftUI 渲染器） · [swift-argument-parser](https://github.com/apple/swift-argument-parser)
- **API**：任意 OpenAI 兼容服务——对话 / 向量 / 转写三种能力可分别指派给不同服务商

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
