// Dictate — push-to-talk local dictation for macOS.
// Hold a modifier key, speak, release: audio goes to a local whisper-server,
// the text lands wherever the cursor is. No cloud, no LLM post-processing.

import AppKit
import AVFoundation
import ServiceManagement

// MARK: - Settings

enum Lang: String, CaseIterable {
    case auto, ru, en

    var title: String {
        switch self {
        case .auto: return "Auto-detect"
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    // A punctuated initial prompt nudges whisper into emitting punctuation.
    var prompt: String {
        switch self {
        case .ru: return "Привет! Как дела? Всё в порядке, спасибо."
        case .en: return "Hello! How are you? Everything is fine, thanks."
        case .auto: return ""
        }
    }
}

enum Hotkey: Int, CaseIterable {
    case rightOption = 61
    case rightCommand = 54
    case rightControl = 62
    case fn = 63

    var title: String {
        switch self {
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "fn / 🌐"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }
}

enum TalkMode: String, CaseIterable {
    case hold, toggle
    var title: String { self == .hold ? "Hold to talk" : "Tap to start / tap to stop" }
}

enum InsertMode: String, CaseIterable {
    case paste, type
    var title: String { self == .paste ? "Paste (⌘V, clipboard restored)" : "Type characters" }
}

struct Settings {
    static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var lang: Lang {
        get { Lang(rawValue: d.string(forKey: "lang") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "lang") }
    }
    static var hotkey: Hotkey {
        get { Hotkey(rawValue: d.integer(forKey: "hotkey")) ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }
    static var talkMode: TalkMode {
        get { TalkMode(rawValue: d.string(forKey: "talkMode") ?? "") ?? .hold }
        set { d.set(newValue.rawValue, forKey: "talkMode") }
    }
    static var insertMode: InsertMode {
        get { InsertMode(rawValue: d.string(forKey: "insertMode") ?? "") ?? .paste }
        set { d.set(newValue.rawValue, forKey: "insertMode") }
    }
    static var sounds: Bool {
        get { d.object(forKey: "sounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "sounds") }
    }
    static var trailingSpace: Bool {
        get { d.object(forKey: "trailingSpace") as? Bool ?? true }
        set { d.set(newValue, forKey: "trailingSpace") }
    }
    static var translateTarget: String {   // Locale.Language minimalIdentifier, e.g. "en", "zh-Hans"
        get { d.string(forKey: "translateTarget") ?? "en" }
        set { d.set(newValue, forKey: "translateTarget") }
    }
    static var translateHotkey: Hotkey? {   // nil = off
        get { d.object(forKey: "translateHotkey") == nil ? .rightCommand : Hotkey(rawValue: d.integer(forKey: "translateHotkey")) }
        set { d.set(newValue?.rawValue ?? 0, forKey: "translateHotkey") }
    }
    static var muteAudio: Bool {
        get { d.object(forKey: "muteAudio") as? Bool ?? true }
        set { d.set(newValue, forKey: "muteAudio") }
    }
    static var serverURL: String {
        get { d.string(forKey: "serverURL") ?? "http://127.0.0.1:18083/audio/transcriptions" }
        set { d.set(newValue, forKey: "serverURL") }
    }
}

// MARK: - Audio recorder

final class Recorder {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL
    private var startedAt: Date?

    init() {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-\(getpid()).wav")
        prepare()
    }

    // 16 kHz mono 16-bit PCM WAV — whisper's native input, no server-side conversion.
    private func prepare() {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        recorder = try? AVAudioRecorder(url: fileURL, settings: settings)
        recorder?.prepareToRecord()
    }

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start() -> Bool {
        guard let r = recorder, !r.isRecording else { return false }
        startedAt = Date()
        return r.record()
    }

    /// Stops and returns (file, duration seconds). Re-prepares for the next take.
    func stop() -> (URL, TimeInterval) {
        let dur = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        recorder?.stop()
        let url = fileURL
        // Next take goes to a fresh file so we can upload this one while recording again.
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-\(getpid())-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        prepare()
        return (url, dur)
    }
}

// MARK: - Whisper client

enum WhisperError: LocalizedError {
    case badStatus(Int, String)
    case noText
    case offline(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let c, let body): return "Server returned \(c): \(body.prefix(200))"
        case .noText: return "Server returned no text"
        case .offline(let m): return "Server unreachable: \(m)"
        }
    }
}

struct Whisper {
    // Phrases Whisper is known to invent on silence / breath noise (YouTube-subtitle credits etc.).
    static let hallucinations: [String] = [
        "субтитры сделал dimatorzok", "субтитры сделал диматорзок", "продолжение следует",
        "редактор субтитров", "субтитры подогнал", "спасибо за просмотр", "субтитры",
        "thank you.", "thank you", "thanks for watching", "you", "bye.", "bye",
        "please subscribe", "subtitles by", "the end",
    ]

    static func transcribe(file: URL, lang: Lang, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: Settings.serverURL) else {
            completion(.failure(WhisperError.offline("bad URL"))); return
        }
        let boundary = "----dictate\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("temperature", "0")
        if lang != .auto { field("language", lang.rawValue) }
        if !lang.prompt.isEmpty { field("prompt", lang.prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append((try? Data(contentsOf: file)) ?? Data())
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60

        URLSession.shared.dataTask(with: req) { data, resp, err in
            try? FileManager.default.removeItem(at: file)
            if let err = err { completion(.failure(WhisperError.offline(err.localizedDescription))); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let data = data ?? Data()
            guard code == 200 else {
                completion(.failure(WhisperError.badStatus(code, String(data: data, encoding: .utf8) ?? ""))); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["text"] as? String else {
                completion(.failure(WhisperError.noText)); return
            }
            completion(.success(clean(raw)))
        }.resume()
    }

    static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = t.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if key.isEmpty || hallucinations.contains(key) { return "" }
        // Whisper sometimes wraps a whole line in [brackets] or (parentheses) for non-speech.
        if let f = t.first, let l = t.last, "[(".contains(f), "])".contains(l) { return "" }
        if Settings.trailingSpace, let last = t.last, !last.isNewline { t += " " }
        return t
    }

    static func ping(completion: @escaping (Bool) -> Void) {
        guard let u = URL(string: Settings.serverURL), let host = u.host, let port = u.port else {
            completion(false); return
        }
        var req = URLRequest(url: URL(string: "http://\(host):\(port)/")!)
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { _, resp, err in
            // Any HTTP answer (even 404) means the process is listening.
            completion(err == nil && resp != nil)
        }.resume()
    }
}

// MARK: - Built-in whisper-server

/// Runs the whisper-server shipped inside the bundle when nothing else answers on the
/// configured port. On the developer machine a launchd-managed server already owns the
/// port, so this stays idle; on a fresh Mac it is the only server there is.
final class ServerManager {
    private var process: Process?
    private(set) var isStarting = false
    private(set) var managed = false
    var onStateChange: (() -> Void)?

    static var bundledServer: URL? {
        let u = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("whisper-server")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }
    static var bundledModel: URL? {
        Bundle.main.url(forResource: "ggml-large-v3-turbo-q5_0", withExtension: "bin")
    }
    static var canRun: Bool { bundledServer != nil && bundledModel != nil }

    var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Dictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("whisper-server.log")
    }

    /// Ping; if the port is dead and it is a localhost URL we own, spawn the bundled server.
    func ensureRunning(completion: @escaping (Bool) -> Void) {
        Whisper.ping { up in
            DispatchQueue.main.async {
                if up { completion(true); return }
                guard Self.canRun, let u = URL(string: Settings.serverURL),
                      u.host == "127.0.0.1" || u.host == "localhost", let port = u.port else {
                    completion(false); return
                }
                self.spawn(port: port, completion: completion)
            }
        }
    }

    private func spawn(port: Int, completion: @escaping (Bool) -> Void) {
        guard !isStarting, let server = Self.bundledServer, let model = Self.bundledModel else {
            completion(false); return
        }
        isStarting = true; managed = true; onStateChange?()
        // A previous Dictate that was force-quit may have left its server behind.
        let sweep = Process()
        sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        sweep.arguments = ["-f", model.path]
        try? sweep.run(); sweep.waitUntilExit()

        let p = Process()
        // sh watchdog: runs the server, kills it when Dictate (the sh's original parent) is gone
        // or when we terminate the sh — so a crash/force-quit never leaves an orphan engine.
        let watchdog = """
            "$0" "$@" & child=$!
            trap 'kill $child 2>/dev/null' EXIT TERM INT
            parent=$PPID
            while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done
            """
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", watchdog, server.path,
                       "-m", model.path, "--host", "127.0.0.1", "--port", String(port),
                       "--inference-path", "/audio/transcriptions", "-l", "auto"]
        p.environment = ["GGML_METAL_PATH_RESOURCES": server.deletingLastPathComponent().path]
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
        else { FileManager.default.createFile(atPath: logURL.path, contents: nil); p.standardOutput = try? FileHandle(forWritingTo: logURL); p.standardError = p.standardOutput }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.process = nil; self?.onStateChange?() }
        }
        do { try p.run() } catch {
            isStarting = false; managed = false; onStateChange?(); completion(false); return
        }
        process = p

        // Model load takes a few seconds; poll until the port answers.
        var tries = 0
        func poll() {
            tries += 1
            Whisper.ping { up in
                DispatchQueue.main.async {
                    if up || tries > 60 || self.process == nil {
                        self.isStarting = false; self.onStateChange?(); completion(up)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
                    }
                }
            }
        }
        poll()
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func stop() {
        process?.terminate()
        process = nil
        managed = false
    }
}

// MARK: - Text insertion

struct Inserter {
    enum Focus { case editable, notEditable, unknown }
    enum Outcome { case inserted, copied }

    /// Asks Accessibility what has keyboard focus. Text fields/areas (native, Electron, web
    /// inputs, terminals) → editable. Nothing focused, or a button/list/desktop → notEditable.
    /// Apps that don't expose a focused element → unknown.
    // Roles that can never take typed text. Anything else that isn't clearly a text field is
    // "unknown": we still paste, and keep the text in the clipboard as a safety net.
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXImage", "AXStaticText", "AXLink", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
        "AXTable", "AXOutline", "AXList", "AXRow", "AXCell", "AXColumn", "AXToolbar", "AXTabGroup",
        "AXWindow", "AXSheet", "AXDrawer", "AXDockItem", "AXMenu", "AXMenuBar", "AXBrowser",
    ]

    /// Electron/Chromium apps (Slack, VS Code, Discord…) keep their accessibility tree
    /// off until a client asks for it. Ask when recording starts, so it's ready by insert time.
    static func primeAccessibility() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func focusedElement() -> (AXError, AXUIElement?) {
        var el: AnyObject?
        var err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &el)
        if err != .success, let app = NSWorkspace.shared.frontmostApplication {
            err = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &el)
        }
        return (err, err == .success ? (el as! AXUIElement) : nil)
    }

    static func focusedField() -> Focus {
        var (err, found) = focusedElement()
        if err == .noValue {
            // Tree may still be waking up after priming — one short retry.
            primeAccessibility()
            usleep(300_000)
            (err, found) = focusedElement()
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        guard let ax = found else {
            dlog("focus: no element (err=\(err.rawValue)) app=\(appName)")
            // Nothing has keyboard focus at all → nowhere for text to go.
            return err == .noValue ? .notEditable : .unknown
        }
        var roleRef: AnyObject?, subroleRef: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subroleRef)
        let role = roleRef as? String ?? "", subrole = subroleRef as? String ?? ""
        var settable: DarwinBoolean = false
        let valueSettable = AXUIElementIsAttributeSettable(ax, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        var range: AnyObject?
        let hasRange = AXUIElementCopyAttributeValue(ax, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        // Web views (Chromium, WebKit) report a selection range and a value on the page body
        // itself, so those aren't proof of a text field. An editable ancestor is.
        var anc: AnyObject?
        let editableAncestor = AXUIElementCopyAttributeValue(ax, "AXEditableAncestor" as CFString, &anc) == .success && anc != nil
        dlog("focus: role=\(role) subrole=\(subrole) settable=\(valueSettable) range=\(hasRange) editableAncestor=\(editableAncestor) app=\(appName)")
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) || valueSettable || editableAncestor { return .editable }
        if nonTextRoles.contains(role) { return .notEditable }
        if ["AXWebArea", "AXGroup", "AXScrollArea", "AXLayoutArea", "AXSplitGroup", "AXApplication", "AXLayoutItem"].contains(role) { return .notEditable }
        return .unknown
    }

    @discardableResult
    static func insert(_ text: String) -> Outcome {
        let focus = focusedField()
        dlog("insert: focus=\(focus) mode=\(Settings.insertMode.rawValue) \(text.count) chars")
        if focus == .notEditable {
            // Nowhere to type: keep the words in the clipboard instead of losing them.
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(text.trimmingCharacters(in: .whitespaces), forType: .string)
            HUD.show("📋 В буфере обмена — курсор был не в тексте")
            return .copied
        }
        switch Settings.insertMode {
        case .paste: paste(text, restoreClipboard: focus == .editable)
        case .type: type(text)
        }
        return .inserted
    }

    private static func paste(_ text: String, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        // Snapshot everything currently on the clipboard so we can put it back.
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)  // 9 = V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the target app time to read the clipboard, then restore the old contents —
        // unless we weren't sure a text field had focus: then the text stays available.
        guard restoreClipboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == ourChange, !saved.isEmpty else { return }
            pb.clearContents()
            let items: [NSPasteboardItem] = saved.map { entries in
                let it = NSPasteboardItem()
                for (t, d) in entries { it.setData(d, forType: t) }
                return it
            }
            pb.writeObjects(items)
        }
    }

    private static func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        // CGEvent unicode payload is limited; send in small chunks.
        for chunk in Array(text.utf16).chunked(20) {
            var buf = chunk
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
            up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(8000)
        }
    }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}

// MARK: - HUD (brief floating notice, no notification permission needed)

enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, seconds: TimeInterval = 1.8) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let pad: CGFloat = 14
        let size = NSSize(width: label.frame.width + pad * 2, height: label.frame.height + pad * 1.2)
        let p = panel ?? NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.setContentSize(size)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .statusBar
        p.ignoresMouseEvents = true; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true
        bg.layer?.cornerRadius = 10; bg.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: pad, y: pad * 0.6)
        bg.addSubview(label)
        p.contentView = bg
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 12))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        hideWork?.cancel()
        let w = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

// MARK: - Global hotkey (CGEvent tap on modifier flags)

final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var down: Hotkey? = nil
    var onPress: ((_ translate: Bool) -> Void)?
    var onRelease: ((_ translate: Bool) -> Void)?

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            me.handle(event)
            return Unmanaged.passUnretained(event)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: callback, userInfo: refcon) else { return false }
        tap = t
        runLoopSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        tap = nil; runLoopSource = nil; down = nil
    }

    private func handle(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let dictate = Settings.hotkey
        let translate = Settings.translateHotkey.flatMap { $0 == dictate ? nil : $0 }
        guard let hk = [dictate, translate].compactMap({ $0 }).first(where: { $0.rawValue == keyCode }) else { return }
        let pressed = event.flags.contains(hk.flag)
        if pressed {
            guard down == nil else { return }          // ignore a second key while one is held
            down = hk
            DispatchQueue.main.async { self.onPress?(hk == translate) }
        } else {
            guard down == hk else { return }
            down = nil
            DispatchQueue.main.async { self.onRelease?(hk == translate) }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case disabled, ready, recording, transcribing, noAccess }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let recorder = Recorder()
    private let hotkey = HotkeyMonitor()
    private let server = ServerManager()
    private let ducker = AudioDucker()
    private var state: State = .ready { didSet { refreshIcon() } }
    private var lastText = ""
    private var lastError = ""
    private var serverUp: Bool? = nil
    private var pressStarted: Date?
    private var translateTake = false

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        hotkey.onPress = { [weak self] t in self?.hotkeyPressed(translate: t) }
        hotkey.onRelease = { [weak self] _ in self?.hotkeyReleased() }
        LangNames.load()

        requestPermissions()
        installSignalHandler()
        ducker.recoverAfterCrash()
        server.onStateChange = { [weak self] in self?.refreshIcon() }
        server.ensureRunning { up in DispatchQueue.main.async { self.serverUp = up } }
    }

    func applicationWillTerminate(_ n: Notification) { ducker.restore(); server.stop() }

    // Turn SIGTERM (kill, logout) into a normal quit so applicationWillTerminate runs.
    private var sigterm: DispatchSourceSignal?
    private func installSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    // MARK: permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            armHotkey()
        } else {
            state = .noAccess
            // Poll until the user grants Accessibility, then arm without a relaunch.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                if AXIsProcessTrusted() { t.invalidate(); self.armHotkey() }
            }
        }
    }

    private func armHotkey() {
        if Settings.enabled {
            state = hotkey.start() ? .ready : .noAccess
        } else {
            hotkey.stop()
            state = .disabled
        }
    }

    // MARK: hotkey flow

    private func hotkeyPressed(translate: Bool) {
        guard Settings.enabled else { return }
        switch Settings.talkMode {
        case .hold:
            pressStarted = Date()
            startRecording(translate: translate)
        case .toggle:
            state == .recording ? stopAndTranscribe() : startRecording(translate: translate)
        }
    }

    private func hotkeyReleased() {
        guard Settings.talkMode == .hold, state == .recording else { return }
        stopAndTranscribe()
    }

    private func startRecording(translate: Bool = false) {
        guard state == .ready else { return }
        translateTake = translate
        Inserter.primeAccessibility()
        if server.isStarting {
            lastError = "Speech engine is still starting, try again in a few seconds"
            sound("Basso"); return
        }
        if recorder.start() {
            state = .recording
            sound("Tink")
            if Settings.muteAudio {
                // Let the start cue play before the speakers go silent.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if self.state == .recording { self.ducker.duck() }
                }
            }
        } else {
            lastError = "Microphone not available (check System Settings → Privacy → Microphone)"
            sound("Basso")
        }
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        let (file, dur) = recorder.stop()
        ducker.restore()
        sound("Pop")
        // A tap shorter than this is a mis-press, not speech — whisper would hallucinate on it.
        guard dur >= 0.4 else {
            try? FileManager.default.removeItem(at: file)
            state = .ready
            return
        }
        state = .transcribing
        Whisper.transcribe(file: file, lang: Settings.lang) { result in
            DispatchQueue.main.async {
                self.state = Settings.enabled ? .ready : .disabled
                switch result {
                case .success(let text):
                    self.lastError = ""
                    guard !text.isEmpty else { return }
                    self.serverUp = true
                    self.deliver(text, translateTake: self.translateTake)
                case .failure(let err):
                    self.lastError = err.localizedDescription
                    if case WhisperError.offline = err {
                        self.serverUp = false
                        self.server.ensureRunning { up in DispatchQueue.main.async { self.serverUp = up } }
                    }
                    self.sound("Basso")
                }
            }
        }
    }

    /// Plain dictation goes straight in; a translate-hotkey take or a spoken
    /// "переведи на … / translate to …" prefix goes through Apple Translation first.
    private func deliver(_ text: String, translateTake: Bool) {
        let cmd = SpokenCommand.parse(text)
        guard translateTake || cmd != nil else {
            lastText = text
            if Inserter.insert(text) == .copied { sound("Glass") }
            return
        }
        let body = cmd?.text ?? text
        state = .transcribing
        Translate.run(body, target: cmd?.target) { r in
            self.state = Settings.enabled ? .ready : .disabled
            switch r {
            case .success(let out):
                var t = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if Settings.trailingSpace { t += " " }
                self.lastText = t
                if Inserter.insert(t) == .copied { self.sound("Glass") }
            case .failure(let e):
                // Fall back to the untranslated words rather than losing what was said.
                self.lastError = "Translate: \(e.localizedDescription)"
                self.lastText = body; Inserter.insert(body); self.sound("Basso")
            }
        }
    }

    private func sound(_ name: String) {
        guard Settings.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: menu bar

    private func refreshIcon() {
        guard let b = statusItem?.button else { return }
        let (symbol, tint, desc): (String, NSColor?, String) = {
            switch state {
            case .disabled: return ("mic.slash", nil, "Dictate: off")
            case .ready: return ("mic", nil, "Dictate: ready")
            case .recording: return ("mic.fill", .systemRed, "Dictate: recording")
            case .transcribing: return ("waveform", .systemOrange, "Dictate: transcribing")
            case .noAccess: return ("exclamationmark.triangle", .systemYellow, "Dictate: needs Accessibility")
            }
        }()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        b.contentTintColor = tint
        b.toolTip = desc
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        server.ensureRunning { up in DispatchQueue.main.async { self.serverUp = up } }
        menu.removeAllItems()

        let status: String = {
            switch state {
            case .disabled: return "Off"
            case .ready: return Settings.talkMode == .hold
                ? "Ready — hold \(Settings.hotkey.title) and speak"
                : "Ready — tap \(Settings.hotkey.title) to start"
            case .recording: return "● Recording…"
            case .transcribing: return "Transcribing…"
            case .noAccess: return "⚠️ Accessibility access needed (if Dictate is already ticked → Fix permissions)"
            }
        }()
        menu.addItem(label(status))
        if Translate.available {
            menu.addItem(label("Say «переведи на …» / «translate to …» before the phrase"))
        }
        if state == .noAccess {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        menu.addItem(item("Fix permissions (reset & relaunch)…", #selector(fixPermissions)))
        let engine: String = {
            if server.isStarting { return "starting…" }
            if serverUp == nil { return "checking…" }
            if !serverUp! { return "OFFLINE" }
            return server.managed ? "online (built-in)" : "online (external)"
        }()
        menu.addItem(label("Speech engine: \(engine)"))
        if !lastError.isEmpty { menu.addItem(label("Error: \(lastError.prefix(80))")) }
        menu.addItem(.separator())

        let en = item("Enabled", #selector(toggleEnabled))
        en.state = Settings.enabled ? .on : .off
        menu.addItem(en)

        menu.addItem(submenu("Language: \(Settings.lang.title)", Lang.allCases.map { l in
            let i = item(l.title, #selector(setLang(_:))); i.representedObject = l.rawValue
            i.state = Settings.lang == l ? .on : .off; return i
        }))
        menu.addItem(submenu("Hotkey: \(Settings.hotkey.title)", Hotkey.allCases.map { h in
            let i = item(h.title, #selector(setHotkey(_:))); i.representedObject = h.rawValue
            i.state = Settings.hotkey == h ? .on : .off; return i
        }))
        menu.addItem(submenu("Mode: \(Settings.talkMode.title)", TalkMode.allCases.map { m in
            let i = item(m.title, #selector(setMode(_:))); i.representedObject = m.rawValue
            i.state = Settings.talkMode == m ? .on : .off; return i
        }))
        menu.addItem(submenu("Insert: \(Settings.insertMode.title)", InsertMode.allCases.map { m in
            let i = item(m.title, #selector(setInsert(_:))); i.representedObject = m.rawValue
            i.state = Settings.insertMode == m ? .on : .off; return i
        }))
        if Translate.available {
            menu.addItem(.separator())
            let cur = LangNames.language(code: Settings.translateTarget).map(LangNames.display) ?? Settings.translateTarget
            let langs = LangNames.supported.isEmpty ? [label("Loading languages…")] : LangNames.supported.map { l in
                let i = item(LangNames.display(l), #selector(setTranslateTarget(_:))); i.representedObject = l.minimalIdentifier
                i.state = l.minimalIdentifier == Settings.translateTarget ? .on : .off; return i
            }
            menu.addItem(submenu("Translate to: \(cur)", langs))
            let thk = Settings.translateHotkey
            var hkItems: [NSMenuItem] = Hotkey.allCases.filter { $0 != Settings.hotkey }.map { h in
                let i = item(h.title, #selector(setTranslateHotkey(_:))); i.representedObject = h.rawValue
                i.state = thk == h ? .on : .off; return i
            }
            let off = item("Off", #selector(setTranslateHotkey(_:))); off.representedObject = 0
            off.state = thk == nil ? .on : .off; hkItems.append(off)
            menu.addItem(submenu("Translate hotkey: \(thk?.title ?? "Off")", hkItems))
        }
        menu.addItem(.separator())

        let snd = item("Sounds", #selector(toggleSounds)); snd.state = Settings.sounds ? .on : .off
        menu.addItem(snd)
        let mute = item("Mute other audio while recording", #selector(toggleMute)); mute.state = Settings.muteAudio ? .on : .off
        menu.addItem(mute)
        let sp = item("Trailing space after text", #selector(toggleSpace)); sp.state = Settings.trailingSpace ? .on : .off
        menu.addItem(sp)
        let login = item("Launch at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Server URL…", #selector(editServer)))
        if server.managed {
            menu.addItem(item("Restart speech engine", #selector(restartServer)))
            menu.addItem(item("Show engine log", #selector(showLog)))
        }
        menu.addItem(.separator())

        if !lastText.isEmpty {
            let preview = lastText.trimmingCharacters(in: .whitespaces)
            menu.addItem(label("Last: " + (preview.count > 60 ? String(preview.prefix(60)) + "…" : preview)))
            menu.addItem(item("Copy last transcription", #selector(copyLast)))
            menu.addItem(.separator())
        }
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(label("Dictate \(ver)"))
        menu.addItem(item("Quit Dictate", #selector(quit), key: "q"))
    }

    private func label(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    private func item(_ s: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: s, action: sel, keyEquivalent: key); i.target = self; return i
    }
    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(); items.forEach { m.addItem($0) }
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.submenu = m; return i
    }

    // MARK: actions

    @objc private func toggleEnabled() { Settings.enabled.toggle(); armHotkey() }
    @objc private func setLang(_ s: NSMenuItem) { Settings.lang = Lang(rawValue: s.representedObject as! String)! }
    @objc private func setHotkey(_ s: NSMenuItem) { Settings.hotkey = Hotkey(rawValue: s.representedObject as! Int)! }
    @objc private func setMode(_ s: NSMenuItem) { Settings.talkMode = TalkMode(rawValue: s.representedObject as! String)! }
    @objc private func setInsert(_ s: NSMenuItem) { Settings.insertMode = InsertMode(rawValue: s.representedObject as! String)! }
    @objc private func setTranslateTarget(_ s: NSMenuItem) { Settings.translateTarget = s.representedObject as! String }
    @objc private func setTranslateHotkey(_ s: NSMenuItem) { Settings.translateHotkey = Hotkey(rawValue: s.representedObject as! Int) }
    @objc private func toggleSounds() { Settings.sounds.toggle() }
    @objc private func toggleMute() { Settings.muteAudio.toggle() }
    @objc private func toggleSpace() { Settings.trailingSpace.toggle() }
    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { lastError = "Launch at login: \(error.localizedDescription)" }
    }

    @objc private func restartServer() {
        server.stop(); serverUp = nil
        server.ensureRunning { up in DispatchQueue.main.async { self.serverUp = up } }
    }
    @objc private func showLog() { NSWorkspace.shared.open(server.logURL) }

    /// A grant given to an earlier build can show as ticked yet be dead (different signature).
    /// Clearing our own TCC entries and relaunching makes macOS ask again, cleanly.
    @objc private func fixPermissions() {
        let a = NSAlert()
        a.messageText = "Reset Dictate's permissions?"
        a.informativeText = "Dictate will forget its Microphone and Accessibility approvals and relaunch, so macOS asks for them again. Use this when the tick in System Settings is on but the hotkey does nothing."
        a.addButton(withTitle: "Reset & Relaunch"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let bundle = Bundle.main.bundleIdentifier ?? "dev.dictate.app"
        for svc in ["Accessibility", "Microphone"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", svc, bundle]; try? p.run(); p.waitUntilExit()
        }
        let relaunch = Process(); relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; open -n \"\(Bundle.main.bundlePath)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func editServer() {
        let a = NSAlert()
        a.messageText = "Whisper server URL"
        a.informativeText = "Full transcription endpoint of a local whisper-server."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        tf.stringValue = Settings.serverURL
        a.accessoryView = tf
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            Settings.serverURL = tf.stringValue.trimmingCharacters(in: .whitespaces)
            serverUp = nil
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
