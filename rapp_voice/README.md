# RAPP Voice

Hold a key anywhere on macOS, speak, release, and cleaned-up text appears at your cursor. Speech recognition runs on-device via whisper.cpp; your voice never leaves the machine. Filler stripping, app-aware formatting and a weighted personal dictionary.

A `runtime: "twin"` rapplication: it hatches into its own brainstem on port 7091 carrying only its own agent, and the host brainstem reaches it over twin-chat.

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
