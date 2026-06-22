# 当前状态 (STATE)

> "现在的快照"。过时就改。细节查 [DECISIONS.md](DECISIONS.md)。
> 最近更新：2026-06-22

## 一句话现状

CLI 全链路(录音→转录→说话人识别→切块入库→检索问答)已通且验证。**正在做 macOS App 套壳**:SwiftUI 三页(Ask Resound 问答 / Library 录音库 / Settings)+ Meet 检测弹窗录音 + 整套磨砂玻璃样式都已编译打包通过,**用户在迭代视觉与录音库细节**。

## ✅ 已完成且验证（细节见 DECISIONS）

- **检索/问答**:transcribe→繁简归一+glossary→切块→contextual→embed(qwen3-8b)→SQLite(FTS5+sqlite-vec)→RRF→LLM rerank→带引用问答。CLI 全套。
- **说话人识别**:弃盲聚类,走「ASR段合并≥4s窗→CAM++声纹→注册匹配」。同会议89-92%、跨录音88%、Swift 复现82-85%。接入检索(search/ask 显示👤)。冷启动在线分堆(命名~6次覆盖92%)。sherpa-onnx 静态库(`scripts/build-sherpa-onnx.sh`)。
- **App**(SPM 应用+`scripts/bundle-app.sh`打签名 .app):
  - Ask Resound 页(接真实 ask)、Settings 页、Library 录音库(列表+播放条+带👤转录+点句跳播放+重命名/删除+拖拽进度条+识别说话人)
  - Meet 检测→弹窗→双路录音(麦克风+ScreenCaptureKit对方音)→转录→**自动索引这一条**→可搜
  - 样式:磨砂玻璃+冷蓝点缀+背景淡蓝辉光+自定义分段切换器,浅深双模式,图标已接
  - **用户实测过**:问答、Meet弹窗、录音都正常

## 🎯 当前焦点 / 下一步

- **用户正测 Library v2**(4项改进:整卡可点/重命名删除/hover手型/拖拽进度条+说话人标注),等截图反馈迭代。
- 之后:**说话人命名 UI**(匿名「说话人N」→改真名+存声纹库,闭合"标几次变准");模型预热(large-v3首次~13min);设置可视化;菜单栏常驻。

## ⚠️ 未提交（用户将 commit 后压缩上下文）

自 `9b56f42` 之后未提交:闭环自动索引(indexRecording)、整套样式重构(Theme/ChatView/RootView)、Library 页(LibraryView/VaultBrowser/Index chunkPersons+deleteRecording/Config vaultPath)。

## 📌 运行 / 测试要点

- App 配置:`.env` 复制到 `~/Library/Application Support/Resound/.env` + 补 `VAULT_PATH`、`SPEAKER_MODEL`(已帮用户写好)。
- 改完样式必须 `killall Resound` 再 `open build/Resound.app`(旧实例在跑则 open 只切前台)。
- GUI 渲染我看不到 → 靠用户截图迭代。权限(麦克风/屏幕录制/自动化)需用户授权。
- 测试数据(ground truth)在 `~/Downloads`:GGbond 2人会议、OS 6人会议(+vault 已有这两条+用户App实录一条)。
- 实验脚本 `experiments/diar-py/`(venv/模型 gitignored)。

## 待办/提醒

- 标注落 vault:diarization.json 已做(Library 识别说话人时写);声纹向量在 index。
- 加音频进真 vault 前装 git-lfs;synthesis pro/flash A/B 未做;拒识阈值 τ 待调。
