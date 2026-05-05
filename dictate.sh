#!/usr/bin/env bash
# whisper-dictate: transcribe a WAV file with whisper.cpp (model + lang
# specified by caller) and inject the result into the focused app.
#
# Usage:
#   dictate.sh --model PATH [--lang CODE] --wav PATH
#
# Examples:
#   dictate.sh --model models/ggml-small.en.bin --lang en --wav /tmp/r.wav
#   dictate.sh --model models/ggml-large-v3-turbo.bin --wav /tmp/r.wav
#     (no --lang -> whisper auto-detects the language from the audio)

set -u

MODEL=""
LANG=""        # may stay empty -> auto-detect
WAV=""

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --lang)  LANG="$2";  shift 2 ;;
    --wav)   WAV="$2";   shift 2 ;;
    *) echo "dictate.sh: unknown arg: $1" >&2; exit 64 ;;
  esac
done

if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
  echo "dictate.sh: missing or invalid --model: $MODEL" >&2
  exit 1
fi
if [ -z "$WAV" ] || [ ! -f "$WAV" ]; then
  echo "dictate.sh: missing or invalid --wav: $WAV" >&2
  exit 1
fi

WHISPER_BIN="/opt/homebrew/bin/whisper-cli"
OUT_BASE="/tmp/whisper_rec_out"   # whisper-cli appends .txt

# Build whisper args. -nt drops timestamps, -np silences progress noise,
# -otxt writes plain text to <OUT_BASE>.txt. -l <code> if specified;
# otherwise pass -l auto so whisper detects from the first ~30 s of audio.
WHISPER_ARGS=(-m "$MODEL" -f "$WAV" -nt -np -otxt -of "$OUT_BASE")
if [ -n "$LANG" ]; then
  WHISPER_ARGS+=(-l "$LANG")
else
  WHISPER_ARGS+=(-l auto)
fi

"$WHISPER_BIN" "${WHISPER_ARGS[@]}" >/dev/null 2>&1

TXT_FILE="${OUT_BASE}.txt"
if [ ! -f "$TXT_FILE" ]; then
  echo "dictate.sh: transcription produced no output file" >&2
  exit 2
fi

# Clean up: drop [BLANK_AUDIO] / [SILENCE] markers, drop bracketed
# timestamp lines, collapse whitespace.
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

# Inject into the focused window.
# Short ASCII text: keystroke directly via System Events.
# Longer text OR any non-ASCII (Persian, Arabic, Chinese, etc): use the
# clipboard-swap + Cmd+V path — System Events keystroke is unreliable
# with non-Latin scripts and slow for long passages.
LEN=${#TEXT}

if LC_ALL=C grep -q '[^\x00-\x7F]' <<<"$TEXT"; then
  USE_CLIPBOARD=1
elif [ "$LEN" -ge 80 ]; then
  USE_CLIPBOARD=1
else
  USE_CLIPBOARD=0
fi

escape_for_applescript() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

if [ "$USE_CLIPBOARD" -eq 0 ]; then
  ESCAPED="$(escape_for_applescript "$TEXT")"
  /usr/bin/osascript -e "tell application \"System Events\" to keystroke \"$ESCAPED\""
else
  ORIG_CLIP="$(pbpaste 2>/dev/null || true)"
  printf '%s' "$TEXT" | pbcopy
  /usr/bin/osascript -e 'tell application "System Events" to keystroke "v" using {command down}'
  sleep 0.4
  printf '%s' "$ORIG_CLIP" | pbcopy
fi

exit 0
