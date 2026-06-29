# MCP 双向接入 —— 实现计划 (Plan)

> 配套 spec [2026-06-26-mcp-bidirectional-design.md](../specs/2026-06-26-mcp-bidirectional-design.md)。
> 节奏：每波后端先 CLI 验绿，再接 UI（沿用智能推算成功经验）。每完成一波同步 STATE/DECISIONS + README 双语。

---

## Wave 0 — 依赖与脚手架

- **T0.1** `Package.swift` 加依赖 `modelcontextprotocol/swift-sdk`（product `MCP`），挂到 `ResoundCore`（客户端/服务器共用）。`swift build` 确认拉取通过、与现有 WhisperKit/FluidAudio 无冲突。
- **T0.2** 新建空骨架文件占位：`Sources/ResoundCore/MCPServer.swift`、`MCPClient.swift`、`MCPSource.swift`、`MCPOAuth.swift`、`SourceAdapters.swift`（按波填充）。
- **验证**：`swift build` 过。

---

## Wave 1 — 模块 B：`resound mcp serve`（最小最稳，先交付）

**目标**：Claude Code 配上后能搜/取你的会议与文档。无 OAuth、无 App UI。

- **T1.1 MCPServer.swift**：swift-sdk `Server` + `StdioTransport`。注册 4 工具（snake_case）：
  - `search_meetings(query, filters?{speaker,source,date_from,date_to,folder}, top_k?)` → 复用 `Index` hybrid 检索 + `Index.Filters`，返回 `[{type,id,title,date,snippet,score,speaker?,time?,url?}]`。
  - `get_recording(id, include)` → 读 vault transcript/summary。
  - `get_document(id)` → 读 content.md，外部文档过内容策略（T1.3）。
  - `list_recordings(filters?)`。
  - 入参/出参 JSON Schema 写全；错误（无此 id/索引缺失）返回结构化错误不崩。
- **T1.2 CLI 接线**：`ResoundCLI.swift` 加 `Mcp` 命令（`commandName:"mcp"`，子命令 `serve`）。`serve` 读 Config（vault + index 路径，复用现有加载）→ 起 server 阻塞运行。注册进 `subcommands`。
- **T1.3 内容策略**：`mcp-server.json`（App Support）存 `contentPolicy: full|link|summary`（默认 summary）。`get_document`/`search_meetings` 对**外部文档**（manifest 有 external 块）按策略裁剪；录音恒 full；`form:link` 恒只给 URL。本波 external 文档还不存在，逻辑先就位+缺省安全（无 external 块＝普通文档 full）。
- **T1.4 安装命令逻辑**（纯函数，UI 在 Wave 3 接）：`mcpInstallCommand(client, resoundPath)` 生成 `claude mcp add ...` / `codex mcp add ...`；`detectClient` = `which claude|codex`；`installToClient`/`uninstallFromClient` shell out。`resoundPath` 解析：优先 bundle 内 CLI，回退 `which resound`（计划中先用当前可执行路径，Wave 3 定稳定路径）。
- **T1.5 调试命令** `mcp-selftest`：本进程内拉起 server + client（in-memory/管道）跑 list_tools + 各 call 一遍，打印结果。
- **验证（CLI 全绿）**：①`resound mcp serve` 能起；②`resound mcp-selftest` 四工具返回合理；③真把它 `claude mcp add` 进本机 Claude Code，问一句能检索到会议；④内容策略三值对外部文档（用假数据）裁剪正确。
- **收尾**：README 双语加「Resound 作为 MCP 服务器」+ CLI 表 `mcp serve`；STATE/DECISIONS 同步。

---

## Wave 2 — 模块 A 后端（远程来源优先，CLI 验绿）

**目标**：命令行能连接来源、粘贴 URL 取回正文入库、判变更同步。无 App UI。

- **T2.1 MCPSource.swift**：`MCPSource` 模型 + `mcp-sources.json` 读写（App Support，不含密钥）+ 内置预设表（Notion/Atlassian/Figma/Google）。host→source 匹配。
- **T2.2 MCPOAuth.swift**：OAuth 2.1 + PKCE + DCR + Keychain token 存取 + 401 refresh。`ASWebAuthenticationSession`（App 层触发，Core 提供无 UI 的 code↔token 交换 + 注册）。回调 scheme/loopback 定型。
- **T2.3 MCPClient.swift**：swift-sdk `Client` + `HTTPClientTransport`（注入 Authorization 头）。连接、`tools/list`、`tools/call`、`resources/read`。
- **T2.4 SourceAdapters.swift**：每内置来源「取正文 fetchContent(url)→markdown」「取版本 fetchVersion(url)→stamp」适配（编码各家工具名/参数 + 从 URL 解析资源 id）；通用来源走 Resources/启发式；无版本戳→TTL 兜。
- **T2.5 URL 路由 + 入库**：`resolveLink(url, recId)` → 4 路（connected→fetch→DocumentStore.importDocument(source_format=external, external 块, content.md=正文)→索引；unconnected/unknown/noperm→form:link 入库或提示）。link-only 不建索引。
- **T2.6 同步引擎**：`syncExternalDoc(docId)` / `syncSource(id)`：取版本戳比对→变了重取重索引（embedding_cache 生效）。TTL 闸。
- **T2.7 调试 CLI**：`mcp-sources`（列）、`mcp-connect <id>`（跑 OAuth，App 外用 token 占位或交互）、`mcp-fetch <url>`（走路由+适配器打印正文/降级）、`mcp-sync <docId|sourceId>`。
- **验证（CLI 全绿）**：①列内置来源；②对一个真 Notion/Atlassian 公共或自有页 `mcp-fetch` 取回 markdown；③改一下源文档 → `mcp-sync` 检出变更并重取；④贴未知/内网 URL → 落 link-only；⑤贴未连来源 URL → 提示去连接。
- **收尾**：README 双语加「外部 MCP 接入」；STATE/DECISIONS 同步。

---

## Wave 3 — App UI（两个设置区 + modal + 录音相关文档 + 安装按钮）

按 `Resound.dc.html` 像素级还原（原生 SwiftUI，复用 palette/子导航/modal）。

- **T3.1 视图模型**：`MCPModel.swift`（@MainActor）—— 来源列表/状态、连接(OAuth)、添加自定义源、内容策略、客户端检测/安装、粘贴链接流。`ExternalDocs` 接入 `LibraryModel`（录音相关文档区）。
- **T3.2 设置 › 外部 MCP 接入**：子导航加项；来源卡列表（三态 + 同步态 + 同步/断开/重连/连接）；「添加自定义来源」入口。
- **T3.3 设置 › Resound MCP**：服务卡（开关/状态/端点）；安装到 Claude Code/Codex（去 Cursor）；手动命令折叠+复制；内容策略单选。
- **T3.4 Modal**：OAuth 连接（redirect/waiting/done，接 ASWebAuthenticationSession）；添加自定义来源（远程 HTTP〔oauth/token + client_id 勾选〕，本地 stdio 字段本波先收集但连接走 Wave 4）；粘贴链接（resolving/resolved/unconnected/unknown/noperm，接 T2.5）。
- **T3.5 录音详情 › 相关文档**：外部文档行（form 角标、freshness、同步/打开/移除）+「关联链接」按钮接粘贴流。
- **验证（App 实机）**：①连接 Notion 走完 OAuth→已连接；②录音里粘贴该源一篇 URL→取回入库→出现在相关文档→Ask 能引用；③粘贴未连/未知/无权限→三种提示对；④Resound MCP 开关+一键装到 Claude Code→Claude Code 实查通；⑤内容策略切换对外部文档生效。
- **收尾**：README 双语补 UI 说明；STATE/DECISIONS。

---

## Wave 4 — 本地 stdio 自定义来源

- **T4.1** 本地传输：`Process` 起 `command args env` 子进程 + stdin/stdout 管道，包成 swift-sdk 客户端传输（或自定义 Transport）。
- **T4.2** 添加自定义源 modal 的「本地 · stdio」分支接通；子进程生命周期/错误（命令不存在/退出）处理。
- **验证**：用 `npx -y @notionhq/notion-mcp-server` 起本地源、连接、取一篇内容。
- **收尾**：README/STATE/DECISIONS。

---

## 贯穿约束

- 改 ResoundCore 后 App 要 `killall Resound` → `bundle-app.sh release` → `open` 才生效（用户在录音时等结束）。
- 密钥绝不进 vault/git；`mcp-sources.json`/`mcp-server.json` 在 App Support。
- 每波 commit/push 需用户要求；commit 前查 README 双语。
- 质量>速度：每波 CLI 验绿再进下一波。
