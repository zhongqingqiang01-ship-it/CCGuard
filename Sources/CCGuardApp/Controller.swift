import SwiftUI
import AppKit
import Network
import ApplicationServices
import CCGuardCore

@MainActor final class Controller:ObservableObject,WorkflowDriver {
    @Published var settings=Settings.load()
    @Published var phase:FlowPhase = .idle
    @Published var completed:[FlowStep]=[]
    @Published var activeStep:FlowStep?
    @Published var failure:String?
    @Published var status="从这里开始四步检查"
    @Published var score:String="—"
    @Published var ip:String="—"
    @Published var lastCheck:String="尚未检测"
    @Published var logs:[String]=[]
    @Published var settingsVisible=false
    @Published var busy=false
    @Published var serviceNotice:String?
    @Published var historyItems:[HistoryEntry]=[]
    @Published var historyLoading=false
    @Published var historyUnreadableFiles=0
    @Published var monitorVisible=true
    @Published var networkConnected:Bool?
    @Published var proxyConnected:Bool?
    @Published var timezoneName=SystemState.timezone
    @Published var tickDate=Date()
    @Published var webActivity:WebActivity = .idle
    @Published var webReadings=""
    private var webStarted:TimeInterval=0
    private var webFinishedSeconds=0
    private var refreshWaitStarted:TimeInterval=0
    var onStateChange:(() -> Void)?
    var onBackground:(() -> Void)?
    var onHistory:(() -> Void)?
    var onMonitorToggle:(() -> Void)?
    lazy var flow:Workflow = {
        let f=Workflow(driver:self); f.onChange={ [weak self,weak f] in
            guard let self,let f else { return }
            self.phase=f.phase;self.completed=f.completed;self.activeStep=f.activeStep;self.failure=f.failure;self.onStateChange?()
            if f.phase == .blocked && self.webActivity.isWorking { self.webActivity = .failed }
        };return f
    }()
    private var watchdog:WatchdogClient?
    private var timer:Timer?
    private var localBusy=false
    private var webBusy=false
    private var stopping=false
    private var lastWebStart:Double=0
    private var permitOrigin:Double=0
    private var permitUptime:Double=0
    private var networkConfig:NetworkConfiguration?
    private var runtimePolicy=RuntimeMonitorPolicy()
    @Published var runtimeNotice:String?
    private let browser=DetectionBrowser(root:Settings.support)
    private var workflowTask:Task<Void,Never>?
    private var networkMonitor:NWPathMonitor?
    private var pathSignature:String?
    private var wakeObserver:NSObjectProtocol?
    private var sessionID=UUID()
    private var editorProcess:Process?
    var isActive:Bool { phase == .checking || phase == .guarding }
    var logURL:URL { (watchdog?.directory ?? Settings.support).appendingPathComponent("events.jsonl") }
    init() {
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in await self?.tick() } }
        if let timer { RunLoop.main.add(timer,forMode:.common) }
        wakeObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in if let self,self.isActive { await self.trip("电脑已唤醒，需要重新执行完整检查") } }
        }
        let monitor=NWPathMonitor();networkMonitor=monitor
        monitor.pathUpdateHandler={ [weak self] path in
            let signature="\(path.status)-"+path.availableInterfaces.map{$0.name}.sorted().joined(separator:",")
            Task { @MainActor in
                guard let self else { return }
                self.networkConnected=path.status == .satisfied
                let changed=self.pathSignature != nil && self.pathSignature != signature
                self.pathSignature=signature
                if changed && self.phase == .guarding { await self.trip("网络接口发生变化，需要重新检查") }
            }
        };monitor.start(queue:DispatchQueue(label:"local.ccguard.network"))
        reloadHistory()
    }
    enum WebActivity {
        case idle,loading,waitingRefresh,pathCheck,background,retrying,passed,failed
        var isWorking:Bool { self == .loading || self == .waitingRefresh || self == .pathCheck || self == .background }
    }
    var phaseTitle:String {
        if failure != nil && !isActive { return "需处理" }
        switch phase {
        case .idle:return "待检查"
        case .checking:return "检查中"
        case .guarding:return "守护中"
        case .blocked:return "已拦截"
        }
    }
    var webProgressText:String {
        let elapsed=max(0,Int(ProcessInfo.processInfo.systemUptime-webStarted))
        switch webActivity {
        case .idle:return "网页待检测"
        case .loading:return "网页加载 \(elapsed) / \(Int(settings.webTimeout)) 秒"
        case .waitingRefresh:return "\(max(0,10-Int(ProcessInfo.processInfo.systemUptime-refreshWaitStarted))) 秒后刷新"
        case .pathCheck:return "核对出口路径 · \(elapsed) 秒"
        case .background:return "后台探测中（不刷新网页）"
        case .retrying:return "后台探测重试中 · 剩余 \(runtimePolicy.retrySecondsRemaining(now:ProcessInfo.processInfo.systemUptime)) 秒"
        case .failed:return "本轮检测已停止"
        case .passed:
            if phase == .guarding {
                let next=max(0,Int(ceil(WebCheckTiming.recheckInterval-(ProcessInfo.processInfo.systemUptime-lastWebStart))))
                return "\(next) 秒后后台探测 · 上次 \(webFinishedSeconds) 秒"
            }
            return "网页已通过 · \(webFinishedSeconds) 秒"
        }
    }
    var compactMonitorStatus:String {
        if phase == .blocked || failure != nil { return "检测异常" }
        if webActivity == .loading {
            let elapsed=max(0,Int(ProcessInfo.processInfo.systemUptime-webStarted))
            return "网页 \(elapsed)/\(Int(settings.webTimeout))s"
        }
        if webActivity == .waitingRefresh { return "等待刷新" }
        if webActivity == .background { return "后台探测" }
        if webActivity == .retrying { return "探测重试中" }
        if webActivity == .pathCheck { return "核对出口" }
        if phase == .checking {
            switch activeStep {
            case .proxy:return "核验节点"
            case .timezone:return "核验时区"
            case .editor:return "打开 Claude"
            default:return "检测中"
            }
        }
        return phaseTitle
    }
    private var stageTitle:String {
        guard let activeStep else { return phaseTitle }
        switch activeStep {
        case .proxy:return "连接节点"
        case .timezone:return "核验时区"
        case .website:return "检测网络环境"
        case .editor:return "打开 Claude Code"
        }
    }
    func reloadHistory() {
        guard !historyLoading else { return };historyLoading=true
        let root=Settings.support
        Task { [weak self] in
            let loaded=await Task.detached(priority:.utility) { ErrorHistory.load(root:root) }.value
            guard let self else { return }
            self.historyItems=HistoryEntry.merging(self.historyItems+loaded.entries)
            self.historyUnreadableFiles=loaded.unreadableFiles;self.historyLoading=false
        }
    }
    func showHistory() { reloadHistory();onHistory?() }
    func toggleMonitor() { onMonitorToggle?() }
    func log(_ text:String,level:HistoryLevel? = nil) {
        let stamp=DateFormatter.localizedString(from:Date(),dateStyle:.none,timeStyle:.medium)
        logs.append(stamp+"  "+text);if logs.count>150 { logs.removeFirst(logs.count-150) }
        var record=["time":ISO8601DateFormatter().string(from:Date()),"message":text,"stage":stageTitle,"ip":ip,"score":score,"webStatus":webProgressText,"webReadings":webReadings]
        if let severity=level ?? HistoryLevel.inferred(from:text) { record["level"]=severity.rawValue }
        if let data=try? JSONSerialization.data(withJSONObject:record),
           let entry=HistoryEntry.decode(data,sessionID:watchdog?.directory.lastPathComponent ?? "全局记录",sourcePath:logURL.path) {
            historyItems=HistoryEntry.merging([entry]+historyItems)
        }
        if let data=try? JSONSerialization.data(withJSONObject:record),let handle=try? FileHandle(forWritingTo:logURL) {
            do { try handle.seekToEnd();try handle.write(contentsOf:data+Data([10]));try handle.close() } catch {}
        } else if let data=try? JSONSerialization.data(withJSONObject:record) { try? (data+Data([10])).write(to:logURL) }
    }
    func start() {
        guard !busy && !isActive else { return }
        failure=nil;serviceNotice=nil;runtimeNotice=nil;runtimePolicy=RuntimeMonitorPolicy()
        guard AXIsProcessTrusted() else { failure="请先点“允许辅助功能”，在系统设置中勾选 CC登录器，再回来开始。";log("已拦截："+failure!);settingsVisible=true;return }
        do {
            try settings.save()
            guard try Editors.selected().allSatisfy({$0.path.hasSuffix("/chrome_crashpad_handler")}) else { throw GuardFailure("请先保存并退出已打开的 VS Code，再从登录器开始完整流程") }
            watchdog?.stop()
            let worker=WatchdogClient();try worker.start();watchdog=worker
        } catch { failure=error.localizedDescription;log("已拦截："+error.localizedDescription);return }
        sessionID=UUID();let token=sessionID
        busy=true;score="—";ip="—";lastCheck="尚未检测";networkConfig=nil;webActivity = .idle;webReadings=""
        log("开始四步检查")
        workflowTask=Task { [weak self] in
            guard let self else { return };await self.flow.start();guard self.sessionID==token else{return};self.busy=false
            if self.phase == .guarding { self.status="守护中 · 本地 1 秒 / 后台探测 30 秒";self.log("四步完成，持续守护已开启") }
            else if let reason=self.failure { self.status="检查未通过";self.log("已拦截："+reason) }
        }
    }
    func didEnterGuarding() async {
        let token=sessionID
        guard phase == .guarding,!Task.isCancelled else { return }
        do { try await browser.minimizeWindow();log("检测专用浏览器已最小化") }
        catch { log("检测浏览器暂未收起："+error.localizedDescription) }
        guard phase == .guarding,sessionID==token,!Task.isCancelled else { return }
        let proxyWindows=AuxiliaryWindows.minimize(bundleID:"com.liguangming.Shadowrocket")
        do {
            try SystemState.verify(SystemState.local(),settings:settings)
            log(proxyWindows.failedCount==0 ? "Shadowrocket 已收起，路由和连接状态仍可核验" : "部分 Shadowrocket 窗口暂未收起，路由和连接状态仍可核验")
        } catch {
            proxyWindows.restore()
            log("Shadowrocket 最小化后状态无法确认，已恢复窗口以保持监控")
        }
        if let bundleID=Bundle(url:URL(fileURLWithPath:settings.timezoneApp))?.bundleIdentifier {
            let result=AuxiliaryWindows.minimize(bundleID:bundleID)
            if result.failedCount>0 { log("部分时区工具窗口暂未收起") }
        }
        guard phase == .guarding,sessionID==token,!Task.isCancelled else { return }
        onBackground?()
        _=NSRunningApplication.runningApplications(withBundleIdentifier:"com.microsoft.VSCode").first?.activate()
        log("启动检测完成，辅助窗口已收起；菜单栏和后台守护继续运行")
    }
    func stop() async {
        guard !stopping else { return };stopping=true
        sessionID=UUID()
        workflowTask?.cancel();browser.invalidate();await flow.finish()
        if phase == .blocked,let reason=failure { log("退出核验失败："+reason) }
        status=phase == .idle ? "已结束使用" : "退出核验未完成";busy=false;stopping=false;webActivity = .idle
    }
    func trip(_ reason:String) async {
        guard !stopping && isActive else { return };stopping=true
        sessionID=UUID()
        workflowTask?.cancel();browser.invalidate();status="已拦截";log("发现异常："+reason)
        await flow.trip(reason);busy=false;stopping=false
        if let failure,failure != reason { log("退出核验失败："+failure) }
        NSApp?.requestUserAttention(.criticalRequest)
    }
    func tick() async {
        tickDate=Date();proxyConnected=SystemState.vpnConnected();timezoneName=SystemState.timezone
        guard !localBusy else { return };localBusy=true;defer{localBusy=false}
        do {
            try watchdog?.pulse()
            if phase == .guarding || (phase == .checking && completed.contains(.proxy)) {
                try watchdog?.verify()
                let local=SystemState.local()
                if watchdog?.armed==true {
                    do { try SystemState.verifyRuntime(local,settings:settings) }
                    catch let error as RuntimeProbeFailure where !error.confirmed {
                        runtimePolicy.markUnknown(now:ProcessInfo.processInfo.systemUptime)
                        let notice="本地状态暂未确认，将后台复核："+error.localizedDescription
                        if runtimeNotice != notice { runtimeNotice=notice;log("提示："+notice,level:.warning) }
                        webActivity = .retrying
                    }
                } else { try SystemState.verify(local,settings:settings,requireTimezone:completed.contains(.timezone)) }
                if let networkConfig {
                    guard try NetworkConfiguration.read(settings:settings).fingerprint==networkConfig.fingerprint else { throw GuardFailure("Claude Code 或代理配置发生变化，需要重新检查") }
                }
            }
            if phase == .guarding || (phase == .checking && watchdog?.armed == true) {
                let now=ProcessInfo.processInfo.systemUptime
                guard !runtimePolicy.expired(now:now) else { throw GuardFailure("后台关键状态持续无法确认，已超过重试期限") }
                if !webBusy && runtimePolicy.shouldProbe(now:now) {
                    let token=sessionID
                    webBusy=true
                    Task { [weak self] in
                        guard let self else{return};defer{self.webBusy=false}
                        do {
                            try await self.inspectRuntime()
                        } catch {
                            guard self.sessionID==token,self.isActive else { return }
                            if (error as? RuntimeProbeFailure)?.confirmed == true { await self.trip(error.localizedDescription) }
                            else if !(error is CancellationError) {
                                self.runtimePolicy.unavailable(now:ProcessInfo.processInfo.systemUptime)
                                self.runtimeNotice="后台探测暂未确认，10 秒后重试："+error.localizedDescription
                                self.webActivity = .retrying
                                self.log("提示："+self.runtimeNotice!,level:.warning)
                            }
                        }
                    }
                }
            }
        } catch { await trip(error.localizedDescription) }
    }
    func prepareProxy() async throws {
        status="1 / 4 连接节点并核验配置路由";log(status)
        let appURL=URL(fileURLWithPath:"/Applications/Shadowrocket.app")
        _=try await NSWorkspace.shared.openApplication(at:appURL,configuration:NSWorkspace.OpenConfiguration())
        AuxiliaryWindows.restore(bundleID:"com.liguangming.Shadowrocket")
        guard NSWorkspace.shared.open(URL(string:"shadowrocket://route/config")!) else { throw GuardFailure("无法调用 Shadowrocket 配置路由入口") }
        for _ in 0..<15 {
            try Task.checkCancellation()
            let current=SystemState.local()
            if current.node != settings.nodeName {
                if let row=AX.elements(bundleID:"com.liguangming.Shadowrocket").first(where:{
                    let label=AX.label($0)
                    return AX.text($0,kAXRoleAttribute)==kAXButtonRole && label.hasPrefix(settings.nodeName+",")
                }) { try AX.press(row) }
                else { throw GuardFailure("未找到指定节点，请检查设置中的节点全名") }
            }
            if !current.vpn { _=NSWorkspace.shared.open(URL(string:"shadowrocket://connect")!) }
            try await Task.sleep(nanoseconds:400_000_000)
            if (try? SystemState.verify(SystemState.local(),settings:settings,requireTimezone:false)) != nil { log("节点已连接，配置路由已核验");return }
        }
        try SystemState.verify(SystemState.local(),settings:settings,requireTimezone:false)
    }
    func prepareTimezone() async throws {
        status="2 / 4 切换并核验纽约时区";log(status)
        if settings.timezoneApp.isEmpty {
            guard SystemState.timezone=="America/New_York" else { throw GuardFailure("请先将系统时区设为纽约，或配置兼容的时区切换 App") }
            log("系统实际时区 America/New_York 已核验（手动配置）");return
        }
        let app=URL(fileURLWithPath:settings.timezoneApp)
        _=try await NSWorkspace.shared.openApplication(at:app,configuration:NSWorkspace.OpenConfiguration())
        if let bundleID=Bundle(url:app)?.bundleIdentifier { AuxiliaryWindows.restore(bundleID:bundleID) }
        let executable=app.appendingPathComponent("Contents/MacOS/EnvironmentSwitch").path
        let response=try await Commands.run(executable,["--service-action","newYork"],timeout:25)
        guard response.code==0 else { throw GuardFailure("时区 App 返回失败（\(response.code)），请检查原 App 的免密组件") }
        guard let data=response.output.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],object["ok"] as? Bool==true else { throw GuardFailure("时区 App 未返回有效的成功回执") }
        guard SystemState.timezone=="America/New_York" else { throw GuardFailure("系统实际时区不是纽约，未放行") }
        log("系统实际时区 America/New_York 已核验")
    }
    func inspectWebsite() async throws {
        guard phase == .checking,watchdog?.armed != true else { throw GuardFailure("完整网页检测仅允许在启动前执行") }
        let token=sessionID
        let wasGuarding=watchdog?.armed == true
        webActivity = .loading;webStarted=ProcessInfo.processInfo.systemUptime
        var succeeded=false
        defer {
            if sessionID==token {
                webFinishedSeconds=max(0,Int(ProcessInfo.processInfo.systemUptime-webStarted))
                if !succeeded { webActivity = .failed }
            }
        }
        if !wasGuarding { status="3 / 4 浏览器检测与网络路径核对";log(status) }
        lastWebStart=ProcessInfo.processInfo.systemUptime
        let snapshot=try await browser.inspect(settings:settings,allowRefresh:!wasGuarding,didRead:{ snapshot in
            guard self.sessionID==token else { return }
            self.ip=snapshot.claudeIP ?? "—"
            self.score=snapshot.score.map{String(format:"%.0f",$0)} ?? "—"
            self.webReadings=[("国内出口",snapshot.chinaIP),("DNS",snapshot.raw["dns"]),("Claude",snapshot.raw["claudeAvailability"]),("服务",snapshot.raw["serviceStatus"])].compactMap { label,value in
                guard let value,!value.isEmpty else { return nil }
                return label+"："+String(value.prefix(80))
            }.joined(separator:" · ")
            if self.serviceNotice != snapshot.serviceStatusWarning {
                self.serviceNotice=snapshot.serviceStatusWarning
                if let notice=self.serviceNotice { self.log("提示："+notice,level:.warning) }
                else { self.log("Claude 全局服务状态恢复正常") }
            }
        }) { progress in
            guard self.sessionID==token else { return }
            switch progress {
            case .loading:self.webActivity = .loading
            case .waitingToRefresh:self.webActivity = .waitingRefresh;self.refreshWaitStarted=ProcessInfo.processInfo.systemUptime
            }
            if !wasGuarding {
                switch progress {
                case .loading: self.status="3 / 4 网页加载中，至少等待 10 秒"
                case .waitingToRefresh: self.status="3 / 4 信息未齐全或不一致，10 秒后刷新一次"
                }
                self.log(self.status)
            }
        }
        try Task.checkCancellation()
        guard sessionID==token else{throw CancellationError()}
        webActivity = .pathCheck
        if serviceNotice != snapshot.serviceStatusWarning {
            serviceNotice=snapshot.serviceStatusWarning
            if let notice=serviceNotice { log("提示："+notice,level:.warning) }
            else { log("Claude 全局服务状态恢复正常") }
        }
        let config=try NetworkConfiguration.read(settings:settings)
        try await config.checkExit(expectedIP:settings.expectedIP)
        try Task.checkCancellation()
        guard sessionID==token else{throw CancellationError()}
        guard phase == .checking || phase == .guarding else { throw CancellationError() }
        try SystemState.verify(SystemState.local(),settings:settings)
        networkConfig=config;ip=snapshot.claudeIP ?? "—";score=snapshot.score.map{String(format:"%.0f",$0)} ?? "—"
        permitOrigin=snapshot.timeOrigin;permitUptime=ProcessInfo.processInfo.systemUptime
        let timing=try WebCheckTiming(timeout:settings.webTimeout)
        guard Date().timeIntervalSince1970*1000-permitOrigin<timing.documentMaxAge*1000 else { throw GuardFailure("网络路径探测结束时网页结果已过期") }
        lastCheck=DateFormatter.localizedString(from:Date(),dateStyle:.none,timeStyle:.medium)
        succeeded=true;webActivity = .passed
        log("网页通过：评分 \(score)，出口 \(ip)；同环境网络探测一致")
    }
    func inspectRuntime() async throws {
        guard isActive,watchdog?.armed==true,let config=networkConfig else { throw CancellationError() }
        let token=sessionID,round=UUID().uuidString,expectedIP=settings.expectedIP
        let start=ProcessInfo.processInfo.systemUptime
        runtimePolicy.started(now:start);lastWebStart=start;webStarted=start;webActivity = .background
        var observation=RuntimeObservation(roundID:round,collectedAt:Date().timeIntervalSince1970*1000)
        try await withThrowingTaskGroup(of:RuntimeObservation.self) { group in
            group.addTask {
                try await config.runtimeProbe(roundID:round,expectedIP:expectedIP,onConfirmed:{ @MainActor reason in
                    if self.sessionID==token,self.isActive { await self.trip(reason) }
                })
            }
            group.addTask { @MainActor in
                do { return try await self.browser.probeInBackground(roundID:round,expectedIP:expectedIP,onConfirmed:{ @MainActor reason in
                    if self.sessionID==token,self.isActive { await self.trip(reason) }
                }) }
                catch let error as RuntimeProbeFailure where error.confirmed { throw error }
                catch { return RuntimeObservation(roundID:round,collectedAt:Date().timeIntervalSince1970*1000,details:["probe":error.localizedDescription]) }
            }
            for try await part in group {
                guard self.sessionID==token,self.isActive else { group.cancelAll();throw CancellationError() }
                // Reject a stale or mismatched component before merging it with another round.
                if part.roundID != round || Date().timeIntervalSince1970*1000-part.collectedAt>35_000 {
                    throw RuntimeProbeFailure("后台探测结果已过期或轮次不一致")
                }
                if let ip=part.chinaIP { observation.chinaIP=ip }
                if let ip=part.cloudflareIP { observation.cloudflareIP=ip }
                if let ip=part.claudeIP { observation.claudeIP=ip;self.ip=ip }
                if let value=part.claudeReachable { observation.claudeReachable=value }
                if let value=part.anthropicReachable { observation.anthropicReachable=value }
                if let value=part.dnsSafe { observation.dnsSafe=value }
                if let value=part.webrtcSafe { observation.webrtcSafe=value }
                if let value=part.browserTimezone { observation.browserTimezone=value }
                observation.details.merge(part.details,uniquingKeysWith:{$1})
            }
        }
        try Task.checkCancellation();guard sessionID==token,isActive else { throw CancellationError() }
        observation.collectedAt=Date().timeIntervalSince1970*1000
        let assessment=observation.assess(expectedIP:settings.expectedIP,expectedRound:round)
        if let service=observation.details["service"] {
            let notice=service=="全部服务正常" ? nil : "Claude 全局服务提示："+service
            if serviceNotice != notice { serviceNotice=notice;if let notice { log("提示："+notice,level:.warning) } }
        }
        webReadings=observation.details.sorted{$0.key<$1.key}.map{$0.key+"："+$0.value}.joined(separator:" · ")
        if !assessment.failures.isEmpty { throw RuntimeProbeFailure(assessment.failures.joined(separator:"；"),confirmed:true) }
        if !assessment.unknown.isEmpty { throw RuntimeProbeFailure(assessment.unknown.joined(separator:"；")) }
        try SystemState.verifyRuntime(SystemState.local(),settings:settings)
        guard try NetworkConfiguration.read(settings:settings).fingerprint==config.fingerprint else {
            throw RuntimeProbeFailure("代理配置发生变化",confirmed:true)
        }
        runtimePolicy.succeeded(now:ProcessInfo.processInfo.systemUptime);runtimeNotice=nil
        webFinishedSeconds=Int(ProcessInfo.processInfo.systemUptime-start);webActivity = .passed
        lastCheck=DateFormatter.localizedString(from:Date(),dateStyle:.none,timeStyle:.medium)
        status="守护中 · 本地 1 秒 / 后台探测 30 秒"
        log("后台探测通过：出口、连通性、DNS、WebRTC、时区一致（未刷新网页，未查询评分/住宅/风险）")
    }
    func armAndOpenEditor() async throws {
        status="4 / 4 开启守护并打开 Claude Code";log(status)
        try SystemState.verify(SystemState.local(),settings:settings)
        let timing=try WebCheckTiming(timeout:settings.webTimeout)
        guard ProcessInfo.processInfo.systemUptime-permitUptime<timing.permitMaxAge,Date().timeIntervalSince1970*1000-permitOrigin<timing.documentMaxAge*1000 else { throw GuardFailure("启动前网页检测结果已过期") }
        guard let config=networkConfig,try NetworkConfiguration.read(settings:settings).fingerprint==config.fingerprint else { throw GuardFailure("网络配置无法确认") }
        guard let watchdog else { throw GuardFailure("后台守护组件未启动") }
        runtimePolicy.begin(now:ProcessInfo.processInfo.systemUptime)
        try await watchdog.arm()
        try Task.checkCancellation()
        guard phase == .checking,watchdog.armed else { throw CancellationError() }
        // Launch directly and synchronously register the process before yielding. A late
        // CLI completion must never start a fresh editor after the permit was revoked.
        guard let executable=Bundle(url:URL(fileURLWithPath:Editors.appPath))?.executableURL else { throw GuardFailure("无法从已安装的 VS Code 读取启动程序") }
        let process=Process();process.executableURL=executable
        process.arguments=["--force-renderer-accessibility=complete","--new-window",settings.workspace];process.environment=config.environment
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();editorProcess=process
        guard NSWorkspace.shared.open(URL(string:"vscode://anthropic.claude-code/open")!) else { throw GuardFailure("Claude Code 对话入口打开失败") }
        var openedByControl=false
        var activatedCode=false
        var lastNodeCount = -1
        var loggedWebMetadata=false
        // First startup may show an OS or workspace prompt. Continue all local and
        // external checks while waiting; a pending UI acknowledgement is no exemption.
        for _ in 0..<240 {
            try Task.checkCancellation()
            let elements=AX.elements(bundleID:"com.microsoft.VSCode")
            if !activatedCode,elements.count>20,let codeApp=NSRunningApplication.runningApplications(withBundleIdentifier:"com.microsoft.VSCode").first {
                _=codeApp.activate(options:[.activateIgnoringOtherApps])
                let root=AXUIElementCreateApplication(codeApp.processIdentifier)
                activatedCode=AXUIElementSetAttributeValue(root,kAXFrontmostAttribute as CFString,kCFBooleanTrue) == .success
                if activatedCode { log("已将 VS Code 切到前台以确认对话页") }
            }
            if !loggedWebMetadata,elements.count>20 {
                let web=elements.filter{AX.text($0,kAXRoleAttribute).contains("Web")}
                log("对话页核验：网页节点 \(web.count)，URL身份匹配 \(web.contains{ClaudeViewIdentity.isConversationWebView(AX.text($0,kAXURLAttribute))})，文档身份匹配 \(elements.contains{ClaudeViewIdentity.isConversationWebView(AX.text($0,kAXDocumentAttribute))})")
                loggedWebMetadata=true
            }
            if lastNodeCount != elements.count {
                log("等待 Claude 对话页：读取到 \(elements.count) 个编辑器界面节点")
                lastNodeCount=elements.count
            }
            if elements.contains(where:{
                (AX.text($0,kAXRoleAttribute)=="AXWebArea" && ClaudeViewIdentity.isConversationWebView(AX.text($0,kAXURLAttribute))) ||
                ClaudeViewIdentity.isConversationWebView(AX.text($0,kAXDocumentAttribute))
            }) {
                try SystemState.verify(SystemState.local(),settings:settings);log("Claude Code 专属对话页面已确认，独立守护已就绪");return
            }
            if !openedByControl,let button=elements.first(where:{
                AX.text($0,kAXRoleAttribute)==kAXButtonRole &&
                [AX.text($0,kAXTitleAttribute),AX.text($0,kAXDescriptionAttribute)].contains(where:{["Claude Code: Open","Claude Code: 打开"].contains($0)})
            }) {
                try AX.press(button);openedByControl=true
                log("通过已安装扩展的打开按钮进入 Claude Code")
            }
            try await Task.sleep(nanoseconds:250_000_000)
        }
        throw GuardFailure("VS Code 已启动，但未能确认 Claude Code 对话界面；已撤销运行许可")
    }
    func closeEditors(reason:String) async throws {
        browser.invalidate()
        guard watchdog?.armed==true else { return }
        try? watchdog?.requestStop()
        try await Task.detached(priority:.userInitiated) { try Editors.closeAll() }.value
        try watchdog?.disarm();log("所有 VS Code 窗口及关联子进程已退出："+reason)
    }
    func accessibilitySettings() {
        let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _=AXIsProcessTrustedWithOptions(options)
        _=NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func showLogs() { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
}
