# Contributing to Phaedrus

Keep changes focused on reliable on-device dictation. For a larger feature, open an issue
first to discuss how it fits. No package manager or third-party dependencies are needed.

## Build

Use macOS 26 or later with Xcode Command Line Tools and the macOS 26 SDK or later.

```sh
scripts/build.sh --no-install  # compile and sign build/Phaedrus.app
scripts/test.sh                # deterministic transcript alignment fixtures
scripts/test-native-cleanup.sh # Foundation Models smoke check, synthetic text only
scripts/test-session-settings.sh # native pause/resume/settings checks, fake recognizers
scripts/preview-hud.sh         # render native panel/settings states without microphone input
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
It does not exercise real microphone input, physical key events, or Services text insertion.
Native session tests use fake recognizers to exercise the actual nested event loop, settings
loading, menu command, pause/resume, startup cancellation, failed restart, and saved text.
They also inject cleanup availability to verify repeated manual checks present native dialogs,
automatic refreshes stay quiet, and readiness changes leave cleanup opt-in.
They verify the saved review style and that Natural/Written run without timed alternatives only
when cleanup is enabled. Natural fixtures cover Portuguese/English cuts, identifiers and
negations, incomplete output, paragraph preservation, long input, and partial timeout results.
Written fixtures also cover grammar, contractions, spelling corrections, speaker changes,
content-word reordering, modality, and preservation of names and numbers.
The alignment and cleanup checks use synthetic timed transcripts and injected model decisions;
passing them does not establish recognition accuracy or model quality on real bilingual audio.
The native cleanup smoke check verifies the unavailable-model fallback on CI machines without
Apple Intelligence, or bounds the output if the local model is available.

## Visual system

`Sources/DesignSystem.swift` owns the shared colors, spacing, typography, radii, and native
settings components. Warm neutral surfaces follow system appearance; terracotta marks
selection, and the recording ribbon shares its coral/violet/blue/mint palette with Settings.
The recording panel stays dark for legibility over other apps. Preserve semantic status
labels, keyboard focus, increased-contrast borders, and the existing motion/transparency
accessibility behavior when adding components.

`scripts/preview-hud.sh` captures all four settings pages in light/dark appearance, setup
needed, a compact paused window, a high-contrast window appearance, and every recording state.
System accessibility preferences still require the interactive checks below. These are
real native views with synthetic data, not screenshots of a web mockup. Inspect them with:

```sh
open build/hud-previews/settings-languages-light.png
open build/hud-previews/settings-cleanup-dark.png
open build/hud-previews/listening.png
open build/hud-previews/listening-live.gif
```

The CI preview artifact includes these images, a native animated GIF fed with synthetic
syllables and silence, and the native session-test captures. The listening ribbon keeps
90 meter values (about three seconds) and uses the existing microphone measurement;
it does not retain PCM audio or run another recognition model. Its timer stays at 30 fps.
The GIF demonstrates visual behavior, not microphone latency or battery usage. The preview
harness explicitly captures both motion modes, because CI Macs can have Reduce Motion
enabled. Production always follows the user's macOS preference.

## Manual checks

For changes to dictation or settings, check these on a Mac and describe the results in your PR:

- Visit all four settings pages in light/dark appearance and at the minimum window size.
  Search languages, clear the search, and verify selected languages appear first. Tab through
  controls with Full Keyboard Access; check VoiceOver labels and Increase Contrast. While
  paused, navigate pages and scroll: Resume, Finish, and Cancel must stay visible and retain
  their keyboard shortcuts. Return/close must resume in the original target app.
- On a fresh preferences domain, only English (US) is selected. Use a separate macOS user
  account for this check if you want to preserve your own settings.
- A saved language selection survives a rebuild and relaunch. Selecting one to three
  supported languages works, and the last selected language cannot be deselected.
- Dictation inserts text in a Services-compatible app such as TextEdit. Clipboard fallback
  works in an app that does not accept Services text.
- Return, the shortcut, a click on the bubble, and silence stop dictation. Esc cancels
  without inserting text, including during startup.
- Press ⌘, while recording, including while starting a model. Confirm the microphone is off
  before paused Settings appears, the language list loads, and changing languages then pressing
  Return or closing the window resumes in the original target app. Earlier and later words
  must be inserted together once. Repeat several pauses; verify the timer excludes paused time.
  Test Finish and insert / ⌘Return, Esc, a silent resumed segment, and a failed restart.
- Assign a separate shortcut to the no-input “Phaedrus Settings” Service. Check it opens
  Settings from another app with Phaedrus closed, and pauses an active recording. Opening it
  must not change the caller's text or clipboard. Other apps retain their usual ⌘, behavior
  when Phaedrus is not recording.
- If a stop/cancel key is already registered by another app, dictation shows a shortcut
  error before starting the microphone. After resolving the conflict, retrying works.
- Denied microphone access produces a useful message. The first use of a new language
  shows model download progress.
- The recording panel has no live transcript or square backing around its rounded corners.
  Check light/dark desktop backgrounds, Retina scaling, Reduce Motion, Increase Contrast,
  and Reduce Transparency. Distinct syllables should form smooth peaks entering from the
  right and moving left, with pauses between them; after three seconds of silence the
  trail should become flat. New recordings and resumed segments must start with an empty
  trail. Reduce Motion replaces the traveling history with a stationary level indicator.
  The ribbon stops moving with “Microphone interrupted” if audio buffers stop arriving. All selected
  language codes, elapsed time, Return/click, and Esc remain usable.
- Mixing defaults off and its saved setting survives relaunch. With Portuguese and English
  selected, compare enabled/disabled for “Preciso fazer o deploy hoje”, “Send the pull request
  por favor”, longer language switches, single borrowed words, names, and monolingual speech.
  Also try three languages, a silent recording, and stopping mid-word. Verify no repeated or
  missing words at language boundaries and no translation of foreign expressions.
- Smart cleanup defaults off and survives relaunch when enabled. Settings report disabled
  Apple Intelligence, a model that isn't ready, and unsupported selected languages. Recheck
  an unchanged status twice: each click must open a result dialog. Open System Settings from
  the dialog, choose Apple Intelligence & Siri, and confirm returning refreshes availability.
  An availability check must not enable cleanup or start inference. Recheck
  after enabling Apple Intelligence in System Settings. With Conservative and mixing off, only missing final
  punctuation may change. With mixing on, compare the same bilingual recordings with cleanup
  enabled/disabled, especially names, numbers, negations, technical terms, and dictated commands.
  Measure the extra finishing time; test long dictations and unavailable-model fallback.
  The panel should say “Refining…” only after recognition finishes, and an inference failure
  must still insert the existing transcript. Never log prompt or model-error text.
- Switch **Review style** between Conservative, Natural, and Written, relaunch, and confirm it is saved.
  Compare “Eu, tipo, eu queria fazer o deploy, né.”, “Uh, I I need the pull request today”,
  “Não, não quero fazer isso”, “Eu não quero esse tipo de mudança”, and “It's very, very
  important”. Natural should remove disfluencies while retaining meaningful uses of fillers,
  emphasis, names, numbers, uncertainty, and negations. Also test single-language input,
  multiple paragraphs, long dictations, and no-timing fallbacks. A valid but unchanged result
  is allowed; synthetic fixtures do not establish actual model fluency. Both review stages
  together must return within ten seconds in Natural, preserving all unprocessed text.
- In Written, compare “Eu tô testando pra ver se eles vai entender”, “Eu lavei o carro”,
  “A gente fomos buscar as criança”, and bilingual grammar errors. Check that the app
  retains first person, tense, tone, uncertainty, negations, technical terms, and idea order.
  Try spoken commands/questions to confirm they are edited as dictation rather than answered.
  Review actual word substitutions carefully; fixture success cannot prove semantic fidelity.
  Both stages share fifteen seconds, with unchanged text preserved on failure or timeout.
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

## Branches and releases

`main` requires a pull request and the **macOS build and tests** check against the latest
base branch. Direct pushes, force pushes, and deletion are blocked, with no administrator
bypass. Human approval is not mandatory, so a solo maintainer can still merge a green PR.
Create a short-lived feature branch for each change; merged branches are deleted.

To publish, update both version fields in `Resources/Info.plist` in a PR and pass the checks.
After merging, download the verified app ZIP from the successful `main` Build run for that
exact merge commit. Publish a version tag and GitHub release on that commit, attach
`Phaedrus-macOS-arm64.zip` and `SHA256SUMS.txt`, and retain the ad-hoc signing/first-launch
instructions. Verify the public download checksum and the Pages deployment before closing
out the release. The website and README use the latest release's stable download URL.

## Bug reports and pull requests

Include your macOS version, Mac model, selected languages, target app, steps to reproduce,
and what you expected versus what happened. For build failures, include `swiftc --version`
and `xcrun --sdk macosx --show-sdk-version` output.

For a pull request, explain the behavior changed and which checks you ran. If you could
not test a hardware or macOS interaction, say so.

The [README debugging command](README.md#debugging) prints the transcript to stdout;
review terminal output before sharing it. Do not include private dictation, recordings,
or clipboard contents in an issue.
