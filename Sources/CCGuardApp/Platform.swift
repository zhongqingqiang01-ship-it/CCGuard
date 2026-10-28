import Foundation
import AppKit
import ApplicationServices
import SystemConfiguration
import CCGuardCore
import Darwin

struct CommandResult { let code: Int32; let output: String }
enum Commands {
    static func run(_ path: String, _ arguments: [String], timeout: Double = 10, environment: [String:String]? = nil) async throws -> CommandResult {
        try await Task.detached(priority:.utility) { try sync(path, arguments, timeout:timeout, environment:environment) }.value
    }
    static func sync(_ path: String, _ arguments: [String], timeout: Double = 10, environment: [String:String]? = nil) throws -> CommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath:path); process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline:.now()+0.3) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } } }
        DispatchQueue.global().asyncAfter(deadline:.now()+timeout, execute:deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); deadline.cancel()
        return CommandResult(code:process.terminationStatus, output:String(decoding:data,as:UTF8.self))
    }
}
struct Settings: Codable {
    var expectedIP = ""
    var nodeName = ""
    var workspace = NSHomeDirectory()
    var timezoneApp = ""
    var webTimeout: Double = WebCheckTiming.defaultTimeout
    static var support: URL { URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support/CCGuardOpenSource") }
    static var url: URL { support.appendingPathComponent("settings.json") }
    static func load() -> Settings { (try? JSONDecoder().decode(Self.self,from:Data(contentsOf:url))) ?? Settings() }
    func save() throws {
        guard DetectionRules.isIPv4(expectedIP), !nodeName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw GuardFailure("请填写完整的 IPv4 地址和节点名称") }
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:workspace,isDirectory:&isDirectory),isDirectory.boolValue else { throw GuardFailure("工作目录不存在，请重新选择") }
        guard timezoneApp.isEmpty || FileManager.default.isExecutableFile(atPath:timezoneApp+"/Contents/MacOS/EnvironmentSwitch") else { throw GuardFailure("时区 App 路径无效") }
        _=try WebCheckTiming(timeout:webTimeout)
        try FileManager.default.createDirectory(at:Self.support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(self).write(to:Self.url,options:.atomic)
    }
}
struct LocalState: Codable {
    var vpn: Bool
    var route: String
    var node: String
    var timezone: String
    var accessibility: Bool
}
enum AX {
    static func text(_ element: AXUIElement, _ key: String) -> String {
        var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return "" }
        if let text=value as? String { return text }
        if let url=value as? URL { return url.absoluteString }
        if let value,CFGetTypeID(value)==CFURLGetTypeID() { return CFURLGetString((value as! CFURL)) as String }
        return ""
    }
    static func elements(bundleID: String) -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.35)
        if bundleID=="com.microsoft.VSCode" {
            // Electron exposes its web UI lazily until an accessibility client opts in.
            _=AXUIElementSetAttributeValue(root,"AXManualAccessibility" as CFString,kCFBooleanTrue)
            _=AXUIElementSetAttributeValue(root,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
        }
        var windows: CFTypeRef?; guard AXUIElementCopyAttributeValue(root,kAXWindowsAttribute as CFString,&windows) == .success,
            let starts = windows as? [AXUIElement] else { return [] }
        if bundleID=="com.microsoft.VSCode" {
            for window in starts { _=AXUIElementSetAttributeValue(window,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue) }
        }
        var queue = starts
        if bundleID=="com.microsoft.VSCode" {
            var focused:CFTypeRef?
            if AXUIElementCopyAttributeValue(root,kAXFocusedUIElementAttribute as CFString,&focused) == .success,
               let focused,CFGetTypeID(focused)==AXUIElementGetTypeID() { queue.append(focused as! AXUIElement) }
        }
        var result: [AXUIElement] = []; var seen:[CFHashCode:[AXUIElement]] = [:]
        while !queue.isEmpty && result.count < 700 {
            let e = queue.removeLast(); let hash = CFHash(e)
            if seen[hash]?.contains(where:{CFEqual($0,e)})==true { continue }
            seen[hash,default:[]].append(e)
            result.append(e)
            for attribute in [kAXChildrenAttribute,"AXContents"] {
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(e,attribute as CFString,&children) == .success, let rows = children as? [AXUIElement] { queue.append(contentsOf:rows) }
            }
        }
        return result
    }
    static func label(_ element: AXUIElement) -> String { [text(element,kAXTitleAttribute),text(element,kAXDescriptionAttribute),text(element,kAXValueAttribute)].filter { !$0.isEmpty }.joined(separator:" ") }
    static func press(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element,kAXPressAction as CFString) == .success else { throw GuardFailure("无法操作应用控件，请保持对应窗口打开后重试") }
    }
}
enum SystemState {
    private static var routeElement:AXUIElement?
    private static var nodeElement:AXUIElement?
    private static var routePID:pid_t?
    static var timezone: String {
        let p = URL(fileURLWithPath:"/etc/localtime").resolvingSymlinksInPath().path
        return p.components(separatedBy:"/zoneinfo/").last ?? "未知"
    }
    static func vpnConnected() -> Bool {
        guard let prefs = SCPreferencesCreate(nil,"CCGuard" as CFString,nil),
            let services = SCPreferencesGetValue(prefs,"NetworkServices" as CFString) as? [String:[String:Any]] else { return false }
        for (identifier,service) in services {
            guard let interface=service["Interface"] as? [String:Any],interface["SubType"] as? String == "com.liguangming.Shadowrocket",
                let connection = SCNetworkConnectionCreateWithServiceID(nil,identifier as CFString,nil,nil) else { continue }
            if SCNetworkConnectionGetStatus(connection) == .connected { return true }
        }
        return false
    }
    static func local() -> LocalState {
        let pid=NSRunningApplication.runningApplications(withBundleIdentifier:"com.liguangming.Shadowrocket").first?.processIdentifier
        if routePID != pid { routeElement=nil;nodeElement=nil;routePID=pid }
        var route=""
        if let element=routeElement {
            AXUIElementSetMessagingTimeout(element,1)
            route=AX.text(element,kAXDescriptionAttribute)
        }
        if !route.contains("全局路由") {
            routeElement=nil
            for element in AX.elements(bundleID:"com.liguangming.Shadowrocket") {
                let description=AX.text(element,kAXDescriptionAttribute)
                if description.contains("全局路由") { routeElement=element;route=description;break }
            }
        }
        if route.isEmpty { route="无法读取" }
        let node = selectedNode() ?? "无法读取"
        return LocalState(vpn:vpnConnected(),route:route,node:node,timezone:timezone,accessibility:AXIsProcessTrusted())
    }
    static func selectedNode() -> String? {
        if let nodeElement,let name=ProxyNodeIdentity.selectedName(in:AX.text(nodeElement,kAXDescriptionAttribute)) { return name }
        nodeElement=nil
        for element in AX.elements(bundleID:"com.liguangming.Shadowrocket") {
            guard AX.text(element,kAXRoleAttribute)==kAXButtonRole,
                  let name=ProxyNodeIdentity.selectedName(in:AX.text(element,kAXDescriptionAttribute)) else { continue }
            nodeElement=element;return name
        }
        return nil
    }
    static func verify(_ state: LocalState, settings:Settings, requireTimezone:Bool = true) throws {
        guard state.accessibility else { throw GuardFailure("请先在系统设置中允许 CC登录器 使用辅助功能，以核验 Shadowrocket 的路由状态") }
        guard state.vpn else { throw GuardFailure("Shadowrocket 未连接，或系统连接状态无法核验") }
        guard state.route.contains("全局路由"), state.route.contains("配置"), !state.route.contains("直连"), !state.route.contains("代理,") else { throw GuardFailure("全局路由不是“配置”，或控件状态无法读取") }
        guard state.node == settings.nodeName || state.node.contains("使用节点 " + settings.nodeName + ",") else { throw GuardFailure("当前节点不是指定节点："+settings.nodeName) }
        if requireTimezone && state.timezone != "America/New_York" { throw GuardFailure("系统时区已变化："+state.timezone) }
    }
    static func verifyRuntime(_ state:LocalState,settings:Settings) throws {
        let result=RuntimeAssessment.local(accessibility:state.accessibility,vpn:state.vpn,
            node:state.node=="无法读取" || state.node.isEmpty ? nil : state.node,
            route:state.route=="无法读取" || state.route.isEmpty ? nil : state.route,
            timezone:state.timezone,expectedNode:settings.nodeName)
        if !result.failures.isEmpty { throw RuntimeProbeFailure(result.failures.joined(separator:"；"),confirmed:true) }
        if !result.unknown.isEmpty { throw RuntimeProbeFailure(result.unknown.joined(separator:"；")) }
    }
}
enum Editors {
    static let appPath = "/Applications/Visual Studio Code.app"
    static func records() throws -> [ProcessRecord] {
        let result = try Commands.sync("/bin/ps",["-axo","pid=,ppid=,uid=,comm="],timeout:3)
        guard result.code == 0 else { throw GuardFailure("无法读取进程列表") }
        var records:[ProcessRecord]=[]
        for line in result.output.split(separator:"\n") {
            let cols = line.split(maxSplits:3,whereSeparator:{$0 == " " || $0 == "\t"})
            guard cols.count == 4, let pid = Int32(cols[0]),let ppid = Int32(cols[1]),let uid = UInt32(cols[2]) else { continue }
            var info=proc_bsdinfo()
            let length=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))
            guard length==MemoryLayout<proc_bsdinfo>.size else {
                if uid==getuid(),String(cols[3]).hasPrefix(appPath+"/"),kill(pid,0)==0 { throw GuardFailure("无法核验 VS Code 进程身份，未将其视为已退出") }
                continue
            }
            if info.pbi_status==SZOMB { continue }
            records.append(ProcessRecord(pid:pid,parent:ppid,uid:uid,path:URL(fileURLWithPath:String(cols[3])).resolvingSymlinksInPath().path,startSeconds:info.pbi_start_tvsec,startMicroseconds:info.pbi_start_tvusec))
        }
        return records
    }
    static func selected(root:String = Editors.appPath) throws -> [ProcessRecord] { EditorSelection.records(try records(),uid:getuid(),appPath:root) }
    static func closeAll(root:String = Editors.appPath) throws {
        var chosen = try selected(root:root)
        // Capture descendants before the editor is killed, so orphaned Claude processes stay covered.
        for _ in 0..<30 {
            for row in chosen.reversed() {
                var info=proc_bsdinfo()
                let length=proc_pidinfo(row.pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))
                if length==MemoryLayout<proc_bsdinfo>.size,info.pbi_status != SZOMB,
                    EditorSelection.sameProcess(row,ProcessRecord(pid:row.pid,parent:Int32(info.pbi_ppid),uid:info.pbi_uid,path:row.path,startSeconds:info.pbi_start_tvsec,startMicroseconds:info.pbi_start_tvusec)) {
                    _ = kill(row.pid,SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval:0.1)
            let all=try records()
            let live=all.filter{ record in chosen.contains(where:{EditorSelection.sameProcess($0,record)}) }
            let fresh=EditorSelection.records(all,uid:getuid(),appPath:root)
            chosen=Array(Dictionary((live+fresh).map{($0.pid,$0)},uniquingKeysWith:{$1}).values)
            if chosen.isEmpty { return }
        }
        throw GuardFailure("仍有 \(chosen.count) 个 VS Code 相关进程未退出")
    }
}
