import SwiftUI

struct AIPane: View {
    @Environment(HostController.self) private var host
    @State private var config = AIConfiguration.load() ?? .empty
    @State private var message = ""
    private var aliyunKey: Binding<String> {
        Binding(get:{ config.speech.apiKey },set:{ config.speech.apiKey = $0; config.qwen.apiKey = $0 })
    }
    var body: some View {
        Form {
            Section("意图理解") {
                Picker("模型", selection: $config.provider) {
                    Text("DeepSeek").tag("deepseek")
                    Text("千问").tag("qwen")
                }
                Text(config.model.model).foregroundStyle(.secondary)
                Text("明确短指令直接处理；日常说法交给模型。模型只规划受支持的基础操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("实时语音") {
                Picker("识别方式",selection: $config.speech.provider) {
                    Text("阿里云实时识别").tag("aliyun")
                    Text("Mac 本机 Apple 识别").tag("apple")
                }
                Text("阿里云模式会发送录音到阿里云北京；Apple 模式在此 Mac 本机处理。手机也可直接使用键盘听写输入文字。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本机凭据") {
                SecureField("DeepSeek API Key",text:$config.deepseek.apiKey)
                SecureField("阿里云 API Key（语音与千问）",text:aliyunKey)
                LabeledContent("理解服务",value: config.model.apiKey.isEmpty ? "未配置" : "已配置")
                LabeledContent("阿里云语音",value: config.speech.apiKey.isEmpty ? "未配置" : "已配置")
                Text("Key 保存在 Mac 的私人配置文件中，不会返回手机或放入仓库。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存设置") {
                    do {
                        try config.save()
                        host.restart()
                        message = "已保存。手机会重新连接。"
                    } catch { message = "保存失败，请检查本机文件权限。" }
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }
        }.settingsForm()
    }
}
