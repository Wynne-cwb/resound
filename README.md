# Resound

Mac 原生个人 wiki：**录音 → 转录 → 说话人识别 → 切块入库 → 检索**。

Resound 本身是**纯实现**，不含任何个人数据。数据存在用户自己指定的、符合
[数据契约](docs/data-contract.md) 的 git repo（vault）中。

## 架构边界

| | 内容 | 位置 | 性质 |
|---|---|---|---|
| **App**（本 repo） | Swift/SwiftUI 实现 | `Wynne-cwb/resound` | 程序，不含数据 |
| **Vault** | 音频/转录/标注/人物/笔记 | 用户配置的 git repo | 事实源，可移植 |
| **Index** | SQLite + FTS5 + sqlite-vec + 声纹 | 本地 App Support | 派生物，可重建 |

核心不变量：**删掉 Index，App 能从 Vault 完整重建。**

## 技术栈

- **本地**：AVAudioEngine 录音 · WhisperKit 转录 · sherpa-onnx diarization + 声纹 · SQLite(FTS5 + sqlite-vec) · RRF 融合
- **API**：Qwen3-Embedding-0.6B（向量）· rerank（bge-reranker-v2-m3）· DeepSeek / 硅基流动（contextual 增强 / 元数据抽取 / 综合）

## 文档

- [数据契约 docs/data-contract.md](docs/data-contract.md) — 项目地基，所有模块遵守
