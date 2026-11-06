import Foundation
import Synchronization
// CLI-only protocol value types; the application uses the generated UniFFI types.
enum VoiceState: String, Sendable { case listening, stopped, unavailable, error }
struct VoiceUpdate: Sendable { var state: VoiceState; var text: String?; var isFinal: Bool; var message: String? }
@main struct ASRCLI {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { fatalError("Supply synthetic mono 16 kHz s16le PCM.") }
        let pcm = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let locale = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "auto"
        let repeats = CommandLine.arguments.count >= 4 ? Int(CommandLine.arguments[3]) ?? 1 : 1
        for _ in 0..<max(1,min(5,repeats)) { run(pcm:pcm,locale:locale) }
    }
    static func run(pcm: Data, locale: String) {
        let lock = Mutex((ready: Double?.none, first: Double?.none, final: Double?.none, text:[String](), stopped: Double?.none, error:String?.none))
        let ended = DispatchSemaphore(value:0)
        let began = Date()
        let asr = AliyunSpeechService { _, update in
            let ms = Date().timeIntervalSince(began) * 1000
            lock.withLock { state in
                if update.state == .listening && update.text == nil && state.ready == nil { state.ready = ms }
                if let text = update.text, !text.isEmpty {
                    if state.first == nil { state.first = ms }
                    if update.isFinal { state.text.append(text); if state.final == nil { state.final = ms } }
                }
                if update.state == .error || update.state == .unavailable { state.error = update.message; ended.signal() }
                if update.state == .stopped { state.stopped = ms; ended.signal() }
            }
        }
        if CommandLine.arguments.contains("--prepare") {
            asr.prepare(locale:locale)
            Thread.sleep(forTimeInterval:3)
        }
        let activation = Date()
        guard asr.start(session:1,locale:locale) else { fatalError("ASR is not configured.") }
        for start in stride(from:0,to:pcm.count,by:640) {
            asr.append(session:1,pcm:pcm.subdata(in:start..<min(start+640,pcm.count)))
            Thread.sleep(forTimeInterval:0.02)
        }
        let stop = Date().timeIntervalSince(began)*1000
        asr.stop(session:1,cancel:false)
        let timedOut = ended.wait(timeout:.now()+12) == .timedOut
        let result: [String:Any] = lock.withLock { s in [
            "transcript":s.text.joined(separator:" "), "locale":locale, "audioMs":Double(pcm.count)/32,
            "preparationMs":activation.timeIntervalSince(began)*1000, "readyMs":s.ready ?? NSNull() as Any, "firstTextMs":s.first ?? NSNull() as Any, "firstFinalMs":s.final ?? NSNull() as Any,
            "finishMs":s.stopped.map{$0-stop} ?? NSNull() as Any,
            "error":s.error ?? NSNull() as Any, "timedOut":timedOut
        ] }
        print(IntentPlan.json(result))
        if timedOut { asr.stop(session:1,cancel:true) }
    }
}
