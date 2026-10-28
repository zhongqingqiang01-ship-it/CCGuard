import SwiftUI
import AppKit
import CCGuardCore
import ApplicationServices
import Darwin

struct Dashboard:View {
    @ObservedObject var model:Controller
    let titles=["连接 Shadowrocket","核验纽约时区","检测网络环境","打开 Claude Code"]
    let captions=["指定节点 · 配置路由","读取系统实际状态","评分 > 90 · 必要项全部通过","四步通过后开启持续守护"]
    let symbols=["network","globe.americas","checkmark.shield","rectangle.and.text.magnifyingglass"]
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:7) {
                    Text("CC 登录器").font(.system(size:28,weight:.semibold))
                    Text("检查环境，再开始工作。").font(.system(size:14)).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.phaseTitle,systemImage:model.phase == .guarding ? "shield.checkered" : "shield")
                    .font(.system(size:12,weight:.medium)).padding(.horizontal,12).padding(.vertical,7)
                    .background((model.phase == .guarding ? Color.green : model.phase == .blocked ? .red : .gray).opacity(0.15),in:Capsule())
            }
            HStack(spacing:0) {
                metric("当前出口",model.ip)
                Divider().frame(height:34).padding(.horizontal,24)
                metric("启动评分",model.score)
                Divider().frame(height:34).padding(.horizontal,24)
                metric("最近通过",model.lastCheck)
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
            VStack(spacing:0) {
                ForEach(Array(FlowStep.allCases.enumerated()),id:\.offset) { index,step in
                    HStack(spacing:14) {
                        ZStack {
                            RoundedRectangle(cornerRadius:10).fill(model.completed.contains(step) ? Color.green.opacity(0.16) : model.activeStep == step ? Color.orange.opacity(0.16) : Color.white.opacity(0.05))
                            if model.activeStep == step { ProgressView().controlSize(.small) }
                            else { Image(systemName:model.completed.contains(step) ? "checkmark" : symbols[index]).foregroundStyle(model.completed.contains(step) ? .green : .secondary) }
                        }.frame(width:42,height:42)
                        VStack(alignment:.leading,spacing:4) {
                            Text(titles[index]).font(.system(size:14,weight:.medium))
                            Text(captions[index]).font(.system(size:12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.completed.contains(step) ? "已通过" : model.activeStep == step ? "进行中" : "等待")
                            .font(.system(size:12)).foregroundStyle(model.completed.contains(step) ? .green : .secondary)
                    }.padding(.vertical,11)
                    if index<3 { Divider().padding(.leading,56) }
                }
            }
            if let failure=model.failure {
                Label(failure,systemImage:"exclamationmark.circle.fill").font(.system(size:12)).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    .padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.red.opacity(0.07),in:RoundedRectangle(cornerRadius:9))
            } else { Text(model.status).font(.system(size:12)).foregroundStyle(.secondary).frame(minHeight:24,alignment:.leading) }
            if let notice=model.serviceNotice {
                Label(notice,systemImage:"exclamationmark.triangle").font(.system(size:11)).foregroundStyle(.orange)
                    .lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
            }
            if let notice=model.runtimeNotice {
                Label(notice,systemImage:"arrow.clockwise").font(.system(size:11)).foregroundStyle(.orange)
                    .lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack(spacing:12) {
                Button { model.start() } label: { Label(model.phase == .blocked ? "重新检查并启动" : "检查并启动",systemImage:"play.fill").frame(minWidth:140) }
                    .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large).disabled(model.isActive || model.busy)
                if model.isActive { Button("结束使用") { Task { await model.stop() } }.controlSize(.large) }
                Spacer()
                Button { model.toggleMonitor() } label:{Image(systemName:"circle.dotted")}.help(model.monitorVisible ? "隐藏监控浮窗" : "显示监控浮窗")
                Button { model.settingsVisible=true } label:{Image(systemName:"slider.horizontal.3")}.help("设置")
                Button { model.showHistory() } label:{Image(systemName:"clock.arrow.circlepath")}.help("报错历史")
            }
            Text("主窗口关闭后继续守护。直接手动打开 VS Code 不会启动本工具。")
                .font(.system(size:11)).foregroundStyle(.tertiary)
        }.padding(30).frame(width:680).background(Color(nsColor:.windowBackgroundColor))
            .sheet(isPresented:$model.settingsVisible) { SettingsView(model:model) }
    }
    func metric(_ title:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:11)).foregroundStyle(.secondary)
            Text(value).font(.system(size:15,weight:.medium,design:.monospaced)).lineLimit(1)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct SettingsView:View {
    @ObservedObject var model:Controller
    @State var saveError:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("启动设置").font(.title2.bold())
            Form {
                TextField("指定出口 IP",text:$model.settings.expectedIP)
                TextField("Shadowrocket 节点全名",text:$model.settings.nodeName)
                HStack {
                    TextField("工作目录",text:$model.settings.workspace)
                    Button("选择") { let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;if p.runModal() == .OK,let url=p.url { model.settings.workspace=url.path } }
                }
                TextField("时区切换 App",text:$model.settings.timezoneApp)
                Stepper("单次加载上限 \(Int(model.settings.webTimeout)) 秒（10–60 秒）",value:$model.settings.webTimeout,in:WebCheckTiming.allowedTimeout,step:5)
            }.disabled(model.isActive)
            Divider()
            Text("首次使用需要辅助功能权限，用于读取和操作 Shadowrocket，并确认 Claude Code 界面。")
                .font(.callout).foregroundStyle(.secondary)
            Label(AXIsProcessTrusted() ? "当前版本：辅助功能已授权" : "当前版本：辅助功能待授权",systemImage:AXIsProcessTrusted() ? "checkmark.circle" : "lock.shield")
                .font(.caption).foregroundStyle(AXIsProcessTrusted() ? .green : .orange)
            Button("允许辅助功能") { model.accessibilitySettings() }
            Text("评分、住宅属性和风险项仅在启动时检查。运行中后台探测，不刷新网页；确认异常立即关闭所有 VS Code，暂时取不到数据每 10 秒重试，连续 120 秒未恢复才关闭。")
                .font(.caption).foregroundStyle(.secondary)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack { Spacer();Button("完成") { do { try model.settings.save();model.settingsVisible=false } catch { saveError=error.localizedDescription } }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width:590)
    }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let model=Controller()
    var window:NSWindow!
    var item:NSStatusItem!
    var monitorPanel:NSPanel!
    var historyWindow:NSWindow?
    var monitorMenuItem:NSMenuItem!
    private var lockFD:Int32 = -1
    func applicationDidFinishLaunching(_ notification:Notification) {
        try? FileManager.default.createDirectory(at:Settings.support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        lockFD=open(Settings.support.appendingPathComponent("app.lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard lockFD>=0,flock(lockFD,LOCK_EX|LOCK_NB)==0 else { NSApp.terminate(nil);return }
        let mainMenu=NSMenu()
        let appItem=NSMenuItem();mainMenu.addItem(appItem)
        let appMenu=NSMenu(title:"CC登录器");appItem.submenu=appMenu
        appMenu.addItem(withTitle:"关于 CC登录器",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"隐藏 CC登录器",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"退出 CC登录器",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();mainMenu.addItem(editItem);let editMenu=NSMenu(title:"编辑");editItem.submenu=editMenu
        for (title,selector,key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {
            editMenu.addItem(withTitle:title,action:Selector(selector),keyEquivalent:key)
        }
        NSApp.mainMenu=mainMenu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:745),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="CC 登录器";window.isReleasedWhenClosed=false;window.delegate=self
        window.contentView=NSHostingView(rootView:Dashboard(model:model));window.appearance=NSAppearance(named:.darkAqua)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image=NSImage(systemSymbolName:"shield",accessibilityDescription:"CC 登录器")
        item.button?.title=" CC"
        let menu=NSMenu()
        menu.addItem(withTitle:"显示登录器",action:#selector(show),keyEquivalent:"").target=self
        monitorMenuItem=NSMenuItem(title:"隐藏监控浮窗",action:#selector(toggleMonitor),keyEquivalent:"")
        monitorMenuItem.target=self;menu.addItem(monitorMenuItem)
        menu.addItem(withTitle:"报错历史",action:#selector(showHistory),keyEquivalent:"").target=self
        menu.addItem(withTitle:"检查并启动",action:#selector(start),keyEquivalent:"").target=self
        menu.addItem(withTitle:"结束使用",action:#selector(stop),keyEquivalent:"").target=self
        menu.addItem(.separator())
        menu.addItem(withTitle:"退出登录器",action:#selector(quit),keyEquivalent:"").target=self
        item.menu=menu
        model.onMonitorToggle={ [weak self] in self?.toggleMonitor() }
        model.onHistory={ [weak self] in self?.showHistory() }
        monitorPanel=NSPanel(contentRect:NSRect(x:0,y:0,width:140,height:140),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        monitorPanel.title="CC 实时监控浮窗";monitorPanel.isReleasedWhenClosed=false
        monitorPanel.isOpaque=false;monitorPanel.backgroundColor = .clear;monitorPanel.hasShadow=false
        monitorPanel.level = .floating;monitorPanel.hidesOnDeactivate=false
        monitorPanel.isMovableByWindowBackground=true
        monitorPanel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        monitorPanel.contentView=NSHostingView(rootView:MonitorOrb(model:model,showMain:{ [weak self] in self?.show() }))
        let restoredMonitorFrame=monitorPanel.setFrameUsingName("CCGuard.Monitor")
        monitorPanel.setFrameAutosaveName("CCGuard.Monitor")
        if restoredMonitorFrame {
            let saved=monitorPanel.frame
            monitorPanel.setFrame(NSRect(x:saved.midX-70,y:saved.midY-70,width:140,height:140),display:false)
        } else {
            let screen=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:800)
            monitorPanel.setFrameOrigin(NSPoint(x:screen.maxX-164,y:screen.maxY-164))
        }
        monitorPanel.delegate=self
        model.monitorVisible=UserDefaults.standard.object(forKey:"monitorVisible") as? Bool ?? true
        updateMonitorVisibility()
        model.onBackground={ [weak self] in
            guard let self,self.model.phase == .guarding else { return }
            self.window.miniaturize(nil)
        }
        model.onStateChange={ [weak self] in
            guard let self else{return}
            self.item.button?.image=NSImage(systemSymbolName:self.model.phase == .guarding ? "checkmark.shield.fill" : self.model.phase == .blocked ? "exclamationmark.shield.fill" : "shield",accessibilityDescription:"CC 登录器")
        }
    }
    @objc func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func start() { show();model.start() }
    @objc func toggleMonitor() {
        model.monitorVisible.toggle();UserDefaults.standard.set(model.monitorVisible,forKey:"monitorVisible")
        updateMonitorVisibility()
    }
    private func updateMonitorVisibility() {
        if model.monitorVisible { monitorPanel.orderFrontRegardless() } else { monitorPanel.orderOut(nil) }
        monitorMenuItem.title=model.monitorVisible ? "隐藏监控浮窗" : "显示监控浮窗"
    }
    @objc func showHistory() {
        model.reloadHistory()
        if historyWindow==nil {
            let history=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:560),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            history.title="CC 登录器 · 报错历史";history.isReleasedWhenClosed=false
            history.contentView=NSHostingView(rootView:ErrorHistoryView(model:model))
            history.appearance=NSAppearance(named:.darkAqua);history.center();historyWindow=history
        }
        if historyWindow?.isMiniaturized==true { historyWindow?.deminiaturize(nil) }
        historyWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func windowDidMove(_ notification:Notification) {
        if let moved=notification.object as? NSWindow,moved === monitorPanel { moved.saveFrame(usingName:"CCGuard.Monitor") }
    }
    @objc func stop() { Task { await model.stop() } }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if model.isActive || model.busy {
            Task { await model.stop();NSApp.reply(toApplicationShouldTerminate:model.phase == .idle) }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { show();return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
}
@main enum Main {
    @MainActor static func main() {
        let args=CommandLine.arguments
        if args.count==5 && args[1]=="--watchdog",let pid=Int32(args[2]) { runWatchdog(parentPID:pid,directory:URL(fileURLWithPath:args[3]),nonce:args[4]) }
        // Integration fixture mode is restricted to the deliberately named disposable app.
        if args.count==6 && args[1]=="--watchdog-fixture",let pid=Int32(args[2]),args[5].hasSuffix("/CCGuardFixture.app"),args[5].contains("/IntegrationFixtures/") {
            runWatchdog(parentPID:pid,directory:URL(fileURLWithPath:args[3]),nonce:args[4],fixtureRoot:args[5])
        }
        if args.contains("--diagnose") {
            let state=SystemState.local();let data=(try? JSONEncoder().encode(state)) ?? Data();print(String(decoding:data,as:UTF8.self));exit(0)
        }
        if args.contains("--check-page") {
            Task { @MainActor in
                let browser=DetectionBrowser(root:Settings.support)
                do {
                    let started=ProcessInfo.processInfo.systemUptime
                    let snapshot=try await browser.inspect(settings:Settings.load(),progress:{ progress in
                        let message:String
                        switch progress {
                        case .loading: message="页面已导航，开始至少 10 秒加载等待"
                        case .waitingToRefresh: message="信息未齐全或不一致，10 秒后刷新一次"
                        }
                        fputs(String(format:"%.3fs ",ProcessInfo.processInfo.systemUptime-started)+message+"\n",stderr)
                    })
                    print(String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self));exit(0)
                } catch {
                    if let snapshot=browser.lastSnapshot,let data=try? JSONEncoder().encode(snapshot) { print(String(decoding:data,as:UTF8.self)) }
                    fputs(error.localizedDescription+"\n",stderr);exit(1)
                }
            }
            RunLoop.current.run();return
        }
        if args.contains("--check-background") {
            Task { @MainActor in
                let browser=DetectionBrowser(root:Settings.support)
                do {
                    let settings=Settings.load(),config=try NetworkConfiguration.read(settings:Settings.load())
                    let origin=try await browser.prepareBackgroundValidation(timeout:settings.webTimeout)
                    fputs("首次上下文加载完成\n",stderr)
                    var records:[[String:Any]]=[]
                    for _ in 0..<2 {
                        let round=UUID().uuidString
                        fputs("开始后台轮次 \(round)\n",stderr)
                        async let native=config.runtimeProbe(roundID:round,expectedIP:settings.expectedIP,stopOnMismatch:false)
                        let web=try await browser.probeInBackground(roundID:round,expectedIP:settings.expectedIP)
                        fputs("DNS/WebRTC 后台轮次完成\n",stderr)
                        var snapshot=try await native
                        fputs("后台出口与连通性请求完成\n",stderr)
                        snapshot.dnsSafe=web.dnsSafe;snapshot.webrtcSafe=web.webrtcSafe
                        snapshot.browserTimezone=web.browserTimezone;snapshot.details=web.details
                        snapshot.collectedAt=Date().timeIntervalSince1970*1000
                        let assessment=snapshot.assess(expectedIP:settings.expectedIP,expectedRound:round)
                        records.append(["snapshot":try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot)),
                                        "passed":assessment.passed,"failures":assessment.failures,"unknown":assessment.unknown])
                    }
                    let finalOrigin=try await browser.currentTimeOrigin()
                    print(String(decoding:try JSONSerialization.data(withJSONObject:["probes":records,"initialTimeOrigin":origin,"finalTimeOrigin":finalOrigin,"pageNotRefreshed":origin==finalOrigin,"vscodeStarted":false,"vscodeClosed":false],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
                    await browser.disconnect();exit(0)
                } catch { fputs(error.localizedDescription+"\n",stderr);exit(1) }
            }
            RunLoop.current.run();return
        }
        if args.contains("--integration-check") {
            Task { @MainActor in
                do {
                    let controller=Controller()
                    try controller.settings.save()
                    try await controller.prepareProxy()
                    try await controller.prepareTimezone()
                    let browser=DetectionBrowser(root:Settings.support)
                    let snapshot=try await browser.inspect(settings:controller.settings)
                    let config=try NetworkConfiguration.read(settings:controller.settings)
                    try await config.checkExit(expectedIP:controller.settings.expectedIP)
                    try SystemState.verify(SystemState.local(),settings:controller.settings)
                    let report:[String:Any]=["result":"passed","proxy":"已连接，配置路由和指定节点已核验","timezone":SystemState.timezone,"score":snapshot.score ?? -1,"ip":snapshot.claudeIP ?? "","nativeExitProbe":"一致","vscodeStarted":false,"vscodeClosed":false]
                    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self));exit(0)
                } catch { fputs(error.localizedDescription+"\n",stderr);exit(1) }
            }
            RunLoop.current.run();return
        }
        if args.contains("--acceptance-run") {
            Task { @MainActor in
                let controller=Controller()
                controller.start()
                do {
                    let deadline=ProcessInfo.processInfo.systemUptime+2*controller.settings.webTimeout+PageInspectionSchedule.refreshDelay+120
                    while controller.busy && ProcessInfo.processInfo.systemUptime<deadline {
                        try await Task.sleep(nanoseconds:250_000_000)
                    }
                    guard controller.phase == .guarding else { throw GuardFailure(controller.failure ?? "启动验收未进入守护状态") }
                    let start=ProcessInfo.processInfo.systemUptime
                    while ProcessInfo.processInfo.systemUptime-start<45 {
                        guard controller.phase == .guarding else { throw GuardFailure(controller.failure ?? "持续守护中断") }
                        try await Task.sleep(nanoseconds:500_000_000)
                    }
                    let checks=controller.logs.filter{$0.contains("周期复检通过")}.count
                    guard checks>0 else { throw GuardFailure("验收期间未完成一次周期复检") }
                    await controller.stop()
                    guard controller.phase == .idle else { throw GuardFailure(controller.failure ?? "结束使用核验失败") }
                    let report:[String:Any]=["result":"passed","fourStepsPassed":true,"guardedSeconds":45,"periodicChecks":checks,"allVSCodeProcessesExited":try Editors.selected().isEmpty,"logPath":controller.logURL.path]
                    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self));exit(0)
                } catch {
                    await controller.stop()
                    fputs(error.localizedDescription+"\n",stderr);exit(1)
                }
            }
            RunLoop.current.run();return
        }
        let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
        withExtendedLifetime(delegate) {}
    }
}
