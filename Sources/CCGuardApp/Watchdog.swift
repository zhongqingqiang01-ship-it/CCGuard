import Foundation
import CCGuardCore
import Darwin

struct WorkerHeartbeat:Codable { var nonce:String; var uptime:Double; var armed:Bool; var pid:Int32 }
@MainActor final class WatchdogClient {
    let directory:URL
    let nonce=UUID().uuidString
    private var process:Process?
    private(set) var armed=false
    init() {
        directory=Settings.support.appendingPathComponent("Sessions/"+UUID().uuidString)
    }
    var leaseURL:URL { directory.appendingPathComponent("lease.json") }
    var workerURL:URL { directory.appendingPathComponent("worker.json") }
    func start() throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try pulse()
        guard let executable=Bundle.main.executableURL else { throw GuardFailure("无法定位守护组件") }
        let p=Process();p.executableURL=executable;p.arguments=["--watchdog",String(getpid()),directory.path,nonce]
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try p.run();process=p
    }
    func pulse() throws {
        let lease=Lease(nonce:nonce,parentPID:getpid(),armed:armed,heartbeat:ProcessInfo.processInfo.systemUptime)
        try JSONEncoder().encode(lease).write(to:leaseURL,options:.atomic)
    }
    func arm() async throws {
        guard process?.isRunning==true else { throw GuardFailure("后台守护未运行") }
        armed=true;try pulse()
        for _ in 0..<30 {
            if let h=try? JSONDecoder().decode(WorkerHeartbeat.self,from:Data(contentsOf:workerURL)),h.nonce==nonce,h.armed,ProcessInfo.processInfo.systemUptime-h.uptime<2 { return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw GuardFailure("后台守护未确认接管，禁止启动 VS Code")
    }
    func disarm() throws { armed=false;try pulse() }
    func requestStop() throws {
        try Data(nonce.utf8).write(to:directory.appendingPathComponent("stop-request"),options:.atomic)
    }
    func verify() throws {
        guard process?.isRunning==true,let data=try? Data(contentsOf:workerURL),let h=try? JSONDecoder().decode(WorkerHeartbeat.self,from:data),h.nonce==nonce,h.uptime<=ProcessInfo.processInfo.systemUptime,ProcessInfo.processInfo.systemUptime-h.uptime<3 else { throw GuardFailure("独立守护心跳失效") }
    }
    func stop() { if !armed { process?.terminate();process=nil } }
}
func runWatchdog(parentPID:Int32,directory:URL,nonce:String,fixtureRoot:String? = nil) -> Never {
    let leaseURL=directory.appendingPathComponent("lease.json"),workerURL=directory.appendingPathComponent("worker.json")
    var wasArmed=false
    while true {
        let uptime=ProcessInfo.processInfo.systemUptime
        let lease=(try? Data(contentsOf:leaseURL)).flatMap{try? JSONDecoder().decode(Lease.self,from:$0)}
        let valid=lease?.valid(nonce:nonce,parentPID:parentPID,uptime:uptime)==true
        if valid { wasArmed=lease!.armed }
        let parentAlive=kill(parentPID,0)==0
        let revoked=(try? String(contentsOf:directory.appendingPathComponent("stop-request"),encoding:.utf8))==nonce
        if (!valid || !parentAlive || revoked) && wasArmed {
            do {
                try Editors.closeAll(root:fixtureRoot ?? Editors.appPath)
                let record:[String:Any]=["reason":"界面进程退出或心跳超时，独立守护已结束 VS Code","time":ISO8601DateFormatter().string(from:Date())]
                try? JSONSerialization.data(withJSONObject:record).write(to:directory.appendingPathComponent("watchdog-stop.json"),options:.atomic)
                exit(0)
            } catch {
                // Retain a bounded diagnostic, and retry until selected processes exit.
                let record=["error":error.localizedDescription]
                try? JSONSerialization.data(withJSONObject:record).write(to:directory.appendingPathComponent("watchdog-error.json"),options:.atomic)
            }
        } else if !parentAlive && !wasArmed { exit(0) }
        let heartbeat=WorkerHeartbeat(nonce:nonce,uptime:uptime,armed:wasArmed,pid:getpid())
        try? JSONEncoder().encode(heartbeat).write(to:workerURL,options:.atomic)
        Thread.sleep(forTimeInterval:0.25)
    }
}
