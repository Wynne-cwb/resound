# 文档模块 P2（纪要纳入关联文档）— 实现计划

> 日期：2026-06-25
> 上游 spec：[2026-06-25-documents-p2-summary-with-docs-design.md](../specs/2026-06-25-documents-p2-summary-with-docs-design.md)（范围 locked）
> 原则：质量>速度；后端先行 + CLI/单元可验证 → App 接线 → 收尾。无关联文档时**零回归**是硬约束。

## 现状勘查（动手前确认的事实）

- `Summarizer.summarize(...)`：当前签名/占位符填充逻辑、`{transcript}` 缺省兜底是怎么实现的（要镜像）。
- `Prompting.swift`：常量放这里。
- 摘要触发路径有几条（手动「生成」、「重新生成」、录音入库后自动摘要）——都在 `LibraryModel`，要统一接 referenceDocs。
- `Document.swift`：`listDocuments` / `documentContent` / `DocumentSummary.linkedRecordingIds` 已有，`linkedDocumentTexts` 在此新增。
- 摘要区 UI 在 `LibraryView`（summaryTab / 空状态）；「相关文档」卡（`relatedDocsCard`）已在 P1 落地，提示行点击滚动到它。

> ⚠️ 动手第一步先读这些文件确认签名，再按下面任务改；若现状与 spec 假设不符，停下来对齐。

---

## Wave 1 — Core（CLI/单元可验证，UI 无关）

- **T1.1 反查关联文档正文**
  `Document.swift` 加 `public func linkedDocumentTexts(vaultRoot:recordingId:) -> [(title: String, text: String)]`：`listDocuments(vaultRoot)` filter `linkedRecordingIds.contains(recordingId)` → 逐篇 `documentContent(dir:)`；读不到正文的跳过。纯函数。

- **T1.2 字数上限常量**
  `Prompting.swift` 加 `maxReferenceDocChars`（~16000）。

- **T1.3 「参考文档」块组装 + 截断**
  在 Summarizer（或 Prompting）加内部 helper `buildReferenceDocsBlock(_ docs:) -> String`：按 spec §4.2 格式拼（含顶部消歧提示）；累计超 `maxReferenceDocChars` → 边界截断当前篇 + 标注「（文档过长，已截断）」，其余篇不纳入 + 块尾「（其余 M 篇文档因长度未纳入）」。空数组 → 返回空串。

- **T1.4 `summarize` 接 referenceDocs + `{documents}` 占位符**
  `summarize(...)` 加 `referenceDocs: [(title:String, text:String)] = []`；按 spec §4.1 填充 `{documents}`（含则替换、不含但有文档则注入到 `{transcript}` 前、无文档则不注入）。`referenceDocs` 为空时**与现状逐字节一致**（回归保护）。

- **依赖**：无。**验证（CLI/最小脚本）**：
  - 造临时 vault：1 录音 + 2 关联文档（含一篇超长）→ `linkedDocumentTexts` 返回正确顺序/正文；超长篇被截断标注。
  - 组 prompt：含/不含 `{documents}`、有/无 referenceDocs 四种组合下，输出符合 §4（占位符位置、消歧提示、截断标注）。
  - 回归：referenceDocs=[] 时组出的 prompt 与改动前一致。

## Wave 2 — App 接线

- **T2.1 生成路径传 referenceDocs**
  `LibraryModel` 所有摘要生成入口（手动生成 / 重新生成 / 入库后自动摘要）在调 `summarize` 前先 `linkedDocumentTexts(vaultRoot:, recordingId:)`，把结果作为 `referenceDocs` 传入。vault 路径走现有 cfg()。

- **T2.2 摘要区可见提示**
  `LibraryView`：
  - 已生成摘要卡顶部：本场有关联文档时显示 `📄 本场关联的 N 篇文档已作为背景纳入`，点击滚动到上方「相关文档」卡（复用现有 ScrollViewReader/anchor）。
  - 空状态（「生成摘要」按钮旁）：有关联文档时显示 `将纳入本场关联的 N 篇文档作为背景`。
  - 照现有摘要 meta 文字风格（字号/颜色 text2/text3），无新设计。N 由 `documents.relatedDocuments(forRecording:)` 实时取。

- **依赖**：Wave 1。**验证（实机）**：spec §7 的 4 条（有关联→摘要体现文档背景+提示出现；无关联→零回归；超长→截断不崩；模板手写 `{documents}`→位置正确）。

## Wave 3 — 收尾

- **T3.1** 模板占位符说明同步：Templates 页占位符提示 + data-contract / 文档里把 `{documents}` 列入支持占位符。
- **T3.2** README 视情况（这是面向用户的能力增强：摘要会用关联文档）——双语各加一句。
- **T3.3** STATE.md 原地更新 + DECISIONS.md 追加本期决策与取舍。
- **依赖**：Wave 1+2 落定。

---

## 里程碑

- **M1 = Wave 1**：Core 完成 + CLI/脚本验证通过（含零回归）。
- **M2 = Wave 2**：App 接线 + 实机验收点过。
- **M3 = Wave 3**：文档/README/STATE/DECISIONS 同步。

## 风险 / 注意

- **零回归**是底线：referenceDocs 为空必须与现状完全一致——Wave 1 验证里专门有这条。
- **token 溢出**：超长转录 + 文档可能撑爆上下文；字数上限只管文档侧，转录侧维持现状（与今天同风险）。若实机遇到，再议是否给转录也加保护（不在本期）。
- **消歧**：「参考文档」块顶部提示必须有，防 LLM 把文档当成会上发言。
- 提示行的「N 篇」与某次摘要实际所用可能因事后改关联而轻微不一致（spec §6 已接受）。
