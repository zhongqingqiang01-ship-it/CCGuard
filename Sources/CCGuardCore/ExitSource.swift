/// Domestic requests may deliberately bypass the proxy under split routing.
public enum ExitSource:String,Sendable {
    case china,cloudflare,claude,anthropic
    public var requiresExpectedIP:Bool { self == .claude || self == .cloudflare }
    public var title:String {
        switch self {
        case .china:return "中国出口"
        case .cloudflare:return "Cloudflare 出口"
        case .claude:return "Claude 出口"
        case .anthropic:return "Anthropic 连通性"
        }
    }
}
