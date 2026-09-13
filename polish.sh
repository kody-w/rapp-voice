#!/bin/bash
# RAPP Voice polish hook.
#   $1 = path to a file containing the dictated text (trigger word already stripped)
#   stdout = the cleaned text, nothing else
#
# Swap the body to point at Ollama instead, e.g.:
#   ollama run llama3.2 "Clean up this dictated text ... : $text"
set -euo pipefail

# Homebrew prefix differs by architecture (/opt/homebrew on Apple Silicon,
# /usr/local on Intel). Resolve rather than hardcode, or this file is a no-op
# on half the Macs it targets.
brewbin() { for p in "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
    [ -x "$p" ] && { echo "$p"; return; }; done
  command -v "$1" 2>/dev/null || echo "/opt/homebrew/bin/$1"; }

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

[ -s "$1" ] || exit 1

exec claude -p "Clean up the dictated text supplied on standard input: fix grammar, remove self-corrections and false starts, and keep the meaning and voice. Output ONLY the cleaned text." < "$1"
