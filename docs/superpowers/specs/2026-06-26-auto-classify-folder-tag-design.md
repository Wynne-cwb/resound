# 智能推算文件夹 / Tag — 设计

> 日期：2026-06-26
> 状态：设计已确认，待写实现计划

## 1. 目标

降低手动组织成本：
- **录音 → 智能推算文件夹**（单选，落 `library.json` 的 `assign`）
- **文档 → 智能推算 Tag**（1-2 个核心 tag，落 `document.yaml` 的 `tags`）

核心交互原则（用户确认）：**建议 + 确认，绝不自动改动用户数据**。

## 2. 已确认的决策

| # | 决策 | 选择 |
|---|---|---|
| 1 | 落地方式 | **建议 + 确认**（AI 给建议，用户一键采纳/忽略，绝不擅自改） |
| 2 | 能否新建 | **优先复用现有文件夹/tag，必要时提议新建**（新建项标「新」，确认才真建） |
| 3 | 触发时机 | **入库时自动算 + 详情页「重新推算」入口** |
| 4 | 数量 | 录音 = **1 个**文件夹；文档 = **1-2 个核心** tag，整组一键接受 |
| 5 | 呈现位置 | **列表项角标**（有建议的行显示小标记，点开确认） |
| 6 | 实现路径 | **路径 2：独立分类器**（单独 Core 单元，入库后用摘要/正文各跑一次小 LLM 调用） |

## 3. 现状（实现锚点）

- **录音文件夹**：`LibraryFolders.swift` — `library.json` 存 `{ folders: [{id,name}], assign: [recordingId: folderId] }`。一条录音归一个文件夹。纯组织层，不动录音目录/契约。
- **文档 tag**：`Document.swift` — 每篇 `document.yaml` 的 `tags: [String]`，自由字符串。`DocumentsModel` / `DocumentsView` 已有按 tag 筛选。tag **不参与 embedding**，是组织/筛选元数据。
- **可复用信号**：录音入库末尾生成 `summary.md`（最浓缩）；文档入库写 `content.md`（正文）。
- **既有模式可参照**：词表建议「观察存 App Support、确认才进 vault」（`CorrectionLearner`）；解析「失败不抛」（`DocumentExtractor`）；调试 CLI（`extract-doc` / `diarize-compare`）；静默失败落 `resound.log`（`AppLog`）；派生 LLM 结果缓存（`enrichment_cache`）。

## 4. 架构

```
入库（摘要/正文就绪）
  → Core 分类器跑一次小 LLM 调用（输入：浓缩信号 + 现有文件夹/tag 列表）
  → 建议存「派生存储」（App Support，不进 vault）
  → 列表项角标
  → 用户点角标确认：采纳 → 写回 vault 事实源 / 忽略 → 消角标 + 标记 dismissed
```

**关键不变量**：未确认的建议**绝不**写进 vault（`library.json` / `document.yaml`），只存在 App Support 的派生存储，确认才落地。沿用词表建议的「观察→确认」分层。

## 5. 组件

### 5.1 Core 层：`AutoClassifier.swift`（新增，纯函数、无副作用、可单测）

```
struct FolderSuggestion { existingId: String?; newName: String? }   // 二选一；都为空表示无建议
struct TagSuggestion    { tag: String; isNew: Bool }

func suggestFolder(summary: String, title: String,
                   existingFolders: [LibraryFolder]) async throws -> FolderSuggestion?
func suggestTags(content: String, title: String,
                 existingTags: [String]) async throws -> [TagSuggestion]   // 0-2 个
```

- **无合适项 → 返回 nil / 空数组**（不打扰，不硬凑）。
- 共用私有 helper：构建结构化 prompt（要求模型优先从现有列表里选，确实没有才提新建名）+ 解析 JSON + **大小写归一去重**（提议的新名若命中现有项，归并为「选中现有」而非新建）。
- 模型：沿用 `config.correctModel`（flash，与校对/排版整理一致），便宜。输入是已浓缩的摘要 / 截断正文，成本低。
- 文档正文超长时截断到上限（与 `MarkdownTidier` / 摘要的字数闸一致的量级，避免长文档撑爆 prompt）。

### 5.2 App 层：`SuggestionStore`（App Support `auto-suggestions.json`）

按 asset id 存 `{ kind: folder|tags, suggestion, state: pending|dismissed }`。
- `pending` → 列表角标显示。
- `dismissed` → 不再自动冒泡（仅「重新推算」可覆盖重置）。
- 采纳后删除该条（已落 vault，不再是建议）。

## 6. 数据流与落地细节

- **挂载点**：录音 = 摘要生成完之后；文档 = `content.md` 写好之后。在 App 层入库完成处调用 Core 分类器（Core 保持纯函数，编排/存储/UI 归 App，符合现有 `LibraryModel` 管 `library.json`、`DocumentsModel` 管 tag 的分工）。
- **只对「未归类」资产自动建议**：录音入库时本就无文件夹 → 必给；已手动归类的不打扰。文档 = 无 tag 才自动给。「重新推算」可对任意资产强制重跑。
- **角标交互**：列表行有 pending 建议时显示小标记（赤陶橙小圆点 + 「建议」）。点角标 → 行内小浮层：「建议归入【X】」/「建议 tag：A、B」+ `[采纳]` `[忽略]`；新建项标「新」，采纳时才真建文件夹。
- **采纳写回**：
  - 录音 → `library.json` 的 `assign[recordingId] = folderId`；新建则先 append `LibraryFolder`。
  - 文档 → `document.yaml` 的 `tags`（整组接受）。tag 不参与 embedding，**无需重建索引**，落地很轻。
- **详情页「重新推算」**：重跑分类器、覆盖 pending 条目（含此前 dismissed 的）。

## 7. 错误处理

- 分类 LLM 失败 / JSON 解析失败 / 无合适项 → **静默无建议**，经 `AppLog` 落 `resound.log`，**绝不阻断入库**（同 `DocumentExtractor` 失败不抛）。
- 提议新名与现有项大小写不敏感冲突 → 视为选中现有，不重复建文件夹/tag。

## 8. 测试

- **先加调试 CLI**（仿 `extract-doc`，仅需 chat key）：
  - `suggest-folder <recDir>`：打印对该录音的文件夹建议。
  - `suggest-tags <docDir>`：打印对该文档的 tag 建议。
  - 目的：**先把 prompt 质量验绿再接 UI**，无头可复现。
- 用例：
  1. 1-on-1 录音（库里已有「1-on-1 会议」文件夹）→ 命中现有，不新建。
  2. 全新主题录音 → 提议新建合理文件夹名。
  3. 模糊 / 信息不足 → 返回空，不打扰。
  4. 文档命中现有 tag → 复用；全新主题 → 1-2 个新 tag 标「新」。
  5. 分类调用失败 → 入库照常完成、无角标、`resound.log` 有记录。

## 9. 范围（YAGNI）

- 录音 1 文件夹、文档 1-2 tag。
- 仅列表角标（**不做**集中收件箱 / 详情页内嵌条）。
- 不向用户展示置信度（内部阈值决定给不给）。
- dismissed 不自动复现（仅手动重算）。
- 不做批量/全库回溯推算（老资产靠「重新推算」逐条触发）。

## 10. 不在本期

- 多文件夹 / 文件夹层级。
- tag 参与检索过滤的增强。
- 全库一键回溯推算。
