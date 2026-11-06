import Foundation

/// Local-only credentials. Never included in the web bundle or protocol replies.
struct AIConfiguration: Codable, Sendable {
    struct Model: Codable, Sendable {
        var apiKey: String
        var baseURL: String
        var model: String
    }
    struct Speech: Codable, Sendable {
        var provider: String
        var apiKey: String
        var model: String
        var workspace: String?
    }
    var provider: String
    var deepseek: Model
    var qwen: Model
    var speech: Speech
    static var empty: Self {
        Self(provider:"deepseek",
             deepseek:Model(apiKey:"",baseURL:"https://api.deepseek.com/v1",model:"deepseek-flash"),
             qwen:Model(apiKey:"",baseURL:"https://dashscope.aliyuncs.com/compatible-mode/v1",model:"qwen-flash"),
             speech:Speech(provider:"aliyun",apiKey:"",model:"qwen3-asr-flash-realtime",workspace:nil))
    }
    static var fileURL: URL {
        if let path = ProcessInfo.processInfo.environment["CMDPALM_AI_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appending(path:"CmdPalmAI-tests-" + String(ProcessInfo.processInfo.processIdentifier) + "/ai-config.json")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CmdPalm AI/ai-config.json")
    }
    static func load() -> Self? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,
                                               attributes:[.posixPermissions:0o700])
        let data = try JSONEncoder().encode(self)
        let temporary = url.deletingLastPathComponent().appending(path:".ai-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath:temporary.path,contents:data,attributes:[.posixPermissions:0o600]) else {
            throw IntentPlanError("无法写入私人配置。")
        }
        if FileManager.default.fileExists(atPath:url.path) { _ = try FileManager.default.replaceItemAt(url,withItemAt:temporary) }
        else { try FileManager.default.moveItem(at:temporary,to:url) }
    }
    var model: Model { provider == "qwen" ? qwen : deepseek }
}
