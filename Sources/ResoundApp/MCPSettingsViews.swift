import SwiftUI
import ResoundCore

// MARK: - 设置 › 外部 MCP 接入（模块 A）

struct MCPSourcesContent: View {
    @EnvironmentObject var mcp: MCPModel
    @Environment(\.palette) var pal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("外部 MCP 接入").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
                Text("通过 MCP 把 Notion、Jira / Confluence、Google Workspace、Figma 等平台连接进来。连接后，你可以把这些平台里的文档关联到某场录音，Resound 会取回内容并纳入检索、问答与纪要。")
                    .font(.system(size: 13)).foregroundStyle(pal.text2).lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
            }

            sectionDivider("已连接的来源 · \(mcp.connectedCount)").padding(.top, 24)

            VStack(spacing: 11) {
                ForEach(mcp.sources) { s in sourceCard(s) }
            }
            .padding(.top, 14)

            addSourceTile.padding(.top, 13)
        }
    }

    private func sourceCard(_ s: MCPSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                SourceIcon(kind: s.kind, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Text(s.name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(pal.text)
                        statusPill(s.status)
                        if !s.builtin {
                            Text("自定义").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.text3)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(pal.inset, in: RoundedRectangle(cornerRadius: 6))
                        }
                        if s.transport == .local {
                            Text("stdio").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.doc)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(pal.docSoft, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Text(s.transport == .local ? localCmdString(s) : (s.url ?? ""))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text2).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            switch s.status {
            case .connected: connectedFooter(s)
            case .expired: expiredBanner(s)
            case .disconnected: disconnectedFooter(s)
            }
        }
        .padding(15)
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous)).stroke(pal.border, corner: 13)
    }

    private func connectedFooter(_ s: MCPSource) -> some View {
        HStack(spacing: 12) {
            if let a = s.account { Text(a).font(.system(size: 12)).foregroundStyle(pal.text2) }
            if s.transport == .local { Text("本地子进程").font(.system(size: 12)).foregroundStyle(pal.text2) }
            Spacer(minLength: 0)
            if let ls = s.lastSync { Text("已同步 · \(ls)").font(.system(size: 11.5)).foregroundStyle(pal.text3) }
            if s.transport == .remote {
                pillButton("同步", icon: "arrow.triangle.2.circlepath", filled: false) { mcp.syncSource(s) }
            }
            Button { mcp.disconnect(s) } label: {
                Text(s.transport == .local ? "移除" : "断开").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text2)
                    .padding(.horizontal, 11).frame(height: 30)
            }.buttonStyle(.plainHit).hoverCursor()
        }
        .padding(.top, 13).overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1).padding(.top, 6.5) }
    }

    private func expiredBanner(_ s: MCPSource) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 16)).foregroundStyle(pal.warn)
            Text("授权已过期，无法再取回新内容。重新授权以恢复同步。")
                .font(.system(size: 12.5)).foregroundStyle(pal.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { mcp.connect(s) } label: {
                Text("重新授权").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32).background(pal.warn, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }.buttonStyle(.plainHit).hoverCursor()
        }
        .padding(11).background(pal.warnSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.warnBorder, corner: 10)
        .padding(.top, 13)
    }

    private func disconnectedFooter(_ s: MCPSource) -> some View {
        HStack(spacing: 12) {
            Text(s.scope ?? "").font(.system(size: 12)).foregroundStyle(pal.text2)
            Spacer(minLength: 0)
            Button { mcp.connect(s) } label: {
                HStack(spacing: 6) { Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .semibold)); Text("连接").font(.system(size: 12.5, weight: .semibold)) }
                    .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 32)
                    .background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }.buttonStyle(.plainHit).hoverCursor()
        }
        .padding(.top, 13).overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1).padding(.top, 6.5) }
    }

    private var addSourceTile: some View {
        Button { mcp.openAddSource() } label: {
            HStack(spacing: 12) {
                ZStack { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.accentSoft)
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(pal.accent) }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加自定义来源").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                    Text("连接任意兼容 MCP 的服务器 —— 填写地址，按需提供客户端标识。").font(.system(size: 12)).foregroundStyle(pal.text2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(pal.borderStrong))
        }.buttonStyle(.plainHit).hoverCursor()
    }

    @ViewBuilder private func statusPill(_ st: MCPSourceStatus) -> some View {
        let (label, color): (String, Color) = {
            switch st {
            case .connected: return ("已连接", pal.ok)
            case .expired: return ("已过期", pal.warn)
            case .disconnected: return ("未连接", pal.text3)
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 2.5).background(color.opacity(0.12), in: Capsule())
    }

    private func localCmdString(_ s: MCPSource) -> String {
        ([s.command ?? ""] + (s.args ?? [])).joined(separator: " ")
    }

    private func sectionDivider(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(pal.text3)
            Rectangle().fill(pal.border).frame(height: 1)
        }
    }

    private func pillButton(_ label: String, icon: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 12, weight: .semibold)); Text(label).font(.system(size: 12, weight: .semibold)) }
                .foregroundStyle(filled ? .white : pal.text).padding(.horizontal, 11).frame(height: 30)
                .background(filled ? pal.accent : pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .stroke(filled ? .clear : pal.borderStrong, corner: 8)
        }.buttonStyle(.plainHit).hoverCursor()
    }
}

// MARK: - 设置 › Resound MCP（模块 B）

struct MCPDeveloperContent: View {
    @EnvironmentObject var mcp: MCPModel
    @Environment(\.palette) var pal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Resound MCP").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
                Text("把你的会议知识库作为 MCP 服务器提供给外部 AI 编码助手。开启后，Claude Code、Codex 等助手就能查询你的会议与文档内容 —— 全程在本机进行。")
                    .font(.system(size: 13)).foregroundStyle(pal.text2).lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
            }

            serviceCard.padding(.top, 20)

            sectionDivider("安装到编码助手").padding(.top, 26)
            VStack(spacing: 10) { ForEach(MCPClientKind.allCases, id: \.self) { clientRow($0) } }.padding(.top, 14)

            manualInstall.padding(.top, 14)

            sectionDivider("提供给助手的内容").padding(.top, 26)
            Text("当助手查询到的是「外部 MCP 接入」来源的文档时，决定 Resound 给出多少内容。会议转录始终以完整内容提供。")
                .font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.top, 9)
            VStack(spacing: 9) { ForEach(MCPContentPolicy.allCases, id: \.self) { policyRow($0) } }.padding(.top, 13)
        }
    }

    private var serviceCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                ZStack { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(pal.accentSoft)
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(pal.accent) }.frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resound 知识库 MCP 服务").font(.system(size: 14.5, weight: .bold)).foregroundStyle(pal.text)
                    HStack(spacing: 7) {
                        Circle().fill(mcp.serverEnabled ? pal.ok : pal.text3).frame(width: 7, height: 7)
                        Text(mcp.serverEnabled ? "运行中 · stdio" : "已停止").font(.system(size: 12.5)).foregroundStyle(pal.text2)
                    }
                }
                Spacer(minLength: 0)
                SwitchToggle(on: Binding(get: { mcp.serverEnabled }, set: { mcp.toggleServer($0) }), pal: pal)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            if mcp.serverEnabled {
                HStack(spacing: 10) {
                    Text("本地端点").font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(pal.text3)
                    Text("stdio · \(mcp.serverCommand)").font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 11).background(pal.inset)
                .overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1) }
            }
        }
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).stroke(pal.border, corner: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func clientRow(_ kind: MCPClientKind) -> some View {
        let detected = mcp.clientDetected[kind] ?? false
        let installed = mcp.clientInstalled[kind] ?? false
        let installing = mcp.installing == kind
        return HStack(spacing: 12) {
            ZStack { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.inset).stroke(pal.border, corner: 9)
                Image(systemName: "terminal").font(.system(size: 15)).foregroundStyle(pal.text2) }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                Text(!detected ? "未在本机检测到 · 用下方命令手动安装" : (installed ? "已连接到 Resound 知识库" : "已检测到 · 未安装"))
                    .font(.system(size: 11.5)).foregroundStyle(!detected ? pal.text3 : (installed ? pal.ok : pal.text2))
            }
            Spacer(minLength: 0)
            if installing {
                HStack(spacing: 7) { Spinner(size: 13, color: pal.accent); Text("安装中…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text2) }
            } else if installed {
                HStack(spacing: 6) { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)); Text("已安装").font(.system(size: 12.5, weight: .semibold)) }
                    .foregroundStyle(pal.ok).padding(.horizontal, 13).frame(height: 32).background(pal.ok.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Button { mcp.uninstall(kind) } label: { Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(pal.text3).frame(width: 32, height: 32) }.buttonStyle(.plainHit).hoverCursor()
            } else if detected {
                Button { mcp.install(kind) } label: {
                    HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 12, weight: .bold)); Text("一键安装").font(.system(size: 12.5, weight: .semibold)) }
                        .foregroundStyle(.white).padding(.horizontal, 15).frame(height: 32).background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }.buttonStyle(.plainHit).hoverCursor()
            } else {
                Text("未检测到").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text3)
                    .padding(.horizontal, 13).frame(height: 32).background(pal.inset, in: RoundedRectangle(cornerRadius: 8)).stroke(pal.border, corner: 8)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .background(detected ? pal.elev : pal.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).stroke(pal.border, corner: 12)
        .opacity(detected ? 1 : 0.75)
    }

    @ViewBuilder private var manualInstall: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { mcp.manualOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(mcp.manualOpen ? 0 : -90))
                    Text("手动安装命令").font(.system(size: 12.5, weight: .semibold))
                }.foregroundStyle(pal.text2).contentShape(Rectangle())
            }.buttonStyle(.plainHit).hoverCursor()
            if mcp.manualOpen {
                VStack(spacing: 11) { ForEach(MCPClientKind.allCases, id: \.self) { manualCmdRow($0) } }.padding(.top, 11)
            }
        }
    }

    private func manualCmdRow(_ kind: MCPClientKind) -> some View {
        let cmd = mcp.manualCommand(kind)
        return VStack(alignment: .leading, spacing: 6) {
            Text(kind.displayName).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.text2)
            HStack(spacing: 0) {
                Text(cmd).font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 13).frame(maxWidth: .infinity, alignment: .leading)
                Button { mcp.copyCommand(cmd) } label: { Image(systemName: "doc.on.doc").font(.system(size: 14)).foregroundStyle(pal.text2).frame(width: 42, height: 42).background(pal.elev) }
                    .buttonStyle(.plainHit).hoverCursor().overlay(alignment: .leading) { Rectangle().fill(pal.border).frame(width: 1) }
            }
            .background(pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.border, corner: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func policyRow(_ p: MCPContentPolicy) -> some View {
        let active = mcp.contentPolicy == p
        let (title, desc): (String, String) = {
            switch p {
            case .full: return ("完整内容", "把缓存的外部文档正文完整提供给助手。上下文最丰富。")
            case .summary: return ("摘要片段 + 链接", "只给与查询相关的片段和摘要，并附上原文链接。在隐私与实用之间平衡。")
            case .link: return ("仅链接", "只给文档标题与可跳转的链接，不外传正文。最保守。")
            }
        }()
        return Button { mcp.setContentPolicy(p) } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(active ? pal.accent : pal.borderStrong, lineWidth: 2).frame(width: 18, height: 18)
                    if active { Circle().fill(pal.accent).frame(width: 18, height: 18); Circle().fill(.white).frame(width: 8, height: 8) }
                }.padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                    Text(desc).font(.system(size: 12)).foregroundStyle(pal.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15).padding(.vertical, 13).contentShape(Rectangle())
            .background(active ? pal.accentSoft : pal.elev, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .stroke(active ? pal.accent : pal.border, corner: 12)
        }.buttonStyle(.plainHit).hoverCursor()
    }

    private func sectionDivider(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(pal.text3)
            Rectangle().fill(pal.border).frame(height: 1)
        }
    }
}
