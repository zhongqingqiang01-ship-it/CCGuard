import Foundation
import CCGuardCore

actor DevTools {
    let socket: URLSessionWebSocketTask
    private var nextID = 0
    private let commands=SerialOperationQueue()
    init(url:URL) {
        // The connection must survive the 10-second load/retry pauses. Individual
        // commands still have their own short deadline below.
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 120
        socket = URLSession(configuration:config).webSocketTask(with:url); socket.resume()
    }
    func close() { socket.cancel(with:.goingAway,reason:nil) }
    func call(_ method:String, _ params:[String:Any] = [:], timeout:TimeInterval = 6) async throws -> [String:Any] {
        nextID += 1; let id = nextID
        let payload = try JSONSerialization.data(withJSONObject:["id":id,"method":method,"params":params])
        return try await commands.run { [socket] in
            let deadline = Task { try? await Task.sleep(nanoseconds:UInt64(timeout*1_000_000_000)); if !Task.isCancelled { socket.cancel(with:.goingAway,reason:nil) } }
            defer { deadline.cancel() }
            try await socket.send(.string(String(decoding:payload,as:UTF8.self)))
            while true {
                let reply = try await socket.receive(); let bytes:Data
                switch reply { case .data(let d): bytes=d; case .string(let s): bytes=Data(s.utf8); @unknown default: continue }
                guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any], object["id"] as? Int == id else { continue }
                if object["error"] != nil { throw GuardFailure("浏览器检测连接返回错误") }
                return object["result"] as? [String:Any] ?? [:]
            }
        }
    }
    func evaluate(_ source:String,timeout:TimeInterval = 6,contextID:Int? = nil) async throws -> Data {
        var params:[String:Any] = ["expression":source,"returnByValue":true,"awaitPromise":false]
        if let contextID { params["contextId"]=contextID }
        let result = try await call("Runtime.evaluate",params,timeout:timeout)
        guard result["exceptionDetails"] == nil,let wrapped=result["result"] as? [String:Any],let value=wrapped["value"] else { throw GuardFailure("网页字段读取失败，页面可能已经变更") }
        return try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed])
    }
}
@MainActor final class DetectionBrowser {
    private var tools:DevTools?
    private var chrome:Process?
    private var port = 0
    private var pageID:String?
    private var backgroundContext:Int?
    private(set) var lastSnapshot:DetectionSnapshot?
    private var generation = UUID()
    let profile:URL
    init(root:URL) { profile=root.appendingPathComponent("Chrome检测专用") }
    var connected:Bool { tools != nil }
    func prepare() async throws {
        if tools != nil { return }
        let chromePath="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        guard FileManager.default.isExecutableFile(atPath:chromePath) else { throw GuardFailure("请先安装 Google Chrome") }
        try FileManager.default.createDirectory(at:profile,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let portFile=profile.appendingPathComponent("DevToolsActivePort")
        // Reuse only this application's dedicated profile, never the personal Chrome debugging port.
        if let data=try? String(contentsOf:portFile,encoding:.utf8),let value=Int(data.split(separator:"\n").first ?? ""), await isAlive(value) { port=value }
        else {
            try? FileManager.default.removeItem(at:portFile)
            let process=Process(); process.executableURL=URL(fileURLWithPath:chromePath)
            process.arguments=["--user-data-dir="+profile.path,"--remote-debugging-port=0","--remote-debugging-address=127.0.0.1","--no-first-run","--no-default-browser-check","--new-window","about:blank"]
            process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
            try process.run(); chrome=process
            for _ in 0..<80 {
                try Task.checkCancellation()
                if let data=try? String(contentsOf:portFile,encoding:.utf8),let value=Int(data.split(separator:"\n").first ?? ""),await isAlive(value) { port=value;break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
        }
        guard port>0 else { throw GuardFailure("独立 Chrome 检测窗口未能启动") }
        var request=URLRequest(url:URL(string:"http://127.0.0.1:\(port)/json/new?about:blank")!); request.httpMethod="PUT"; request.timeoutInterval=3
        let (data,_)=try await URLSession.shared.data(for:request)
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let urlString=object["webSocketDebuggerUrl"] as? String,let url=URL(string:urlString),url.host=="127.0.0.1" || url.host=="localhost" else { throw GuardFailure("浏览器未返回可用的本地检测连接") }
        pageID=object["id"] as? String; tools=DevTools(url:url)
        _=try await tools!.call("Page.enable")
        _=try await tools!.call("Network.enable")
        _=try await tools!.call("Network.setCacheDisabled",["cacheDisabled":true])
    }
    private func isAlive(_ value:Int) async -> Bool {
        var request=URLRequest(url:URL(string:"http://127.0.0.1:\(value)/json/version")!); request.timeoutInterval=1
        guard let (data,_)=try? await URLSession.shared.data(for:request),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return false }
        return (object["Browser"] as? String)?.contains("Chrome") == true
    }
    func inspect(settings:Settings, allowRefresh:Bool = true,
                 didRead:(DetectionSnapshot)->Void = { _ in },
                 progress:(PageInspectionSchedule.Progress)->Void = { _ in }) async throws -> DetectionSnapshot {
        _=try WebCheckTiming(timeout:settings.webTimeout)
        try await prepare(); guard let tools else { throw GuardFailure("检测窗口未就绪") }
        let own=UUID(); generation=own
        let extractorURL=Bundle.main.resourceURL?.appendingPathComponent("extract-detection.js")
        guard let extractorURL,let extractor=try? String(contentsOf:extractorURL,encoding:.utf8) else { throw GuardFailure("检测组件缺失，请重新构建 App") }
        var token=""
        var start=0.0
        let snapshot=try await PageInspectionSchedule.run(allowRefresh:allowRefresh, navigate: {
            try Task.checkCancellation(); guard self.generation==own else { throw CancellationError() }
            token=UUID().uuidString
            self.backgroundContext=nil
            self.lastSnapshot=nil
            start=ProcessInfo.processInfo.systemUptime
            _=try await tools.call("Page.navigate",["url":"https://ip.net.coffee/claude/?ccguard="+token],timeout:settings.webTimeout)
        }, read: {
            try await self.readPage(tools:tools,extractor:extractor,token:token,start:start,own:own,settings:settings,didRead:didRead)
        }, progress:progress)
        try Task.checkCancellation(); guard generation==own else { throw CancellationError() }
        lastSnapshot=snapshot
        return snapshot
    }
    private func readPage(tools:DevTools,extractor:String,token:String,start:Double,own:UUID,settings:Settings,didRead:(DetectionSnapshot)->Void) async throws -> DetectionSnapshot {
        var expectedOrigin:Double?
        var lastReasons=["正在等待检测完成"]
        // Always sample once after the minimum wait, including a 10-second timeout.
        repeat {
            try Task.checkCancellation(); guard generation==own else { throw CancellationError() }
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            guard elapsed<=settings.webTimeout+0.5 else { throw PageInspectionFailure("网页检测超时："+lastReasons.joined(separator:"；"),mayRefresh:true) }
            let data=try await tools.evaluate(extractor,timeout:min(6,max(0.25,settings.webTimeout-elapsed)))
            guard let snapshot=try? JSONDecoder().decode(DetectionSnapshot.self,from:data) else { throw GuardFailure("检测结果格式改变，未放行") }
            // Navigate is asynchronous: only accept the page carrying this exact fresh navigation token.
            guard let url=URLComponents(string:snapshot.url),url.host=="ip.net.coffee",url.path=="/claude/",url.queryItems?.contains(where:{$0.name=="ccguard" && $0.value==token})==true else {
                try await Task.sleep(nanoseconds:200_000_000);continue
            }
            if expectedOrigin==nil { expectedOrigin=snapshot.timeOrigin }
            lastSnapshot=snapshot;didRead(snapshot)
            let timing=try WebCheckTiming(timeout:settings.webTimeout)
            let rules=DetectionRules(expectedIP:settings.expectedIP,maxDocumentAge:timing.documentMaxAge)
            let verdict=rules.validate(snapshot,expectedTimeOrigin:expectedOrigin)
            lastReasons=verdict.reasons
            if !snapshot.explicitFailures.isEmpty { throw PageInspectionFailure(snapshot.explicitFailures.joined(separator:"；"),mayRefresh:snapshot.mayRefreshAfterFailure()) }
            let knownIPs=[snapshot.cloudflareIP,snapshot.claudeIP].compactMap{$0}
            if knownIPs.contains(where:{$0 != settings.expectedIP}) || Set(knownIPs).count>1 { throw PageInspectionFailure("出口 IP 与指定 IP 不一致",mayRefresh:true) }
            if let country=snapshot.country,!country.isEmpty,country != "未知",!["United States","United States of America","美国","美國","US"].contains(country) { throw GuardFailure("出口地区不是美国") }
            if snapshot.browserTimezone != "America/New_York" { throw PageInspectionFailure("浏览器时区不是纽约",mayRefresh:true) }
            if verdict.passed { return snapshot }
            let countryPending=snapshot.country?.trimmingCharacters(in:.whitespacesAndNewlines)=="未知"
            if snapshot.missingRequiredFields.isEmpty && snapshot.readyState=="complete" && !countryPending { throw GuardFailure(verdict.reasons.joined(separator:"；")) }
            try await Task.sleep(nanoseconds:300_000_000)
        } while ProcessInfo.processInfo.systemUptime-start<settings.webTimeout
        throw PageInspectionFailure("网页检测超时："+lastReasons.joined(separator:"；"),mayRefresh:true)
    }
    func invalidate() {
        generation=UUID()
        backgroundContext=nil
        let old=tools;tools=nil
        Task { await old?.close() }
    }
    /// Reconnect only to the existing dedicated target. Never open or navigate a window in runtime.
    private func backgroundTools() async throws -> (DevTools,Int) {
        if tools == nil {
            guard port>0,let pageID else { throw RuntimeProbeFailure("后台探测窗口连接不可用") }
            var request=URLRequest(url:URL(string:"http://127.0.0.1:\(port)/json/list")!);request.timeoutInterval=3
            let (data,_)=try await URLSession.shared.data(for:request)
            guard let rows=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],
                  let row=rows.first(where:{$0["id"] as? String == pageID}),
                  let raw=row["webSocketDebuggerUrl"] as? String,let url=URL(string:raw),url.host=="127.0.0.1" || url.host=="localhost" else {
                throw RuntimeProbeFailure("检测专用后台上下文已关闭")
            }
            tools=DevTools(url:url)
        }
        guard let tools else { throw RuntimeProbeFailure("后台探测连接不可用") }
        if backgroundContext == nil {
            let tree=try await tools.call("Page.getFrameTree")
            guard let frameTree=tree["frameTree"] as? [String:Any],let frame=frameTree["frame"] as? [String:Any],
                  let frameID=frame["id"] as? String,
                  let rawURL=frame["url"] as? String,let url=URLComponents(string:rawURL),url.scheme=="https",url.host=="ip.net.coffee",url.path=="/claude/" else {
                let frameTree=tree["frameTree"] as? [String:Any]
                let frame=frameTree?["frame"] as? [String:Any]
                throw RuntimeProbeFailure("后台上下文地址发生变化，无法探测："+(frame?["url"] as? String ?? "缺少 frame URL"))
            }
            let world=try await tools.call("Page.createIsolatedWorld",["frameId":frameID,"worldName":"CCGuardRuntime"])
            guard let id=world["executionContextId"] as? Int else { throw RuntimeProbeFailure("无法创建后台探测上下文") }
            backgroundContext=id
        }
        return (tools,backgroundContext!)
    }
    /// CLI-only diagnostic: load a context once, then compare its navigation identity across probes.
    func prepareBackgroundValidation(timeout:TimeInterval) async throws -> Double {
        try await prepare();guard let tools else { throw RuntimeProbeFailure("检测连接未就绪") }
        _=try await tools.call("Page.navigate",["url":"https://ip.net.coffee/claude/"],timeout:timeout)
        let start=ProcessInfo.processInfo.systemUptime
        repeat {
            let data=try await tools.evaluate("({url:location.href,ready:document.readyState,origin:performance.timeOrigin})")
            if let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
               object["ready"] as? String=="complete",object["url"] as? String=="https://ip.net.coffee/claude/",
               let origin=object["origin"] as? Double { return origin }
            try await Task.sleep(nanoseconds:250_000_000)
        } while ProcessInfo.processInfo.systemUptime-start<timeout
        throw RuntimeProbeFailure("验证上下文首次加载超时")
    }
    func currentTimeOrigin() async throws -> Double {
        guard let tools else { throw RuntimeProbeFailure("检测连接不可用") }
        return try JSONDecoder().decode(Double.self,from:await tools.evaluate("performance.timeOrigin"))
    }
    func probeInBackground(roundID:String,expectedIP:String,
                           onConfirmed:@escaping @MainActor @Sendable (String) async -> Void = { _ in }) async throws -> RuntimeObservation {
        let own=generation
        do {
            let (tools,context)=try await backgroundTools()
            guard let resource=Bundle.main.resourceURL?.appendingPathComponent("background-probe.js"),
                  let template=try? String(contentsOf:resource,encoding:.utf8) else { throw RuntimeProbeFailure("后台探测组件缺失") }
            let data=try JSONSerialization.data(withJSONObject:["roundID":roundID,"expectedIP":expectedIP])
            let script=template.replacingOccurrences(of:"/*PARAMETERS*/",with:String(decoding:data,as:UTF8.self))
            _=try await tools.evaluate(script,contextID:context)
            let started=ProcessInfo.processInfo.systemUptime
            repeat {
                try Task.checkCancellation();guard generation==own else { throw CancellationError() }
                let bytes=try await tools.evaluate("globalThis.__ccguardRuntimeProbe?.result ?? null",contextID:context)
                if let snapshot=try? JSONDecoder().decode(RuntimeObservation.self,from:bytes),snapshot.roundID==roundID {
                    if snapshot.dnsSafe==false || snapshot.webrtcSafe==false {
                        let message=snapshot.dnsSafe==false ? "后台 DNS 探测发现泄露" : "后台 WebRTC 探测发现泄露"
                        await onConfirmed(message)
                        throw RuntimeProbeFailure(message,confirmed:true)
                    }
                    let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any]
                    if object?["complete"] as? Bool == true { return snapshot }
                }
                try await Task.sleep(nanoseconds:250_000_000)
            } while ProcessInfo.processInfo.systemUptime-started<RuntimeMonitorPolicy.probeTimeout-6
            throw RuntimeProbeFailure("后台 DNS / WebRTC 探测暂未完成")
        } catch {
            if !(error is RuntimeProbeFailure) { let old=tools;tools=nil;backgroundContext=nil;await old?.close() }
            throw error
        }
    }
    func minimizeWindow() async throws {
        guard let tools,let pageID else { throw GuardFailure("检测窗口连接不可用") }
        let result=try await tools.call("Browser.getWindowForTarget",["targetId":pageID])
        guard let windowID=result["windowId"] as? Int else { throw GuardFailure("无法定位检测专用窗口") }
        _=try await tools.call("Browser.setWindowBounds",["windowId":windowID,"bounds":["windowState":"minimized"]])
        let current=try await tools.call("Browser.getWindowBounds",["windowId":windowID])
        guard let bounds=current["bounds"] as? [String:Any],bounds["windowState"] as? String=="minimized" else { throw GuardFailure("检测窗口未能最小化") }
    }
    func disconnect() async { generation=UUID();await tools?.close();tools=nil }
}
