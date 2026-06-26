# 智能推算文件夹 / Tag — 实现计划

> 日期：2026-06-26 ｜ 设计：[specs/2026-06-26-auto-classify-folder-tag-design.md](../specs/2026-06-26-auto-classify-folder-tag-design.md)
> 路径 2（独立分类器）｜ 建议+确认 ｜ 列表角标 ｜ 入库自动 + 重新推算

## 现状勘查（动手前确认的事实）

- **录音文件夹**：`LibraryModel`（App）持有 `folders: [LibraryFolder]` + `assign: [recId:folderId]`，落盘 `LibraryStore.save(LibraryOrganization(...), vaultRoot:)`（[LibraryModel.swift:527](../../Sources/ResoundApp/LibraryModel.swift)）。新建文件夹经 `folderEditor`。事实源 `library.json`。
- **录音入库摘要**：Core `IndexPipeline.summarizeRecording`（写 `summary.md`，[IndexPipeline.swift:278](../../Sources/ResoundCore/IndexPipeline.swift)）；App 自动入库路径在 [LibraryModel.swift:670](../../Sources/ResoundApp/LibraryModel.swift) 调用、手动重生成在 :801。**挂载点 = 这两处 summarize 成功之后**。
- **文档入库**：App `DocumentsModel.ingestFile`（[DocumentsModel.swift:265](../../Sources/ResoundApp/DocumentsModel.swift)）→ `store.importDocument` → `indexDocument`。**挂载点 = indexDocument 之后**。`content.md` 经 `DocumentsModel.content` 已可读。
- **文档 tag 写入**：`DocumentStore.updateManifest(dir:tags:)`（[DocumentsModel.swift:391](../../Sources/ResoundApp/DocumentsModel.swift)）。
- 可参照：`ChatClient`（complete）、`config.correctModel`、`AppLog`（静默失败落 resound.log）、调试 CLI（`ExtractDoc`）、`CorrectionLearner`（观察存 App Support）。

## Wave 1 — Core：AutoClassifier（CLI 无头可验证，UI 无关）

1. **`Sources/ResoundCore/AutoClassifier.swift`**（新增，纯函数）：
   - `struct FolderSuggestion { existingId: String?; newName: String? }`、`struct TagSuggestion { tag: String; isNew: Bool }`。
   - `func suggestFolder(summary:title:existingFolders:[LibraryFolder]) async throws -> FolderSuggestion?`
   - `func suggestTags(content:title:existingTags:[String]) async throws -> [TagSuggestion]`（0-2 个）。
   - 私有 helper：构 prompt（要求**优先从现有列表选**，确无才提新建；输出 JSON）+ 解析 + **大小写归一去重**（新名命中现有 → 归并为选中现有）+ 文档正文截断上限（取 16000 字，与 `MarkdownTidier`/摘要量级一致）。
   - 模型默认 `config.correctModel`（flash）。无合适 → nil/空（不硬凑）。
2. **调试 CLI**（仿 `ExtractDoc`，仅需 chat key）：
   - `suggest-folder <recDir>`：读 summary.md/title + 现有 library.json folders → 打印建议。
   - `suggest-tags <docDir>`：读 content.md/title + 现有全库 tags → 打印建议。
   - 注册进 `ResoundCLI` subcommands。
3. **验收（无头）**：用 `vaults/wayne-resound` 真实数据跑——1-on-1 录音命中现有文件夹、全新主题提新建、模糊→空；文档命中现有 tag / 提新 tag。**先把 prompt 调绿再进 Wave 2。**

## Wave 2 — App 接线（UI + 存储 + 落地）

4. **`SuggestionStore`**（App Support `auto-suggestions.json`）：按 asset id 存 `{kind, suggestion, state: pending|dismissed}`；增删查 + 持久化。
5. **入库挂载**：
   - 录音：`LibraryModel` 自动 summarize（:670）成功后，后台 `Task` 调 `suggestFolder`（仅当该录音 `assign` 无值）→ 存 pending。失败静默（AppLog）。
   - 文档：`DocumentsModel.ingestFile` 的 `indexDocument` 后，调 `suggestTags`（仅当 tags 空）→ 存 pending。
6. **列表角标**：录音列表 / 文档列表行——有 pending 建议时显示赤陶橙小圆点 +「建议」。点角标 → 行内小浮层：录音「建议归入【X】(新)」、文档「建议 tag：A、B」+ `[采纳]` `[忽略]`。
7. **落地写回**：
   - 采纳-录音：`assign[recId]=folderId`（新建则先 append `LibraryFolder`）→ `LibraryStore.save` → 删 pending。
   - 采纳-文档：`updateManifest(dir:tags:)`（整组接受，tag 不重建索引）→ 删 pending。
   - 忽略：标记 dismissed（不再冒泡）。
8. **详情页「重新推算」**：录音详情 / 文档详情各加入口，重跑分类器、覆盖 pending（含此前 dismissed）。

## Wave 3 — 收尾

9. **README 双语**：新增用户可见能力（智能推算文件夹/Tag）→ 同步「功能特性」+（如加了 CLI）「CLI 命令」。
10. **STATE / DECISIONS** 同步（决策 + 验收点）。
11. `swift build` → `killall Resound` → `bundle-app.sh release` → `open` 实机验收。

## 里程碑

- **M1 = Wave 1**：调试 CLI 对真实数据给出合理建议（prompt 验绿）。
- **M2 = Wave 2**：入库自动出角标、点开采纳/忽略写回正确、重新推算可用（实机）。
- **M3 = Wave 3**：README/STATE/DECISIONS 同步 + 实机验收过。

## 风险 / 注意

- **prompt 质量是成败点**：先靠 Wave 1 的 CLI 无头迭代，别在 UI 里调 prompt。
- **派生存储不进 vault**：pending 建议只在 App Support；只有采纳才动 library.json / document.yaml。
- **零回归**：分类失败/空 → 无角标、入库照常；老资产无 pending（靠重新推算逐条触发）。
- **token**：每条入库一次小调用（输入是已浓缩摘要/截断正文 + 现有列表），便宜；不做全库回溯。
