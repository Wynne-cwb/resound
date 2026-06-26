# Ask Resound 场景谱系 × 统一检索架构 —— 设计文档

> 日期：2026-06-26　状态：设计待评审
> 关联：修复「时间感知问答误判」（DECISIONS 2026-06-26）；本设计是它的上层重构。

## 1. 背景与目标

Ask Resound 当前只有两种形状（`QueryPlanner` 抽时间范围 + 判 `qa`/`digest`），擅长「小窗口回顾」和「具体事实」，但面对**跨长时间的主题性回顾**会撞墙（digest 无上限地把全库摘要一股脑塞进一个 prompt、且主题盲；qa 只取 top-8 太浅）。同时缺「按说话人」「时间线演变」「对比」等高频诉求。

**目标**：把 Ask 重构成一个**统一检索内核**，覆盖下列 7 个场景，且它们**可叠加、不互斥**。砍掉⑥（行动项/承诺追踪）不在本期。

## 2. 场景谱系（按「检索形状」归类）

| # | 场景 | 例子 | 形状 |
|---|---|---|---|
| ① | 单条目内问 | 「这条录音里 X 说了啥」「这篇文档讲了啥」 | 单条目检索（已存在） |
| ② | 跨长时间主题回顾 | 「2026 年我做了哪些管理动作改进」 | 全库主题综合（digest 变体） |
| ③ | 针对性现状 | 「OS **最新**的迁移策略是什么」 | 点事实 + **近因偏好** |
| ④ | 小窗口回顾 | 「上周/这个月开了哪些会、聊了啥」 | 小范围 digest（已擅长） |
| ⑤ | 人物维度 | 「我和 Jerry 都聊过什么」「谁负责 OS 迁移」 | **按说话人过滤 / 或人是答案** |
| ⑦ | 主题演变/时间线 | 「OS 迁移策略怎么一步步演变到现在」 | 按时间串成轨迹（digest 变体） |
| ⑧ | 对比/差异 | 「这周和上周 1-on-1 重点差在哪」 | 两个集合对比（digest 变体） |

**关键洞察**：②⑦⑧ 共用一台引擎——「跨多条录音按主题圈子集 → 综合」，只是最后「综合」那步换形状（汇总 / 串时序 / 比差异）。

## 3. 架构总览：两个正交维度

检索 = **过滤层（圈子集，可自由组合）× 综合层（选一种输出形状）**。

```
提问 ─► 路由器 QueryPlanner v2
            │ 输出 {query, shape, filters{time,speaker,source}, recency, compare_sets}
            ▼
        过滤层（chunks 列 AND 组合：recording_date / person_id / source_kind / 单条目）
            ▼
        检索层（hybrid: 向量+FTS+RRF+rerank；recency=true 时叠加近因加权）
            ▼
        综合层（按 shape 分流）
            ├─ qa       → Synthesizer（点答案 + 引用）           ①③⑤(人是答案)
            ├─ digest   → 子集摘要 + 命中片段 → 汇总              ②④⑤(按人)
            ├─ timeline → 同上，按日期串成演变叙事                ⑦
            └─ compare  → 两个子集各自检索 → 对比综合              ⑧
            ▼
        （子集过大时）map-reduce 分批综合再合并 ── 治「无上限/超 context」
            ▼
        source-aware 引用（🎙️/📄，沿用现有）
```

**综合数据源（已与用户定）= 混合**：综合时喂【相关录音的**摘要** + 语义**命中的原文片段**】，既有全局视角又能引到具体原话，成本/延迟可控（年度回顾约数十秒级）。不做"只读摘要"（会漏没写进摘要的细节），也不做"全量原文 map-reduce"（太慢太贵）。

## 4. 路由器：QueryPlanner v2

单次 LLM 调用，输出扩展为：

```json
{
  "query": "清洗后的检索词（话题；话题里的时间词要保留，如『下半年的规划』）",
  "shape": "qa | digest | timeline | compare",
  "filters": {
    "date_from": "yyyy-MM-dd | null",   // 仅当时间词修饰『录音发生时间』
    "date_to":   "yyyy-MM-dd | null",
    "speakers":  ["Jerry"] | null,       // 按说话人筛（chunks.person_id）
    "source":    "recording | document | both | null"
  },
  "recency": false,                       // 『最新/现状/目前』意图 → 近因加权
  "compare_sets": null | [                 // 仅 shape=compare
    {"label": "这周", "date_from": "...", "date_to": "...", "speakers": null},
    {"label": "上周", "date_from": "...", "date_to": "...", "speakers": null}
  ]
}
```

**意图分类规则（写进 system prompt，给足正反例）**：
- **shape**：
  - `qa`：问具体事实/细节/「谁负责 X」。
  - `digest`：要概览/汇总/「有哪些会、聊了啥」、或跨大范围的主题回顾。
  - `timeline`：要「怎么演变/发展历程/关键节点/一步步」。
  - `compare`：要「A 和 B 的区别/差异/对比」。
- **time as filter vs time as topic**（沿用 2026-06-26 修复的规则）：时间词修饰「录音/会议发生在何时」才填 `filters.date_*`；若是话题名词的一部分（修饰规划/计划/目标/预算），两端 null、保留在 query。
- **recency**：出现「最新/目前/现在/截至现在」且问的是某事的当前状态 → `recency=true`（按录音日期对召回结果做时间衰减加权，让最近的讨论优先）。
- **speakers**：出现具体人名且语义是「按这个人筛内容」（「我和 Jerry 聊过什么」）→ 填 `speakers`；若人名是**被问的答案**（「谁负责 X」）→ 不填，走 qa。
- **source**：明确「文档里/根据那份文档」→ document；「会上/录音里」→ recording；默认 both。

**安全兜底（核心教训落地）**：
- 解析失败 / 判不准 → 退回 `shape=qa, filters 全 null, recency=false`，绝不空手挡死。
- `dropFutureRange`（已实现）继续生效：纯未来日期范围丢弃。
- **过滤后子集为空** → 自动放宽（去掉最可能误加的过滤，按优先级：先去 speaker→再去 time）重试一次；仍空才提示「没有命中，换个问法或时间范围」，并说明放宽过什么。**不再出现「②类问题被一句『没有录音』挡死」**。

## 5. 过滤层（复用现有 chunks 列，零 schema 改动）

`chunks` 已有：`recording_date`(text yyyy-MM-dd)、`person_id`(说话人名)、`source_kind`('recording'|'document')、`doc_id`。

扩展 `Index.vectorSearch` / `ftsSearch` 增加可选参数并 AND 进 SQL：
- `dateRange`（已有）
- `speakers: [String]?` → `and c.person_id in (?...)`
- `source: SourceKind?` → `and c.source_kind = ?`
- `recordingId` / `docId`（已有，供①单条目）

过滤条件天然可组合（都是 WHERE 的 AND）。`person_id` 边界：匿名说话人（「说话人1」）按原值参与；用户用真名提问时只会命中已命名的人，符合预期。

## 6. 检索层：hybrid + 近因加权（③）

现有：向量 + FTS → RRF 融合 → LLM rerank。新增：
- 当 `recency=true`，对融合后候选按 `recording_date` 施加**时间衰减**（越近权重越高，例如半衰期 N 天的指数衰减），再交 rerank。门控触发——非 recency 查询不加，避免污染「这个主题讲过啥」这类无近因诉求的检索。

## 6.5 检索宽度随模式自适应（关键：现有 8 段上限是宽问题的瓶颈）

现状漏斗（`search`）：召回 `pool=40`(向量) + 40(FTS) → RRF 留 `rerankCandidates=15` → 重排取 `topK=8`(qa) / 6(单条目)。最终仅 ~8 段进写答案的 LLM。

- **qa / 单条目**：保持精简（final ≈ 6–8）。多塞无关片段会**稀释/干扰**答案且更贵 → 不放大。
- **digest / timeline / compare**：上限**显著放大**。这一步的目的不是"挑最相关 8 段"，而是**尽量找全相关的录音子集**——若仍卡在 40/15/8，会漏掉本该纳入的录音。建议：`pool` 80–120、候选保留数十段、按 `recording_id` 去重后得到"相关录音集合"（数量级是录音数，不是片段数）。
- 这些上限作为**按 shape 取值的常量**（保守默认，实测再调），不写死单一 `topK`。

## 7. 综合层（4 种形状）

统一签名：拿到「子集（recordingRows + 命中 chunks）」后按 shape 产出文本，全部保留 source-aware 引用。

- **qa**：现有 `Synthesizer.answer(query, hits)`，不变。①③⑤(人是答案) 走它。
- **digest**：重构现有 `digestAnswer`。输入从「全部录音的摘要」改为「**主题子集的录音摘要 + 命中片段原文**」。
  - ④小窗口无主题词时：子集=范围内全部录音、无命中片段 → 退化为「喂摘要」（≈ 现有行为，零回归）。
  - ②大范围有主题词时：先 hybrid 检索圈出相关录音子集（而非全取），再喂【这些录音摘要 + 命中片段】。**这就是治②「无上限+主题盲」的核心**。
- **timeline**：同 digest 取数，但综合 prompt = 「按 `recording_date` 升序，串成『谁在何时推动了什么 → 如何演变到现在』的叙事，标注日期节点」。
- **compare**：对 `compare_sets` 的两个集合各做一次过滤+检索，综合 prompt = 「分两栏列各自重点，再点明差异」。

## 8. map-reduce（治规模，服务 ②⑦⑧）

当子集材料超预算（如录音数 > K 或拼接字符 > M，K/M 设为可调常量）：
1. **map**：把子集按时间分批（每批 ≤ 预算），各批先产「针对该问题的局部小结（带引用标记）」。
2. **reduce**：把各批小结 + 问题再交 LLM 合成终答，保留引用。

预算内则单次综合（不绕 map-reduce，省延迟）。这彻底替掉现在「`recordingsInRange` 无 LIMIT 全拼」的隐患。

## 9. 引用

沿用现有 source-aware 引用（🎙️ 录音跳时间点 / 📄 文档跳高亮段）。timeline/compare 的引用挂在各时点/各栏目的来源上。digest 的引用既可指向录音整体（摘要来源）也可指向命中片段（精确时间点）。

## 10. CLI 优先验证 + App 接线（项目惯例）

- **CLI 先行**：`resound ask` 已是同一条 `IndexPipeline.answer` 路径。新增调试输出（命中的 shape / filters / 子集录音数 / 是否走 map-reduce），无头跑通 7 类问句再碰 App。
- **App**：`ChatView`/`ChatStore` 基本零改——它已消费 `AnswerResult`。需要的是：
  - 顶部那条「🗓 时间范围」提示扩展成「🗓 时间 / 👤 人物 / 🧭 模式」的轻量 chip（让用户看见系统怎么理解了他的问题，也便于发现误判）。
  - `.emptyTime` 兜底文案改成「放宽后仍无命中」的通用版（配合 §4 兜底）。

## 11. 实现分批（按共享地基排，不是砍需求）

1. **第一批（地基）**：QueryPlanner v2（含 §4 兜底）+ 过滤层（speaker/source 参数）+ digest 重构成「主题子集 + 混合数据源」+ map-reduce。→ 覆盖 ①②④⑤ 基础 + ③的 qa 部分。
2. **第二批**：近因加权（③ recency）。
3. **第三批**：timeline（⑦）、compare（⑧）两个综合形状。

每批 CLI 验证全绿再接 App、再重建实机。

## 12. 零回归要求

- 无时间/人/来源过滤、shape=qa 的普通问题：行为逐字节同现状。
- ④小窗口无主题 digest：退化路径 ≈ 现有 `digestAnswer`（喂摘要）。
- 单条目①：`answerInRecording`/`answerInDocument` 路径不变。

## 13. 验收点

1. ②「2026 年做了哪些管理改进」→ 走 digest、子集是主题相关录音（非全量）、答案带引用、不超时不空。
2. ③「OS 最新迁移策略」→ recency 生效，最近的讨论优先。
3. ④「这个月聊了啥」→ 与今天行为一致。
4. ⑤「我和 Jerry 聊过什么」→ 按 person_id=Jerry 筛；「谁负责 OS 迁移」→ qa、人是答案。
5. ⑦「OS 迁移怎么演变的」→ 按日期串成时间线。
6. ⑧「这周 vs 上周 1-on-1 差异」→ 两集合对比。
7. **兜底**：故意问会过滤到空的问题 → 自动放宽 + 说明，绝不「没有录音」挡死。
8. 回归：上述无过滤普通 qa / 小窗口 digest 不变。

## 14. 取舍 / 暂不做

- **⑥ 行动项/承诺追踪**：本期不做（需要跨录音抽 commitments 的额外建模，独立成期）。
- 全量原文 map-reduce 综合：不做（太慢太贵），采用混合数据源。
- 不为 ⑤ 加新 schema 列（复用 person_id）。

## 15. 待定 / 风险

- 路由器模式变多 → 误判风险上升。对策=正反例 + 安全兜底（§4）。上线后靠真实问句迭代 prompt（杠杆在 prompt，沿用既有教训）。
- 近因衰减半衰期、map-reduce 的 K/M 阈值：先定保守默认，实测再调。
- timeline/compare 是低频但高价值，若实现成本超预期可降级（compare 用两次 qa 拼）。
