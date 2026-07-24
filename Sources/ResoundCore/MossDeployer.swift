import Foundation
import Security

/// MOSS 一键部署：把内置的 moss_modal.py 部署到**用户自己的 Modal workspace**。
///
/// 流程（每步失败可整体重跑，全部幂等）：
///   ① 找 python3（≥3.9） ② App Support 建 venv + pip install modal ③ Modal 登录
///  （已有 token 跳过；否则 `modal setup` 自动开浏览器，新用户顺路注册）④ 生成随机
///   API key → `modal secret create --force` ⑤ `modal deploy` 解析两个 endpoint URL
///   ⑥ 合成 1s 音频真打一遍 submit/poll 验证（顺路触发首次权重下载预热）。
///
/// 全程 shell 出去（Modal 只有 Python 客户端，无公开 REST 部署 API）；输出逐行回调给 UI。
public enum MossDeployer {

    public struct Deployment: Sendable {
        public let submitURL: String
        public let resultURL: String
        public let apiKey: String
    }

    public enum DeployError: Error, CustomStringConvertible {
        case pythonMissing
        case step(String, String)   // (步骤, 摘要)
        public var description: String {
            switch self {
            case .pythonMissing:
                return "没找到 python3（≥3.9）。安装 Xcode 命令行工具（xcode-select --install）或 Homebrew python 后重试。"
            case .step(let s, let m): return "\(s)失败：\(m)"
            }
        }
    }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resound")
    }
    static var venvPython: URL { supportDir.appendingPathComponent("modal-venv/bin/python") }

    /// Modal 是否已登录过（有 token 文件；有效性在部署时真验）。
    public static var hasModalToken: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.modal.toml")
    }

    // MARK: - 主流程

    public static func deploy(log: @escaping @Sendable (String) -> Void) async throws -> Deployment {
        // ① python3
        log("① 检查 Python…")
        guard let python = findPython() else { throw DeployError.pythonMissing }
        log("   ✓ \(python.path)")

        // ② venv + modal CLI
        log("② 准备 Modal CLI（一次性，约半分钟）…")
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: venvPython.path) {
            let r = try await run(python.path, ["-m", "venv", supportDir.appendingPathComponent("modal-venv").path])
            guard r.code == 0 else { throw DeployError.step("创建 venv", r.tail) }
        }
        // fastapi 必须一起装：`modal deploy` 会在本地执行 moss_modal.py（顶层 import fastapi），
        // 而 modal 包自身不依赖 fastapi。
        let pip = try await run(venvPython.path, ["-m", "pip", "install", "-q", "--upgrade", "modal", "fastapi"], timeout: 300)
        guard pip.code == 0 else { throw DeployError.step("安装 modal", pip.tail) }
        log("   ✓ modal CLI 就绪")

        // ③ 登录（先探测既有 token；无效/缺失才走浏览器授权，新用户顺路注册）
        log("③ 检查 Modal 登录…")
        let authed = (try? await run(venvPython.path, ["-m", "modal", "app", "list"], timeout: 60))?.code == 0
        if authed {
            log("   ✓ 已登录 Modal")
        } else {
            log("   ▶︎ 浏览器将打开 Modal 授权页（没有账号就在该页注册），完成后自动继续…")
            let setup = try await run(venvPython.path, ["-m", "modal", "setup"], timeout: 300, stream: { line in
                if line.contains("modal.com/token-flow/") {
                    log("   授权链接（浏览器没弹出就手动打开）：\(line.trimmingCharacters(in: .whitespaces))")
                }
            })
            guard setup.code == 0 else { throw DeployError.step("Modal 登录", setup.tail) }
            log("   ✓ 登录成功")
        }

        // ④ API key + Secret（--force 覆盖旧值，保证本地 key 与云端一致）
        log("④ 生成访问密钥…")
        let key = randomKey()
        let secret = try await run(venvPython.path,
            ["-m", "modal", "secret", "create", "moss-api-key", "MOSS_API_KEY=\(key)", "--force"], timeout: 60)
        guard secret.code == 0 else { throw DeployError.step("创建 Secret", secret.tail) }
        log("   ✓ Secret 已写入你的 workspace")

        // ⑤ 部署（首次构建云端镜像约 3 分钟；重部署秒级）
        log("⑤ 部署 MOSS 服务（首次约 3 分钟）…")
        guard let script = Bundle.module.url(forResource: "moss_modal", withExtension: "py") else {
            throw DeployError.step("内置脚本", "app bundle 里没找到 moss_modal.py")
        }
        let localScript = supportDir.appendingPathComponent("moss_modal.py")
        try? FileManager.default.removeItem(at: localScript)
        try FileManager.default.copyItem(at: script, to: localScript)
        let dep = try await run(venvPython.path, ["-m", "modal", "deploy", localScript.path], timeout: 900)
        guard dep.code == 0 else { throw DeployError.step("modal deploy", dep.tail) }
        let all = dep.out + "\n" + dep.err
        guard let submit = firstMatch(#"https://[a-z0-9-]+--moss-transcribe-submit\.modal\.run"#, in: all),
              let result = firstMatch(#"https://[a-z0-9-]+--moss-transcribe-result\.modal\.run"#, in: all) else {
            throw DeployError.step("解析部署输出", "没找到 endpoint URL（modal 输出格式变了？）\n\(dep.tail)")
        }
        log("   ✓ 已部署：\(submit)")

        // ⑥ 端到端验证（合成音频真打一遍；首次会顺路下载模型权重到云端缓存，约 3~6 分钟）
        log("⑥ 端到端验证（首次含云端下载模型，约 3~6 分钟，请耐心）…")
        let dm = Deployment(submitURL: submit, resultURL: result, apiKey: key)
        try await verify(dm, log: log)
        log("✅ 部署完成，MOSS 已可用")
        return dm
    }

    /// 用 1 秒合成音频走一遍 submit → poll（镜像 ProviderProbe 的「测试连接」思路，但走真 GPU）。
    public static func verify(_ d: Deployment, timeout: TimeInterval = 600,
                              log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        var cfg = try? Config.load()
        cfg?.mossSubmitURL = d.submitURL; cfg?.mossResultURL = d.resultURL; cfg?.mossKey = d.apiKey
        let wav = synthWAV(seconds: 1.2)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("moss-verify-\(UUID().uuidString).wav")
        try wav.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let c = cfg else { throw DeployError.step("验证", "无法读取配置") }
        let t = try MossTranscriber(config: withMoss(c, d), hotwords: [])
        do {
            _ = try await t.transcribe(audio: tmp, timeout: timeout, log: log)
        } catch MossError.empty {
            // 合成音没有语音内容 → 「MOSS 返回空转录」也算链路通（服务端 GPU 正常跑完了）
        }
    }

    /// 轻量连通性检查（不动 GPU）：带 key 打 result 端点，区分「密钥错」vs「可达」。
    public static func probe(submitURL: String, resultURL: String, apiKey: String) async -> (ok: Bool, detail: String) {
        guard var comps = URLComponents(string: resultURL) else { return (false, "endpoint URL 不合法") }
        comps.queryItems = [URLQueryItem(name: "call_id", value: "fc-probe")]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? -1 {
            case 401: return (false, "密钥不对（服务在，但 Bearer 校验失败）")
            case 200, 202, 400, 404, 422, 500: return (true, "服务可达 · 密钥有效")
            case let c: return (false, "服务响应异常 HTTP \(c)")
            }
        } catch {
            return (false, "连不上：\(error.localizedDescription)")
        }
    }

    private static func withMoss(_ c: Config, _ d: Deployment) -> Config {
        var c = c
        c.transcribeBackend = "moss"; c.mossSubmitURL = d.submitURL
        c.mossResultURL = d.resultURL; c.mossKey = d.apiKey
        return c
    }

    // MARK: - 工具

    static func findPython() -> URL? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            // /usr/bin/python3 在未装 CLT 时是个会弹窗的 stub —— 用 --version 探测真身且校验版本
            if let v = try? runSync(p, ["--version"]), v.code == 0,
               let ver = firstMatch(#"3\.(\d+)"#, in: v.out + v.err),
               let minor = Int(ver.dropFirst(2)), minor >= 9 {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    struct RunResult { let code: Int32; let out: String; let err: String
        var tail: String { String((err.isEmpty ? out : err).suffix(400)) } }

    /// 子进程执行（异步，超时强杀；stream 回调逐行吐 stdout+stderr）。
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 120,
                    stream: (@Sendable (String) -> Void)? = nil) async throws -> RunResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: exe)
                    p.arguments = args
                    var env = ProcessInfo.processInfo.environment
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                    env["TERM"] = "dumb"   // modal CLI 少画进度条
                    p.environment = env
                    let outPipe = Pipe(), errPipe = Pipe()
                    p.standardOutput = outPipe; p.standardError = errPipe
                    var outData = Data(), errData = Data()
                    let lock = NSLock()
                    outPipe.fileHandleForReading.readabilityHandler = { h in
                        let d = h.availableData
                        guard !d.isEmpty else { return }
                        lock.lock(); outData.append(d); lock.unlock()
                        if let s = String(data: d, encoding: .utf8), let stream {
                            s.split(whereSeparator: \.isNewline).forEach { stream(String($0)) }
                        }
                    }
                    errPipe.fileHandleForReading.readabilityHandler = { h in
                        let d = h.availableData
                        guard !d.isEmpty else { return }
                        lock.lock(); errData.append(d); lock.unlock()
                        if let s = String(data: d, encoding: .utf8), let stream {
                            s.split(whereSeparator: \.isNewline).forEach { stream(String($0)) }
                        }
                    }
                    try p.run()
                    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                    p.waitUntilExit()
                    killer.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    lock.lock()
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    lock.unlock()
                    cont.resume(returning: RunResult(code: p.terminationStatus, out: out, err: err))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func runSync(_ exe: String, _ args: [String]) throws -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        try p.run(); p.waitUntilExit()
        return RunResult(code: p.terminationStatus,
                         out: String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                         err: String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    /// 1.2s 440Hz 正弦 WAV（16k mono s16le）——「测试连接」合成音频，镜像 ProviderProbe 做法。
    static func synthWAV(seconds: Double) -> Data {
        let sr = 16000, n = Int(Double(sr) * seconds)
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let v = Int16(8000 * sin(2 * .pi * 440 * Double(i) / Double(sr)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
