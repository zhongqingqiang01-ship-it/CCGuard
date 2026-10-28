import Foundation

public enum ClaudeViewIdentity {
    public static func isConversationWebView(_ url:String)->Bool {
        guard let components=URLComponents(string:url),components.scheme=="vscode-webview",
            components.user==nil,components.password==nil,components.host?.isEmpty==false else { return false }
        let identifiers=components.queryItems?.filter{$0.name=="extensionId"}.compactMap(\.value) ?? []
        return identifiers.count==1 && identifiers[0].lowercased()=="anthropic.claude-code"
    }
}
