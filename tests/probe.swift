// Probe: exercises SpokenCommand + Apple Translation without the hotkey/mic path.
import AppKit
import Translation
enum Lang: String { case auto, ru, en }
struct Settings { static var translateTarget = "en"; static var lang = Lang.auto }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
LangNames.load()

func parseCases() {
    let cases = ["Переведи на английский, встретимся завтра в три.",
                 "переведи на испанский язык: где здесь метро",
                 "Translate to Japanese. Thank you for the dinner.",
                 "Переведи на счёт сто долларов",          // not a command
                 "Переведи, я опоздаю на десять минут",     // no language → auto
                 "Обычная диктовка без команды"]
    for c in cases {
        if let r = SpokenCommand.parse(c) { print("CMD  target=\(r.target.map(LangNames.display) ?? "auto")  text=«\(r.text)»") }
        else { print("PLAIN «\(c)»") }
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    print("supported: \(LangNames.supported.map(LangNames.display).joined(separator: ", "))")
    print("names: \(LangNames.byName.count)")
    parseCases()
    let jobs: [(String, String?)] = [("Встретимся завтра в три, я принесу документы.", "en"),
                                     ("Where is the nearest metro station?", nil),      // auto → ru
                                     ("Спасибо за ужин, было очень вкусно.", "es")]
    var i = 0
    func next() {
        guard i < jobs.count else { print("DONE"); exit(0) }
        let (text, tgt) = jobs[i]; i += 1
        Translate.run(text, target: tgt.flatMap { LangNames.language(code: $0) }) { r in
            switch r { case .success(let t): print("→ [\(tgt ?? "auto")] \(t)"); case .failure(let e): print("✗ [\(tgt ?? "auto")] \(e.localizedDescription)") }
            next()
        }
    }
    next()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("TIMEOUT"); exit(2) }
app.run()
