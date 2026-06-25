# 文档模块 P3（富格式解析）— 实现计划

> 日期：2026-06-25（已据"自研零依赖"决策修订）
> 上游 spec：[2026-06-25-documents-p3-rich-formats-design.md](../specs/2026-06-25-documents-p3-rich-formats-design.md)（范围 locked）
> 原则：质量>速度；后端先行 + CLI 无头可验证 → App 接线 → 收尾。原有 md/txt 导入**零回归**是硬约束。
> **零升级零依赖**：Swift 6.0.3 / macOS 14.5 直接做，不动 `Package.swift`、不加 SPM/C 依赖。

## 现状勘查（动手前确认的事实）

- `DocumentStore.importDocument(title:text:sourceFormat:tags:links:date:)`（[Document.swift:164](../../Sources/ResoundCore/Document.swift)）：现在 `original.<ext>` 由 text 写出（md/txt）；要加 `originalFileURL` 拷贝真原件。
- App 导入入口：`DocumentsModel.importFiles(_:)`（按扩展名定 fmt、读 UTF8）、`openFilePicker`（UTType 白名单）、`importComposed`/`importText`（粘贴）。CLI `import-doc`。
- 导入进度：`DocImportItem`（status: .indexing/.done/...）。
- 失败兜底范式：`AppLog`/`resound.log`、导入失败行 UI。
- Core 已有 helper：`firstLineTitle`、`slugify`、`iso8601`（可复用）。

> ⚠️ 动手前先读上述文件确认签名；若现状与 spec 假设不符，停下来对齐。

---

## Wave 1 — Core：DocumentExtractor（CLI 无头可验证，UI 无关）

每个提取器**独立可验证**，建议按子任务顺序逐个落地 + 各自跑 CLI。

- **T1.1 骨架 + 直通**
  新增 [DocumentExtractor.swift](../../Sources/ResoundCore/DocumentExtractor.swift)：`ExtractResult{markdown, sourceFormat, warnings}`；`extractDocument(url:)` 按扩展名分派；**失败不抛**（空 markdown + warnings + 写 `AppLog`）。先实现 `md/markdown/txt` 直通（与现状一致）。

- **T1.2 图片 OCR（Vision）**
  `VNRecognizeTextRequest`（accurate，`recognitionLanguages=["zh-Hans","zh-Hant","en-US"]`，`usesLanguageCorrection=true`）→ 按 observation 顺序拼行。支持 png/jpg/jpeg/heic/heif/tiff/bmp/gif。无字 → warning。

- **T1.3 PDF（PDFKit + OCR 回退）**
  `PDFDocument`：`isEncrypted` → warning 退出；逐页取 `attributedString`，枚举 `.font` 属性按字号/加粗映射 `#`/`##`/正文，段落/页用空行分隔。**全文 trim 后近空 → 判扫描件 → 逐页渲染 `NSImage` 复用 T1.2 OCR**。

- **T1.4 mini-unzip（Compression）**
  内部 util：解析 zip End of Central Directory → 中央目录 → 按名取条目（local header + 压缩字节）→ `compression_decode_buffer(COMPRESSION_ZLIB)` 解 raw deflate（兼顾 stored/method0）。返回 `Data`。docx/pptx 共用。**单测：对一个已知 docx 取出 `word/document.xml` 字节正确。**

- **T1.5 docx（XMLParser → md）**
  mini-unzip 取 `word/document.xml` → `XMLParser`：`w:p`+`w:pStyle(Heading1..)`→`#`层级、`w:numPr`→`-` 列表、`w:tbl`/`w:tr`/`w:tc`→markdown 表、`w:t` 收文本。容错：未知样式当正文。

- **T1.6 pptx（XMLParser → 按页 md）**
  mini-unzip 枚举 `ppt/slides/slide*.xml`（按序号排序）→ `XMLParser` 收 `<a:t>` → 每页 `## 第 N 页\n\n<文本分行>`。无 slide/损坏 → warning。

- **T1.7 HTML（标签→md）**
  手写常见标签转换（h1-6/p/ul-ol-li/table/a/strong/em/pre/code/br）；解析异常回退 `NSAttributedString(html:)` 剥纯文本。

- **T1.8 `importDocument` 加 `originalFileURL`**
  `DocumentStore.importDocument(... originalFileURL: URL? = nil)`：有 → `FileManager.copyItem` 真原件为 `original.<url.pathExtension>`；无 → 沿用现逻辑。**默认 nil 逐字节同现状**。

- **T1.9 CLI `import-doc` 接 extractDocument**
  导入路径：`extractDocument(url)` → `importDocument(text: result.markdown, sourceFormat:, originalFileURL: url)` → `indexDocument`；warnings 打 stderr。

- **依赖**：无（纯 Core）。**验证（CLI 无头，不碰 App）**：
  - 备样例：数字 PDF / 扫描 PDF（或截图）/ docx / pptx / html / 加密 PDF / 损坏文件。
  - 逐个 `resound import-doc <file>`：content.md 内容正确、original.<ext> 是真原件、加密/损坏不崩且有 warning、`resound search` 能命中。
  - 回归：md/txt 导入产出与改前一致；`originalFileURL=nil` 路径不变。

## Wave 2 — App 接线

- **T2.1 文件选择器扩格式**
  `DocumentsModel.openFilePicker` / `DocumentsView` 的 `allowedContentTypes` 加 `.pdf`、`.html`、`.image` 及 docx/pptx UTType（`UTType(filenameExtension:)` 或 `org.openxmlformats.*`）。

- **T2.2 导入走 extractDocument**
  `importFiles(_:)`：每个 url → 后台 `extractDocument` → `importDocument(text: markdown, sourceFormat:, originalFileURL: url)`。粘贴路径（importText/importComposed）不变。

- **T2.3 进度状态 + warning 提示**
  `DocImportItem` 加解析阶段文案（`解析中… / OCR 中… / 建索引…`）；warnings 非空 → toast。OCR 慢，后台 Task 不阻塞 UI。

- **依赖**：Wave 1。**验证（实机）**：spec §8 的 1–7 条。⚠️ 打包/启动前按惯例 `killall Resound` 再重建——**但用户在录音期间不要 kill**，等录完。

## Wave 3 — 收尾

- **T3.1** [data-contract.md](../../docs/data-contract.md)：documents/ 的 `source_format` 扩展值（pdf/docx/pptx/html/image）+ `original.<ext>` 为真原件说明。
- **T3.2** README 双语：「文档导入」能力补上富格式 + OCR（面向用户能力增强，必须同步两份）。
- **T3.3** STATE.md 原地更新 + DECISIONS.md 追加本期决策（自研零依赖的依据：SwiftText 需 6.1→要升 macOS/独立 toolchain，取舍后选自研；PDF 不直接 OCR；mini-zip 用 Compression）。
- **依赖**：Wave 1+2 落定。

---

## 里程碑

- **M1 = Wave 1**：DocumentExtractor 各格式 + CLI 无头验证通过（含零回归）。
- **M2 = Wave 2**：App 导入富格式实机验收点过。
- **M3 = Wave 3**：data-contract/README/STATE/DECISIONS 同步。

## 风险 / 注意

- **PDF 表格/多列**弱（PDFKit 文本层限制）；标题靠字号启发式，不同 PDF 字号体系不一，需用几份真实 PDF 调阈值。
- **mini-zip 自写**：注意 stored（method 0，未压缩）与 deflate（method 8）都要处理；大文件流式可选，docx/pptx 一般不大可整体解。
- **OCR 慢**：扫描 PDF/大图后台跑 + 进度提示；别在主线程。
- **零回归**：md/txt 导入、`originalFileURL=nil`、粘贴路径必须与现状一致——Wave 1 验证专列。
- **录音保护**：用户当前在录音；Wave 2 实机验证若需重建 App，先确认录音已结束再 `killall Resound`。
