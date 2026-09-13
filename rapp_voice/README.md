# RAPP Voice

Native macOS dictation with local whisper.cpp recognition, a weighted dictionary,
app-aware cleanup, and safe insertion or manual-copy fallback. Optional cloud
polish is off until explicitly consented.

The native application is the primary desktop download. This source package
retains its existing `runtime: "twin"` integration and port 7091: the Python
singleton/UI and twin are secondary integration, not a native app installer.
The retired egg is unchanged and is not the 1.1.0 desktop download.

## Native downloads — 1.1.0

- [Apple Silicon / arm64 ZIP](https://github.com/kody-w/rapp-voice/releases/download/v1.1.0/rapp_voice-1.1.0-arm64.zip)
  · [publisher release report](https://github.com/kody-w/rapp-voice/releases/download/v1.1.0/rapp_voice-1.1.0-arm64.zip.evidence.json)
- [Intel / x86_64 ZIP](https://github.com/kody-w/rapp-voice/releases/download/v1.1.0/rapp_voice-1.1.0-x86_64.zip)
  · [publisher release report](https://github.com/kody-w/rapp-voice/releases/download/v1.1.0/rapp_voice-1.1.0-x86_64.zip.evidence.json)

Expand the correct ZIP in Finder, move **RAPPVoice.app** into **Applications**,
then launch it and complete microphone/model setup. The ZIPs contain the signed,
notarized/stapled native app; their exact live byte counts and SHA-256 values are
in `manifest.json` and `index_entry.json`.

The [release](https://github.com/kody-w/rapp-voice/releases/tag/v1.1.0) and
[successful native CI run](https://github.com/kody-w/rapp-voice/actions/runs/34733631656)
refer to native source `45e5529509c04b2b346e27b8b8a82c59cb5ec32d`.
Federation resolves this later metadata revision separately and pins integration
URLs to that metadata commit. Publisher reports are inspectable evidence, not
independent Apple authentication or RAPP Store acceptance.

## Actions

- `doctor`
- `dictionary`
- `add_term`
- `stats`
- `process`

## Requires

The native **RAPP Voice 1.1.0** app (macOS 14+) and a downloaded, verified
on-device model for dictation. The adapter discovers `RAPPVoice.app` in
`/Applications` or `~/Applications`, or `RAPPVOICE_NATIVE_CLI`, and invokes its
existing five actions as typed JSON (`RAPPVoice --action`). None of these actions
can record, insert text, execute a shell, or invoke polish. Native failures are
reported without replaying side effects.

When no native app is installed, legacy Hammerspoon `hs` / localhost speech-server
integration is retained. `RAPPVOICE_HOME` still selects the dictionary/log
directory. No protocol/manifest identities or retired eggs are changed.

Dictation and cleanup run locally. Optional executable polish is disabled until
the user reviews its provider/hook disclosure and explicitly consents in the
native GUI; the legacy supplied hook can transmit text to Claude/Anthropic.
Twin `/chat` may separately use its host's LLM.

See https://github.com/kody-w/rapp-voice for build, permissions, and safe tests.

MIT.
