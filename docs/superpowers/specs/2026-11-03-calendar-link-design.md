# 录音自动关联 Google Calendar 日程 — 设计（2026-11-03）

## 目标

会议录音自动关联到对应的 Google Calendar 日程，把日程上下文（标题、参会人、描述、Notion 链接、重复系列）沉淀进录音元数据，供说话人命名、AI 纪要、关联文档和 MCP（Agent）使用。

## 已确认的决策（用户 2026-11-03）

1. **读取途径 = macOS 系统日历（EventKit）**：用户的公司 Google 账号已同步到系统日历，无需 GCP 项目 / Google API / IT 审批。
2. **Notion 链接自动导入**（P3），同 URL 只导入一次，多场共享。
3. **说话人：参会人作参考**（P2）。参会人照现行门限；非参会人需更严门限（暂定 cos ≥ 0.80）才自动命名。实测 69 场可信配对里，已标说话人约 25% 不在邀请名单（转发链接入会、会议室设备入会等），故不能硬排除。margin 始终在全库算，不在缩小的候选集里算（缩小候选集会让 margin 变容易、反而多认错）。
4. **标题优先级**：浏览器标签标题 > 日程标题 > 默认生成名；用户改过的标题绝不覆盖。
5. **参会人邮箱可以存进 vault**（会随 git 自动推送到 vault 远端）。
6. **MCP 默认带日历信息，邮箱默认不返回**（`include_emails: true` 才返回）。

## 关键事实

- **`recorded_at` 对会议录音是「停录时刻」**：取自混音文件修改时间（`IngestPipeline.ingest` 的 `fileModifiedDate`），不是开始时刻。时间匹配用 `[recorded_at − duration, recorded_at]`。旧探针按开始时刻算导致 Platform 周会「对不上」、多场并列。
- **每个 Meet 日程都带会议码**（描述里的 `meet.google.com/xxx-xxxx-xxx`），可精确匹配；`MeetWatcher` 已读到 URL，但没有保存。
- 参会人 `name` 常见格式：`全名, 英文名`（`Jie Cong Yang, Jerry`）、`英文名, 中文名`（`Mason, Mai`）、`英文名 姓`（`Bryce Zhang`）、纯邮箱。会议室以参会人身份出现（EventKit `participantType` = room/resource，或邮箱属 `resource.calendar.google.com`）。
- EventKit 拿不到日程附件（含 Gemini 笔记），只能拿描述里的链接。

## 数据

- `recording.yaml` 新增顶层可选行 `meet_code: "bno-ujdp-mhv"`（现有解析器按行读顶层键，老代码忽略未知键）。
- 新增 `calendar.json`（录音目录内，`schema: resound.calendar/1`）：

```json
{
  "schema": "resound.calendar/1",
  "match": "exact | time | manual",
  "linked_at": "2026-11-03T18:00:00+08:00",
  "event": {
    "id": "<externalId>@<start ISO>",
    "series_id": "<externalId，仅重复会议>",
    "title": "Team Sprite Weekly Meeting",
    "start": "...", "end": "...",
    "calendar": "wb.chen@aftership.com",
    "meet_code": "ayn-krbe-sad",
    "organizer": {"name": "...", "email": "..."},
    "attendees": [{"name": "Jie Cong Yang, Jerry", "email": "...", "status": "accepted"}],
    "description": "去掉 Google 入会说明后的描述",
    "links": ["https://www.notion.so/..."]
  }
}
```

单独成文件的原因：手写 YAML 解析器不支持列表，现有改写逻辑按行前缀替换，嵌套字段易撞名；老代码完全不读它，零兼容风险。

## 匹配（`CalendarMatcher`，纯逻辑，可单测）

1. **精确**：有会议码时，在录音区间 ±12h 内找描述/地点/URL 含该会议码的日程；重复会议取与录音重叠最多（否则开始时间最近）的那一次 → `exact`。
2. **时间兜底**（无会议码，即历史录音或非 Meet 会）：候选 = 与录音区间重叠 > 0 的非全天日程。
   - **标题**：显示标题或录音 id 里的原标签名（id = 开录时浏览器标签标题，用户改显示标题后仍在）与日程标题相似度（字符 bigram Dice）≥ 0.8 → 唯一则采用；多个则用说话人证据挑；
   - **说话人证据**（录音已命名 ≥ 2 人时）：覆盖录音 ≥ 50% 的候选里，所有已命名说话人都在邀请名单的、邀请人数最少的那个 → 采用（1:1 胜过同时段的大会）；
   - **无名字时**：唯一候选覆盖录音 ≥ 50%、没有其它候选覆盖 ≥ 25%、且录音覆盖该日程 ≥ 50% → 采用；
   - 其余情况为 **ambiguous**：不写入，CLI 列出候选，可用 `--pick` 手动指定（`manual`）。
   - **录音时刻未知**：`recorded_at` 为 `T12:00:00`（被「按标题改日期」重写过，真实时刻丢失）时改用 id 前缀 `YYYY-MM-DD-HHMM`；日期对不上就不做时间匹配。
   - 2026-11-03 真实数据（104 场会议录音）：关联 100、歧义 2、无日程 2；靠非标题证据关联的 21 场逐条核对无误挂。初版只看时间时挂错 2 场（背靠背的临时 1 on 1、被改过日期的录音），即上面两条规则的来由。
3. 只处理 `source: meeting` 的录音；导入文件不关联。

## 入口

- **新录音**：录音开始/检测到会议时记下会议码（手动开录也做一次标签查询），写 sidecar `.meet`，App 重启可恢复；入库后、建索引前调用关联。标题为默认名时改成日程标题（见决策 4）。
- **历史回填**：`resound calendar-link [--id ID] [--dry-run] [--pick N]`。终端进程通常没有日历权限 → 报错并提示到 App 的「设置」里点「关联历史录音」；App 内同一逻辑。
- **开关**：设置里的「关联日历日程」默认开。拒绝授权、无匹配或读取失败时只是不关联，绝不影响入库。
- Info.plist 加 `NSCalendarsFullAccessUsageDescription`。

## 使用方

| 方 | 用法 | 期 |
|---|---|---|
| MCP `list_recordings` | 返回 `meeting {title, series_id, attendees[名字]}`；新参数 `attendee` 过滤、`include_emails` | P1 |
| MCP `get_recording` | 开头加会议信息块（组织者/参会人/描述/链接） | P1 |
| MCP `search_meetings` | 每条录音命中带 `meeting_title`；`attendee` 过滤 | P1 |
| 说话人命名 | 见决策 3 | P2 |
| AI 纪要 | `{meeting}` 占位符，未写则自动注入 | P2 |
| 关联文档 | Notion 链接自动导入、按 URL 去重 | P3 |
| 文件夹 | 同系列建议同一文件夹 | P3 |

## 失败与兼容

- 无 `calendar.json` 的录音：MCP 输出与现在逐字节一致（字段省略）。
- 关联是附加、可删：删 `calendar.json` + `meet_code` 行即还原；回滚 = 关开关。
- 合并录音：新录音按时间重新匹配（合并结果多半跨日程 → ambiguous → 不关联）。

## 验收

- 单测：会议码提取、精确匹配、停录时刻倒推区间、标题消歧、ambiguous 判定、会议室过滤、描述清洗与链接提取、`meet_code` 行写入、默认标题判定、MCP 渲染（有/无日历）。
- 真实数据：对现有会议录音跑 `calendar-link --dry-run`，人工抽查采用项 0 误挂；此前探针的 3 场误挂（GGBond 1on1、HRBP 1on1、Returns 渲染内部对齐）不得被采用。
- 新录音的「精确匹配率 100%」需要真实开一场 Meet 录音验证 —— **由用户在打包后的 App 里验收**。

## P2 实现与回放结果（2026-11-04）

- **参会人 ↔ 声纹名**：`CalendarAttendance`。名字键 = 参会人名字逗号各段、各段首词、邮箱前缀首段；仍对不上的从历史会议学别名——一场已关联、已命名的会里恰好只剩 1 个说话人和 1 位参会人对不上就记一票，同一参会人出现过两个不同名字即作废。别名每次命名时从 vault 现算，不另存文件。
- **门限**（`SpeakerMatchPolicy`，全部 4 条命名路径共用；录音没关联日程时行为与之前逐字节一致）：
  - 受邀者：常规 0.70 / margin 0.10；
  - 未受邀者：还需 cos ≥ **0.80**（`outsiderTauAbs`），margin 仍在全库算；
  - **参会人消歧**：最像者受邀、但第二像的人未受邀且自己够不上 0.80 时，margin 改按「下一个算数的对手」计算，且最像者 cos ≥ **0.75**（`attendanceTieBreakMin`）。
- **纪要**：`{meeting}` 占位符（日程标题、组织者、受邀人、议程描述，不含邮箱），模板不写也在有日程时自动注入到转录前；提示里注明「邀请名单 ≠ 实际发言人」。
- **回放验收**（vault 与索引 APFS 克隆，副本上写日历关联后重跑 100 场命名，以 52 场用户手标会议为真值，1674 分钟）：

| 规则 | 认对 | 认错 | 匿名 |
|---|---|---|---|
| 旧规则（无日历） | 94.8% | 0.13%（132s） | 5.1% |
| 仅「未受邀者更严」 | 94.7% | 0.13% | 5.1% |
| + 参会人消歧（无下限） | 98.5% | 0.2%（Carlos→Brent 83s，cos 0.70） | 1.3% |
| **+ 消歧下限 0.75（采用）** | **98.5%** | **0.16%（159s）** | **1.3%** |

  收益几乎全来自消歧：Team Sprite 07-31 里本人 42 分钟（cos 0.78 / margin 0.03，第二像者未受邀）、OS RBAC 09-01 里 Carlos 20 分钟。多出的 28s 认错（10-08 周会 Bryce→Charles，两人都受邀）是非 MOSS 路径「声纹重验」的连带变化。
