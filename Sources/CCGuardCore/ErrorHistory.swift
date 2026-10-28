import Foundation

public enum HistoryLevel:String,Codable,CaseIterable {
    case error,warning
    public var title:String { self == .error ? "错误" : "提示" }
    public static func inferred(from message:String) -> HistoryLevel? {
        if ["已拦截：","发现异常：","启动失败：","退出核验失败："].contains(where:message.hasPrefix) { return .error }
        if ["提示：","检测浏览器暂未收起：","部分 Shadowrocket 窗口暂未收起","Shadowrocket 最小化后状态无法确认","部分时区工具窗口暂未收起"].contains(where:message.hasPrefix) { return .warning }
        return nil
    }
}

public struct HistoryEntry:Identifiable,Equatable {
    public let time:Date
    public let level:HistoryLevel
    public let message:String
    public let stage:String
    public let sessionID:String
    public let sourcePath:String
    public let details:String
    public var id:String { "\(sessionID)|\(time.timeIntervalSince1970)|\(level.rawValue)|\(message)" }

    public init(time:Date,level:HistoryLevel,message:String,stage:String = "",sessionID:String,sourcePath:String,details:String = "") {
        self.time=time;self.level=level;self.message=message;self.stage=stage
        self.sessionID=sessionID;self.sourcePath=sourcePath
        self.details=details
    }
    public static func decode(_ data:Data,sessionID:String,sourcePath:String) -> HistoryEntry? {
        guard let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let stamp=object["time"] as? String,let message=object["message"] as? String,
              let level=(object["level"] as? String).flatMap(HistoryLevel.init(rawValue:)) ?? HistoryLevel.inferred(from:message) else { return nil }
        let formatter=ISO8601DateFormatter()
        var date=formatter.date(from:stamp)
        if date==nil { formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds];date=formatter.date(from:stamp) }
        guard let time=date else { return nil }
        let details=[("IP","ip"),("评分","score"),("网页","webStatus"),("读数","webReadings")].compactMap { label,key -> String? in
            guard let value=object[key] as? String,!value.isEmpty,value != "—" else { return nil }
            return label+"："+value
        }.joined(separator:" · ")
        return HistoryEntry(time:time,level:level,message:message,stage:object["stage"] as? String ?? "",sessionID:sessionID,sourcePath:sourcePath,details:details)
    }
    public static func merging(_ entries:[HistoryEntry]) -> [HistoryEntry] {
        var seen=Set<String>()
        return entries.filter{seen.insert($0.id).inserted}.sorted {
            $0.time == $1.time ? $0.id > $1.id : $0.time > $1.time
        }
    }
}

public struct HistoryLoadResult {
    public let entries:[HistoryEntry]
    public let unreadableFiles:Int
}

public enum ErrorHistory {
    public static func load(root:URL) -> HistoryLoadResult {
        var files:[URL]=[]
        let main=root.appendingPathComponent("events.jsonl")
        if FileManager.default.fileExists(atPath:main.path) { files.append(main) }
        if let iterator=FileManager.default.enumerator(at:root.appendingPathComponent("Sessions"),includingPropertiesForKeys:[.contentModificationDateKey],options:.skipsHiddenFiles) {
            for case let file as URL in iterator where ["events.jsonl","watchdog-stop.json","watchdog-error.json"].contains(file.lastPathComponent) { files.append(file) }
        }
        var entries:[HistoryEntry]=[]
        var unreadable=0
        for file in files {
            guard let data=try? Data(contentsOf:file) else { unreadable += 1;continue }
            let session=file==main ? "全局记录" : file.deletingLastPathComponent().lastPathComponent
            if file.lastPathComponent=="events.jsonl" {
                for line in data.split(separator:10) {
                    if let entry=HistoryEntry.decode(Data(line),sessionID:session,sourcePath:file.path) { entries.append(entry) }
                }
            } else if let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                // Normal “结束使用” also notifies the watchdog; it is not an error.
                let explicitlyStopped=FileManager.default.fileExists(atPath:file.deletingLastPathComponent().appendingPathComponent("stop-request").path)
                if file.lastPathComponent=="watchdog-stop.json" && explicitlyStopped { continue }
                guard let message=(object["reason"] ?? object["error"]) as? String else { continue }
                let stamp=(object["time"] as? String).flatMap{ISO8601DateFormatter().date(from:$0)}
                let modified=(try? file.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate
                entries.append(HistoryEntry(time:stamp ?? modified ?? Date(timeIntervalSince1970:0),level:.error,message:message,stage:"独立守护",sessionID:session,sourcePath:file.path))
            }
        }
        return HistoryLoadResult(entries:HistoryEntry.merging(entries),unreadableFiles:unreadable)
    }
}
