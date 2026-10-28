import Foundation

public enum ProxyNodeIdentity {
    public static func selectedName(in description:String) -> String? {
        let prefix="使用节点 "
        guard description.hasPrefix(prefix) else { return nil }
        let name=description.dropFirst(prefix.count).split(whereSeparator:{$0=="," || $0=="，"}).first?
            .trimmingCharacters(in:.whitespacesAndNewlines)
        guard let name,!name.isEmpty else { return nil }
        return name
    }
}
