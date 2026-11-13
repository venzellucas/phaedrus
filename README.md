<p align="center"><img src="docs/icon.png" width="160" alt="Phaedrus icon: a black-figure microphone on a terracotta tile"></p>

<h1 align="center">Phaedrus</h1>

<p align="center"><b>Press 🎤, speak, and your words appear at the cursor in any Mac app.<br>
Speech recognition runs entirely on your Mac.</b></p>

<p align="center"><a href="https://venzellucas.github.io/phaedrus/">Website &amp; installation guide</a></p>

> …writing is unfortunately like painting; for the creations of the painter have the attitude
> of life, and yet if you ask them a question they preserve a solemn silence.
>
> (Socrates, in Plato's *Phaedrus* 275d, translated by Benjamin Jowett)

Socrates never wrote anything down; he talked. Phaedrus lets you talk and still end up with text.

## Features

- **On-device.** Uses Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26). No cloud service, no API key, no subscription. Your audio never leaves the Mac.
- **Optional language detection.** Starts with English (US). Select up to three languages in settings to listen in all of them and keep the transcript that fits best.
- **Experimental language mixing.** Optionally combine words from the selected languages in one dictation, without translating them. This runs on-device and is off by default.
- **Quiet recording UI.** A smooth colored ribbon responds to microphone input, with elapsed time and all selected language codes. No distracting live transcript.
- **No Accessibility permission, no admin rights.** Text is inserted through a macOS *Service*, so it also works on managed Macs where you can't grant Accessibility.
- **Stays out of the way.** No Dock icon and no menu-bar item. It starts when you press the key and quits after 15 idle minutes.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode Command Line Tools with the macOS 26 SDK or later (`xcode-select --install`)

## Install

```sh
git clone https://github.com/venzellucas/phaedrus.git
cd phaedrus
scripts/build.sh                  # builds and installs ~/Applications/Phaedrus.app
open ~/Applications/Phaedrus.app  # opens the settings
```

In the settings window, turn on **Use the 🎤 key to dictate**. This makes the 🎤 key (F5 on
Mac laptops) send F18, binds F18 to Phaedrus, and keeps the remap after restarts. Other
key remaps you have made with `hidutil` are kept.

If your keyboard has no 🎤 key, click **Change shortcut in System Settings…** and give
**Keyboard Shortcuts → Services → Text → Dictate with Phaedrus** any shortcut you like.

The first dictation asks for microphone access. Each language's speech model is downloaded
from Apple once; the bubble shows the download progress.

### Download a test build

For **Apple silicon Macs running macOS 26 or later**, the latest successful
[Build workflow](https://github.com/venzellucas/phaedrus/actions/workflows/build.yml)
on `main` includes a `Phaedrus-macOS-arm64.zip` download under **Artifacts**.
Sign in to GitHub to download it; test builds expire after 30 days.

Extract the ZIP and move `Phaedrus.app` into `~/Applications` before opening it.
If Phaedrus is already running, stop it first (`pkill -x Phaedrus` in Terminal).
These builds are **ad-hoc signed, not notarized**. macOS may block the first launch;
if you trust the download, follow Apple's
[Open Anyway instructions](https://support.apple.com/en-us/102445)
in System Settings → Privacy & Security. Managed Macs may restrict this option.
Then open Phaedrus's settings and configure your shortcut as above.

## Use

1. Click into a text field.
2. Press **🎤**. A rounded recording panel appears and you hear a *tink*.
3. Speak. The colored ribbon responds to microphone input; a timer confirms the session is running. Text stays hidden until you finish. If audio buffers stop arriving, the panel says **Microphone interrupted**.
4. To stop, press **🎤** again, press **Return**, click the bubble, or stay quiet for 3 seconds.
   **Esc** cancels, also while the bubble still says "Starting…".

The text replaces the current selection, if there is one. While the bubble is visible,
Return and Esc go to Phaedrus, not to the app you're typing in.

A few apps don't accept text from Services (some Electron-based apps, for example). With
**Also copy the text to the clipboard** turned on (the default), just press ⌘V there.

## Settings

Open **Phaedrus** from Spotlight or Finder:

| Setting | Default |
|---|---|
| Shortcut: 🎤 key, or any shortcut | 🎤 key off until you enable it |
| Languages (up to 3) | English (US) |
| Mix languages in one dictation (experimental) | off |
| Stop after silence | 3 s |
| Give up if nothing is heard | 10 s |
| Longest dictation | 5 min (up to 15) |
| Also copy the text to the clipboard | on |
| Start and stop sounds | on |

The settings are stored in the `io.github.venzellucas.phaedrus` defaults domain.
The language default applies to fresh installs; updating preserves your saved selection.
To switch an existing install to English only, deselect the other languages in settings.

### Mixing Portuguese and English

Select Portuguese and English, then enable **Mix languages in one dictation (experimental)**.
For example, the intended result for “Preciso fazer o deploy hoje” keeps “deploy” in English.
With mixing disabled, the best whole-recording transcript still wins.

Mixing aligns finalized words by their audio timestamps and replaces short spans only when
another language has substantially higher confidence and covers the same speech. Missing
timing, incomplete results, or ambiguous matches retain the original transcript. It does
not translate or use a language model to rewrite what you said.

This is a conservative heuristic, not guaranteed bilingual recognition. The language models'
confidence scores may disagree even when both are wrong; borrowed words, names, and rapid
switches still need testing with real speech. If you pause to find a word, increasing **Stop
after silence** can help avoid finishing the recording too soon.

## Privacy

- Audio is processed on the Mac by Apple's speech framework. The only network traffic is
  Apple's one-time download of each language's speech model.
- Transcripts are not stored or logged. The debug log (below) records lengths and timings only.
- The clipboard copy is marked for this Mac only, so Universal Clipboard does not send it to
  your other devices. Clipboard-manager apps can still record it; turn the copy off if that matters to you.

## How it works

| File | What it does |
|---|---|
| `Sources/Engine.swift` | Microphone → `AVAudioEngine` → one `SpeechAnalyzer` with a `SpeechTranscriber` per language. The highest-confidence transcript is the baseline; optional mixing uses finalized timed words. Auto-stop combines microphone level with transcription activity. |
| `Sources/TranscriptMerger.swift` | Conservative alignment and confidence-based replacement of spans across languages. Incomplete or misaligned alternatives leave the baseline intact. |
| `Sources/HUD.swift` | Rounded recording panel, microphone-driven ribbon, elapsed time, and listening/finishing/error states. Respects Reduce Motion and Increase Contrast. |
| `Sources/App.swift` | The Service entry point, temporary global keys and the session loop. The keys use Carbon `RegisterEventHotKey`, which needs no permission, and are registered only while a session runs. |
| `Sources/SettingsView.swift` | The SwiftUI settings window. |
| `scripts/mic-key.sh` | `on`/`off`: remaps the 🎤 key (HID usage `0xC000000CF`) to F18 with `hidutil` and installs a LaunchAgent that re-applies it at login. Bundled in the app and used by the settings toggle. |
| `scripts/make-icon.swift` | Draws the icon, a black-figure Greek pottery style. `scripts/make-icon.sh` rebuilds `Resources/AppIcon.icns`. |

Why a Service? A Service returns text straight to the focused app, so Phaedrus needs no
Accessibility permission to type or paste. The trade-off is that apps without Services
support can't receive it directly, hence the clipboard copy.

### Debugging

```sh
PHAEDRUS_DEBUG=1 ~/Applications/Phaedrus.app/Contents/MacOS/Phaedrus --once
```

This runs one dictation from the terminal. The debug log on stderr has lengths and timings
only. The transcript itself is printed to stdout, since that is what the test is for.

## Uninstall

```sh
scripts/uninstall.sh
```

This removes the 🎤 remap and its login item, the app, the Services shortcut, the settings
and the microphone permission. If you delete the app by hand, run `scripts/mic-key.sh off` first.

## Limitations

- Mixed-language dictation is experimental and off by default. It can improve switches only when one of the selected recognizers supplies better words with usable timing; it cannot recover words that every recognizer misses.
- The app is ad-hoc signed and built from source. After a rebuild, macOS may ask for microphone access again.

## Contributing

Bug reports and small, focused pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for build instructions, manual checks, and what to include in a report.

## License

[MIT](LICENSE)
