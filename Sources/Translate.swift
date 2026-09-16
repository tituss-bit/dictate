// Translation: spoken code word ("переведи на английский …", "translate to Spanish …")
// or a dedicated hotkey routes the transcript through Apple's on-device Translation
// framework (macOS 15+). Nothing leaves the machine; language packs download once.

import AppKit
import NaturalLanguage
import SwiftUI
import Translation

// MARK: - Language naming

struct LangNames {
    /// spoken name (lowercased, RU / EN / native) → language, built from what Apple can translate.
    private(set) static var byName: [String: Locale.Language] = [:]
    private(set) static var supported: [Locale.Language] = []

    static func load() {
        guard #available(macOS 15, *) else { return }
        Task {
            let langs = await LanguageAvailability().supportedLanguages
            await MainActor.run { index(langs) }
        }
    }

    private static func index(_ langs: [Locale.Language]) {
        // Simplified Chinese first so the bare word "chinese"/"китайский" resolves to it.
        // Apple lists regional variants (en-US, en-GB, en-IN…); the framework accepts a bare
        // language, and a bare one never hits an unsupported regional pair (ru→en-IN is unsupported).
        var seen = Set<String>()
        supported = langs
            .map { Locale.Language(languageCode: $0.languageCode, script: $0.script, region: nil) }
            .filter { seen.insert($0.minimalIdentifier).inserted }
            .sorted {
                if $0.languageCode == $1.languageCode { return ($0.script?.identifier ?? "") < ($1.script?.identifier ?? "") }
                return display($0) < display($1)
            }
        var d: [String: Locale.Language] = [:]
        for l in supported {
            guard let code = l.languageCode?.identifier else { continue }
            for loc in ["ru", "en", code] {
                if let n = Locale(identifier: loc).localizedString(forLanguageCode: code)?.lowercased(), d[n] == nil { d[n] = l }
            }
            if l.script?.identifier == "Hant" {
                d["traditional chinese"] = l; d["традиционный китайский"] = l; d["繁體中文"] = l
            }
        }
        // Colloquial forms whisper actually produces.
        let extra: [String: String] = ["инглиш": "en", "рашн": "ru", "english": "en", "русский": "ru",
                                       "украинский": "uk", "испанский": "es", "немецкий": "de",
                                       "французский": "fr", "итальянский": "it", "португальский": "pt",
                                       "японский": "ja", "корейский": "ko", "китайский": "zh",
                                       "турецкий": "tr", "польский": "pl", "арабский": "ar", "хинди": "hi"]
        for (name, code) in extra where d[name] == nil {
            if let l = supported.first(where: { $0.languageCode?.identifier == code }) { d[name] = l }
        }
        byName = d
    }

    static func display(_ l: Locale.Language) -> String {
        let en = Locale(identifier: "en")
        var s = en.localizedString(forLanguageCode: l.languageCode?.identifier ?? "") ?? l.minimalIdentifier
        if let sc = l.script?.identifier, l.languageCode?.identifier == "zh" {
            s += sc == "Hant" ? " (Traditional)" : " (Simplified)"
        }
        return s
    }

    static func language(code: String) -> Locale.Language? {
        supported.first { $0.minimalIdentifier == code } ?? supported.first { $0.languageCode?.identifier == code }
    }

    static func detect(_ text: String) -> Locale.Language? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let l = r.dominantLanguage else { return nil }
        return language(code: l.rawValue)
    }

    static func same(_ a: Locale.Language?, _ b: Locale.Language?) -> Bool {
        guard let a = a, let b = b else { return false }
        return a.languageCode == b.languageCode
    }
}

// MARK: - Spoken command

struct SpokenCommand {
    let text: String
    let target: Locale.Language?   // nil = "переведи" with no language → auto direction

    private static let ru = try! NSRegularExpression(
        pattern: #"^(?:переведи|перевести|переведите)(?:\s+(?:это|мне))?(?:\s+на\s+(?<lang>[\p{L}\-]+)(?:\s+язык)?)?[\s,.:;!\-—]+(?<rest>.+)$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let en = try! NSRegularExpression(
        pattern: #"^translate(?:\s+(?:this|it))?(?:\s+(?:to|into)\s+(?<lang>[\p{L}\-]+))?[\s,.:;!\-—]+(?<rest>.+)$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// Returns nil when the transcript is ordinary dictation.
    static func parse(_ raw: String) -> SpokenCommand? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = t as NSString
        for re in [ru, en] {
            guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { continue }
            let langRange = m.range(withName: "lang")
            var target: Locale.Language? = nil
            if langRange.location != NSNotFound {
                let name = ns.substring(with: langRange).lowercased()
                guard let l = LangNames.byName[name] else { return nil }  // "переведи на счёт…" — not a command
                target = l
            }
            let rest = ns.substring(with: m.range(withName: "rest")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { return nil }
            return SpokenCommand(text: rest, target: target)
        }
        return nil
    }
}

/// Always appended to ~/Library/Logs/Dictate/dictate.log; also stderr with DICTATE_DEBUG=1.
func dlog(_ m: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(m)\n"
    if ProcessInfo.processInfo.environment["DICTATE_DEBUG"] != nil { FileHandle.standardError.write(line.data(using: .utf8)!) }
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Dictate", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("dictate.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

struct TranslateError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

// MARK: - Apple Translation bridge (SwiftUI-only API hosted in a hidden window)

@available(macOS 15, *)
final class Translator: ObservableObject {
    static let shared = Translator()

    @Published var config: TranslationSession.Configuration?
    fileprivate var pending: (text: String, done: (Result<String, Error>) -> Void)?
    private var window: NSWindow?
    private var hostShown = false
    private var job = 0

    func translate(_ text: String, from source: Locale.Language?, to target: Locale.Language,
                   completion: @escaping (Result<String, Error>) -> Void) {
        guard pending == nil else { completion(.failure(TranslateError(msg: "Translation already in progress"))); return }
        ensureHost()
        pending = (text, completion)
        job += 1
        let thisJob = job
        dlog("translate job \(thisJob): \(source?.minimalIdentifier ?? "auto") → \(target.minimalIdentifier), \(text.count) chars")
        if let c = config, c.target == target, c.source == source {
            config?.invalidate()
        } else {
            config = TranslationSession.Configuration(source: source, target: target)
        }
        // Never leave the app stuck in "Transcribing…": 20 s normally, 10 min while a
        // language pack download sheet is on screen.
        func watchdog(_ delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.pending != nil, self.job == thisJob else { return }
                if self.hostShown && delay < 60 { watchdog(600); return }
                dlog("job \(thisJob) timed out (download sheet shown: \(self.hostShown))")
                self.finish(.failure(TranslateError(msg: self.hostShown
                    ? "Language download did not finish" : "Translation timed out")))
            }
        }
        watchdog(20)
    }

    fileprivate func finish(_ r: Result<String, Error>) {
        let p = pending; pending = nil
        hideHost()
        p?.done(r)
    }

    /// The download-language sheet needs a real, visible window to attach to.
    fileprivate func showHost() {
        guard let w = window else { return }
        hostShown = true
        dlog("showing language download window")
        w.setContentSize(NSSize(width: 420, height: 160)); w.center()
        w.alphaValue = 1; w.ignoresMouseEvents = false; w.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func hideHost() {
        guard let w = window else { return }
        hostShown = false
        // Keep the window alive (SwiftUI needs it for the next task) but invisible and inert.
        w.alphaValue = 0; w.ignoresMouseEvents = true; w.level = .normal
        w.setContentSize(NSSize(width: 1, height: 1)); w.setFrameOrigin(NSPoint(x: 0, y: 0))
        w.orderBack(nil)
    }

    private func ensureHost() {
        guard window == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Dictate — Translation"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: TranslatorView(bridge: self))
        // SwiftUI only runs translationTask for a view that lives in an on-screen window,
        // so the host stays on screen — invisible (alpha 0), 1×1, click-through.
        window = w
        hideHost()
    }
}

@available(macOS 15, *)
struct TranslatorView: View {
    @ObservedObject var bridge: Translator

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Preparing translation…").font(.callout)
        }
        .frame(width: 420, height: 160)
        .translationTask(bridge.config) { session in
            dlog("translationTask fired; pending=\(bridge.pending != nil) config=\(String(describing: bridge.config))")
            guard let job = bridge.pending else { return }
            do {
                if let c = bridge.config, let src = c.source {
                    let status = await LanguageAvailability().status(from: src, to: c.target ?? src)
                    dlog("status \(src.minimalIdentifier)→\(c.target?.minimalIdentifier ?? "?"): \(status)")
                    if status == .supported { bridge.showHost(); try await session.prepareTranslation() }
                    if status == .unsupported { throw TranslateError(msg: "This language pair is not supported") }
                }
                let r = try await session.translate(job.text)
                dlog("translated ok")
                bridge.finish(.success(r.targetText))
            } catch {
                dlog("translate error: \(error)")
                bridge.finish(.failure(error))
            }
        }
    }
}

// MARK: - Entry point used by the app

enum Translate {
    static var available: Bool {
        if #available(macOS 15, *) { return true } else { return false }
    }

    /// Picks the direction: explicit target, else the configured default; never translates a
    /// language into itself — falls back to the dictation language or the other of RU/EN.
    static func run(_ text: String, target explicit: Locale.Language?, completion: @escaping (Result<String, Error>) -> Void) {
        guard #available(macOS 15, *) else {
            completion(.failure(TranslateError(msg: "Translation needs macOS 15 or newer"))); return
        }
        let source = LangNames.detect(text)
        var target = explicit ?? LangNames.language(code: Settings.translateTarget)
        if target == nil || LangNames.same(source, target) {
            let dict = Settings.lang == .auto ? nil : LangNames.language(code: Settings.lang.rawValue)
            if let d = dict, !LangNames.same(source, d) { target = d }
            else { target = LangNames.language(code: source?.languageCode?.identifier == "en" ? "ru" : "en") }
        }
        guard let t = target else { completion(.failure(TranslateError(msg: "No target language"))); return }
        Translator.shared.translate(text, from: source, to: t) { r in
            DispatchQueue.main.async { completion(r) }
        }
    }
}
