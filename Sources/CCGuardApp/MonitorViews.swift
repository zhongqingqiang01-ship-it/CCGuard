import SwiftUI
import AppKit
import CCGuardCore

struct FrostedGlass:NSViewRepresentable {
    func makeNSView(context:Context) -> NSVisualEffectView {
        let view=NSVisualEffectView()
        view.material = .hudWindow;view.blendingMode = .behindWindow;view.state = .active
        view.appearance=NSAppearance(named:.vibrantDark)
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {}
}

private final class OrbDragSurface:NSView {
    var showMain:()->Void = {}
    var showHistory:()->Void = {}
    var hide:()->Void = {}
    override var mouseDownCanMoveWindow:Bool { true }
    override func mouseDown(with event:NSEvent) {
        if event.clickCount==2 { showMain() } else { window?.performDrag(with:event) }
    }
    override func rightMouseDown(with event:NSEvent) {
        let menu=NSMenu()
        for (title,action) in [("显示登录器",#selector(openMain)),("报错历史",#selector(openHistory)),("隐藏浮窗",#selector(hideOrb))] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc private func openMain() { showMain() }
    @objc private func openHistory() { showHistory() }
    @objc private func hideOrb() { hide() }
}
private struct OrbDragRegion:NSViewRepresentable {
    let showMain:()->Void
    let showHistory:()->Void
    let hide:()->Void
    func makeNSView(context:Context) -> OrbDragSurface { OrbDragSurface() }
    func updateNSView(_ view:OrbDragSurface,context:Context) {
        view.showMain=showMain;view.showHistory=showHistory;view.hide=hide
        view.toolTip="拖动移动 · 双击显示登录器 · 右键查看历史或隐藏"
    }
}

struct MonitorOrb:View {
    @ObservedObject var model:Controller
    let showMain:()->Void
    var body:some View {
        ZStack {
            FrostedGlass().opacity(0.30).clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.2),lineWidth:0.8))
            VStack(spacing:10) {
                Text(model.compactMonitorStatus).font(.system(size:12,weight:.semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel("检测状态："+model.compactMonitorStatus)
                Text(model.ip == "—" ? "IP 待检测" : model.ip)
                    .font(.system(size:10,weight:.medium,design:.monospaced))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel(model.ip == "—" ? "出口 IP 尚未检测" : "最近出口 IP \(model.ip)")
            }.frame(width:108).foregroundStyle(.white)
                .shadow(color:.black.opacity(0.75),radius:1.5,y:1)
            OrbDragRegion(showMain:showMain,showHistory:{ model.showHistory() },hide:{ model.toggleMonitor() })
        }.frame(width:128,height:128)
            .clipShape(Circle()).contentShape(Circle()).shadow(color:.black.opacity(0.15),radius:5,y:3).padding(6)
    }
}

struct ErrorHistoryView:View {
    @ObservedObject var model:Controller
    @State private var search=""
    @State private var filter="all"
    private var entries:[HistoryEntry] {
        model.historyItems.filter {
            (filter=="all" || $0.level.rawValue==filter) &&
            (search.isEmpty || ($0.message+" "+$0.stage+" "+$0.sessionID+" "+$0.details).localizedCaseInsensitiveContains(search))
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("报错历史").font(.title2.bold())
                    Text("跨启动保留 · 本机时间 · 新错误实时更新").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.historyLoading { ProgressView().controlSize(.small) }
                Button("刷新") { model.reloadHistory() }.disabled(model.historyLoading)
            }
            HStack {
                TextField("搜索原因、步骤或会话",text:$search).textFieldStyle(.roundedBorder)
                Picker("类型",selection:$filter) {
                    Text("全部").tag("all")
                    Text("错误").tag("error")
                    Text("提示").tag("warning")
                }.pickerStyle(.segmented).frame(width:210)
            }
            if entries.isEmpty {
                VStack(spacing:12) {
                    Image(systemName:"clock.arrow.circlepath").font(.system(size:28)).foregroundStyle(.secondary)
                    Text(model.historyLoading ? "正在读取历史记录…" : model.historyItems.isEmpty ? "暂无错误或提示" : "没有匹配的记录")
                    Text("启动失败、运行异常和服务告警会在这里保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                List(entries) { entry in
                    VStack(alignment:.leading,spacing:8) {
                        HStack(spacing:9) {
                            Text(entry.level.title).font(.caption.weight(.semibold))
                                .foregroundStyle(entry.level == .error ? .red : .orange)
                                .padding(.horizontal,7).padding(.vertical,3)
                                .background((entry.level == .error ? Color.red : Color.orange).opacity(0.1),in:Capsule())
                            Text(entry.time,format:.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button("原始日志") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:entry.sourcePath)]) }
                                .font(.caption).buttonStyle(.link)
                        }
                        Text(entry.message).font(.system(size:12)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        if !entry.details.isEmpty { Text(entry.details).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                        Text((entry.stage.isEmpty ? "" : entry.stage+" · ")+"会话 "+String(entry.sessionID.prefix(8)))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }.padding(.vertical,8)
                }.listStyle(.plain)
            }
            HStack {
                Text("共 \(model.historyItems.filter{$0.level == .error}.count) 条错误，\(model.historyItems.filter{$0.level == .warning}.count) 条提示")
                Spacer()
                if model.historyUnreadableFiles>0 { Text("\(model.historyUnreadableFiles) 份旧日志暂时无法读取").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth:620,minHeight:420)
            .background(Color(nsColor:.windowBackgroundColor)).onAppear { model.reloadHistory() }
    }
}
