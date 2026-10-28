import AppKit
import ApplicationServices

struct MinimizedWindows {
    let windows:[AXUIElement]
    let failedCount:Int
    func restore() {
        for window in windows {
            _=AXUIElementSetAttributeValue(window,kAXMinimizedAttribute as CFString,kCFBooleanFalse)
        }
    }
}

enum AuxiliaryWindows {
    static func restore(bundleID:String) {
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first else { return }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.35)
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(root,kAXWindowsAttribute as CFString,&value) == .success,
              let windows=value as? [AXUIElement] else { return }
        for window in windows where AX.text(window,kAXSubroleAttribute)==kAXStandardWindowSubrole {
            _=AXUIElementSetAttributeValue(window,kAXMinimizedAttribute as CFString,kCFBooleanFalse)
        }
    }
    /// Minimize windows without closing the application or disconnecting its service.
    static func minimize(bundleID:String) -> MinimizedWindows {
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first else {
            return MinimizedWindows(windows:[],failedCount:0)
        }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.35)
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(root,kAXWindowsAttribute as CFString,&value) == .success,
              let windows=value as? [AXUIElement] else { return MinimizedWindows(windows:[],failedCount:1) }
        var changed:[AXUIElement]=[]
        var failures=0
        for window in windows where AX.text(window,kAXSubroleAttribute)==kAXStandardWindowSubrole {
            var minimized:CFTypeRef?
            if AXUIElementCopyAttributeValue(window,kAXMinimizedAttribute as CFString,&minimized) == .success,
               minimized as? Bool == true { continue }
            if AXUIElementSetAttributeValue(window,kAXMinimizedAttribute as CFString,kCFBooleanTrue) == .success {
                changed.append(window)
            } else { failures += 1 }
        }
        return MinimizedWindows(windows:changed,failedCount:failures)
    }
}
