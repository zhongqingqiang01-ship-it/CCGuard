import XCTest
@testable import CCGuardCore

final class ClaudeViewIdentityTests:XCTestCase {
    func testActualObservedExtensionWebViewIsAccepted() {
        XCTAssertTrue(ClaudeViewIdentity.isConversationWebView("vscode-webview://view/index.html?id=123&extensionId=Anthropic.claude-code&platform=electron"))
    }
    func testToolbarLabelsAndWelcomePageCannotPretendToBeTheConversation() {
        for value in ["Claude Code: Open","Claude Code — project","vscode-file://vscode-app/workbench.html","vscode-webview://view/index.html?extensionId=github.copilot-chat","https://view/index.html?extensionId=Anthropic.claude-code"] {
            XCTAssertFalse(ClaudeViewIdentity.isConversationWebView(value))
        }
    }
    func testMissingAndDuplicateIdentitiesFail() {
        XCTAssertFalse(ClaudeViewIdentity.isConversationWebView("vscode-webview://view/index.html"))
        XCTAssertFalse(ClaudeViewIdentity.isConversationWebView("vscode-webview://view/index.html?extensionId=Anthropic.claude-code&extensionId=evil"))
    }
}
