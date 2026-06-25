# 文档模块 P3：富格式解析（PDF/Word/PPT/HTML/图片）入库 — 设计 spec

> 日期：2026-06-25　状态：待 review（已据"自研零依赖"决策修订）
> 上游：文档模块 P1（文档成一等检索/问答源）+ P2（关联文档纳入纪要）均已落地。
> 原始诉求：现在文档导入只吃 md/txt；用户希望能直接导入真实的会议材料——PDF、Word、PowerPoint、HTML、图片（含扫描件/截图），由程序解析出文字塞进检索/问答/纪要链路。

## 1. 范围（locked）

经与用户多轮澄清确定：

| 决策点 | 选择 |
|---|---|
| **支持格式** | PDF、Word(.docx)、PowerPoint(.pptx)、HTML、图片（png/jpg/jpeg/heic/tiff/…）。**不做** Excel |
| **OCR** | 图片**必走** OCR；扫描型/图片型 PDF（无文本层）**自动回退** OCR。识别语言：中（简+繁）+ 英 |
| **提取保真度** | 尽量转**结构化 markdown**（标题/列表/表格），而非一坨平文本 |
| **实现路线** | **全自研、零外部依赖**——全用 macOS 原生框架（PDFKit / Vision / Compression / XMLParser）。**不引第三方库、不升工具链、不升系统** |
| **PDF 不直接 OCR** | 数字版 PDF 用 PDFKit 文本层（`attributedString` + 排版推断标题），**只有扫描件**才 OCR——直接 OCR 数字 PDF 反而丢真字、引错 |

> **为什么自研**：最优库 SwiftText 需 Swift 6.1（package traits），而升 6.1 要么升 macOS 15（动静太大）、要么装独立 toolchain（build/打包要切 TOOLCHAINS、有 SwiftPM 小毛病）。底层能力其实同源（都是 PDFKit/Vision），自研只是多写标题推断与表格代码，**换来零升级零依赖**——在当前 Swift 6.0.3 / macOS 14.5 直接可跑。

**做**：导入上述格式时，解析出结构化 markdown 写入 `content.md`（进现有索引/问答/纪要链路），真实原件二进制留档为 `original.<ext>`。下游（切块/embedding/检索/问答/纪要纳入）**零改动**。

**不做（各自留后续）**：
- Excel/.xlsx、CSV 表格。
- 在线源（Google Docs/Notion/URL）= P4。
- 文档内嵌图片的图注 OCR（只 OCR 整图 / 整页扫描件，不抠正文里的插图）。
- macOS 26 的 Vision `RecognizeDocumentsRequest`（结构化表格/列表）——以后升级了再 `#available` 接（非本期）。

## 2. 技术栈（全原生，零依赖）

| 能力 | 框架 | 备注 |
|---|---|---|
| PDF 文本+属性 | **PDFKit** `PDFDocument`/`PDFPage.attributedString` | 字号/加粗 → 标题层级推断 |
| 图片 / 扫描件 OCR | **Vision** `VNRecognizeTextRequest`（accurate） | `recognitionLanguages = ["zh-Hans","zh-Hant","en-US"]`；macOS 10.15+，14.5 可用 |
| docx/pptx 解压 | **Compression** 框架手写最小 zip 读取器 | `COMPRESSION_ZLIB` 正好吃 zip 的 raw deflate；**不 shell out、不加依赖** |
| docx/pptx/HTML XML | **Foundation** `XMLParser` | 流式解析 |

**无 `Package.swift` 改动**（tools-version 仍 6.0、language mode v5）、**无新增 SPM/C 依赖**。

## 3. 架构：一个提取器，一处接入

### 3.1 新增 `Sources/ResoundCore/DocumentExtractor.swift`

单一入口，按扩展名/UTType 分派：

```swift
public struct ExtractResult {
    public var markdown: String       // 提取出的结构化正文（写 content.md）
    public var sourceFormat: String   // "pdf" | "docx" | "pptx" | "html" | "image" | "markdown" | "txt"
    public var warnings: [String]     // 解析告警（空正文/加密/OCR无字等），上层提示用
}

/// 把任意支持的文件解析成结构化 markdown。失败不抛——返回空 markdown + warnings，让原件照常留档。
public func extractDocument(url: URL) -> ExtractResult
```

各格式提取器（同文件内或拆小文件）：

| 扩展名 | 提取器 | 产出 |
|---|---|---|
| `pdf` | PDFKit 逐页 `attributedString` → 按字号/加粗映射 `#`/`##`/正文；**全文几乎为空 → 判定扫描件 → 渲染每页 `NSImage` 走 Vision OCR** | 结构化 md（数字版）/ 文本（扫描版），页间空行 |
| 图片 | Vision `VNRecognizeTextRequest`（中简繁+英），按识别行拼接 | 按行文本 |
| `docx` | mini-unzip → `XMLParser(word/document.xml)`：`w:pStyle=Heading*`→`#`、`w:numPr`→`-`、`w:tbl`→markdown 表、`w:p`→段落 | 结构化 md |
| `pptx` | mini-unzip → 逐张 `ppt/slides/slideN.xml` 收 `<a:t>` → 每页 `## 第 N 页` + 文本 | 按页 md |
| `htm`/`html` | 手写常见标签→markdown（h1-6/p/ul-ol-li/table/a/strong/em/pre/br）；异常回退 `NSAttributedString(html:)` 剥纯文本 | 结构化 md |
| `md`/`markdown`/`txt` | 直通（现状逻辑） | 原样 |

> **mini-unzip**：docx/pptx 本质是 zip+XML。手写 ~150 行最小 zip 读取器——解析 End of Central Directory → 遍历中央目录 → 对需要的条目读 local header + 压缩数据 → `compression_decode_buffer(COMPRESSION_ZLIB)` 解 raw deflate。docx/pptx 共用。

### 3.2 接入点改造（最小）

现状导入链：`读 UTF8 字符串 → DocumentStore.importDocument(text:)`。改为：

```
选文件 → extractDocument(url) → 拿 markdown 当 text → importDocument(text:, originalFileURL: url)
```

`DocumentStore.importDocument` **加可选入参 `originalFileURL: URL?`**：
- 有 → **原样拷贝真实原件**为 `original.<真实扩展名>`（如 `original.pdf`）。
- 无（粘贴文本路径）→ 沿用现逻辑（按 text 写 `original.md`/`original.txt`）。
- **默认 nil 时与现状逐字节一致**（回归保护）。

`content.md` 永远是提取后的 markdown（被索引/查看）。**下游一律不动。**

## 4. 数据流

```
用户在 Documents 页选文件（或 CLI import-doc <file>）
  ① extractDocument(url) → ExtractResult(markdown, sourceFormat, warnings)
  ② DocumentStore.importDocument(title, text=markdown, sourceFormat, originalFileURL=url)
       └─ 写 document.yaml + content.md(markdown) + original.<ext>(真实原件)
  ③ IndexPipeline.indexDocument(docDir)   ← 现有，零改
  ④ warnings 非空 → toast 提示（仍建文档、原件已留档、可重试/打开）
→ 文档可被检索 / Ask 引用 / 作为关联文档纳入纪要
```

## 5. 失败兜底（沿用 P1/转写失败那套：可见、不静默吞）

- 提取失败 / 产出为空（加密 PDF、损坏 docx、OCR 无字）→ **仍建文档但正文空 + warning**；**原件照常留档**，用户可"在 Finder 显示原件"重试或换工具。
- 加密/带密码 PDF（`PDFDocument.isEncrypted`）→ 明确 warning「无法解析（可能加密）」。
- 解析抛错 → 捕获进 warnings，落 `resound.log`（复用 AppLog）。
- 扫描 PDF/大图 OCR 慢 → 后台跑 + 进度状态提示（见 §6）。

## 6. App / CLI 接入

- **文件选择器**：`allowedContentTypes` 扩到 pdf/docx/pptx/html + 图片 UTType（`.pdf .image` + OOXML 类型）。
- **导入进度行**：现有 `DocImportItem` 加状态文案——`解析中… / OCR 中… / 建索引…`（OCR 慢，给反馈）。解析在后台 Task，UI 不阻塞。
- **CLI `import-doc`**：接受这些扩展名，复用同一 `extractDocument`（无头可验证）。

## 7. 取舍 / 风险

- **PDF 表格/复杂版式**在 macOS 14.5 上偏弱（受 PDFKit 文本层限制，多列/表格可能错序）；自研只能做到字号推断标题 + 段落，**表格全保真要等 macOS 26 的结构化 OCR**（以后 `#available` 接）。当前可达范围内已是最优。
- **自研代码量**：PDF 标题启发式、docx/pptx XML 解析、mini-zip 都要自己写并调；比用库多写一些，但**零依赖零升级**、完全可控。
- **pptx 自研**：幻灯片文字常碎片化，结构弱（按页+文本框），适合检索关键词，不追求版式还原。
- **OCR 准确率**依赖 Vision；中英混排、竖排、艺术字可能漏识——属底层能力边界，warning 兜底。
- **HTML 手写转换**只覆盖常见标签，复杂页面回退纯文本（可接受——导入的多是会议文档而非任意网页）。

## 8. 验收点（实现后）

1. 导入一份**数字版 PDF** → 正文是文本（非乱码），标题/段落大致成形，可被 Ask 检索引用。
2. 导入一张**截图/扫描件**（或扫描型 PDF）→ OCR 出中文/英文文字，能检索到。
3. 导入 **.docx** → 标题/列表/表格在查看时呈现为 markdown 结构。
4. 导入 **.pptx** → 按页分隔、每页文字出现。
5. 导入 **.html** → 转成干净 markdown（无标签残留）。
6. 导入**加密/损坏**文件 → 不崩、有 warning、原件留档、可在 Finder 打开。
7. 原有 md/txt 导入与 P1/P2 行为**零回归**；`originalFileURL=nil` 路径不变。
