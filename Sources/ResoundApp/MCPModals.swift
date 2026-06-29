import SwiftUI
import ResoundCore

/// MCP 三个模态：OAuth 连接 / 添加自定义来源 / 粘贴链接关联。挂在 OverlayHost 顶层。
struct MCPModalsHost: View {
    @EnvironmentObject var mcp: MCPModel
    @Environment(\.palette) var pal

    var body: some View {
        ZStack {
            if mcp.connecting != nil { connectingModal }
            if mcp.credsEntry != nil { credsModal }
            if mcp.addSource != nil { addSourceModal }
            if mcp.linkFlow != nil { linkModal }
        }
    }

    // MARK: 手动凭证（Google：Cloud Console 的 client_id + client_secret）

    private var credsValid: Bool {
        guard let e = mcp.credsEntry else { return false }
        return !e.clientId.trimmingCharacters(in: .whitespaces).isEmpty
            && !e.clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder private var credsModal: some View {
        if let e = mcp.credsEntry {
            ModalScrim(pal: pal, onClose: { mcp.cancelCreds() }) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        SourceIcon(kind: e.kind, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("连接 \(e.name)").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                            Text("Google 不支持自动注册，需要你自己的 OAuth 凭证").font(.system(size: 12)).foregroundStyle(pal.text2)
                        }
                        Spacer(minLength: 0)
                    }

                    infoBox(icon: "info.circle",
                            "在 Google Cloud Console 里：① 加入 Workspace Developer Preview；② 启用 Google Drive API 与 Drive MCP API；③ 在「凭据」新建 OAuth 客户端，类型选「桌面应用 / Desktop」；④ 把它的 Client ID 和 Client Secret 填到下面。")
                        .padding(.top, 16)

                    Button { mcp.openExternal("https://console.cloud.google.com/apis/credentials") } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                            Text("打开 Google Cloud Console 凭据页").font(.system(size: 12.5, weight: .semibold))
                        }.foregroundStyle(pal.accent)
                    }.buttonStyle(.plainHit).hoverCursor().padding(.top, 10)

                    fieldLabel("Client ID").padding(.top, 16)
                    field("xxxxxx.apps.googleusercontent.com", text: credsBind(\.clientId), mono: true).padding(.top, 6)

                    fieldLabel("Client Secret").padding(.top, 14)
                    secureField("GOCSPX-…", text: credsBind(\.clientSecret)).padding(.top, 6)

                    infoBox(icon: "lock.shield", "Client Secret 只保存在本机 Keychain，不进 vault、不上传。点「连接」会在浏览器打开 Google 授权页。")
                        .padding(.top, 12)

                    HStack(spacing: 9) {
                        Spacer()
                        secondaryBtn("取消") { mcp.cancelCreds() }
                        Button { mcp.submitCreds() } label: {
                            Text("连接").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 34)
                                .background(credsValid ? pal.accent : pal.accent.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }.buttonStyle(.plainHit).hoverCursor().disabled(!credsValid)
                    }.padding(.top, 22)
                }
                .frame(width: 480)
            }
        }
    }

    private func credsBind(_ kp: WritableKeyPath<MCPModel.CredsEntry, String>) -> Binding<String> {
        Binding(get: { mcp.credsEntry?[keyPath: kp] ?? "" }, set: { mcp.credsEntry?[keyPath: kp] = $0 })
    }

    // MARK: OAuth 连接

    @ViewBuilder private var connectingModal: some View {
        if let c = mcp.connecting {
            ZStack {
                Color.black.opacity(0.32).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        SourceIcon(kind: c.kind, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("连接 \(c.name)").font(.system(size: 15.5, weight: .bold)).foregroundStyle(pal.text)
                            Text("OAuth 授权 · 在浏览器中登录后返回").font(.system(size: 12)).foregroundStyle(pal.text2)
                        }
                        Spacer(minLength: 0)
                    }
                    switch c.phase {
                    case .redirect, .waiting:
                        VStack(spacing: 14) {
                            Spinner(size: 26, color: pal.accent)
                            Text(c.phase == .redirect ? "正在打开浏览器…" : "等待浏览器授权返回…")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(pal.text)
                            Text("在弹出的窗口中登录并授权 \(c.name)，完成后会自动返回这里。")
                                .font(.system(size: 12.5)).foregroundStyle(pal.text2).multilineTextAlignment(.center).lineSpacing(2).frame(maxWidth: 300)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.top, 8)
                        HStack { Spacer(); secondaryBtn("取消") { mcp.cancelConnecting() } }
                    case .done:
                        VStack(spacing: 13) {
                            ZStack { Circle().fill(pal.ok.opacity(0.14)).frame(width: 52, height: 52)
                                Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(pal.ok) }
                            Text("已连接到 \(c.name)").font(.system(size: 15, weight: .bold)).foregroundStyle(pal.text)
                            Text("现在可以把这个来源里的文档关联到录音了。Resound 会取回内容并纳入检索。")
                                .font(.system(size: 12.5)).foregroundStyle(pal.text2).multilineTextAlignment(.center).lineSpacing(2).frame(maxWidth: 300)
                            primaryBtn("完成") { mcp.connecting = nil }.padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16).padding(.top, 8)
                    }
                }
                .padding(24).frame(width: 430)
                .background(pal.elev, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).stroke(pal.borderStrong, corner: 16)
            }
        }
    }

    // MARK: 添加自定义来源

    @ViewBuilder private var addSourceModal: some View {
        if let a = mcp.addSource {
            ModalScrim(pal: pal, onClose: { mcp.cancelAddSource() }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("添加自定义来源").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    Text("连接任意兼容 MCP 的服务器。Resound 会通过它取回并缓存文档内容。")
                        .font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(1.5).padding(.top, 5)

                    fieldLabel("名称").padding(.top, 18)
                    field("例如 内部 Wiki", text: bind(\.name)).padding(.top, 6)

                    fieldLabel("连接方式").padding(.top, 14)
                    segmented(["远程 · HTTP", "本地 · stdio 命令"], selected: a.transport == .remote ? 0 : 1) { i in
                        mcp.addSource?.transport = (i == 0) ? .remote : .local
                    }.padding(.top, 6)

                    if a.transport == .remote { remoteFields(a) } else { localFields(a) }

                    HStack(spacing: 9) {
                        Spacer()
                        secondaryBtn("取消") { mcp.cancelAddSource() }
                        Button { mcp.submitAddSource() } label: {
                            Text(submitLabel(a)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 34)
                                .background(mcp.addSourceValid ? pal.accent : pal.accent.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }.buttonStyle(.plainHit).hoverCursor().disabled(!mcp.addSourceValid)
                    }.padding(.top, 22)
                }
                .frame(width: 480)
            }
        }
    }

    private func submitLabel(_ a: MCPModel.AddSourceState) -> String {
        if a.transport == .local { return "添加来源" }
        return a.auth == .oauth ? "连接" : "添加来源"
    }

    @ViewBuilder private func remoteFields(_ a: MCPModel.AddSourceState) -> some View {
        fieldLabel("MCP 服务器地址").padding(.top, 14)
        field("https://mcp.example.com/mcp", text: bind(\.url), mono: true).padding(.top, 6)

        fieldLabel("认证方式").padding(.top, 14)
        segmented(["OAuth 授权", "API Token"], selected: a.auth == .oauth ? 0 : 1, width: 240) { i in
            mcp.addSource?.auth = (i == 0) ? .oauth : .token
        }.padding(.top, 6)

        if a.auth == .oauth {
            HStack(spacing: 9) {
                CheckBox(on: bind(\.needsClientId), pal: pal)
                Text("该服务器不支持自动注册，需要手动填写客户端标识").font(.system(size: 12.5)).foregroundStyle(pal.text)
            }.padding(.top, 12)
            if a.needsClientId {
                field("客户端标识 / Client ID", text: bind(\.clientId), mono: true).padding(.top, 8)
            }
            infoBox(icon: "info.circle", "点「连接」会在浏览器中打开该服务器的登录授权页，完成后返回 Resound。").padding(.top, 12)
        } else {
            fieldLabel("API Token").padding(.top, 14)
            secureField("粘贴访问令牌", text: bind(\.token)).padding(.top, 6)
        }
    }

    @ViewBuilder private func localFields(_ a: MCPModel.AddSourceState) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) { fieldLabel("命令"); field("npx", text: bind(\.command), mono: true) }.frame(width: 130)
            VStack(alignment: .leading, spacing: 6) { fieldLabel("参数"); field("-y @org/mcp-server", text: bind(\.args), mono: true) }
        }.padding(.top, 14)

        fieldLabel("环境变量 · 可选").padding(.top, 14)
        if !a.env.isEmpty {
            VStack(spacing: 7) {
                ForEach(a.env) { e in
                    HStack(spacing: 7) {
                        Text("\(e.key)=\(e.value)").font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).frame(height: 32)
                            .background(pal.inset, in: RoundedRectangle(cornerRadius: 8)).stroke(pal.border, corner: 8)
                        Button { mcp.removeEnvVar(e.id) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.text3).frame(width: 30, height: 30) }.buttonStyle(.plainHit).hoverCursor()
                    }
                }
            }.padding(.top, 6)
        }
        HStack(spacing: 7) {
            field("KEY", text: bind(\.envK), mono: true).frame(width: 130)
            Text("=").foregroundStyle(pal.text3)
            field("value", text: bind(\.envV), mono: true)
            secondaryBtn("添加") { mcp.addEnvVar() }
        }.padding(.top, 7)
        infoBox(icon: "terminal", "本地服务器会作为子进程在这台 Mac 上启动 —— 例如 npx -y @notionhq/notion-mcp-server。命令与环境变量都只保存在本机。").padding(.top, 12)
    }

    // MARK: 粘贴链接

    @ViewBuilder private var linkModal: some View {
        if let lf = mcp.linkFlow {
            ModalScrim(pal: pal, onClose: { mcp.cancelLink() }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("关联外部文档").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    (Text("粘贴 Notion / Jira / Confluence / Google Drive 等文档的链接，关联到「").foregroundStyle(pal.text2)
                        + Text(lf.recTitle).foregroundStyle(pal.text).fontWeight(.semibold) + Text("」。").foregroundStyle(pal.text2))
                        .font(.system(size: 12.5)).lineSpacing(1.5).padding(.top, 5)

                    HStack(spacing: 9) {
                        Image(systemName: "link").font(.system(size: 14)).foregroundStyle(pal.text3)
                        TextField("粘贴文档链接…", text: Binding(get: { mcp.linkFlow?.url ?? "" }, set: { mcp.linkFlow?.url = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(pal.text)
                            .onSubmit { mcp.resolveLink() }
                        Button { mcp.resolveLink() } label: {
                            Text("关联").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).frame(height: 32).background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }.buttonStyle(.plainHit).hoverCursor()
                    }
                    .padding(.leading, 13).padding(.trailing, 5).padding(.vertical, 5)
                    .background(pal.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous)).stroke(pal.borderStrong, corner: 11)
                    .padding(.top, 16)

                    linkBody(lf)
                }
                .frame(width: 500)
            }
        }
    }

    @ViewBuilder private func linkBody(_ lf: MCPModel.LinkFlow) -> some View {
        switch lf.phase {
        case .input:
            EmptyView()
        case .resolving:
            VStack(spacing: 14) { Spinner(size: 26, color: pal.accent); Text("正在识别来源并取回内容…").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text) }
                .frame(maxWidth: .infinity).padding(.vertical, 22).card(pal, corner: 12).padding(.top, 16)
        case .importing:
            VStack(spacing: 14) { Spinner(size: 26, color: pal.accent); Text("正在入库并建立索引…").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                Text("取回的正文正在切块、向量化写入知识库，稍候。").font(.system(size: 12)).foregroundStyle(pal.text2) }
                .frame(maxWidth: .infinity).padding(.vertical, 22).card(pal, corner: 12).padding(.top, 16)
        case .resolved:
            if let r = lf.result {
                resultCard(r, note: lf.importError.map { "入库失败：\($0)" } ?? "内容已取回并缓存，可被搜索、问答与纪要引用。",
                           noteColor: lf.importError == nil ? pal.ok : pal.rec)
                HStack(spacing: 9) { Spacer()
                    secondaryBtn("取消") { mcp.cancelLink() }
                    primaryBtn(lf.importError == nil ? "关联到本场录音" : "重试") { mcp.confirmLink() }
                }.padding(.top, 18)
            }
        case .unconnected:
            if let r = lf.result {
                warnCard(title: "这个链接来自 \(r.sourceName)，但还没连接",
                         desc: "连接 \(r.sourceName) 后，Resound 才能取回正文并纳入检索；否则只能作为「仅链接」保存。", r: r)
                HStack(spacing: 9) {
                    Button { mcp.saveLinkOnly() } label: { Text("仍以仅链接保存").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text2) }.buttonStyle(.plainHit).hoverCursor()
                    Spacer()
                    secondaryBtn("取消") { mcp.cancelLink() }
                    primaryBtn("去连接 \(r.sourceName)") { mcp.connectThenLink() }
                }.padding(.top, 18)
            }
        case .unknown:
            unknownCard()
            HStack(spacing: 9) { Spacer()
                secondaryBtn("取消") { mcp.cancelLink() }
                primaryBtn("以仅链接保存") { mcp.saveLinkOnly() }
            }.padding(.top, 18)
        case .noperm:
            if let r = lf.result {
                warnCard(title: "无权访问这条内容",
                         desc: "你的 \(r.sourceName) 账号没有这篇文档的访问权限。请向文档所有者申请权限，或换一个有权访问的账号重新授权。", r: r)
                HStack(spacing: 9) {
                    Button { mcp.saveLinkOnly() } label: { Text("以仅链接保存").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text2) }.buttonStyle(.plainHit).hoverCursor()
                    Spacer()
                    secondaryBtn("关闭") { mcp.cancelLink() }
                    primaryBtn("重试") { mcp.resolveLink() }
                }.padding(.top, 18)
            }
        }
    }

    private func resultCard(_ r: MCPModel.LinkResultView, note: String, noteColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SourceIcon(kind: r.kind, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(r.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                        formBadge(imported: r.imported)
                    }
                    Text("\(r.sourceName) · \(r.url)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.text2).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(noteColor)
                Text(note).font(.system(size: 11.5)).foregroundStyle(pal.text2).lineSpacing(1.5)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).background(pal.inset, in: RoundedRectangle(cornerRadius: 9)).padding(.top, 12)
        }
        .padding(15).card(pal, corner: 12).padding(.top, 16)
    }

    private func warnCard(title: String, desc: String, r: MCPModel.LinkResultView) -> some View {
        HStack(alignment: .top, spacing: 11) {
            SourceIcon(kind: r.kind, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(pal.text)
                Text(desc).font(.system(size: 12)).foregroundStyle(pal.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15).background(pal.warnSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).stroke(pal.warnBorder, corner: 12).padding(.top, 16)
    }

    private func unknownCard() -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(pal.inset).stroke(pal.border, corner: 10)
                Image(systemName: "questionmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(pal.text3) }.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("无法识别来源，或地址无法访问").font(.system(size: 13.5, weight: .bold)).foregroundStyle(pal.text)
                Text("这可能是不受支持的平台，或是内网 / 本机地址，Resound 取不到正文。仍可作为「仅链接」保存，随时可点击跳转。")
                    .font(.system(size: 12)).foregroundStyle(pal.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15).card(pal, corner: 12).padding(.top, 16)
    }

    // MARK: 复用件

    private func bind(_ kp: WritableKeyPath<MCPModel.AddSourceState, String>) -> Binding<String> {
        Binding(get: { mcp.addSource?[keyPath: kp] ?? "" }, set: { mcp.addSource?[keyPath: kp] = $0 })
    }
    private func bind(_ kp: WritableKeyPath<MCPModel.AddSourceState, Bool>) -> Binding<Bool> {
        Binding(get: { mcp.addSource?[keyPath: kp] ?? false }, set: { mcp.addSource?[keyPath: kp] = $0 })
    }

    private func field(_ placeholder: String, text: Binding<String>, mono: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13.5, design: mono ? .monospaced : .default)).foregroundStyle(pal.text)
            .padding(.horizontal, 12).frame(height: 38).background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
    }
    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(pal.text)
            .padding(.horizontal, 12).frame(height: 38).background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
    }
    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(pal.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func segmented(_ labels: [String], selected: Int, width: CGFloat? = nil, _ pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                let on = i == selected
                Button { pick(i) } label: {
                    Text(l).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(on ? pal.text : pal.text2)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(on ? pal.elev : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }.buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(3).background(pal.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(width: width)
    }
    private func infoBox(icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(pal.text3)
            Text(text).font(.system(size: 11.5)).foregroundStyle(pal.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13).padding(.vertical, 11).background(pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func formBadge(imported: Bool) -> some View {
        Text(imported ? "已导入" : "仅链接").font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(imported ? pal.doc : pal.text3)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(imported ? pal.docSoft : pal.inset, in: RoundedRectangle(cornerRadius: 6))
    }
    private func primaryBtn(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 16).frame(height: 34).background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous)) }.buttonStyle(.plainHit).hoverCursor()
    }
    private func secondaryBtn(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text).padding(.horizontal, 16).frame(height: 34).background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9) }.buttonStyle(.plainHit).hoverCursor()
    }
}
