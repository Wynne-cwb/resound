# Resound — Claude 工作指南 & 持久记忆机制

Resound = macOS 原生(Swift/SwiftUI, Apple Silicon)个人 wiki：**录音 → 转录 → 说话人识别 → 切块入库 → 检索/问答**。本仓库是**纯实现**，不含个人数据；数据放用户自配的 vault repo。

## 🗣️ 沟通语言

**始终用中文跟用户交流**（对话回复、解释、提问都用中文）。用户来自新加坡、正在学中文，中文是其官方语言之一。代码标识符、命令、技术术语、文件内英文等保持原样不必翻译。

## 🧠 持久记忆机制（每个 session 必读必守）

Context 会被压缩/重启。状态沉淀在两份文件，职责严格区分：

| 文件 | 是什么 | 写法 |
|---|---|---|
| **[docs/STATE.md](docs/STATE.md)** | 当前状态**快照**：现状/进行中/下一步/后台任务/待办阻塞 | **原地覆盖**，过时即删/移走，保持 ≤1 屏 |
| **[docs/DECISIONS.md](docs/DECISIONS.md)** | 决策 & 已完成实践 & 踩坑的**增长日志** | **追加**，带日期，永不删历史 |

### 何时更新（触发点 → 动作）—— 触发即更，别攒着

| 触发点 | 更 STATE | 追加 DECISIONS |
|---|---|---|
| session 开始 | 先**读**（不写）；需细节查 DECISIONS | — |
| 切换当前焦点 / 下一步变了 | ✅ 改"现状/下一步" | — |
| 启动/完成后台任务(workflow/agent) | ✅ 改"后台任务" | 完成且有结论时 ✅ |
| **定下一个决策**(选型/参数/方案) | ✅ 若影响下一步 | ✅ 必写(决策+依据+日期) |
| **完成一个功能并验证** | ✅ 移进"已完成" | ✅ 一行记功能+怎么验的 |
| **踩到新坑/得到反直觉结论** | 若改变方向 ✅ | ✅ 必写(现象+根因+对策) |
| 遇到阻塞 / 等用户输入 | ✅ 写进"待办/阻塞" | — |
| **压缩 context 前 / 结束工作** | ✅ **必须**确保 STATE 反映真实现状 | 把本轮新决策补齐 |

### 怎么写（清晰度铁律）

- **STATE 永远能在 1 分钟内回答三问**：现在在干嘛？下一步具体做什么？卡在哪/等什么？做不到就是 STATE 太肥或过时。
- **不重复**：STATE 只放"现在/下一步"的精简结论，细节/依据放 DECISIONS，STATE 用链接指过去。
- **STATE 顶部更新"最近更新"日期**；DECISIONS 每条带日期。
- 改完代码做了实质进展，就顺手把这两份同步了再继续——别等到最后一次性补(会漏)。
- 这两份是 in-repo 文件，随相关改动一起 commit（不必单独刷 commit）。

其他参考：数据契约 [docs/data-contract.md](docs/data-contract.md)；密钥在 gitignored `.env`。

## 快速上手

```bash
swift build                                   # 首次会拉 WhisperKit/FluidAudio 等依赖
.build/debug/resound <子命令>                  # transcribe/record/normalize/diarize/diarize-eval/index/search/ask/doctor
```
- 配置/密钥：repo 根 `.env`（gitignored，含 aihubmix embedding key + DeepSeek chat key）。
- 用户 vault 本地工作副本：`vaults/wayne-resound/`（gitignored）。
- 索引：`~/Library/Application Support/Resound/index.sqlite`（派生物，可重建）。

## 工程约定

- Swift 6 工具链但 **language mode v5**（避开严格并发）。`@main` 不放 `main.swift`。
- C 依赖用 amalgamation + C target 静态链（见 CSQLiteVec）。
- 提交：用户要求才 commit/push；`.env`/`vaults/`/`.build/`/`*.sqlite` 绝不进 git。
- **改了功能就同步 README**：每次 commit/push **前**必须检查 [README.md](README.md) 是否需要更新（尤其「功能特性」/「配置」/「CLI 命令」）——面向用户的能力有增删改就一起改 README，纯内部重构/修 bug 无外部可见变化可跳过，但要确认过。
- 质量 > 速度（用户定的原则）：凡"快 vs 准"默认选准。
