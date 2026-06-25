# 文档模块 P1 实现计划（Documents — Phase 1）

> 日期：2026-06-25
> 依据 spec：[../specs/2026-06-25-documents-p1-design.md](../specs/2026-06-25-documents-p1-design.md)
> 方法：按 writing-plans 思路拆任务（writing-plans 技能未安装，直接产出）。

## 编排原则

- **后端先行、UI 后接**：后端不依赖 UI 设计稿，且可用 **CLI 无头验证**（GUI 看不到，靠 CLI + 截图）。UI 等用户拿 spec §8.1 的 prompt 让 Claude Design 出图后再接线。
- **复用优先**：切块/enrichment/embedding/检索/问答管线已 source-agnostic，最大化复用，最小化新代码。
- **向后兼容**：`chunks` 加列走 `addColumnIfMissing`；vault 无 `documents/` 不报错。
- **原子提交**：每个任务一笔（或数笔）可独立编译通过的提交。

---

## Wave 1 — 后端数据层（无 UI 依赖，CLI 可验证）

### T1.1 Document 模型 + DocumentStore（vault 读写）
- **做**：新增 `Document` 模型（id/title/sourceFormat/importedAt/tags/links）与 `DocumentStore`：
  读写 `documents/<id>/document.yaml`（`resound.document/1`）+ `content.md` + `original.*`；
  id 用「日期-slug」生成（仿录音 id）。仿 [Vault.swift](../../../Sources/ResoundCore/Vault.swift) / [Models.swift](../../../Sources/ResoundCore/Models.swift) 既有 YAML 读写风格。
- **文件**：`Sources/ResoundCore/Document.swift`（新）、必要时 `Models.swift`。
- **验收**：单测/CLI 临时跑——写一个 doc 文件夹再读回，字段往返一致。

### T1.2 chunks 表来源区分 + 检索改造
- **做**：① `chunks` 加 `source_kind text default 'recording'`、`doc_id text`（`addColumnIfMissing`）；
  新增 `doc_links(doc_id text, recording_id text)` 表。
  ② `insertChunk` 增 `sourceKind`/`docId` 参数（默认 recording，旧调用不变）。
  ③ `SearchHit` 增 `sourceKind`、`docId`、`docTitle`；`vectorSearch`/`ftsSearch` select 出 `source_kind`/`doc_id`，
  并新增可选 `docId` scoping（镜像现有 `recordingId` 过滤）。
  ④ 新增 `deleteChunks(docId:)`、`doc_links` 读写。
- **文件**：[Index.swift](../../../Sources/ResoundCore/Index.swift)。
- **依赖**：T1.1。
- **验收**：旧库打开自动迁移（pragma 看到新列）；录音检索行为零回归（CLI `search` 旧问题结果不变）。

### T1.3 文档 ingest（复用切块/embedding）
- **做**：① Chunker 加无时间轴路径 `chunk(text:)`（按段落/标题切，`start/end` 留空/0）——
  不动现有 `chunk(_ transcript:)`。② `IndexPipeline` 加 `indexDocument(docDir:indexPath:...)`：
  读 content.md + document.yaml → 切块 → enrichment + embedding（复用）→ `insertChunk(sourceKind:.document, docId:)` → 镜像 doc_links。
- **文件**：[Chunker.swift](../../../Sources/ResoundCore/Chunker.swift)、[IndexPipeline.swift](../../../Sources/ResoundCore/IndexPipeline.swift)。
- **依赖**：T1.2。
- **验收**：对一个 md 文档跑 indexDocument，chunks 表出现 source_kind='document' 的行、向量/FTS 都建上。

### T1.4 `index` 全量重建纳入文档 + CLI `import-doc`
- **做**：① CLI `index`（[ResoundCLI.swift](../../../Sources/resound/ResoundCLI.swift) `IndexCommand`）重建时新增遍历 `documents/` 的并行循环。
  ② 新增 CLI `import-doc <file> [--title --tags --link <recId>]`：把本地 md/txt 导入 vault + 建索引（**无头验证主入口**）。
- **文件**：`ResoundCLI.swift`。
- **依赖**：T1.3。
- **验收**：`resound import-doc note.md` → vault 出现 documents/<id>/，索引含其 chunks。

### T1.5 跨源检索/问答 + 按文档 scoping + 引用带来源
- **做**：① 确认 `search`/`ask` 默认全源召回（文档+录音一起 RRF→rerank）。
  ② `IndexPipeline` 加 `answerInDocument(question:documentId:...)`（镜像 `answerInRecording`）。
  ③ 综合/引用渲染带 `sourceKind`（CLI `ask` 输出区分 📄文档/🎙️录音 + 文档显示标题、录音显示时间）。
- **文件**：[IndexPipeline.swift](../../../Sources/ResoundCore/IndexPipeline.swift)、[Synthesizer.swift](../../../Sources/ResoundCore/Synthesizer.swift)、`ResoundCLI.swift`（Ask 输出）。
- **依赖**：T1.4。
- **验收（Wave 1 总验收 / 关键 gate）**：
  导入一篇含某独有事实的 md → `resound ask "<只有该文档答得了的问题>"` → 答案命中且引用标为 📄文档；
  再问一个录音相关问题 → 仍正常引用录音。**跨源问答闭环跑通 = Wave 1 完成。**

---

## Wave 2 — App 视图模型（无最终视觉依赖，可先写）

### T2.1 DocumentsModel（列表/导入/详情/关联状态）
- **做**：仿 [LibraryModel.swift](../../../Sources/ResoundApp/LibraryModel.swift)：文档列表加载、导入（文件/粘贴）、
  删除、编辑元数据、管理关联录音、导入/建索引的异步状态（importing/indexing/ready/failed）。
- **依赖**：Wave 1。

### T2.2 向本文档提问（逻辑层）
- **做**：仿 [RecAskStore.swift](../../../Sources/ResoundApp/RecAskStore.swift) + `LibraryModel.askRecording` → 文档版
  （按 docId scoping 调 `answerInDocument`，按 docId 持久化对话）。
- **依赖**：T2.1、T1.5。

---

## Wave 3 — UI 接线（在 Claude Design 出图后）

> 视觉/布局以设计稿为准；以下是要接的功能面（spec §8）。

- **T3.1** 文档主面 + 主导航入口（浏览/搜索/筛选/导入/删除/空状态）
- **T3.2** 导入流程视图（文件/粘贴 + 标题/标签 + 状态机）
- **T3.3** 文档详情（渲染 md + 元数据 + 关联录音列表 + 「向本文档提问」）
- **T3.4** 关联录音双向（文档侧选择器 / 录音详情「相关文档」区）
- **T3.5** Ask UI 跨源引用区分 + 文档引用点击跳转并高亮被引段落
- **T3.6** 同步 [data-contract.md](../../data-contract.md)（§9 列出的条目）
- **依赖**：Wave 2 + 设计稿。

---

## 落地顺序与里程碑

```
M1 (后端闭环)：T1.1 → T1.2 → T1.3 → T1.4 → T1.5     ← CLI 可完整验证「导入文档→跨源问答带文档引用」
M2 (视图模型)：T2.1 → T2.2                          ← 可先写，等设计稿接 UI
M3 (UI 接线) ：T3.1…T3.6                            ← 拿到 Claude Design 设计稿后
```

**建议现在就推进 M1**（后端，UI 无关、可无头验证）。M3 等设计稿。M2 可与「等设计稿」并行先写。

## 风险 / 注意

- **Chunker 无时间轴**：文档块 `start/end`/`person_id` 为空，确保下游（引用渲染、`chunkTimes`/`chunkPersons` 等按 recordingId 的查询）不被文档块干扰——这些查询都带 `where recording_id=?`，文档块 recording_id 为 null 故天然不命中，低风险，但实现时复核。
- **enrichment 成本**：文档可能很长 → chunk 数多 → embedding/enrichment 调用多。P1 先不优化，但导入大文档时 UI 要有「建索引中」进度（T2.1 已含）。
- **id 冲突**：同标题同日导入两篇 → id 加序号去重（仿录音）。
