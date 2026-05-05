#!/usr/bin/env bash
# whisper-dictate: transcribe a WAV file with whisper.cpp (small model, on-device)
# and inject the result into the focused app.
#
# Usage: dictate.sh /path/to/audio.wav

set -u

WAV="${1:-}"
if [ -z "$WAV" ] || [ ! -f "$WAV" ]; then
  echo "dictate.sh: missing or invalid WAV path: $WAV" >&2
  exit 1
fi

# --- Hardcoded paths (Apple Silicon Homebrew + project model) ---
WHISPER_BIN="/opt/homebrew/bin/whisper-cli"
MODEL="/Users/bardiabarabadi/whisper-dictate/models/ggml-small.bin"
OUT_BASE="/tmp/whisper_rec_out"   # whisper-cli appends .txt

# --- Run transcription. -nt drops timestamps, -np silences progress noise,
#     -otxt writes the plain text to <OUT_BASE>.txt. Metal is auto-used on
#     Apple Silicon when the bottle is built with Metal support. ---
"$WHISPER_BIN" \
  -m "$MODEL" \
  -f "$WAV" \
  -l en \
  -nt \
  -np \
  -otxt \
  -of "$OUT_BASE" \
  >/dev/null 2>&1

TXT_FILE="${OUT_BASE}.txt"
if [ ! -f "$TXT_FILE" ]; then
  echo "dictate.sh: transcription produced no output file" >&2
  exit 2
fi

# --- Clean up: drop [BLANK_AUDIO] / [SILENCE] markers, drop bracketed
#     timestamp lines like [00:00:00.000 -> 00:00:02.000], collapse blank
#     lines, trim leading/trailing whitespace. ---
TEXT="$(
  sed -E \
    -e 's/\[BLANK_AUDIO\]//g' \
    -e 's/\[SILENCE\]//g' \
    -e 's/\[[0-9:.[:space:]]+-+>[0-9:.[:space:]]+\]//g' \
    "$TXT_FILE" \
  | awk 'NF' \
  | tr '\n' ' ' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
)"

# Nothing to type? exit silently.
if [ -z "$TEXT" ]; then
  exit 0
fi

# --- Inject text into the focused window ---
# Short text: keystroke directly via System Events (works in iTerm2, SSH, etc.)
# Longer text: clipboard swap + Cmd+V, restoring the original clipboard after
# a short delay so we don't clobber whatever the user had copied.
LEN=${#TEXT}

# Escape backslashes and double-quotes for AppleScript string literal.
escape_for_applescript() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

ESCAPED="$(escape_for_applescript "$TEXT")"

if [ "$LEN" -lt 80 ]; then
  /usr/bin/osascript -e "tell application \"System Events\" to keystroke \"$ESCAPED\""
else
  # Save current clipboard to a temp file (handles binary-ish content reasonably
  # via base64). pbpaste returns text; if the clipboard has non-text data we
  # just won't be able to restore it perfectly — acceptable trade-off.
  ORIG_CLIP="$(pbpaste 2>/dev/null || true)"

  # Put new text on clipboard
  printf '%s' "$TEXT" | pbcopy

  # Paste into focused app
  /usr/bin/osascript -e 'tell application "System Events" to keystroke "v" using {command down}'

  # Give the focused app a moment to actually consume the paste before we
  # restore the original clipboard.
  sleep 0.4
  printf '%s' "$ORIG_CLIP" | pbcopy
fi

exit 0
