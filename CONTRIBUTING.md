# Contributing to Phaedrus

Keep changes focused on reliable on-device dictation. For a larger feature, open an issue
first to discuss how it fits. No package manager or third-party dependencies are needed.

## Build

Use macOS 26 or later with Xcode Command Line Tools and the macOS 26 SDK or later.

```sh
scripts/build.sh --no-install  # compile and sign build/Phaedrus.app
scripts/test.sh                # deterministic transcript alignment fixtures
scripts/test-native-cleanup.sh # Foundation Models smoke check, synthetic text only
scripts/preview-hud.sh         # render native panel states without microphone input
scripts/build.sh               # rebuild and install to ~/Applications
open ~/Applications/Phaedrus.app
```

The install command replaces your installed Phaedrus app and stops any running instance.
Use the installed copy for Service testing so macOS does not register competing copies.
The app is ad-hoc signed; microphone permission may need to be granted again after a build.

CI checks shell syntax, compiles the app with Swift 6, and verifies its bundle and signature.
It also packages an Apple silicon test ZIP, extracts it, and checks the executable and
signature again before uploading it as a workflow artifact. You can run **Build** manually
from the Actions tab. Downloads expire after 30 days and require GitHub sign-in.
It does not exercise microphone input, keyboard shortcuts, or text insertion.
The alignment and cleanup checks use synthetic timed transcripts and injected model decisions;
passing them does not establish recognition accuracy or model quality on real bilingual audio.
The native cleanup smoke check verifies the unavailable-model fallback on CI machines without
Apple Intelligence, or bounds the output if the local model is available.

## Manual checks

For changes to dictation or settings, check these on a Mac and describe the results in your PR:

- On a fresh preferences domain, only English (US) is selected. Use a separate macOS user
  account for this check if you want to preserve your own settings.
- A saved language selection survives a rebuild and relaunch. Selecting one to three
  supported languages works, and the last selected language cannot be deselected.
- Dictation inserts text in a Services-compatible app such as TextEdit. Clipboard fallback
  works in an app that does not accept Services text.
- Return, the shortcut, a click on the bubble, and silence stop dictation. Esc cancels
  without inserting text, including during startup.
- If a stop/cancel key is already registered by another app, dictation shows a shortcut
  error before starting the microphone. After resolving the conflict, retrying works.
- Denied microphone access produces a useful message. The first use of a new language
  shows model download progress.
- The recording panel has no live transcript or square backing around its rounded corners.
  Check light/dark desktop backgrounds, Retina scaling, Reduce Motion, Increase Contrast,
  and Reduce Transparency. The ribbon expands with speech, settles during silence, and
  stops moving with “Microphone interrupted” if audio buffers stop arriving. All selected
  language codes, elapsed time, Return/click, and Esc remain usable.
- Mixing defaults off and its saved setting survives relaunch. With Portuguese and English
  selected, compare enabled/disabled for “Preciso fazer o deploy hoje”, “Send the pull request
  por favor”, longer language switches, single borrowed words, names, and monolingual speech.
  Also try three languages, a silent recording, and stopping mid-word. Verify no repeated or
  missing words at language boundaries and no translation of foreign expressions.
- Smart cleanup defaults off and survives relaunch when enabled. Settings report disabled
  Apple Intelligence, a model that isn't ready, and unsupported selected languages. Recheck
  after enabling Apple Intelligence in System Settings. With mixing off, only missing final
  punctuation may change. With mixing on, compare the same bilingual recordings with cleanup
  enabled/disabled, especially names, numbers, negations, technical terms, and dictated commands.
  Measure the extra finishing time; test long dictations and unavailable-model fallback.
  The panel should say “Refining…” only after recognition finishes, and an inference failure
  must still insert the existing transcript. Never log prompt or model-error text.
- If changing shortcuts, check enabling and disabling the mic key, a login with the
  remap enabled, and preservation of unrelated `hidutil` mappings.

For installer or uninstall changes, also check installation, reinstallation, and removal
using a separate macOS user account. Uninstall deletes the app's saved preferences.

## Website

GitHub Pages publishes `docs/` from `main`. Edit `docs/index.html`, `docs/style.css`,
or `docs/site.js`; no build tools or dependencies are needed. Preview locally with
`python3 -m http.server 8000 --directory docs` and open `http://localhost:8000`.
Check both a narrow phone layout and a desktop layout, keyboard navigation, the example,
and the copy button. Keep installation details consistent with the README.

## Bug reports and pull requests

Include your macOS version, Mac model, selected languages, target app, steps to reproduce,
and what you expected versus what happened. For build failures, include `swiftc --version`
and `xcrun --sdk macosx --show-sdk-version` output.

For a pull request, explain the behavior changed and which checks you ran. If you could
not test a hardware or macOS interaction, say so.

The [README debugging command](README.md#debugging) prints the transcript to stdout;
review terminal output before sharing it. Do not include private dictation, recordings,
or clipboard contents in an issue.
