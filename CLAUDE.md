# Resound — Claude 工作指南 & 持久记忆机制

Resound = macOS 原生(Swift/SwiftUI, Apple Silicon)个人 wiki：**录音 → 转录 → 说话人识别 → 切块入库 → 检索/问答**。本仓库是**纯实现**，不含个人数据；数据放用户自配的 vault repo。

## 🧠 持久记忆机制（每个 session 必读必守）

Context 会被压缩/重启。为了无缝接续，状态沉淀在两份文件里：

1. **[docs/STATE.md](docs/STATE.md) — 当前状态**：现状、进行中、下一步、后台任务、待办/阻塞。**小而新**。
2. **[docs/DECISIONS.md](docs/DECISIONS.md) — 决策 & 已完成实践**：定下的技术选型/参数/结论 + 已完成功能 + 关键踩坑。**增长型日志**。

**规则**：
- **session 开始**：先读 STATE.md（知道现在在干嘛、下一步），需要细节再查 DECISIONS.md。
- **干活过程中**：状态有变就**更新 STATE.md**（这是"现在的快照"，过时内容删掉/移走）。
- **做出新决策 / 完成一个功能 / 踩到新坑**：**追加到 DECISIONS.md**（带日期，别删历史）。
- **压缩 context 前**：确保 STATE.md 反映真实现状（这样压缩后能接续）。
- 其他参考：数据契约 [docs/data-contract.md](docs/data-contract.md)；密钥在 gitignored `.env`。

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
- 质量 > 速度（用户定的原则）：凡"快 vs 准"默认选准。
