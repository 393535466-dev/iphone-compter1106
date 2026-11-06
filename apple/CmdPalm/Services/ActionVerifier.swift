import AppKit
import ApplicationServices
import Synchronization

/// Read-back data stays on this Mac; the phone receives only opaque receipts and outcomes.
enum ActionVerifier {
    private final class TextSnapshot: @unchecked Sendable {
        let at = Date()
        let pid: pid_t
        let element: AXUIElement
        let expected: String
        let value: String
        init(pid: pid_t, element: AXUIElement, expected: String, value: String) {
            self.pid = pid; self.element = element; self.expected = expected; self.value = value
        }
    }
    private static let snapshots = Mutex<[String: TextSnapshot]>([:])
    static func verify(_ json: String) -> String {
        guard let data = json.data(using:.utf8),
              let action = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            return response("unverified", "操作结果未确认。")
        }
        let kind = action["kind"] as? String ?? ""
        if kind == "app", let id = action["id"] as? String {
            let op = action["op"] as? String ?? "open"
            let end = Date().addingTimeInterval(1.2)
            repeat {
                let app = NSRunningApplication.runningApplications(withBundleIdentifier:id).first
                if op == "quit" && app == nil { return response("verified", "应用已退出。") }
                if op == "open" && app?.isActive == true { return response("verified", "应用已切到前台。") }
                if op == "hide" && app?.isHidden == true { return response("verified", "应用已隐藏。") }
                Thread.sleep(forTimeInterval:0.05)
            } while Date() < end
            return response("unverified", "应用操作已发送，但未确认预期状态，请核对。")
        }
        if kind == "text", let expected = action["text"] as? String {
            if action["prepare"] as? Bool == true { return prepare(expected) }
            guard let receipt = action["receipt"] as? String,
                  let before = snapshots.withLock({ $0.removeValue(forKey:receipt) }),
                  before.at.timeIntervalSinceNow > -60, before.expected == expected else {
                return response("unverified", "文字已发送，输入位置无法读回，请核对内容。")
            }
            let end = Date().addingTimeInterval(1)
            repeat {
                if let (pid, field) = focused(), pid == before.pid, CFEqual(field,before.element),
                   let text = value(field), text == before.value {
                    return response("verified", "已核对本次插入的完整原文。")
                }
                Thread.sleep(forTimeInterval:0.05)
            } while Date() < end
            return response("unverified", "文字已发送，但内容或输入位置未与本次预期完全一致，请核对。")
        }
        return response("unverified", "操作已发送，请核对 Mac 上的结果。")
    }
    private static func prepare(_ expected: String) -> String {
        snapshots.withLock { $0 = $0.filter { $0.value.at.timeIntervalSinceNow > -60 } }
        guard expected.utf8.count <= 16_384, let (pid, field) = focused(), let old = value(field),
              old.utf16.count <= 1_000_000 else {
            return response("unverified", "当前应用不能读回输入位置。")
        }
        var selection: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,&selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
              AXValueGetValue(selection as! AXValue,.cfRange,&range),
              range.location >= 0, range.length >= 0, range.location + range.length <= old.utf16.count else {
            return response("unverified", "当前应用不能读回输入位置。")
        }
        let new = (old as NSString).replacingCharacters(in:NSRange(location:range.location,length:range.length),with:expected)
        let receipt = UUID().uuidString
        snapshots.withLock {
            if $0.count >= 16 { $0.removeAll() }
            $0[receipt] = TextSnapshot(pid:pid,element:field,expected:expected,value:new)
        }
        DispatchQueue.global().asyncAfter(deadline:.now()+60) {
            _ = snapshots.withLock { $0.removeValue(forKey:receipt) }
        }
        return IntentPlan.json(["state":"prepared","receipt":receipt])
    }
    private static func focused() -> (pid_t, AXUIElement)? {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(front.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application,kAXFocusedUIElementAttribute as CFString,&focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (front.processIdentifier,focused as! AXUIElement)
    }
    private static func value(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXValueAttribute as CFString,&value) == .success else { return nil }
        return value as? String
    }
    private static func response(_ state: String, _ message: String) -> String {
        IntentPlan.json(["state":state,"message":message])
    }
}
