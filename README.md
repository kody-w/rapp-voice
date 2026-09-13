# RAPP Voice

Hold a key anywhere on macOS, speak, release — cleaned-up text appears at your
cursor in whatever app is in front.

## Native macOS app — 1.1.0

### Download the released app

[RAPP Voice v1.1.0](https://github.com/kody-w/rapp-voice/releases/tag/v1.1.0)
is available for macOS 14+. Each ZIP contains a Developer ID-signed,
notarized application with a stapled ticket.

| Mac | Download | Publisher release report |
|---|---|---|
| Apple Silicon | [arm64 ZIP](https://github.com/kody-w/rapp-voice/releases/download/v1.1.0/rapp_voice-1.1.0-arm64.zip) | [Evidence JSON](https://github.com/kody-w/rapp-voice/releases/download/v1.1.0/rapp_voice-1.1.0-arm64.zip.evidence.json) |
| Intel | [x86_64 ZIP](https://github.com/kody-w/rapp-voice/releases/download/v1.1.0/rapp_voice-1.1.0-x86_64.zip) | [Evidence JSON](https://github.com/kody-w/rapp-voice/releases/download/v1.1.0/rapp_voice-1.1.0-x86_64.zip.evidence.json) |

Expand the matching ZIP in Finder, drag **RAPPVoice.app** into **Applications**,
and launch it there. Download a verified speech model in Setup before dictating;
the model weights are separate from the app download. The Python integration
and legacy `install.sh` are **not** the native application installer.

Release tag `v1.1.0` is bound to native source
`45e5529509c04b2b346e27b8b8a82c59cb5ec32d`, with
[successful source-bound native CI](https://github.com/kody-w/rapp-voice/actions/runs/34733631656).
The reports above describe the enclosed app's actual signing, Gatekeeper, and
stapler checks; the archive hashes and sizes are recorded in the federation
metadata. Publisher reports are not an independent Apple or RAPP Store
certification. Later metadata-only commits do not change the native source or
the release tag.

`native/` is a real **macOS 14+ SwiftUI/AppKit application**, not a Hammerspoon
launcher. It owns microphone capture through AVFoundation, produces mono 16 kHz
16-bit PCM WAV, and uses the bundled [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
engine through RAPP Tools' shared desktop support. **No Hammerspoon, Homebrew,
ffmpeg, localhost server, account, or API key is required at runtime.**

```
explicit hold / Start → app-owned AVFoundation microphone → mono 16 kHz PCM WAV
release / Stop        → bundled whisper-cli + weighted dictionary prompt
                      → local cleanup + app-aware formatting
                      → verified safe target, or visible Copy / manual-paste result
```

Audio work files are deleted after completion, errors, or cancellation. Native
diagnostics store counts and status, **not transcripts**. Capture never starts
on launch or as a side effect of a model download or permission grant. The app
does not run the optional legacy polish hook unless separately consented.

### Native setup and use

1. Open **RAPP Voice → Setup**. Enable Microphone; granting it records nothing.
2. Select **Base English** (~148 MB) or **Small English** (~488 MB). Press
   **Download / retry** and wait for size/SHA-256 verification. Progress,
   cancellation, errors, and retry are visible. Save the model selection.
3. For the all-app shortcut and automatic insertion, grant **Accessibility**
   and **Input Monitoring** to **RAPP Voice**, then refresh grants or reopen
   the app if macOS requires it. Without these, buttons, the own-app shortcut,
   transcript review, and Copy/manual-paste remain usable.
4. Focus a normal text field. **Hold Right ⌘**, speak, then release. Short taps
   are discarded. **Double-tap** for hands-free recording; tap again or press
   **Stop & transcribe**. **Cancel** or Escape stops work, invalidates late
   results, and deletes that session's audio.

The selected modifier is reserved **exclusively**. Use the opposite-side
modifier for normal shortcuts. A dedicated session event-tap thread handles
press/release in other apps **and RAPP Voice itself** without blocking behind
model verification or microphone startup. Without global grants a local event
monitor handles only this app. Settings include modifier choice, paste/type/manual
insertion, language, recording limit, and clipboard restore delay.

The original process, field, and selection must still match before automatic
insertion. Secure Input, protected/unknown fields, missing event permissions,
held modifiers, focus changes, and clipboard conflicts use a clearly labeled
manual path. The app never activates another app or forces protected input.
**“Copied only” is not “pasted.”** Keyboard-event delivery is labeled
“paste shortcut sent” or “typing events sent,” not a confirmed target write.
Only a verified insertion into RAPP Voice's own editor is labeled inserted.

Paste mode snapshots every available pasteboard item/representation, including
images and file URLs, and restores even an originally empty clipboard. A newer
clipboard change is never overwritten. A clipboard that cannot be preserved
fully is left untouched. Manual mode changes the clipboard **only** when you
press Copy. Type mode avoids it completely; review the target after an
interrupted partial typing operation.

Defaults retain the Lua behavior: 0.25s tap, 0.35s double-tap window and minimum
audio duration, 600s hard recording limit, 0.05s paste delay, and 0.25s clipboard
restore delay. Native transcription has a 120s deadline; polish has a 60s deadline.
Digital silence, short WAVs, annotations, and transcripts without words insert
nothing. The native CLI loads a model per job, so the legacy resident-server
latency measurements below are **not native performance claims**.

### Dictionary, state, and optional polish

Native dictation reads **the existing `~/.rappvoice/dictionary.txt`** at each
recording. The GUI supports canonical terms and `heard text => Canonical Term`
rewrites, literal punctuation/digits, deduplicated twice-weighted recognizer
prompts, and longest-rewrite-first processing. Saving detects external edits
instead of silently overwriting them. Native dictionaries are bounded to 64 KiB
and reject NUL characters before recording starts. Fillers, sentence case, raw terminal/editor
formatting, and dictionary casing have regression fixtures derived from the Lua
acceptance suite.

Native settings, verified models, status-only diagnostics, and per-job work live
under `~/Library/Application Support/io.rapp.voice/`. Existing `~/.rappvoice`
models, hooks, logs, and all root Lua/Hammerspoon files are preserved. Native
settings do not rewrite `CONFIG` in `rappvoice.lua`.

**Polish is OFF by default, even if `~/.rappvoice/hooks/polish.sh` exists.**
The Optional polish tab discloses exactly which executable will receive the
triggered transcript, asks for its provider/data recipient, and requires explicit
consent. The legacy shipped hook uses Claude/Anthropic and may incur charges;
review the file before enabling it. A hook is arbitrary user-chosen executable
code, not an app-managed cloud service. Microphone audio is not passed to it.
Changing the selected provider or path invalidates consent.

When disabled, “polish” is ordinary dictated text and all cleanup stays local.
When consented, saying “polish” first invokes the reviewed executable with the
remaining text in a file. A failed, empty, or timed-out hook preserves useful
local text and is labeled local fallback; cancellation never inserts that
fallback. Model downloads are the only native network use without optional
polish. Driving the existing twin over `/chat` is separate and can use its
host brainstem's LLM.

### Build and safe tests

Development needs Xcode 16+ / Swift 6. Both `native/Package.swift` and
`native/project.yml` pin `https://github.com/kody-w/rapp-tools.git` to
`f0bc616c2aed34f2a88888806ed056ec7bafba61`; no sibling checkout is needed.
The SwiftPM and generated Xcode workspace `Package.resolved` files are committed
as well, so dependency resolution is reproducible independently of this workspace.
The current shared `SpeechTranscriber` has no prompt parameter: the
dictionary-biased path therefore supplies `--prompt` to the same bundled
`whisper-cli` through shared `RuntimeTools` / `ProcessRunner`. Unweighted ASR uses
`SpeechTranscriber` directly. No model transport, checksum, or process-lifecycle
helper is duplicated.

```bash
cd native
swift test -j 2
swift build -j 2
# XcodeGen produces the actual application/core/test targets:
xcodegen generate --spec project.yml
xcodebuild -project RAPPVoice.xcodeproj -scheme RAPPVoice \
  -configuration Release -derivedDataPath DerivedData \
  -jobs 2 CODE_SIGNING_ALLOWED=NO build
cd ..
./tools/dryrun.sh --safe
```

On a development host with Git's `safe.bareRepository=explicit`, SwiftPM's
managed bare dependency clones may be rejected. For this approved pinned
dependency, scope any exception to the build command, for example
`env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift package resolve`.
Use the same command-scoped environment for Xcode package resolution if needed;
do not change global Git policy or identity.

`swift build` builds the native executable, not a signed `.app`. Release
packaging must put the appropriate `whisper-cli` and its runtime libraries at
`RAPPVoice.app/Contents/Resources/runtime/bin/`, then sign the app and its nested
code and complete the release's notarization/publication checks. Source builds
must not be represented as notarized downloads. The source targets arm64 and
x86_64, macOS 14.0+. `RAPP_RUNTIME_BIN` is an explicit development override;
there is no implicit PATH/Homebrew runtime fallback.

Safe tests use deterministic transcript fixtures, synthetic PCM samples, mock
input/pasteboards, and isolated dictionaries under `native/.build/`. They never
record the microphone, inject events, invoke paid APIs, download models, or
change the user's clipboard/state. Native tests cover formatting, weighting,
press/release/latch transitions, permission/model failures, cancellation,
deadlines, WAV validation, polish consent/fallback, insertion policy, and
pasteboard ownership. Adapter tests also exercise the built native action CLI.

### Native CI and source freeze

`.github/workflows/native-ci.yml` runs the same-repository checks on
`macos-latest` (**arm64**) and `macos-15-intel` (**x86_64**) for pushes,
pull requests, and manual dispatch. Each job checks its actual host architecture,
runs the safe Swift and adapter suites, builds an unsigned architecture-specific
`.app`, runs the Xcode core tests, and reruns the adapter checks against that
built app's action CLI. XcodeGen is installed only if the runner lacks it.

The exact local/CI entry points are:

```bash
./tools/native-ci.sh arm64    # on an Apple Silicon host
./tools/native-ci.sh x86_64   # on an Intel host
```

The script uses `swift test -j 2`, `swift build -j 2`, Xcode `-jobs 2` with
`CODE_SIGNING_ALLOWED=NO`, and `python3 -B tools/test_native_adapter.py`.
It never launches the GUI, records speech, grants TCC permissions, downloads
models, invokes polish, signs, or publishes. Its derived data and result bundles
stay inside `native/.build/ci/`, separate from release packaging outputs.

The workflow has read-only repository permissions and no signing secrets.
For release publication, use a successful public push/dispatch run whose
`head_sha` equals the final native-build commit; a PR merge-snapshot check is not
that source-freeze reference. Concurrency includes the source SHA, so a later
metadata-only commit does not cancel verification of the frozen native source.
This CI run verifies source/build behavior, not Apple signing or notarization.

Real-device acceptance still requires a human on the final signed app:
Microphone/TCC onboarding; physical modifier behavior in both this app and
TextEdit/Notes/Terminal/Electron; latch/Stop/Escape and sleep cancellation;
changing the focused field during ASR; Secure Input/password-field refusal;
rich clipboard restoration with an active clipboard manager; and actual speech
recognition with the bundled engine. Autonomous tests deliberately do not claim
those grants, recordings, signing, or notarization results.

### Native agent/CLI compatibility

Both singleton and twin adapters discover an installed `RAPPVoice.app` in
`/Applications` or `~/Applications` (both spaced and unspaced names), or an
explicit `RAPPVOICE_NATIVE_CLI`. They send typed JSON to the executable:

```bash
printf '%s' '{"action":"process","text":"um git status","app":"Terminal"}' \
  | /Applications/RAPPVoice.app/Contents/MacOS/RAPPVoice --action
```

The existing five actions remain `doctor`, `dictionary`, `add_term`, `stats`,
and `process`. Responses are bounded-action JSON with `ok`, `runtime`, `version`,
`action`, and `text`; no Grail/protocol/manifest identity or retired egg changes
are made. No action can capture, paste, run a shell, or invoke polish.
`doctor` reports native readiness without opening the mic or requesting grants.
Adapters use legacy `hs` / localhost only if no native executable is present;
a native failure is reported, never silently retried through legacy side effects.
Tests/developers can isolate state with `RAPPVOICE_HOME` and
`RAPPVOICE_NATIVE_HOME`; normal operation preserves the existing home directory.

---

## Legacy Hammerspoon compatibility

The rest of this document describes the retained Lua runtime, not native app
requirements. Its historical measured Apple M4 latency was **142–350 ms** with a
resident whisper-server. Do not run both runtimes' same global shortcut at once;
disable the legacy module when using the native shortcut.

### Legacy install

```bash
git clone https://github.com/kody-w/rapp-voice.git
cd rapp-voice
./install.sh
```

The installer is idempotent — safe to re-run. It installs `ffmpeg`,
`whisper-cpp` and Hammerspoon via Homebrew, downloads the two speech models
(~630 MB total) into `~/.rappvoice/models/`, links the Lua files into
`~/.hammerspoon/`, and starts the speech server.

It will not overwrite a `dictionary.txt` or a `hooks/polish.sh` you have edited.

### Permissions — both are required

**1. Accessibility** — for the key tap and the ⌘V injection.

> System Settings → Privacy & Security → **Accessibility** → enable **Hammerspoon**

Without this the hotkey does nothing at all. RAPP Voice shows an alert on load if
it is missing.

**2. Microphone** — for recording.

Your *first* recording triggers the microphone prompt for Hammerspoon. Approve
it. That first attempt inserts nothing; just hold the key again afterwards. If
the prompt never appears, add it by hand:

> System Settings → Privacy & Security → **Microphone** → enable **Hammerspoon**

**3. Reload after granting either permission** — Hammerspoon menubar → *Reload
Config*, or the RAPP Voice `◌` menu → *Reload Hammerspoon config*.

---

## Use

| Action | Result |
|---|---|
| **Hold Right ⌘**, speak, release | Text inserted at your cursor |
| **Double-tap Right ⌘** | Hands-free recording; **tap again** to finish |
| Tap the key once | Nothing — taps are never dictations |
| Press/release with no speech | Nothing inserted, no error |

Menubar: `◌` idle · `🔴` recording · `⋯` transcribing. The menu has server
status, a server restart, and a config reload.

Say **"polish"** as the first word to route the rest through an LLM cleanup pass
(see below) — that costs seconds, so it is opt-in per dictation.

---

## What the post-processing does

Whisper gives you a raw sentence; RAPP Voice makes it look like you typed it.

- **Trims** whitespace and drops whisper's non-speech annotations (`[BLANK_AUDIO]`,
  `*laughs*`).
- **Strips filler words** on word boundaries, then repairs the punctuation the
  removal leaves behind:
  `"Um, so this is, uh, basically the plan."` → `"So this is, basically the plan."`
- **Sentence-cases** and adds terminal punctuation.
- **App-aware:** in a terminal or a code editor it does the opposite — it
  *removes* the capital and the trailing period whisper added, because
  `"Git status."` is not what you wanted in a shell:

  | Frontmost app | `"git status"` becomes |
  |---|---|
  | TextEdit, Notes, Slack… | `Git status.` |
  | Terminal, VS Code, Cursor… | `git status` |

- **Applies your dictionary** (below).
- **Silence guard:** a recording shorter than `minRecordSeconds`, or a
  transcript with no words in it, inserts nothing and raises no dialog.

---

## Personal dictionary

`~/.rappvoice/dictionary.txt`, one entry per line. Edits apply on your next
dictation — no reload.

```
Kubernetes
PostgreSQL
OpenRappter
```

Every term is fed to the recogniser as a decoding bias, and then enforced in the
output so the spelling and casing come out exactly as written here.

The bias is **weighted** — each term is emitted twice in the prompt. That is not
cosmetic. For an invented word that sounds like a real one, a plain comma-joined
list is not enough:

```
"OpenRappter, RappterStore, ..."               ->  "OpenRaptor"    wrong
"OpenRappter. OpenRappter. RappterStore. ..."  ->  "OpenRappter"   right
```

Weighting costs nothing and does not bleed your terms into unrelated speech
(checked against fixtures that contain none of them, including silence).

If a term is a true homophone of a real word and biasing still cannot land it,
add an explicit rewrite instead:

```
heard text => Term
```

Keep the left side multi-word or clearly invented — a bare one-word rewrite would
also corrupt genuine uses of the real word.

---

## Optional LLM polish

Say `"polish"` first and the rest of the transcript is piped through
`~/.rappvoice/hooks/polish.sh` before insertion. The shipped hook uses the
`claude` CLI:

```
"polish um I think we should uh maybe possibly consider shipping it"
                            ↓
"I think we should consider shipping it."
```

It is a plain shell script — `$1` is a file holding the text, stdout is the
cleaned result — so point it anywhere. For a fully offline polish, use Ollama:

```bash
#!/bin/bash
text="$(cat "$1")"
ollama run llama3.2 "Fix grammar and remove false starts. Output only the cleaned text: $text"
```

If the hook fails or times out, the un-polished transcript is inserted rather
than losing the dictation.

---

## Config reference

All of it is the `CONFIG` table at the top of `rappvoice.lua`.

| Key | Default | Meaning |
|---|---|---|
| `hotkey` | `"rightCmd"` | `rightCmd`, `leftCmd`, `rightOption`, `leftOption`, `rightShift`, `leftShift`, `fn` |
| `model` | `ggml-small.en.bin` | Primary model, kept resident |
| `fallbackModel` | `ggml-base.en.bin` | Used by the `whisper-cli` fallback |
| `port` | `8765` | whisper-server port |
| `language` | `"en"` | `"auto"` to detect (needs a multilingual model) |
| `audioDevice` | `":default"` | avfoundation device. **The leading colon is required.** |
| `minRecordSeconds` | `0.35` | Shorter recordings count as silence |
| `maxRecordSeconds` | `600` | Hard stop, so a stuck latch cannot run forever |
| `insertMethod` | `"paste"` | `"paste"` (clipboard + ⌘V) or `"type"` (simulated keystrokes) |
| `pasteDelay` | `0.05` | Seconds between setting the clipboard and ⌘V |
| `clipboardRestoreDelay` | `0.25` | Seconds after ⌘V before your clipboard is put back |
| `fillers` | `um, uh, uhm, erm, hmm, mhm, you know` | Removed on word boundaries |
| `rawApps` | Terminal, iTerm2, Ghostty, VS Code, Cursor, Alacritty, kitty, WezTerm, Warp | Apps that get unformatted text (name **or** bundle ID) |
| `polishTrigger` | `"polish"` | Spoken word that routes through the hook |
| `polishTimeout` | `60` | Seconds before a hung hook gives up and inserts the un-polished text |
| `doubleTapSeconds` | `0.35` | Max gap for a double-tap to latch |
| `tapMaxSeconds` | `0.25` | A hold shorter than this is a tap, not a dictation |
| `sounds` | `true` | Cue when the mic opens, and when text lands |

### Common changes

**Change the hotkey** — `CONFIG.hotkey = "fn"`, then reload.

**Swap the model** — download another `ggml-*.bin` into `~/.rappvoice/models/`,
point `CONFIG.model` at it, then use the menubar's *Restart speech server*.
`small.en` is the accuracy/latency sweet spot; `medium.en` is noticeably better
on hard audio and roughly 3× slower; `base.en` is fastest.

**Preserve your clipboard manager's history** — `insertMethod = "type"`. Slower
for long text, but it never touches the clipboard.

---

## Logs and profiling

`~/.rappvoice/logs/rappvoice.log` — one JSON object per event.

```json
{"event":"dictation","app":"TextEdit","raw_mode":false,"engine":"server",
 "mic_open_ms":312,"ffmpeg_exit_ms":41,"asr_ms":154,"post_ms":0,"insert_ms":1,
 "total_ms":183,
 "raw":" Hello world, this is a test.\n","text":"Hello world, this is a test."}
```

`total_ms` is the number that matters: key-release → clipboard set (the ⌘V
itself lands `pasteDelay` later). `mic_open_ms`
is how long avfoundation took to open the device on key-*down* — that window is
before the start cue, which is why the cue plays only once capture is truly live.

Server output is in `whisper-server.log`.

---

## Tests

```bash
./tools/dryrun.sh --safe         # default: hermetic native + adapter tests
./tools/dryrun.sh --legacy-live  # explicit, interactive legacy acceptance only
```

The historical suite contains 41 assertions. **It is not microphone/clipboard/cloud
safe**: some speech is synthesised with
`say`, then pushed through the real pipeline via the Hammerspoon `hs` CLI. It
covers latency, filler stripping, app-aware raw mode, the dictionary (including
terms with digits and terms ending in punctuation), both silence guards, the
clipboard save/restore for text *and* images, the polish hook, and the
whisper-cli fallback with the server deliberately killed. It uses its own fixture
dictionary, so your personal one does not affect the results.

The hotkey state machine — tap, double-tap latch, long hold — is covered too, by
`tools/statemachine.lua`, which the suite runs. It drives the press/release logic
with synthetic events paced against the real `tapMaxSeconds` and
`doubleTapSeconds` windows, but those state transitions **open the real microphone**.
It also modifies the live clipboard, restarts services, and can call the paid
polish hook. Do not run `--legacy-live` in autonomous validation.

What is left for a human, because only the real eventtap and a real ⌘V can
exercise it:

1. Hold Right ⌘ in TextEdit, say *"hello world this is a test"*, release —
   confirms the real hotkey and that ⌘V lands in the app.
2. Repeat in Notes, Safari's address bar, and VS Code (Electron).

---

## Troubleshooting

**Nothing happens when I hold the key.** Accessibility is not granted, or the
config was not reloaded after granting it. Check:
`hs -c 'print(hs.accessibilityState())'`.

**Text appears in the wrong app.** The target is captured on key-*down*. Click
into the field you want before you start holding.

**The first word gets clipped.** avfoundation needs ~300 ms to open the mic. The
start cue plays when capture is actually live — wait for it.

**Nothing is inserted and the log says `silence_skipped`.** Either the recording
was under `minRecordSeconds`, or whisper heard no words. `raw` in the log entry
shows what it did hear.

**Latency got worse.** Check the server is still resident:
`pgrep -f whisper-server`. If it died, RAPP Voice falls back to `whisper-cli`,
which reloads the model on every call — seconds instead of milliseconds. The
menubar menu shows server status and can restart it.

**A `⌘V` fires but the text is stale.** Raise `pasteDelay`; some Electron apps
read the pasteboard lazily.

---

## Uninstall

```bash
rm -rf ~/.rappvoice ~/.hammerspoon/rappvoice.lua
pkill -f whisper-server
# and remove the require("rappvoice") line from ~/.hammerspoon/init.lua
```

---

## Layout

```
~/.hammerspoon/init.lua        → require("rappvoice") + the ipc listener
~/.hammerspoon/rappvoice.lua   → symlink to this repo's rappvoice.lua
~/.rappvoice/
  models/                      ggml-small.en.bin, ggml-base.en.bin
  dictionary.txt               your vocabulary
  hooks/polish.sh              the LLM polish hook
  logs/                        rappvoice.log, whisper-server.log
```

`init.lua` also starts Hammerspoon's `hs.ipc` listener, which is what provides
the `hs` shell CLI the test suite drives. It is local-only. Delete those lines if
you would rather not have it — dictation is unaffected; only the tests stop
working.

Built with [whisper.cpp](https://github.com/ggerganov/whisper.cpp),
[Hammerspoon](https://www.hammerspoon.org), and ffmpeg. MIT.
