# MCP 双向接入 —— 设计 (Design / Spec)

> 2026-06-26。讨论共识见 [DECISIONS](../../DECISIONS.md)「MCP 双向接入」。UI 契约 = Claude Design handoff `Resound.dc.html`（本仓库外，用户提供）。
> 两个独立模块：**A 接入 MCP（消费方）** + **B 提供 MCP（生产方）**。先 A 后 B 在讨论里说先做 A，但**实现顺序按风险**：先 Wave 1 = 模块 B 服务器（最小最稳），见 §7。

---

## 1. 范围

**v1 做：**
- 模块 A：内置远程来源（Notion / Jira·Confluence / Google Workspace / Figma）+ 自定义来源（远程 HTTP **与** 本地 stdio 命令）；认证 OAuth 2.1（PKCE + DCR）与 API Token；粘贴链接绑定到录音；版本戳判变更 + TTL/手动同步；拉取入库走现有文档管线。
- 模块 B：`resound mcp serve`（stdio）暴露检索原语 `search_meetings`/`get_recording`/`get_document`(+`list_recordings`)；一键安装到 **Claude Code、Codex**；外部文档内容策略全局开关（完整/仅链接/片段+链接，默认片段+链接）。

**v1 不做（明确排除）：**
- **Cursor 安装**（无官方 `cursor mcp add`，靠写 `~/.cursor/mcp.json`，本期不做）。
- 应用内 MCP 搜索绑定、自动推荐绑定（后续增强）。
- 查询时实时 agentic 拉取（已在讨论里否决，走绑定时入库）。
- 模块 B 的 HTTP 服务器形态（swift-sdk 的 HTTP server 不成熟；我们只走 stdio）。

---

## 2. 依赖

新增 SPM 依赖 `modelcontextprotocol/swift-sdk`（product `MCP`，`from: "0.11.0"`）。
- 客户端（模块 A）：`Client` + `HTTPClientTransport`（远程，支持 SSE 流）；本地 stdio 自定义源用 `Process` 起子进程 + 管道喂传输。
- 服务器（模块 B）：`Server` + `StdioTransport`。
- **OAuth 自实现**（SDK 不含）：`ASWebAuthenticationSession` + PKCE + DCR + Keychain，token 注入 HTTPClientTransport 的 Authorization 头。
- 风险：SDK pre-1.0，API 可能变；本地 stdio 客户端传输可能需自己包一层 `Process` 管道（若 `StdioTransport` 不收自定义 FileHandle）。

---

## 3. 模块 A —— 接入 MCP（消费方）

### 3.1 数据模型（扩展现有文档模块，不另起炉灶）

外部文档 = `documents/` 下的文档，复用 [Document.swift](../../../Sources/ResoundCore/Document.swift) 的 `DocumentManifest`/`DocumentStore`，**新增 external 元数据块**（写进 `document.yaml`，向后兼容——老文档无此块即普通本地文档）：

```yaml
schema: resound.document/1
id: 2026-06-18-q3-roadmap
title: Q3 Roadmap — 产品
source_format: external          # 新增取值；区分本地导入
imported_at: 2026-06-18T...+08:00
tags: [...]
links: [recording:2026-06-18-1430-standup]
external:                        # ← 新增块（仅外部文档有）
  source_id: src_notion          # 来自哪个已连来源
  kind: notion                   # notion | atlassian | google | figma | custom
  url: https://notion.so/acme/Q3-Roadmap-8f3a2
  form: imported                 # imported（已取回正文）| link（仅链接，无正文）
  content_version: "2026-06-18T09:12:00Z"   # 上次取回时的版本戳（last_edited_time/updated/modifiedTime）
  last_sync: 2026-06-18T09:13:00+08:00
```

- **两级形态**：`form: imported` → 有 `content.md`（取回的正文），进检索/问答/纪要，走现有索引管线（`chunks.source_kind='document'`、`doc_id` 指向它，模型零改）。`form: link` → **无 content.md**（或空），只是可点书签，**不入检索**。
- `external` 块是事实源随 vault 走；但**凭证不在 vault**（见 3.2）。
- `doc_links`（录音关联镜像）不变。

### 3.2 来源注册表（Source Registry）

来源是「机器/账号级配置 + 密钥」，**不进 vault**，放 App Support：
- `~/Library/Application Support/Resound/mcp-sources.json` —— 来源配置（不含密钥）。
- Keychain —— OAuth token / API token / refresh token。

一个来源（`MCPSource`）：
```
id, kind(notion|atlassian|google|figma|custom), name,
transport(remote|local),
  remote: url, auth(oauth|token), needsClientId?, clientId?
  local:  command, args[], env{}      // 子进程
status(connected|expired|disconnected),
account?, scope?, hostPatterns[],     // host→来源匹配用
builtin(Bool)
```

内置预设（builtin=true，远程 HTTP + oauth + DCR）：
| kind | name | MCP server URL | hostPatterns |
|---|---|---|---|
| notion | Notion | https://mcp.notion.com/mcp | notion.so, notion.site |
| atlassian | Jira / Confluence | https://mcp.atlassian.com/v1/mcp | *.atlassian.net |
| google | Google Workspace | (Google MCP 端点) | docs.google.com, drive.google.com |
| figma | Figma | https://mcp.figma.com/mcp | figma.com |

> URL 以实现时各家最新文档为准；预设只是预填，用户授权即可用。

### 3.3 MCP 客户端 + 每来源「取内容/取版本」映射（**关键复杂点**）

MCP server 暴露的是**各不相同的工具**，没有统一的「按 URL 取正文」。所以需要**每来源适配**把两个动作落到该 server 的具体工具上：
- **取正文**（fetch by url/id → markdown）
- **取版本戳**（metadata → last_edited_time / updated / modifiedTime）

策略：
- **内置来源**：写薄适配器，编码各家工具名与参数（如 Notion `fetch`、Atlassian `getConfluencePage`/`getJiraIssue`、Figma 取设计元信息）。从 URL 解析出资源 id。
- **通用/自定义 MCP**：优先用 MCP **Resources**（`resources/read` by URI）；无 Resources 能力则连接后 `tools/list` 发现，按启发式挑 fetch 类工具；都不行 → 退化为「仅链接」。
- 版本戳缺失的来源（尤其自定义）→ 退化为「按 TTL 定时重拉 / 仅手动刷新」。

### 3.4 OAuth

OAuth 2.1 + PKCE，经 `ASWebAuthenticationSession` 拉起系统浏览器；回调 loopback `127.0.0.1:<port>` 或自定义 scheme `resound://oauth/callback`；code 换 token，存 Keychain；401 用 refresh token 自动续。
- **DCR（RFC 7591）**：连接前若 server 元数据声明支持动态注册 → 临场注册 client，无需预建 app（Notion/Atlassian 托管 MCP 支持）。
- **不支持 DCR**：UI 勾「需要手动填 client_id」（设计稿 add-source modal 已有），用户贴一次。
- API Token 来源：直接存 token，注入请求头，无浏览器流程。

### 3.5 URL 路由（粘贴链接，4 路降级）

按 host 匹配 `hostPatterns` →
1. **命中且已连接** → 调适配器取正文 → `form:imported` 入库。
2. **像已知来源但未连接** → 提示去连接（设计稿 `linkUnconnected`），可「仍以仅链接保存」。
3. **未知/不支持/内网/不可达** → `linkUnknown`，存 `form:link`。
4. **已连接但无权限/取空** → `linkNoPerm`，可重试或存 `form:link`。

### 3.6 同步引擎

- 每外部文档存 `content_version`。刷新 = 先取版本戳（廉价）比对；变了才重取正文 → 重走索引（`embedding_cache` 让只有变化 chunk 重嵌）。
- **TTL 闸 + 手动**：常态不每查都判；设置/录音里提供「同步」按钮（来源级 + 单文档级）。"stale" 角标 = 距上次同步超阈值或已知变更。
- 失败（网络/授权过期）→ 记录、UI 提示，不阻塞主流程。

---

## 4. 模块 B —— 提供 MCP（生产方）

### 4.1 `resound mcp serve`

新增 CLI 子命令；swift-sdk `Server` over `StdioTransport`；只读共享 `index.sqlite` + vault。被 coding agent 作为子进程拉起，GUI 开不开都不影响、零 IPC。工具名 **snake_case**（SDK 要求）：

- `search_meetings(query, filters?{speaker, source, date_from, date_to, folder}, top_k?=8)`
  → `[{type: "recording"|"document", id, title, date, snippet, score, speaker?, time?, url?}]`，复用现有 hybrid/RRF/filters（`Index.Filters`）。
- `get_recording(id, include: "transcript"|"summary"|"both"=both)` → 该场全文。
- `get_document(id)` → 文档正文（外部文档受 §4.2 内容策略约束）。
- `list_recordings(filters?)` → 枚举/浏览。

### 4.2 内容策略（全局开关）

对外提供**外部文档**内容时（`get_document` 与 `search_meetings` 的外部命中），按全局设置：
- `full`（完整内容）：返回缓存全文。
- `link`（仅链接）：只给 URL + 标题/元信息。
- `summary`（片段+链接，**默认**）：命中片段/摘要 + URL。

**录音/转录/摘要永远 full**（agent 别处拿不到）；`form:link` 文档天然只有 URL。存于 `mcp-server.json`（App Support）。

### 4.3 一键安装

- 装：`which claude`/`which codex` 检测在否 → 在则点亮「一键安装」→ shell out `claude mcp add resound -- <resoundPath> mcp serve` / `codex mcp add resound -- <resoundPath> mcp serve`。
- 卸：`claude mcp remove resound` / `codex mcp remove resound`。
- 手动兜底：折叠区展示可复制的同款命令（设计稿已有）。
- `<resoundPath>`：指向 App 内置/已安装的 `resound` 可执行文件路径（解析方式见计划；可能需把 CLI 安装到稳定路径或用 bundle 内路径）。

---

## 5. UI 契约

完全按 Claude Design handoff `Resound.dc.html` 还原（像素级，原生 SwiftUI 复刻，复用现有 palette/子导航/modal 范式）：
- **设置 › 外部 MCP 接入**：已连来源卡列表（connected/expired/disconnected 三态 + 同步态 + account/scope/docCount + 同步/断开/重连/连接）+「添加自定义来源」。
- **设置 › Resound MCP**：服务卡（开关 + 状态 + 本地端点）+ 安装到编码助手列表（**仅 Claude Code / Codex**，去掉 Cursor；installed/installing/canInstall/notDetected 态）+ 手动命令折叠（复制）+ 内容策略三选一单选。
- **Modal**：OAuth 连接（redirect/waiting/done）；添加自定义来源（远程 HTTP〔oauth/token + 需 client_id 勾选〕/ 本地 stdio〔命令/参数/env〕）；粘贴链接（resolving/resolved/unconnected/unknown/noperm）。
- **录音详情 › 相关文档**：外部文档行（form 角标 imported/link、freshness fresh/stale/syncing、同步/浏览器打开/移除）+「关联链接」入口。

---

## 6. 测试策略（每波 CLI 先验绿，再接 UI——沿用智能推算成功节奏）

- **Wave 1（服务器）**：`resound mcp serve` 起后，用 Claude Code 实连 + 调试命令 `mcp-selftest`（本进程内拉起 server+client 跑一轮 list/call）验证四个工具与内容策略。
- **Wave 2（客户端）**：调试 CLI `mcp-sources`（列来源）、`mcp-connect <id>`、`mcp-fetch <url>`（走路由+适配器取正文打印）、`mcp-sync` —— 无头验证连接/取内容/判变更/降级四路。
- **Wave 3（UI）**：App 实机验收点见计划。

---

## 7. 实现波次（按风险，不按模块先后）

1. **Wave 1 = 模块 B 服务器**：`resound mcp serve` + 4 工具 + 内容策略 + 安装命令逻辑。无 OAuth、无 UI 依赖，最小最稳，先交付、可被 Claude Code 直接用。
2. **Wave 2 = 模块 A 后端（远程优先）**：来源注册表 + MCP 客户端（HTTP）+ OAuth/PKCE/DCR/Keychain + 每来源适配器 + URL 路由 + 同步 + 拉取入库。CLI 验绿。
3. **Wave 3 = App UI**：两个设置区 + 各 modal + 录音相关文档外部区 + 安装按钮（含模块 B 的设置 UI）。
4. **Wave 4 = 本地 stdio 自定义来源**：子进程客户端传输 + env 注入。

---

## 8. 风险 / 待核实

- **每来源工具映射**（取正文/取版本）是最不确定处——内置写适配器，通用靠 MCP Resources，定计划时各家工具名以最新文档为准。
- swift-sdk pre-1.0 churn；本地 stdio 客户端传输可能需自包 `Process` 管道。
- `resound` CLI 路径解析（安装命令要用）。
- OAuth DCR 各家支持度；回调 scheme/loopback 选型。
- Google Workspace MCP 端点与能力待核实（可能 v1 先 Notion/Atlassian/Figma，Google 视情况）。
