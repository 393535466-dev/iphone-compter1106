import Foundation
import AppKit
import Synchronization

/// A late-bound, weak reference to the core host, for services created
/// before it and called from other threads.
final class HostReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: CoreHost?

    var host: CoreHost? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Answers the core's requests for things only macOS frameworks can do. The
/// core calls these from its network threads, never the main thread.
final class HostBridge: HostDelegate, Sendable {
    let apps: AppCatalog
    let volume: AudioVolume
    let pasteboard: Pasteboard
    let speech: SpeechService
    let cloudSpeech: AliyunSpeechService
    private let planner = IntentPlannerService()
    private let cloudSessions = Mutex(Set<UInt64>())
    /// Mirrors the host config's `allowShell`, which also governs file URLs.
    private let allowsShell = Mutex(false)
    private let events: @Sendable (HostEvent) -> Void

    init(apps: AppCatalog, volume: AudioVolume, pasteboard: Pasteboard, speech: SpeechService, cloudSpeech: AliyunSpeechService, events: @escaping @Sendable (HostEvent) -> Void) {
        self.apps = apps
        self.volume = volume
        self.pasteboard = pasteboard
        self.speech = speech
        self.cloudSpeech = cloudSpeech
        self.events = events
    }

    func setAllowsShell(_ allowed: Bool) { allowsShell.withLock { $0 = allowed } }

    func onEvent(event: HostEvent) { events(event) }

    func listApps() -> [AppEntry] { apps.list() }

    func appIcon(id: String, size: UInt32) -> Data? { apps.icon(id: id, size: size) }

    func appAction(id: String, op: AppOp) -> Bool { apps.perform(id: id, op: op) }

    func openUrl(url: String) -> Bool { SystemActions.open(url, allowShellLike: allowsShell.withLock { $0 }) }

    func native(command: NativeCommand) -> Bool { SystemActions.run(command) }

    func runShortcut(name: String) -> Bool { SystemActions.runShortcut(name) }

    func setVolume(value: Float?, muted: Bool?) { volume.set(value: value, muted: muted) }

    func clipboardText() -> String? { pasteboard.text() }

    func setClipboardText(text: String) { pasteboard.setText(text) }

    func beginPaste(text: String) -> Bool { pasteboard.beginPaste(text) }

    func endPaste() { pasteboard.endPaste() }

    func planInstruction(text: String, context: String) -> String {
        var current = (context.data(using:.utf8).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]) ?? [:]
        current["frontApp"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let list = apps.list().map { ["id":$0.id,"name":$0.name] }
        return planner.plan(text:text,context:current,apps:list)
    }

    func verifyAction(action: String) -> String { ActionVerifier.verify(action) }

    func aiStatus() -> String {
        let config = AIConfiguration.load()
        return IntentPlan.json(["configured": !(config?.model.apiKey.isEmpty ?? true),
            "provider":config?.provider ?? "", "model":config?.model.model ?? "",
            "speechProvider":AliyunSpeechService.configured ? "aliyun" : "apple"])
    }

    func openUrlInApp(url: String, app: String) -> Bool {
        guard let url = URL(string:url), ["http","https"].contains(url.scheme ?? ""),
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier:app) else { return false }
        let done = DispatchSemaphore(value:0)
        let success = Mutex(false)
        DispatchQueue.main.async {
            NSWorkspace.shared.open([url],withApplicationAt:application,configuration:NSWorkspace.OpenConfiguration()) { _,error in
                success.withLock { $0 = error == nil }; done.signal()
            }
        }
        return done.wait(timeout:.now()+3) == .success && success.withLock { $0 }
    }

    func openFolder(name: String) -> Bool {
        let directory: FileManager.SearchPathDirectory?
        switch name {
        case "downloads": directory = .downloadsDirectory
        case "desktop": directory = .desktopDirectory
        case "documents": directory = .documentDirectory
        case "home": directory = nil
        default: return false
        }
        let url = directory.flatMap { FileManager.default.urls(for:$0,in:.userDomainMask).first } ?? FileManager.default.homeDirectoryForCurrentUser
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        return true
    }

    func prepareVoice(locale: String?) { cloudSpeech.prepare(locale:locale) }

    func voiceStart(session: UInt64, locale: String?) -> Bool {
        if AliyunSpeechService.configured {
            speech.stop(session:session,cancel:true)
            _ = cloudSessions.withLock { $0.insert(session) }
            return cloudSpeech.start(session:session,locale:locale)
        }
        _ = cloudSessions.withLock { $0.remove(session) }
        return speech.start(session:session,locale:locale == "auto" ? nil : locale)
    }

    func voiceAudio(session: UInt64, pcm: Data) {
        if cloudSessions.withLock({ $0.contains(session) }) { cloudSpeech.append(session:session,pcm:pcm) }
        else { speech.append(session:session,pcm:pcm) }
    }

    func voiceStop(session: UInt64, cancel: Bool) {
        if cloudSessions.withLock({ $0.contains(session) }) { cloudSpeech.stop(session:session,cancel:cancel) }
        else { speech.stop(session:session,cancel:cancel) }
    }
}
