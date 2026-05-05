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

# Force a UTF-8 locale. Hammerspoon's hs.task launches subprocesses with
# a stripped environment (no LANG / LC_*), which makes pbcopy mangle
# multi-byte UTF-8 (Persian, Arabic, Chinese, emoji, etc.) into something
# the receiving app can't render. Setting LANG explicitly here keeps
# Unicode round-tripping intact regardless of who launched us.
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

set -u

LOG=/tmp/whisper-dictate.log
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }

MODEL=""
LANG_CODE=""
WAV=""

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2";     shift 2 ;;
    --lang)  LANG_CODE="$2"; shift 2 ;;
    --wav)   WAV="$2";       shift 2 ;;
    *) echo "dictate.sh: unknown arg: $1" >&2; exit 64 ;;
  esac
done

log "----- run -----"
log "model=$MODEL  lang=${LANG_CODE:-AUTO}  wav=$WAV"

if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
  log "ERR: invalid --model: $MODEL"
  echo "dictate.sh: missing or invalid --model: $MODEL" >&2
  exit 1
fi
if [ -z "$WAV" ] || [ ! -f "$WAV" ]; then
  log "ERR: invalid --wav: $WAV"
  echo "dictate.sh: missing or invalid --wav: $WAV" >&2
  exit 1
fi

WHISPER_BIN="/opt/homebrew/bin/whisper-cli"
OUT_BASE="/tmp/whisper_rec_out"

WHISPER_ARGS=(-m "$MODEL" -f "$WAV" -nt -np -otxt -of "$OUT_BASE")
if [ -n "$LANG_CODE" ]; then
  WHISPER_ARGS+=(-l "$LANG_CODE")
else
  WHISPER_ARGS+=(-l auto)
fi

"$WHISPER_BIN" "${WHISPER_ARGS[@]}" >/dev/null 2>&1
WHISPER_EXIT=$?
log "whisper exit=$WHISPER_EXIT"

TXT_FILE="${OUT_BASE}.txt"
if [ ! -f "$TXT_FILE" ]; then
  log "ERR: no output file produced"
  echo "dictate.sh: transcription produced no output file" >&2
  exit 2
fi

log "raw whisper output: $(tr '\n' ' ' < "$TXT_FILE")"

# Drop [BLANK_AUDIO] / [SILENCE] markers and any [HH:MM:SS-->HH:MM:SS]
# timestamp lines. Collapse whitespace.
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

log "cleaned text: [$TEXT]"

if [ -z "$TEXT" ]; then
  log "INFO: empty after cleanup -> nothing to type"
  exit 0
fi

# Always use the clipboard-paste path. It's reliable for every script
# (Latin / Persian / Arabic / Chinese / emoji / etc.), it's faster than
# per-character keystroke for anything more than a few words, and it
# avoids the System Events keystroke quirks with non-ASCII in many apps.
# Trade-off: we briefly clobber the clipboard, then restore it after the
# paste settles. Plain-text restore only — image/file clipboards aren't
# preserved, but that's a rare case for live dictation.
ORIG_CLIP="$(pbpaste 2>/dev/null || true)"

printf '%s' "$TEXT" | pbcopy
PBCOPY_EXIT=$?
log "pbcopy exit=$PBCOPY_EXIT  clipboard now=[$(pbpaste)]"

# Use `key code 9` (physical V key on US ANSI) instead of `keystroke "v"`.
# `keystroke` translates a *character* through the ACTIVE keyboard layout,
# so when a Persian / Arabic / Cyrillic / Chinese layout is active, "v" is
# not on the layout at all and the synthesized event never registers as
# Cmd+V. `key code 9` sends the physical key event regardless of layout.
/usr/bin/osascript -e 'tell application "System Events" to key code 9 using {command down}'
OSA_EXIT=$?
log "osascript Cmd+V (key code 9) exit=$OSA_EXIT"

# Give the focused app a moment to consume the paste before we restore
# the original clipboard contents.
sleep 0.4
printf '%s' "$ORIG_CLIP" | pbcopy

log "done"
exit 0
