# Dictate

Push-to-talk dictation for macOS that runs entirely on your Mac.

Hold a key, speak, release — the text lands wherever your cursor is. Any app: chat, browser, editor, terminal. No cloud, no account, no LLM sitting in memory. Just a [whisper.cpp](https://github.com/ggml-org/whisper.cpp) engine bundled inside the app.

Whisper large-v3-turbo handles Russian and English (and ~90 other languages) far better than the built-in macOS dictation.

## Features

- **Hold to talk** on a modifier key (Right ⌥ by default; Right ⌘ / Right ⌃ / fn selectable), or tap-to-start / tap-to-stop.
- **Fully offline.** Audio goes to a local `whisper-server` on `127.0.0.1` and nowhere else.
- **Self-contained.** The app ships its own statically built `whisper-server` and a quantized `large-v3-turbo` model. Nothing to install. If you already run a whisper-server, point the app at it and the built-in one stays idle.
- **Speak-to-translate.** Say *"переведи на английский, …"* or *"translate to Spanish, …"* in front of a phrase and the translation is inserted instead. Uses Apple's on-device Translation framework (macOS 15+), ~20 languages. A second hotkey (Right ⌘ by default) translates to a preset language without the code word.
- **Mutes other audio while you record**, so music or a video call doesn't bleed into the microphone. Restores the exact previous state on release.
- **Nothing gets lost.** If the cursor isn't in a text field (desktop, a web page body, a button), the text goes to the clipboard and a small HUD tells you so.
- **Hallucination guard.** Drops the phrases Whisper invents on silence, and ignores presses shorter than 0.4 s.
- Menu-bar only, ~4 MB binary, one Swift file per concern, no Xcode project needed.

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 13 Ventura or newer (macOS 15 for translation)
- Permissions: **Microphone** and **Accessibility** (the hotkey is a global modifier-key tap, and ⌘V is posted as a key event)

## Install

Download `Dictate-<version>.dmg` from [Releases](../../releases), drag **Dictate** to Applications, launch.

The app is signed with a local certificate, not an Apple Developer ID, so on first launch macOS will say it "could not verify" the app. Click **Done**, then **System Settings → Privacy & Security → scroll down → Open Anyway**. You'll then be asked for Microphone and Accessibility access.

## Usage

Hold **Right ⌥ Option**, speak, release. A "tink" marks the start, a "pop" the end. The text appears at the cursor about a second later.

The menu-bar microphone icon holds all settings:

| Item | What it does |
|---|---|
| Enabled | On/off |
| Language | Auto-detect / Russian / English (auto is usually fine) |
| Hotkey | Right ⌥ / Right ⌘ / Right ⌃ / fn |
| Mode | Hold to talk, or tap to start / tap to stop |
| Insert | Paste via ⌘V (clipboard restored afterwards) or type characters one by one |
| Translate to | Target language for the translate hotkey and bare "переведи / translate" |
| Translate hotkey | Second key that translates instead of dictating |
| Mute other audio while recording | Silence the Mac's output during a take |
| Launch at login | |
| Fix permissions | Resets the app's Microphone/Accessibility entries and relaunches, for when a tick in System Settings is on but dead |

### Translation

```
"Переведи на английский, встретимся завтра в три"   →  We'll meet tomorrow at three.
"Translate to Japanese, thank you for dinner"        →  夕食をありがとう。
"Переведи, я опоздаю"   (no language named)          →  Russian↔English, picked from the input
```

The first time a language pair is used, macOS offers to download a language pack (one-off, ~100–200 MB). Translation is done by the same on-device engine as Apple's Translate app.

## Build from source

```bash
git clone https://github.com/<you>/dictate.git
cd dictate
./scripts/fetch-vendor.sh   # clones whisper.cpp, builds a static whisper-server, downloads the model (~600 MB)
./build.sh                  # → build.noindex/Dictate.app
./make-dmg.sh               # → ~/Downloads/Dictate/Dictate-<version>.dmg
```

Only Xcode Command Line Tools and CMake (`brew install cmake`) are needed. If `vendor/` is missing, `build.sh` still produces an app that relies on an external whisper-server at the URL set in the menu.

### Code signing

`build.sh` signs with a keychain identity named **"Dictate Dev"** when one exists, otherwise ad-hoc. A stable identity matters: macOS ties the Accessibility grant to the signature, so ad-hoc builds lose their permissions on every rebuild. To make one:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=Dictate Dev" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -inkey key.pem -in cert.pem -out dev.p12 -passout pass:x -name "Dictate Dev"
security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
```

## How it works

1. A CGEvent tap (listen-only) watches modifier-key changes for the chosen key.
2. `AVAudioRecorder` writes 16 kHz mono WAV — Whisper's native input, no conversion.
3. On release the file is POSTed as multipart to `whisper-server`'s `/audio/transcriptions` with a punctuated prompt so the model emits punctuation.
4. Before inserting, the app asks Accessibility what has keyboard focus. Electron/Chromium apps keep their accessibility tree off until asked (`AXManualAccessibility`), so the app primes it when recording starts.
5. Text is placed on the clipboard, ⌘V is posted, and the previous clipboard contents are put back.

Logs: `~/Library/Logs/Dictate/dictate.log` (decisions) and `whisper-server.log` (engine).

## Troubleshooting

- **⚠️ icon in the menu bar** — Accessibility not granted. Menu → Open Accessibility Settings.
- **Tick is on but nothing happens** — a grant from an older build. Menu → Fix permissions.
- **"Speech engine: OFFLINE"** — Menu → Restart speech engine, or check the engine log.
- **Right ⌘ does nothing on a non-Apple keyboard** — pick another translate hotkey in the menu.

## License

MIT. whisper.cpp and the Whisper model weights are MIT-licensed by their respective authors.
