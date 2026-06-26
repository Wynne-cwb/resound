# 原生 Markdown 渲染器（替换 MarkdownUI）设计

日期：2026-06-26 · 状态：已批准，待实现

## 背景 / 动机

全 App 的 Markdown（会议摘要、文档正文、本场提问/向文档提问/全局 Ask 答复）都经唯一包装 `SummaryMarkdown` 走 **MarkdownUI**。埋点实测确认它是**结构性性能瓶颈**：

- MarkdownUI 把每个块（标题/段落/列表项/表格…）渲染成独立的嵌套 SwiftUI 视图，一篇大文档 = 几百个视图节点，SwiftUI 一次性布局它们就慢（单篇 300ms~1s+）。
- 已先后做过两层缓解：`SummaryMarkdown` 加 `Equatable`（剪枝重解析）、解析结果 `contentCache`（切页不重跑 cmark）、常驻页「隐藏不布局」（`pageVisible` 环境值）。这些削掉了**解析**与**隐藏页重排**成本，但**残余的「布局整篇视图树」开销仍在**（切页到大文档/大摘要仍 300~650ms）。

结论：要根治必须去掉 MarkdownUI 的「每块一棵视图树」结构。用户拍板：**原生自绘替换**，且**多级嵌套列表是硬需求**；解析器选 **swift-markdown**（Apple 官方 cmark-gfm 包装，纯解析）。

## 架构

```
text ──swift-markdown解析──▶ Document AST ──递归 visitor──▶ 原生 SwiftUI 块视图 ──▶ VStack
                                  ▲
                            按原文缓存（切页重建不重解析）
```

- 新增 `MarkdownNative(text:pal:)`，**保留 `SummaryMarkdown(text:pal:highlight:)` 对外签名**——7 处调用点零改动，仅换内部实现（`SummaryMarkdown` 内部改为构造 `MarkdownNative`，或直接重写其 body）。
- `swift-markdown` 解析成 `Markdown.Document`；递归遍历**顶层块**，每块渲染成原生视图，装进一个 `VStack(alignment:.leading)`。
- **解析缓存**：`static var cache: [String: Document]`（沿用现 contentCache 思路，容量上限 ~48，超则清空），切页/重建视图不重解析。
- **核心收益**：段落 = **单个 `Text(AttributedString)`**（1 个视图），把 MarkdownUI「每段几十个嵌套视图」塌缩。一篇文档从「几百棵块树」→「几百个廉价 Text」，布局快一个量级。配合既有「隐藏不布局」+解析缓存，卡顿根除。
- 不引入嵌套 `LazyVStack`（`SummaryMarkdown` 同时用于 ScrollView 与 chat 行内，嵌套 lazy 有坑）；纯 `VStack` 的廉价 Text 足够快，必要时后续再加懒加载。

## 块级渲染（对齐现有 resound 主题，观感不变）

参照现 `MarkdownUI.Theme.resound(pal)` 的取值：

| 块 | 渲染 |
|---|---|
| Heading 1–4 | 字号 1.5 / 1.28 / 1.12 / 1.0 em（基准 13.5），粗体（h4 半粗），accent 色；上下 margin 同现值（h1 16/10、h2 16/8、h3 14/6、h4 12/6）。h5/h6 退化到 h4。 |
| Paragraph | `Text(AttributedString)`，pal.text 13.5，行距 ≈0.45em（≈6pt），段后 12pt。 |
| 无序/有序列表（**含多级嵌套**） | `HStack(marker, 内容)`；**缩进 = 深度 × 20pt**；无序按深度切 `•`/`◦`/`▪`，有序用 `1.`/`2.` 序号；列表项内容可再含子列表 → **递归 depth+1**，逐级正确缩进；行距 0.45em、项间距 ≈0.4em。 |
| GFM 任务列表 | `[ ]`→☐、`[x]`→☑，前置于列表项。 |
| BlockQuote | 左侧 3pt `accent.opacity(0.5)` 竖条 + 内容左内边距 12，内容 text2 色；内容递归（可含段落/列表）。 |
| 代码块 | 等宽、inset 背景、圆角 ~8，内边距；超宽横向滚动；代码原文不解析行内。 |
| 行内代码 | 等宽、~0.9em、accent 前景 + accentSoft 背景（`AttributedString.backgroundColor`）。 |
| Table（GFM） | `Grid`：表头行半粗 + 数据行 + `pal.border` 网格线；按列对齐（left/center/right）。 |
| ThematicBreak | `Rectangle().fill(pal.border).frame(height:1)`，上下留白。 |
| 其它（HTMLBlock 等） | 退化为原文 `Text`，不崩。 |

**行内**（合成进一个 `AttributedString`）：普通文本、Strong（半粗）、Emphasis（斜体）、Strikethrough（删除线）、InlineCode（等宽+底色）、Link（accent 色 + `.link`，可点）、SoftBreak（空格）、LineBreak（换行）、Image（显示 alt 文本占位，内容里罕见）。链接走 `Text` 自带 AttributedString `.link`，可点且用我们设的前景色。

## 集成 & 清理

- `Package.swift`：`ResoundApp` 依赖从 `gonzalezreal/swift-markdown-ui` 换成 `apple/swift-markdown`（`.product(name:"Markdown",package:"swift-markdown")`）。
- `import MarkdownUI` → `import Markdown`；删除 `MarkdownUI.Theme.resound(pal)` 扩展。
- `highlight` 参数：维持签名（当前摘要未用），**本期不做**行内查找高亮，保持现状。
- 流式/打字机：chat `.answering` 态本就用纯 `Text` 逐字显示，仅 `.done` 用 `SummaryMarkdown` 渲染**完整定稿**文本——故渲染器只需处理完整 markdown，不需增量解析。

## 验收

1. **观感比对**：拿那篇 ~13000 字大文档 + 含表格/多级嵌套列表/引用/代码块的摘要，逐项肉眼对齐（重点：表格、列表多级缩进——最易出视觉差）。
2. **性能复测**（埋点）：切页到大文档/大摘要的卡顿从 300~650ms 降到几十 ms 级；「隐藏页不布局」「转录 find 不卡」结论保持不回归。
3. **覆盖**：7 处调用点（摘要 tab、文档正文、本场提问、向文档提问、全局 Ask）全部渲染正常。
4. 验收通过后关掉 `Perf.enabled`。

## 风险

- **表格 / 深层嵌套列表**最易与 MarkdownUI 有视觉差，重点比对。
- swift-markdown 的 AST 节点 API（List/Table/ListItem 的 children、Table.head/body、对齐枚举）需按实际版本核对字段名。
- 边角 markdown（嵌套引用+列表混排、列表内代码块）逐一回归。
