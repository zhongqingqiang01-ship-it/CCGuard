import XCTest
@testable import CCGuardCore

final class ProxyNodeIdentityTests:XCTestCase {
    func testSelectedButtonProvidesExactNameWithoutProtocolOrLatency() {
        XCTAssertEqual(ProxyNodeIdentity.selectedName(in:"使用节点 美国 示例 192.0.2.10 · 主线, VLESS / UDP, 135ms"),"美国 示例 192.0.2.10 · 主线")
        XCTAssertEqual(ProxyNodeIdentity.selectedName(in:"使用节点 备用节点，VLESS，200ms"),"备用节点")
    }
    func testUnselectedOrEmptyNodeCannotPassAsSelected() {
        for text in ["美国 示例 192.0.2.10 · 主线, VLESS", "", "使用节点 ", "未使用节点 主线"] {
            XCTAssertNil(ProxyNodeIdentity.selectedName(in:text))
        }
    }
    func testChangingSelectionInvalidatesPreviousButtonValue() {
        let oldValue="使用节点 主线, VLESS"
        let changedValue="主线, VLESS"
        XCTAssertEqual(ProxyNodeIdentity.selectedName(in:oldValue),"主线")
        XCTAssertNil(ProxyNodeIdentity.selectedName(in:changedValue))
        XCTAssertEqual(ProxyNodeIdentity.selectedName(in:"使用节点 备用, VLESS"),"备用")
    }
}
