# Resound 数据契约 (Data Contract)

> 这是整个项目的地基。所有模块（录音、转录、声纹、切块、检索）都必须遵守这份契约。
> 改动这份文档前先想清楚向后兼容，schema 一律带版本号。

---

## 0. 三个边界：Vault / App / Index

项目有三块物理上分开的东西，**不要混存**：

| 名称 | 内容 | 在哪 | 版本化 | 性质 |
|---|---|---|---|---|
| **Vault**（数据仓库） | 音频、转录、说话人标注、人物表、markdown 笔记 | 独立 GitHub repo | ✅ Git | **事实源**，可移植 |
| **App**（应用代码） | Swift/SwiftUI 源码 | 另一个 repo | ✅ Git | 程序 |
| **Index**（检索索引） | SQLite + FTS5 + sqlite-vec + 声纹向量 + LLM 缓存 | 本地 App Support 目录 | ❌ gitignore | **派生物**，可一键重建 |

核心不变量：**删掉整个 Index，App 能从 Vault 完整重建出来。** 这条决定了什么进 Vault、什么进 Index。

### 0.1 Vault 是可配置的数据源，不是写死的 repo

App（`resound`）只是**纯实现**，不绑定任何具体数据 repo。Vault 是用户在设置里**指定**的、符合本契约的任意 git repo（如 `github.com/Wynne-cwb/wayne-resound`）。

交互模型：**App 操作本地工作副本，git 只当同步/版本层**——不直接调 GitHub API。

```
用户在设置里填:  github.com/<owner>/<vault-repo>
   ↓ 首次:  git clone 到 ~/Library/Application Support/Resound/vaults/<repo>
   ↓ 运行:  App 全程读写本地副本（录音/转录/标注都落本地文件）
   ↓ 同步:  合适时机 git commit + push 回用户的 repo
   ↓ 换源:  改设置 URL → 重新 clone → 重建 Index
```

- App 加载时**校验 vault 结构**（根目录有 `resound.yaml` + `recordings/` + `people/`）才认。
- 认证复用机器上已有的 git 凭据（gh/git），App 不自己管 token。
- 天然支持多 vault（工作/私人切换）和换机迁移。

### 0.2 音频走 Git LFS

git 不适合大二进制。约定：**`*.m4a` 等音频走 Git LFS，文本（transcript/labels/notes/yaml）走普通 git**。
保住"Vault = 单一事实源 + 可移植"原则。注意 GitHub 私有 repo 的 LFS 免费额度有限，重度录音需留意配额。
vault repo 根目录需带 `.gitattributes`：

```
*.m4a filter=lfs diff=lfs merge=lfs -text
*.flac filter=lfs diff=lfs merge=lfs -text
*.wav filter=lfs diff=lfs merge=lfs -text
```

---

## 1. 源 vs 派生 的三档分类

不是非黑即白，有中间档。这决定一个数据放 Vault 还是 Index：

| 档 | 定义 | 例子 | 放哪 |
|---|---|---|---|
| **纯事实** | 人产生的、无法重算 | 原始音频、用户的说话人标注、人物表、手写笔记 | **Vault** |
| **昂贵可修正** | 机器生成但①重算贵 ②人会手动改 | 转录文本、diarization 分段 | **Vault**（首次生成后当事实源） |
| **免费可重算** | 确定性、随时重算 | 文本 embedding、FTS 索引、声纹向量、merge 后的 segments | **Index** |
| **LLM 派生** | 非确定性 + 花钱 | contextual 增强文本、LLM 抽的元数据 | **Index 的 cache 表**（按内容 hash 缓存，避免重复付费 / 保证可复现） |

> 关键陷阱：**LLM 派生物绝不能当"免费可重算"每次重建都重跑**——非确定且烧钱。统一进 `enrichment_cache`，key = 内容 hash + 模型版本。

---

## 2. Vault 目录结构

```
resound-vault/
├── resound.yaml                      # vault 配置：schema 版本、默认设置
├── glossary.txt                      # 用户词表：专有名词偏置 + 别名纠正（事实源）
├── people/
│   └── people.yaml                   # 人物注册表（事实源，声纹身份的锚）
├── recordings/
│   └── 2026/06/
│       └── 2026-06-18-1430-standup/  # 一次录音 = 一个文件夹，id 即文件夹名
│           ├── recording.yaml        # 录音元数据清单（人可编辑）
│           ├── audio.m4a             # 原始音频归档（事实源）
│           ├── transcript.json       # 词级时间戳转录（昂贵可修正）
│           ├── diarization.json      # 说话人时间分段（昂贵可修正）
│           └── labels.json           # spk_N → person_id 映射（用户确认，最珍贵的事实）
├── notes/
│   └── 2026-06-18-架构讨论.md         # 自由 markdown 笔记（带 frontmatter）
└── .gitignore
```

设计决策：
- **一次录音一个文件夹**：音频+转录+分段+标注内聚，整体可移动/删除，git diff 清晰。
- **按 `年/月/` 分层**：避免单目录文件爆炸。
- **transcript / diarization / labels 拆三个文件**：三者生命周期不同——transcript 会改错字、diarization 会改分段、labels 是用户金标。拆开后改一个不脏另一个，git 历史干净。
- **格式分工**：人编辑的用 **YAML**（manifest、people、配置），机器生成的用 **JSON**（transcript/diarization/labels）。只用两种格式。

---

## 3. Schema 定义

### 3.1 `resound.yaml`（vault 根配置）

```yaml
schema: resound.vault/1
vault_name: my-wiki
created: 2026-06-18
timezone: Asia/Shanghai          # 所有无时区时间戳的默认解释
default_language: zh
```

### 3.2 `people/people.yaml`（人物注册表）

```yaml
schema: resound.people/1
people:
  - id: p_zhangsan               # 稳定 id，一经分配永不复用、不改
    name: 张三
    aliases: [Zhang San, 老张]    # 检索别名 / 实体归一
    note: 团队同事
    created: 2026-06-18
  - id: p_self
    name: 我
    aliases: [本人]
    created: 2026-06-18
```

规则：
- `id` 用 `p_` 前缀 + slug，**永不复用**（删人也别回收 id，避免历史标注串人）。
- 声纹向量**不在这里**——它是 Index 里的派生物，由 `audio + labels` 重算。这张表只存"人是谁"这个事实。

### 3.3 `recording.yaml`（录音清单）

```yaml
schema: resound.recording/1
id: 2026-06-18-1430-standup       # = 文件夹名
title: 周一站会
recorded_at: 2026-06-18T14:30:00+08:00
duration_sec: 1820
source: meeting                   # meeting | memo | call | lecture | ...
language: zh
tags: [work, standup]
audio_file: audio.m4a

# 溯源：用什么模型生成的，重建/对账用
provenance:
  asr_model: whisperkit-large-v3
  diarization_model: sherpa-onnx-pyannote-segmentation-3.0
  speaker_embed_model: 3dspeaker-eres2net-large   # 声纹模型，换了要重算声纹
```

### 3.4 `transcript.json`（词级转录）

```json
{
  "schema": "resound.transcript/1",
  "language": "zh",
  "segments": [
    {
      "id": 0,
      "start": 12.34,
      "end": 18.90,
      "text": "我们今天先过一下这周的排期",
      "words": [
        { "w": "我们", "start": 12.34, "end": 12.80 },
        { "w": "今天", "start": 12.80, "end": 13.20 }
      ]
    }
  ]
}
```

- `words` 词级时间戳是**硬要求**——切块和 diarization 对齐都靠它。
- 用户改错字时改 `text`（必要时连带 `words`），这是允许的"昂贵可修正"。

### 3.5 `diarization.json`（说话人分段）

```json
{
  "schema": "resound.diarization/1",
  "speakers": ["spk_0", "spk_1"],
  "segments": [
    { "speaker": "spk_0", "start": 12.30, "end": 25.10 },
    { "speaker": "spk_1", "start": 25.10, "end": 31.40 }
  ]
}
```

- `spk_N` 是**录音内的局部 id**，只表示"这段录音里的第 N 个人"，跨录音无意义。
- 跨录音的稳定身份靠 `labels.json` 映射到 `person_id`。

### 3.6 `labels.json`（说话人身份映射 —— 最珍贵的事实）

```json
{
  "schema": "resound.labels/1",
  "map": {
    "spk_0": "p_zhangsan",
    "spk_1": "p_lisi"
  },
  "confirmed_by": "user",
  "confirmed_at": "2026-06-18T15:00:00+08:00",
  "overrides": [
    {
      "start": 40.0,
      "end": 45.0,
      "person_id": "p_zhangsan",
      "reason": "diarization 把张三误切给了 spk_1"
    }
  ],
  "unresolved": ["spk_2"]
}
```

- `map`：本录音 `spk_N` → 全局 `person_id`，是声纹增量注册和重建声纹库的**金标来源**。
- `overrides`：人工纠正 diarization 错误的时间段级覆盖（你设计里要的"人工纠正入口"的落盘格式）。
- `unresolved`：落在双阈值中间地带、还没确认的 speaker，留给 UI 待确认队列。

### 3.8 `glossary.txt`（用户词表 —— 提升专有名词识别）

通用 ASR 对私有专有名词/人名/术语识别差。词表两层兜：①转录前把规范词注入 WhisperKit
`promptTokens` 做偏置（预防）；②转录后把变体确定性替换成规范词（兜底）。纠正**改写
transcript.json**，原始音频仍是 ground truth。

```
# 一行一条，# 为注释
Resound = Resount             # 规范词 = 变体；转录后变体→规范词
Qwen3 = 昆3, 坤3              # 多个变体逗号分隔
rerank = Re-rank
sherpa-onnx                   # 无 "="：只做偏置、不纠正
```

- 实测：即便弱模型(small)，别名纠正也能把 `Resount/坤3/Re-rank` 全部纠回。
- 词表是用户领域事实，随 vault 走；将来可复用给检索做实体归一。
- CLI `--hint <词>` 可临时叠加偏置词（不写入 glossary、不做纠正）。

### 3.7 `notes/*.md`（自由笔记）

```markdown
---
schema: resound.note/1
title: 架构讨论
date: 2026-06-18
tags: [resound, 架构]
people: [p_zhangsan, p_self]              # 关联人物
links: [recording:2026-06-18-1430-standup] # 关联录音
---

正文……
```

---

## 4. Index（派生，本地，可重建）

SQLite 单文件，放 `~/Library/Application Support/Resound/index.sqlite`，**不进 git**。

### 关键表

```
meta                 -- 索引级元信息（见下，对账用）
people               -- 从 people.yaml 镜像
recordings           -- 从 recording.yaml 镜像
speaker_embeddings   -- 声纹向量（sqlite-vec），由 audio + labels 重算
chunks               -- 切块：text, context, person_id, recording_id, start, end, tags...
chunks_fts           -- FTS5 全文索引（关键词路 / BM25）
chunks_vec           -- sqlite-vec 向量表，dim=1024（向量路）
enrichment_cache     -- LLM 派生缓存：key=hash(chunk+prompt+model) → context 文本
```

### `meta` 表内容（重建对账的核心）

```
schema_version      = resound.index/1
vault_commit        = <git sha>          -- 索引基于哪个 vault commit 建的
embedding_provider  = aihubmix (https://aihubmix.com/v1, OpenAI 兼容)
embedding_model     = qwen3-embedding-8b
embedding_dim       = 4096
normalized          = true
distance            = cosine
query_instruction   = "Given a search query, retrieve relevant passages that answer it"
rerank_model        = bge-reranker-v2-m3
built_at            = <timestamp>
```

> 换 embedding 模型 / 维度 → `meta` 不匹配 → 触发全量重 embed。这是上一轮定的"锁定 embedding 并写进元信息"的落地。

---

## 5. 重建逻辑（Index 怎么从 Vault 重算）

```
for 每个 recording:
    读 transcript.json + diarization.json + labels.json
    ① 对齐：按时间把 words 归到 diarization 段 → 段归到 person_id（应用 overrides）
    ② 切块：按说话人轮次 / 话题段切 → chunks（带 person_id, time range, recording_id）
    ③ 声纹：对每个 person 的高质量片段抽 embedding → speaker_embeddings（增量注册）
    ④ 上下文增强：每个 chunk 查 enrichment_cache，命中读缓存，否则调 LLM 生成并写缓存
    ⑤ 文本 embedding：context+chunk → Qwen3-Embedding → chunks_vec
    ⑥ 建 FTS5：chunk 文本 → chunks_fts
写 meta（含 vault_commit）
```

幂等：同一个 vault commit 重跑结果一致（LLM 那步靠 cache 保证）。

---

## 6. 决策记录

| # | 问题 | 决策 |
|---|---|---|
| 1 | Vault / App 是否分 repo | ✅ **分**。App = `github.com/Wynne-cwb/resound`（纯实现）；Vault = 用户可配置的数据 repo，作者本人的是 `github.com/Wynne-cwb/wayne-resound` |
| 2 | Vault 是否写死 | ❌ 不写死，**用户设置里指定**，App 操作本地工作副本（见 0.1） |
| 3 | 音频格式 | **m4a**（AAC），走 **Git LFS**（见 0.2） |
| 4 | LLM enrichment 缓存放哪 | 默认放 Index（不提交）；若需跨机免重付 LLM 费用 + 完全可复现，再单独建 `cache/` 提交。**先放 Index** |
```
