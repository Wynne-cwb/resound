# MOSS 转写后端 + 一键部署 设计稿（2026-07-22）

## 需求（用户原话归纳）

1. 设置页**优先支持/推荐 MOSS** 作为转写模型。
2. **新装用户** onboarding 时若选 MOSS：**一键登录 Modal → 自动部署 MOSS 服务**到用户自己的 Modal workspace。
3. 不用 MOSS 则回退现有 **Whisper online / Whisper local**。

## 背景

- 评测结论（见 DECISIONS 2026-07-22）：MOSS 端到端「转录+说话人」联合模型，说话人归属显著强于现管线，难音频转录更通顺；已部署 Modal 验证（异步 submit/poll，L4 RTF 0.36，$30/月免费额度内）。
- MOSS 一次调用同时产出转录+说话人分段 → MOSS 模式下**不再跑本地 diarization**（Sortformer/逐窗法跳过），但**跨录音识人仍走本地 CAM++**（MOSS 只给 S01/S02 匿名标签）。
- 已知取舍：MOSS 无词级时间戳，逐句点跳/引用定位为段级（2–5s）粒度（用户已知情选择 MOSS）。

## 架构

### 转写后端三选

`transcribeBackend: moss | whisperOnline | whisperLocal`（providers.json 新字段，缺省按现状推导保持零回归：配了在线转写= whisperOnline，否则 whisperLocal）。

### MOSS 模式的入库管线

```
音频 → VADGate(保留,剪静音省GPU费,时间已映射回原轴) → AudioNormalizer(保留)
     → MossClient.transcribe(submit→poll)  ←─ 热词: glossary 偏置词精简 top~20 拼进 prompt
     → 产出: 转录段(带 Sxx 说话人标签+段级时间戳)
     → 写 transcript.json(段级,无 words) + diarization.json(由 Sxx 段直接映射)
     → AI 校对(现有,继续适用) → 说话人命名: 按 Sxx 分组取音频段 → CAM++ 声纹 → 注册库双门匹配 → 真名/匿名分堆(复用现有 SpeakerNaming 路径)
     → 切块/索引/摘要(零改)
```

- whisperOnline/whisperLocal 路径**逐字节不变**（零回归底线）。
- MOSS 失败（网络/额度耗尽/超时）→ **自动回退 whisperOnline（若配置）否则 whisperLocal**，UI/日志明示「MOSS 失败已回退」。

### MossClient（ResoundCore）

- `submit(audioURL, prompt?, maxNewTokens) -> callId`：multipart POST `<submitURL>`，Bearer key。
- `poll(callId) -> running | done(MossResult) | failed(Error)`：GET `<resultURL>?call_id=`；轮询间隔 10s，总超时 = max(20min, 音频时长×1.5)。
- `MossResult.segments: [start,end,speaker,text]` → 映射成现有 Segment/diarization 结构。
- 配置：`mossSubmitURL` / `mossResultURL` / `mossAPIKey`（providers.json；key 随现有 providers 的存法）。

### MossDeployer（一键部署，ResoundCore + App UI）

App 内置资源：`moss_modal.py`（本仓库 experiments/moss-eval 的同款，随 bundle 分发）。

状态机（设置页与 onboarding 复用同一组件）：

```
checkPython → python3 ≥3.9? 否→引导(装 Xcode CLT / brew)
→ ensureVenv   App Support/Resound/modal-venv/ 一次性 `python3 -m venv` + `pip install modal`
→ modalAuth    `python -m modal setup`（自动开浏览器登录/注册,轮询完成;已有 ~/.modal.toml 则跳过）
→ ensureSecret 本地生成随机 key → `modal secret create moss-api-key MOSS_API_KEY=…`(已存在则复用)
→ deploy       `modal deploy <bundled>/moss_modal.py`,解析输出抓 submit/result URL
→ verify       用 10s 合成音频打一遍 submit/poll(镜像现有「测试连接」做法)
→ 写回 providers.json(backend=moss + 三项配置) → 完成
```

- 每一步失败可重试、显示 stderr 摘要；全程进度日志在 UI 上滚动。
- 用户须自己绑卡解锁 $30/月（未绑只有 $1）→ 部署完成页放提示 + 「打开 Modal 账单页」链接。

### 设置页（转写区改三选）

`MOSS 云端（推荐） / 在线 Whisper / 本地 Whisper`。选 MOSS：
- 未部署 → 部署卡（状态机 UI，一键部署按钮）。
- 已部署 → 显示 endpoint + 「测试连接」+「重新部署」。

### Onboarding

转写能力卡改推荐 MOSS（默认选中），复用部署卡组件；「跳过用 Whisper」回退现状行为。转写能力仍可留空兜底本地 whisper（现状不变）。

## 波次

- **Wave 1 Core**：providers/Config 扩展 + MossClient + 管线接入（MOSS 转写→transcript/diarization 落盘→CAM++ 命名接通）+ 失败回退 + CLI `transcribe --backend moss`（调试用）。CLI 全链路验证。
- **Wave 2 App 设置页**：三选 UI + MossDeployer + 部署卡 + 测试连接。
- **Wave 3 Onboarding**：能力卡推荐 MOSS + 复用部署卡。README 双语同步。

## 不做（本期）

- vLLM 提速、A10G 升级（后手，改 moss_modal.py 一行）。
- 官方 MOSS API 接入（定价未知，留观察）。
- 旧录音批量用 MOSS 重跑（可手动「重新转录」逐条走新 backend）。
