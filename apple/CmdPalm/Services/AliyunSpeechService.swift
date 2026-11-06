import Foundation

/// Credentials and streaming sockets stay on the Mac. A single silent warm connection expires after 20 seconds.
final class AliyunSpeechService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.cmdpalm.ai.asr")
    private let update: @Sendable (UInt64, VoiceUpdate) -> Void
    private var sessions: [UInt64: Session] = [:]
    private var prepared: Session?
    private final class Session: @unchecked Sendable {
        let socket: URLSessionWebSocketTask
        let configuration: String
        var id: UInt64 = 0
        var active = false
        var locale = "zh"
        var ready = false
        var stopping = false
        var pending: [Data] = []
        var pendingBytes = 0
        var audioBytes = 0
        var items: [String: String] = [:]
        var finals = Set<String>()
        init(socket: URLSessionWebSocketTask, configuration: String) { self.socket = socket; self.configuration = configuration }
    }
    init(update: @escaping @Sendable (UInt64, VoiceUpdate) -> Void) { self.update = update }
    static var configured: Bool {
        guard let speech = AIConfiguration.load()?.speech else { return false }
        return speech.provider == "aliyun" && !speech.apiKey.isEmpty
    }
    private func makeSession() -> Session? {
        guard let c = AIConfiguration.load()?.speech, c.provider == "aliyun", !c.apiKey.isEmpty else { return nil }
        let workspace = c.workspace ?? ""
        guard workspace.isEmpty || workspace.range(of: "^[A-Za-z0-9_-]{1,100}$",options:.regularExpression) != nil,
              c.model.range(of: "^qwen3-asr-flash-realtime(?:-[0-9]{4}-[0-9]{2}-[0-9]{2})?$",options:.regularExpression) != nil
        else { return nil }
        let host = workspace.isEmpty ? "dashscope.aliyuncs.com" : workspace + ".cn-beijing.maas.aliyuncs.com"
        guard let url = URL(string:"wss://" + host + "/api-ws/v1/realtime?model=" + c.model) else { return nil }
        var request = URLRequest(url:url)
        request.setValue("Bearer " + c.apiKey,forHTTPHeaderField:"Authorization")
        request.timeoutInterval = 8
        return Session(socket:URLSession.shared.webSocketTask(with:request),configuration:c.model + "|" + workspace + "|" + c.apiKey)
    }
    /// Opens only the network connection. No microphone, audio or transcription is started here.
    func prepare(locale: String? = nil) {
        guard let fresh = makeSession() else { return }
        queue.async { [self] in
            if let prepared, prepared.configuration == fresh.configuration, prepared.locale == Self.language(locale) { fresh.socket.cancel(with:.normalClosure,reason:nil); return }
            prepared?.socket.cancel(with:.goingAway,reason:nil)
            prepared = fresh
            fresh.locale = Self.language(locale)
            connect(fresh)
            configure(fresh)
            queue.asyncAfter(deadline:.now()+20) { [self] in
                guard prepared === fresh, !fresh.active else { return }
                prepared = nil
                fresh.socket.cancel(with:.normalClosure,reason:nil)
            }
        }
    }
    func start(session id: UInt64, locale: String?) -> Bool {
        guard let fresh = makeSession() else { return false }
        queue.async { [self] in
            let session: Session
            if let warm = prepared, warm.configuration == fresh.configuration, warm.locale == Self.language(locale) {
                session = warm; prepared = nil; fresh.socket.cancel(with:.normalClosure,reason:nil)
            } else {
                prepared?.socket.cancel(with:.goingAway,reason:nil); prepared = nil
                session = fresh
            }
            sessions.removeValue(forKey:id)?.socket.cancel(with:.goingAway,reason:nil)
            session.id = id; session.active = true
            sessions[id] = session
            if session === fresh {
                session.locale = Self.language(locale)
                connect(session)
                configure(session)
            } else if session.ready {
                update(id,VoiceUpdate(state:.listening,text:nil,isFinal:false,message:nil))
            }
            queue.asyncAfter(deadline:.now()+8) { [self] in
                guard current(session), !session.ready else { return }
                fail(session,"实时识别连接超时，未执行语音指令。")
            }
            queue.asyncAfter(deadline:.now()+65) { [self] in
                guard current(session) else { return }
                fail(session,"本段语音已达到时长上限，请分段输入。")
            }
        }
        return true
    }
    private static func language(_ locale: String?) -> String {
        locale == "auto" ? "auto" : locale?.lowercased().hasPrefix("en") == true ? "en" : "zh"
    }
    private func configure(_ session: Session) {
        var transcription: [String:Any] = [:]
        if session.locale != "auto" { transcription["language"] = session.locale }
        send(session,["type":"session.update","session":[
            "input_audio_format":"pcm","sample_rate":16000,"input_audio_transcription":transcription,
            "turn_detection":["type":"server_vad","threshold":0.2,"silence_duration_ms":500]
        ]])
    }
    private func connect(_ session: Session) {
        session.socket.resume()
        receive(session)
    }
    func append(session id: UInt64, pcm: Data) {
        queue.async { [self] in
            guard let session = sessions[id], !session.stopping else { return }
            session.audioBytes += pcm.count
            guard pcm.count % 2 == 0, session.audioBytes <= 1_952_000 else { fail(session,"录音过长或音频格式无效。"); return }
            if session.ready { append(session,pcm) }
            else {
                session.pendingBytes += pcm.count
                guard session.pendingBytes <= 256_000 else { fail(session,"连接准备过慢，请重试。"); return }
                session.pending.append(pcm)
            }
        }
    }
    func stop(session id: UInt64, cancel: Bool) {
        queue.async { [self] in
            guard let session = sessions[id] else { return }
            if cancel {
                sessions.removeValue(forKey:id)
                session.socket.cancel(with:.goingAway,reason:nil)
                return
            }
            guard !session.stopping else { return }
            session.stopping = true
            if session.ready { send(session,["type":"session.finish"]) }
            queue.asyncAfter(deadline:.now()+8) { [self] in
                guard current(session) else { return }
                fail(session,"语音末尾确认超时，草稿已保留，没有执行指令。")
            }
        }
    }
    private func current(_ session: Session) -> Bool { prepared === session || sessions[session.id] === session }
    private func append(_ session: Session, _ pcm: Data) { send(session,["type":"input_audio_buffer.append","audio":pcm.base64EncodedString()]) }
    private func send(_ session: Session, _ object: [String:Any]) {
        var payload = object; payload["event_id"] = UUID().uuidString
        guard let data = try? JSONSerialization.data(withJSONObject:payload), let text = String(data:data,encoding:.utf8) else { return }
        session.socket.send(.string(text)) { [weak self] error in
            if error != nil { self?.queue.async { [weak self] in self?.fail(session,"语音连接中断，草稿已保留，没有执行指令。") } }
        }
    }
    private func receive(_ session: Session) {
        session.socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async { [self] in
                guard self.current(session) else { return }
                switch result {
                case .failure: self.fail(session,"语音连接中断，草稿已保留，没有执行指令。"); return
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: self.fail(session,"语音响应格式无效。"); return
                    }
                    guard let event = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                          let type = event["type"] as? String else { self.fail(session,"语音响应格式无效。"); return }
                    if type == "session.updated" {
                        session.ready = true
                        for pcm in session.pending { self.append(session,pcm) }
                        session.pending = []; session.pendingBytes = 0
                        if session.active { self.update(session.id,VoiceUpdate(state:.listening,text:nil,isFinal:false,message:nil)) }
                        if session.stopping { self.send(session,["type":"session.finish"]) }
                    } else if type == "conversation.item.created", let item = event["item"] as? [String:Any], let id = item["id"] as? String {
                        session.items[id] = ""
                    } else if type.hasPrefix("conversation.item.input_audio_transcription.") {
                        guard let id = event["item_id"] as? String else { self.fail(session,"语音结果缺少分段编号。"); return }
                        if type.hasSuffix(".failed") { self.fail(session,"识别未完成，草稿已保留。"); return }
                        if type.hasSuffix(".completed") {
                            let text = event["transcript"] as? String ?? ""
                            session.items[id] = text
                            if session.finals.insert(id).inserted && !text.isEmpty {
                                self.update(session.id,VoiceUpdate(state:.listening,text:text,isFinal:true,message:nil))
                            }
                        } else if type.hasSuffix(".text") && !session.finals.contains(id) {
                            let text = (event["text"] as? String ?? "") + (event["stash"] as? String ?? "")
                            session.items[id] = text
                            self.update(session.id,VoiceUpdate(state:.listening,text:text,isFinal:false,message:nil))
                        }
                    } else if type == "session.finished" {
                        guard session.stopping, !session.finals.isEmpty,
                              session.items.keys.allSatisfy({session.finals.contains($0)}) else {
                            self.fail(session,"语音未完整确认，请核对草稿后重试。"); return
                        }
                        self.sessions.removeValue(forKey:session.id)
                        session.socket.cancel(with:.normalClosure,reason:nil)
                        self.update(session.id,VoiceUpdate(state:.stopped,text:nil,isFinal:true,message:nil))
                        self.prepare(locale:session.locale)
                        return
                    } else if type == "error" {
                        self.fail(session,"阿里云识别未完成，请在 Mac 检查语音配置或网络。"); return
                    }
                    self.receive(session)
                }
            }
        }
    }
    private func fail(_ session: Session, _ message: String) {
        guard current(session) else { return }
        if prepared === session { prepared = nil }
        sessions.removeValue(forKey:session.id)
        session.socket.cancel(with:.goingAway,reason:nil)
        if session.active { update(session.id,VoiceUpdate(state:.error,text:nil,isFinal:false,message:message)) }
    }
}
