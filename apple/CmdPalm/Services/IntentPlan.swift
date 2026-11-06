import Foundation
import CoreFoundation

struct IntentPlanError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// This validator, rather than the prompt, defines what an AI may execute.
enum IntentPlan {
    static let systems: Set<String> = [
        "newTab", "closeTab", "closeWindow", "minimize", "hideApp", "showDesktop",
        "fullscreen", "copy", "paste", "cut", "selectAll", "undo", "redo",
        "reload", "back", "forward", "nextTab", "previousTab", "missionControl",
        "appExpose", "spotlight", "lockScreen"
    ]
    static let media: Set<String> = ["volumeUp", "volumeDown", "mute", "playPause", "next", "previous"]
    static func boolean(_ x: Any?) -> Bool? {
        guard let n = x as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    static func number(_ x: Any?) -> Double? {
        guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func validate(_ input: [String: Any], appIDs: Set<String>) throws -> [String: Any] {
        guard let decision = input["decision"] as? String,
              ["execute", "clarify", "noop", "unsupported"].contains(decision) else {
            throw IntentPlanError("没有取得明确的任务计划，原话已保留。")
        }
        var plan: [String: Any] = ["decision": decision]
        for key in ["summary", "message"] {
            if let value = input[key] as? String { plan[key] = String(value.prefix(400)) }
        }
        guard decision == "execute" else { plan["steps"] = []; return plan }
        guard let steps = input["steps"] as? [[String: Any]], !steps.isEmpty, steps.count <= 8 else {
            throw IntentPlanError("一个任务需要 1 至 8 个明确步骤。")
        }
        for step in steps {
            guard let kind = step["kind"] as? String else { throw IntentPlanError("步骤缺少动作类型。") }
            let fields: Set<String>
            switch kind {
            case "app":
                fields = ["kind", "id", "op"]
                guard let id = step["id"] as? String, appIDs.contains(id),
                      let op = step["op"] as? String, ["open", "hide", "quit"].contains(op) else {
                    throw IntentPlanError("没有确认目标应用。")
                }
            case "text":
                fields = ["kind", "text", "enter"]
                guard let text = step["text"] as? String, !text.isEmpty, text.utf8.count <= 16_384,
                      (step["enter"] == nil || boolean(step["enter"]) == false) else {
                    throw IntentPlanError("输入文字不能为空，也不能自动发送消息。")
                }
            case "folder":
                fields = ["kind", "name"]
                guard let name = step["name"] as? String, ["downloads","desktop","documents","home"].contains(name) else {
                    throw IntentPlanError("请选择下载、桌面、文档或个人文件夹。")
                }
            case "url":
                fields = ["kind", "url", "app"]
                guard let text = step["url"] as? String, let url = URL(string: text),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    throw IntentPlanError("网页地址无效。")
                }
                if step["app"] != nil {
                    guard let app = step["app"] as? String, appIDs.contains(app),
                          ["com.apple.Safari","com.google.Chrome","org.mozilla.firefox","com.microsoft.edgemac",
                           "company.thebrowser.Browser","com.brave.Browser","com.operasoftware.Opera"].contains(app) else {
                        throw IntentPlanError("没有确认打开网页的浏览器。")
                    }
                }
            case "system":
                fields = ["kind", "name"]
                guard let name = step["name"] as? String, systems.contains(name) else {
                    throw IntentPlanError("当前基础版还不支持这个系统操作。")
                }
            case "media":
                fields = ["kind", "key"]
                guard let key = step["key"] as? String, media.contains(key) else {
                    throw IntentPlanError("媒体操作无效。")
                }
            case "volume":
                fields = ["kind", "value", "delta", "muted"]
                let value = number(step["value"]), delta = number(step["delta"])
                guard !(value != nil && delta != nil),
                      value.map({ (0...1).contains($0) }) ?? true,
                      delta.map({ (-1...1).contains($0) && $0 != 0 }) ?? true,
                      (step["value"] == nil || value != nil), (step["delta"] == nil || delta != nil),
                      (step["muted"] == nil || boolean(step["muted"]) != nil),
                      value != nil || delta != nil || boolean(step["muted"]) != nil else {
                    throw IntentPlanError("音量数值无效。")
                }
            default:
                throw IntentPlanError("当前基础版不执行脚本、自动发消息或任意点击。")
            }
            guard Set(step.keys).isSubset(of: fields) else { throw IntentPlanError("步骤包含未支持的参数。") }
        }
        plan["steps"] = steps
        return plan
    }
    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"decision\":\"clarify\",\"message\":\"任务计划无效。\",\"steps\":[]}" }
        return text
    }
    static func outcome(_ decision: String, _ message: String, steps: [[String: Any]] = []) -> [String: Any] {
        ["decision": decision, "summary": message, "message": message, "steps": steps]
    }
    static func local(_ raw: String, apps: [[String: String]], context: [String: Any] = [:]) -> [String: Any]? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = text.replacingOccurrences(of: "[。！!？?.]+$", with: "", options: .regularExpression).lowercased()
        if ["你好", "您好", "hello", "hi", "谢谢", "thanks", "不用操作", "算了"].contains(clean) {
            return outcome("noop", "已听到，这句话没有执行电脑操作。")
        }
        if ["everything", "全部", "那个", "这个", "它"].contains(clean) {
            return outcome("clarify", "你想操作哪个应用，做什么？")
        }
        if let range = text.range(of: #"^(?i:please\s+)?type\s+(?i:this\s+exactly|the\s+following)\s*:\s*"#,options:.regularExpression) {
            let payload = String(text[range.upperBound...])
            if !payload.isEmpty { return outcome("execute","原样输入文字",steps:[["kind":"text","text":payload,"enter":false]]) }
        }
        if text.range(of:"(?:刚才|之前|上次).*(?:哪个|什么).*应用",options:.regularExpression) != nil {
            if let id = context["recentApp"] as? String, let app = apps.first(where:{$0["id"] == id}) {
                return outcome("noop","刚才操作的是" + (app["name"] ?? id) + "。")
            }
            return outcome("clarify","这台手机还没有近期操作的应用记录，你指的是哪个应用？")
        }
        if text.hasPrefix("输入") || text.hasPrefix("原文：") || text.lowercased().hasPrefix("type ") {
            let prefix = text.hasPrefix("原文：") ? 3 : text.lowercased().hasPrefix("type ") ? 5 : 2
            var payload = String(text.dropFirst(prefix))
            if payload.hasPrefix("：") || payload.hasPrefix(":") { payload.removeFirst() }
            guard !payload.isEmpty else { return outcome("clarify", "你要输入什么文字？") }
            return outcome("execute", "原样输入文字", steps: [["kind":"text", "text":payload, "enter":false]])
        }
        let aliases = ["微信":"com.tencent.xinWeChat", "访达":"com.apple.finder", "finder":"com.apple.finder",
                       "chrome":"com.google.Chrome", "谷歌浏览器":"com.google.Chrome", "safari":"com.apple.Safari",
                       "备忘录":"com.apple.Notes", "文本编辑":"com.apple.TextEdit", "vscode":"com.microsoft.VSCode"]
        for app in apps {
            let id = app["id"] ?? ""
            let names = [app["name"] ?? ""] + aliases.filter { $0.value == id }.map { $0.key }
            for name in names where !name.isEmpty {
                let escaped = NSRegularExpression.escapedPattern(for:name.lowercased())
                let polite = "(?:(?:请|帮我|麻烦你?|给我)\\s*){0,2}(?:把\\s*)?"
                let leading = "^" + polite + "(?:打开|启动|切到|切换到)\\s*" + escaped + "(?:\\s*(?:一下|吧))?$"
                let trailing = "^" + polite + escaped + "\\s*(?:打开|启动|调出来|叫出来|切到前台|切换到前台)(?:一下|吧)?$"
                if clean.range(of:leading,options:.regularExpression) != nil || clean.range(of:trailing,options:.regularExpression) != nil ||
                   clean == "打开" + name.lowercased() || clean == "open " + name.lowercased() {
                    return outcome("execute", "打开" + name, steps: [["kind":"app","id":id,"op":"open"]])
                }
                let prefix = name + "输入"
                if text.lowercased().hasPrefix(prefix.lowercased()) {
                    var payload = String(text.dropFirst(prefix.count))
                    if payload.hasPrefix("：") || payload.hasPrefix(":") { payload.removeFirst() }
                    if !payload.isEmpty { return outcome("execute", "向" + name + "原样输入", steps: [
                        ["kind":"app","id":id,"op":"open"],["kind":"text","text":payload,"enter":false]]) }
                }
            }
        }
        let fixed = ["复制":"copy","粘贴":"paste","撤销":"undo","重做":"redo","全选":"selectAll",
                     "新建标签页":"newTab","关闭标签页":"closeTab","最小化窗口":"minimize","显示桌面":"showDesktop"]
        if let name = fixed[clean] { return outcome("execute", text, steps: [["kind":"system","name":name]]) }
        if ["声音小点","音量小点"].contains(clean) { return outcome("execute", "调低音量", steps: [["kind":"volume","delta":-0.1]]) }
        if ["声音大点","音量大点"].contains(clean) { return outcome("execute", "调高音量", steps: [["kind":"volume","delta":0.1]]) }
        return nil
    }
}
