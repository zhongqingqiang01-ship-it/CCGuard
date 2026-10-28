import Foundation
import CryptoKit
import CCGuardCore

struct NetworkConfiguration {
    let environment:[String:String]
    let fingerprint:String
    static func read(settings:Settings) throws -> NetworkConfiguration {
        var environment=ProcessInfo.processInfo.environment
        let proxyKeys=["http_proxy","https_proxy","HTTP_PROXY","HTTPS_PROXY","NO_PROXY","no_proxy","ALL_PROXY","all_proxy"]
        var fingerprintParts:[String]=[]
        var editorProxy=""
        var editorProxySupport="override"
        let home=NSHomeDirectory()
        let files=[home+"/Library/Application Support/Code/User/settings.json",home+"/.claude/settings.json",settings.workspace+"/.vscode/settings.json",settings.workspace+"/.claude/settings.json",settings.workspace+"/.claude/settings.local.json"]
        for path in files {
            guard FileManager.default.fileExists(atPath:path) else { continue }
            let data=try Data(contentsOf:URL(fileURLWithPath:path))
            guard let document=try JSONSerialization.jsonObject(with:data,options:[.json5Allowed]) as? [String:Any] else { throw GuardFailure("网络配置文件格式无法核验："+URL(fileURLWithPath:path).lastPathComponent) }
            if let proxy=document["http.proxy"] as? String { editorProxy=proxy }
            if let support=document["http.proxySupport"] as? String { editorProxySupport=support }
            if let env=document["env"] as? [String:Any] {
                for (key,value) in env { if let text=value as? String { environment[key]=text } }
            }
            if let entries=document["claudeCode.environmentVariables"] as? [[String:String]] {
                for entry in entries { if let name=entry["name"],let value=entry["value"] { environment[name]=value } }
            }
        }
        guard editorProxy.isEmpty || editorProxySupport=="off" else { throw GuardFailure("VS Code 配有独立代理，当前无法确认扩展与检测路径一致；请先核对该配置") }
        fingerprintParts.append("editorProxy:"+editorProxy+":"+editorProxySupport)
        for key in ["ANTHROPIC_BASE_URL","CLAUDE_CODE_USE_BEDROCK","CLAUDE_CODE_USE_VERTEX","CLAUDE_CODE_USE_FOUNDRY"] {
            fingerprintParts.append(key+":"+(environment[key] ?? ""))
        }
        for key in ["CLAUDE_CODE_USE_BEDROCK","CLAUDE_CODE_USE_VERTEX","CLAUDE_CODE_USE_FOUNDRY"] where environment[key]=="1" {
            throw GuardFailure("当前首版仅核验本地官方 Claude Code 网络，检测到其他提供方配置")
        }
        if let raw=environment["ANTHROPIC_BASE_URL"],!raw.isEmpty {
            guard let u=URL(string:raw),u.scheme=="https",u.host=="api.anthropic.com" else { throw GuardFailure("检测到自定义 Claude 接口，无法以官方出口检测证明其路径") }
        }
        // Claude uses HTTPS/HTTP env proxies. Do not silently substitute a SOCKS route.
        for key in proxyKeys {
            if let value=environment[key],!value.isEmpty {
                if !key.lowercased().contains("no_proxy") {
                    guard let u=URL(string:value),["https","http"].contains(u.scheme?.lowercased() ?? "") else { throw GuardFailure("检测到不支持的代理配置："+key) }
                }
                fingerprintParts.append(key+":"+value)
            }
        }
        let fingerprint=SHA256.hash(data:Data(fingerprintParts.joined(separator:"\n").utf8)).map{String(format:"%02x",$0)}.joined()
        return NetworkConfiguration(environment:environment,fingerprint:fingerprint)
    }
    func checkExit(expectedIP:String) async throws {
        for host in ["https://claude.ai/cdn-cgi/trace","https://1.1.1.1/cdn-cgi/trace"] {
            let result=try await Commands.run("/usr/bin/curl",["--fail","--silent","--show-error","--max-time","8",host],timeout:9,environment:environment)
            guard result.code==0 else { throw GuardFailure("Claude Code 网络路径探测失败，未沿用浏览器的通过结果") }
            let ip=result.output.split(separator:"\n").first(where:{$0.hasPrefix("ip=")}).map{String($0.dropFirst(3))}
            guard ip==expectedIP else { throw GuardFailure("Claude Code 网络探测出口与指定 IP 不一致") }
        }
    }
    func runtimeProbe(roundID:String,expectedIP:String,stopOnMismatch:Bool = true,
                      onConfirmed:@escaping @MainActor @Sendable (String) async -> Void = { _ in }) async throws -> RuntimeObservation {
        struct Reading:Sendable { let name:ExitSource;let ip:String?;let reachable:Bool }
        let environment=self.environment
        return try await withThrowingTaskGroup(of:Reading.self) { group in
            for (name,url) in [(ExitSource.claude,"https://claude.ai/cdn-cgi/trace"),
                               (.cloudflare,"https://1.1.1.1/cdn-cgi/trace"),
                               (.anthropic,"https://www.anthropic.com/cdn-cgi/trace"),
                               (.china,"https://2026.ip138.com/")] {
                group.addTask {
                    func request(_ url:String) async -> CommandResult? {
                        try? await Commands.run("/usr/bin/curl",["--fail","--silent","--show-error","--location","--proto","=https","--proto-redir","=https","--connect-timeout","4","--max-time","8","--max-filesize","1048576","--header","Cache-Control: no-cache",url],timeout:9,environment:environment)
                    }
                    var response=await request(url)
                    if name == .china,response?.code != 0 { response=await request("https://my.ip.cn/") }
                    let succeeded=response?.code==0
                    let text=succeeded ? response?.output ?? "" : ""
                    let ip=name == .china ? RuntimeProbeParsing.chinaIP(text) : RuntimeProbeParsing.traceIP(text)
                    if stopOnMismatch,name.requiresExpectedIP,let ip,ip != expectedIP {
                        let message="后台 \(name.title)与指定 IP 不一致：当前 \(ip)，指定 \(expectedIP)"
                        await onConfirmed(message)
                        throw RuntimeProbeFailure(message,confirmed:true)
                    }
                    return Reading(name:name,ip:ip,reachable:succeeded)
                }
            }
            var observation=RuntimeObservation(roundID:roundID,collectedAt:Date().timeIntervalSince1970*1000)
            for try await reading in group {
                switch reading.name {
                case .claude:observation.claudeIP=reading.ip;observation.claudeReachable=reading.reachable
                case .cloudflare:observation.cloudflareIP=reading.ip
                case .china:
                    observation.chinaIP=reading.ip
                    observation.details["国内出口（允许智能分流）"]=reading.ip ?? "暂未获取"
                case .anthropic:observation.anthropicReachable=reading.reachable
                }
            }
            observation.collectedAt=Date().timeIntervalSince1970*1000
            return observation
        }
    }
}
