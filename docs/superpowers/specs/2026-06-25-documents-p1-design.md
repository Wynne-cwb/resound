# 文档模块 P1 设计（Documents — Phase 1: 地基）

> 日期：2026-06-25
> 状态：设计已与用户对齐，待 review → 转实现计划
> 范围：本 spec **只覆盖 P1**。P2（生成）/P3（富格式）/P4（在线集成）各自后续立 spec。

---

## 1. 背景与动机

Resound 定位是个人「会议知识库」。录音是核心模块，但一场会议通常伴随文档
（议程、PRD、slides、纪要）做信息同步。要让知识库完整，必须支持把这些文档
纳入：**与录音结合、并辅助 LLM 的检索与生成**。

文档模块是一个大方向，整体愿景包含三类生成诉求（文档当纪要背景、从录音+文档
生成新文档、问答混引文档+录音）和多种格式（md/txt、PDF、docx、PPT、
Google Docs/Notion/URL）。本 spec 只做**第一期地基**，把价值最快、风险最低的
部分先落地。

## 2. 关键决策（已与用户对齐）

| # | 决策 | 依据 |
|---|---|---|
| D1 | **文档是 wiki 一等公民，可关联 0~N 场录音、也可不关联** | 最 wiki-native；现有 `notes/` 与 `chunks` 表几乎为它准备好 |
| D2 | **主干方案 A：边缘归一化**——各格式入库时转成纯文本/markdown，下游只认归一化文本，原件留档 | 下游零改造；格式可逐个加，不阻塞主干。结构感知（页码/页号）作为后续增量增强 |
| D3 | **分期 P1→P4**，本期只做 P1 | 第一期即可用（导入 md/文本 → 问答里和录音一起被引用），不必等所有格式做完才见效 |
| D4 | **`documents/` 与 `notes/` 分成两个实体** | notes = app 内手写自由笔记；documents = 导入的外部文档（带原件、格式、导入溯源）。P1 都是 md 但语义与未来不同 |

## 3. P1 范围

**做：** 纯文本 / Markdown 文档成为 vault + UI 一等公民 → 自动进检索/问答（跨源引用）
→ 手动关联录音（双向）。

**不做（明确排除，留后续期）：**
- 生成能力（纪要用文档做上下文、从录音+文档生成新文档）→ P2
- PDF / docx / PPT 抽取、OCR → P3
- Google Docs / Notion / URL 拉取与同步 → P4

---

## 4. 架构主干

```
文档(md/txt) ──抽取(P1=原样)──► content.md ──► 切块 ──► enrichment ──► embedding ──► chunks 表
   │  原件留档(事实源)                       (复用 Chunker)   (复用)        (复用)   (加 source_kind / doc_id)
   │
   └─ documents/<id>/ : original.* + content.md + document.yaml(可 links:[recording:xxx])
                                                              │
检索/问答 ◄─── 复用 hybrid→RRF→rerank→synthesize（自动跨源；引用区分 📄文档 / 🎙️录音）
```

核心：文档切块进 `chunks` 后，**检索与问答几乎零成本即得**；P1 真正新写的是
① `documents/` vault 实体 ② chunks 来源区分 ③ 导入/详情/关联的 UI ④ 问答引用区分。

---

## 5. Vault 数据模型

### 5.1 `documents/` 目录（与 `recordings/`、`notes/` 平级）

```
documents/
  2026/06/
    2026-06-20-prd-search-revamp/      # id = 文件夹名（年/月分层，防单目录爆炸）
      document.yaml                    # 元数据（人可编辑，事实源）
      content.md                       # 规范化文本（P1 = 原文本身）
      original.md                      # 原件留档（事实源；P1 与 content 暂同源，P3 起分离）
```

### 5.2 `document.yaml`（schema 带版本号）

```yaml
schema: resound.document/1
id: 2026-06-20-prd-search-revamp
title: 搜索改版 PRD
source_format: markdown            # markdown | txt（P1 仅这两种；字段为 P3 预留）
imported_at: 2026-06-20T10:00:00+08:00
tags: [prd, search]
links: [recording:2026-06-18-1430-standup]   # 手动关联的录音，可 0~N；关联关系的单一事实源
```

- 关联关系**只存在 `document.yaml` 的 `links:`**（单一事实源），录音侧由索引镜像读出。
- `original.*` 后缀随 `source_format`（P3 起可能是 `.pdf`/`.docx`）。

---

## 6. Index 变更（向后兼容迁移）

现状：`chunks(id, recording_id, idx, text, context, start, end, person_id, recording_date)`。

新增两列（用既有 `addColumnIfMissing` 增量迁移，旧库平滑升级）：

```
source_kind  text default 'recording'   -- 'recording' | 'document'
doc_id       text                        -- 文档块填；录音块为 null
```

- **录音块**：`source_kind='recording'`，`recording_id` 照旧，`doc_id`/`start`/`end`/`person_id` 为 null（行为不变）。
- **文档块**：`source_kind='document'`，`doc_id` 填，时间/说话人列留空。
- `SearchHit` 增加 `source_kind`（及文档块的 `doc_id`/标题），问答据此渲染引用并决定跳转目标。
- 文档关联镜像：索引建一张 `doc_links(doc_id, recording_id)`（或等价结构），供录音侧「相关文档」快速反查；事实源仍是 `document.yaml`。

重建逻辑（§ data-contract 第 5 节）新增一个并行循环：遍历 `documents/`，读
`content.md` + `document.yaml` → 切块 → enrichment → embedding → `insertChunk(source_kind='document', doc_id=…)`。

---

## 7. Ingestion 流程（复用现有切块/embedding）

```
导入 md/txt
  → 写 documents/<id>/(content.md + original.* + document.yaml)
  → 切块（复用 Chunker；无时间轴，按段落/标题切）
  → enrichment + embedding（复用，零改）
  → insertChunk(source_kind='document', doc_id=…)
  → 镜像 doc_links
```

- 检索侧：`vectorSearch`/`ftsSearch` 默认**全源召回**（文档与录音一起进 RRF→rerank）；
  已有的按录音 scoping 不受影响。
- 新增**按文档 scoping**（`doc_id` 过滤），供「向本文档提问」用——是现有 `recordingId`
  过滤的镜像，低成本。

---

## 8. UI 功能设计（P1）

> 本节只定义「功能与状态」，视觉/布局/组件由设计阶段（Claude Design）决定。

新增/触及 **5 个功能面**：

1. **文档主面**（一等公民入口，与录音库平级）
   - 展示：每条文档的标题、标签、导入时间、已关联录音数
   - 操作：导入新文档、搜索、按标签筛选、打开、删除
   - 状态：空（还没有文档）、搜索无结果

2. **导入流程**
   - 来源：选本地 `.md`/`.txt`，或直接粘贴/输入文本
   - 可填：标题（可从文件名/首行预填）、标签（可选）
   - 状态：导入中 → 建索引中（异步耗时）→ 就绪；索引失败可重试
   - 结果：完成后出现在主面，且立即可被问答检索

3. **文档详情**
   - 展示：正文（渲染后的 markdown）、元数据（标题/标签/格式/导入时间）、已关联录音列表（可点跳转）
   - 操作：编辑标题/标签、管理关联录音、删除、查看原件
   - 「**向本文档提问**」：限定本篇的问答对话（与现有「向本场提问」对称；基础设施已支持按来源 scoping）

4. **关联录音（双向）**
   - 文档侧：加/删关联录音——能搜索并选择录音的选择器
   - 录音侧：录音详情新增「相关文档」区，列出关联文档并可点开

5. **问答里的跨源引用（扩展现有 Ask）**
   - 答案引用来源现在可能是「文档」或「录音」，两者一眼可区分
   - 点录音引用 → 跳到录音对应时间点；点文档引用 → 打开该文档并定位/高亮被引段落

**不在 P1 的 UI**：PDF/PPT 预览、生成相关界面、在线文档接入。

### 8.1 Claude Design Handoff Prompt（不预设视觉方向）

> 用户将把下面这段交给 Claude Design 出视觉设计。它只描述功能与状态 + 「与现有
> App 一致」这一条约束，不含任何颜色/间距/布局/组件取向。

```
为一款名为 Resound 的 macOS 原生桌面应用设计「文档」模块的界面。

【产品背景】
Resound 是一个面向个人的「会议知识库」桌面 App：把录音转成带说话人、
带时间轴的文稿，并支持用自然语言对全部内容提问、拿到带引用的答案。
现在要新增一个与「录音」平级的一等内容类型：用户导入的「文档」（本期仅
纯文本 / Markdown）。文档可以关联到某场会议录音，并和录音一起参与全局问答。

【设计目标】
为下列功能面设计界面。请你自行决定信息架构、布局、层级、组件与视觉表达——
本说明只描述「功能与状态」，不预设任何视觉方向。唯一约束是：新界面应与
这款 App 已有的部分（录音库、问答、设置三个主区，支持浅色/深色主题，
录音详情里已有一个「向本场提问」的标签页）在体验上自然一致，像同一款产品。

【要设计的界面】

1. 文档主面——浏览全部已导入文档
   - 每条展示：标题、标签、导入时间、已关联录音的数量
   - 操作：导入新文档、搜索、按标签筛选、打开某条、删除某条
   - 状态：无任何文档时的空状态；搜索无结果

2. 导入文档
   - 两种来源：选择本地文件，或直接粘贴/输入文本
   - 可填：标题（可自动从文件名/首行预填）、标签（可选）
   - 过程状态：导入中 → 建立索引中（耗时、异步）→ 就绪；以及索引失败可重试

3. 文档详情
   - 展示：正文（已渲染的 Markdown）、元数据（标题/标签/格式/导入时间）、
     已关联录音的列表（可点击跳转到该录音）
   - 操作：编辑标题/标签、管理关联录音、删除、查看原件
   - 含一个「向本文档提问」入口：在仅限本篇文档的范围内做问答对话
     （交互可参照本 App 已有的提问对话体验）

4. 关联录音
   - 在文档详情里：添加/移除关联录音——需要一个能搜索并选择录音的选择器
   - 在录音详情里：新增「相关文档」区，列出关联的文档并可点开

5. 问答里的引用区分（在已有的问答界面上扩展）
   - 答案下方的引用来源现在可能是「文档」或「录音」两种
   - 两种来源要让用户一眼可区分；点击录音引用跳到录音的对应时间点，
     点击文档引用跳到该文档并定位/高亮被引用的段落

【交付】
覆盖以上界面的高保真设计，并给出关键状态（空、加载/建索引中、错误、
正常有内容）。浅色与深色都需要。
```

---

## 9. 数据契约需要补充的条目

实现 P1 时同步更新 [docs/data-contract.md](../../data-contract.md)：
- 第 0 节边界表/校验：vault 校验逻辑可选识别 `documents/`（缺失不报错，向后兼容）。
- 新增 `3.x documents/<id>/` 目录与 `resound.document/1` schema。
- 第 4 节 Index：`chunks` 增 `source_kind`/`doc_id`；新增 `doc_links` 镜像表。
- 第 5 节重建逻辑：新增遍历 `documents/` 的并行循环。

## 10. 未决问题

- 无阻塞性未决项。「向本文档提问」（§8 文档详情）确认纳入 P1（低成本、与现有对称）；
  若实现期发现成本超预期，可降级为 P1.1。

## 11. 后续期（仅记录，不在本 spec 实现）

- **P2 生成**：关联文档喂进纪要生成；从录音+关联文档生成新纪要文档。
- **P3 富格式**：PDF / docx / PPT 抽取器（先吃有文本层的，OCR 最后）；`original` 与 `content` 分离；可选结构感知（页码/页号）增强引用。
- **P4 在线集成**：Google Docs / Notion / URL 拉取与同步。
