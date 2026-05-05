# whisper-dictate

A free, fully **on-device** voice-to-text dictation tool for Apple Silicon Macs.

Two CapsLock gestures, two modes:

| Gesture | Mode | Model | Language |
|---|---|---|---|
| **Quick tap** (press + release) | English | `small.en` (~466 MB) | always English |
| **Press & hold** (push-to-talk) | Multilingual | `large-v3-turbo` (~1.5 GB) | follows your active macOS keyboard layout (Persian, Arabic, Chinese, etc.); falls back to whisper's audio-based auto-detection |

Tap-toggle for English (tap to start, tap again to stop). Hold-to-talk for everything else (records while held, transcribes on release).

No cloud calls. No API keys. No subscriptions. Works offline.

## How it works

```
CapsLock tap            -> Hammerspoon F18 hotkey -> sox records WAV
CapsLock tap (again)    ->                         -> dictate.sh + small.en
                                                       └─ types into focused window

CapsLock press & hold   -> after 350ms -> sox records WAV
CapsLock release        ->              -> dictate.sh + large-v3-turbo + active keyboard layout
                                            └─ types into focused window
```

Why F18 instead of binding CapsLock directly? CapsLock can't be reliably bound through Hammerspoon — `flagsChanged` events race the OS's caps-lock LED toggle. The canonical workaround: at startup we use `hidutil` to remap CapsLock (HID `0x700000039`) to F18 (HID `0x70000006D`) at the HID layer. macOS never sees a CapsLock press, so the LED never toggles, and Hammerspoon binds F18 with a normal `hs.hotkey`. The remap is reapplied on each Hammerspoon launch (it doesn't persist across reboot — that's why **Hammerspoon must be set to launch at login**).

## File layout (canonical)

Everything lives under `~/.hammerspoon/`:

```
~/.hammerspoon/
├── init.lua                              # Hammerspoon config (hotkey + state machine)
└── whisper-dictate/                      # this repo
    ├── dictate.sh                        # transcription + text-injection script
    ├── init.lua                          # repo copy of the Hammerspoon block
    ├── README.md
    ├── .gitignore
    └── models/
        ├── ggml-small.en.bin             # English model        (~466 MB, gitignored)
        └── ggml-large-v3-turbo.bin       # multilingual model   (~1.5 GB, gitignored)
```

There is intentionally **no folder under `~/`** — earlier versions used `~/whisper-dictate/`, which made it tempting to delete and broke dictation. The current layout makes the dependency on `.hammerspoon` explicit.

## Install (clean machine)

> Apple Silicon, macOS Sonoma+, Homebrew already installed.

### 1. Install dependencies

```bash
brew install sox whisper-cpp hammerspoon
```

### 2. Clone the repo into `~/.hammerspoon/`

```bash
mkdir -p ~/.hammerspoon
git clone https://github.com/bardiabarabadi/whisper-dictate.git ~/.hammerspoon/whisper-dictate
chmod +x ~/.hammerspoon/whisper-dictate/dictate.sh
```

### 3. Download the two models (~2 GB total)

```bash
mkdir -p ~/.hammerspoon/whisper-dictate/models

# English model (~466 MB)
curl -L --fail --progress-bar \
  -o ~/.hammerspoon/whisper-dictate/models/ggml-small.en.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"

# Multilingual model (~1.5 GB)
curl -L --fail --progress-bar \
  -o ~/.hammerspoon/whisper-dictate/models/ggml-large-v3-turbo.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
```

### 4. Install the Hammerspoon config

If `~/.hammerspoon/init.lua` doesn't exist yet:

```bash
cp ~/.hammerspoon/whisper-dictate/init.lua ~/.hammerspoon/init.lua
```

If you already have a Hammerspoon config, append the contents of `whisper-dictate/init.lua` to your existing `~/.hammerspoon/init.lua`. The block is self-contained.

### 5. Launch Hammerspoon and set it to launch at login

```bash
open -a Hammerspoon
```

Then in the Hammerspoon menubar icon → **Preferences** → check **"Launch Hammerspoon at login"**. This is **important**: the hidutil remap doesn't survive reboot, so Hammerspoon needs to launch on login to re-apply it. Without that, after a restart your CapsLock key will be a regular CapsLock again.

### 6. Grant macOS permissions

System Settings → Privacy & Security — enable **Hammerspoon** in:

| Pane | Why |
|---|---|
| **Accessibility** | Lets osascript send keystrokes / Cmd+V to the focused app |
| **Input Monitoring** | Required for `hs.hotkey` to receive the F18 (remapped CapsLock) events |
| **Microphone** | Lets `sox` (launched by Hammerspoon) capture from the mic |

After granting, **right-click the Hammerspoon menubar icon → Reload Config** (or quit + relaunch).

### 7. Test it

1. Click into any text field.
2. Tap **CapsLock**. Red **● English** banner. Speak. Tap **CapsLock** again. Your text is typed in.
3. Press and hold **CapsLock**. Purple **● Multilingual** (or `● FA (multi)` etc.) banner. Speak while holding. Release. Your text is typed in.

If the multilingual banner shows e.g. `● FA (multi)`, your active keyboard layout was correctly mapped to Persian. Switch keyboard layouts with the macOS input-source switcher (Globe key / Ctrl+Space) before holding to dictate in a different language.

## Configuration

### Change the hold threshold

In `~/.hammerspoon/init.lua`, edit `HOLD_THRESHOLD` (default `0.35` seconds). Lower = easier to trigger hold mode, higher = less likely to trigger it accidentally.

### Change the hotkey

CapsLock is the hotkey because we hidutil-remap it to F18. To switch to a different physical key, replace the `0x700000039` (CapsLock HID) in the `hidutil` line with the HID code of your chosen key — e.g. `0x70000006A` for Right Option, `0x700000064` for the section/§ key. The bound `hs.hotkey.bind({}, "F18", ...)` line stays as is.

### Add languages to the keyboard-layout map

The mapping table `LAYOUT_TO_LANG` in `~/.hammerspoon/init.lua` translates macOS input-source IDs to Whisper language codes. To find the ID of your current keyboard, open the Hammerspoon Console and run:

```lua
print(hs.keycodes.currentSourceID())
```

Add that ID to the table mapped to the appropriate Whisper language code. Anything not mapped falls through to `whisper -l auto`, which sniffs the language from the audio — usually fine but slightly slower and occasionally wrong on short clips.

### Change models

Edit `MODEL_EN` or `MODEL_MULTI` in `~/.hammerspoon/init.lua`. Available sizes:

| Model | Size | M1 Max latency (10 s clip) | Notes |
|---|---|---|---|
| `tiny` / `tiny.en` | 75 MB | ~0.3 s | Fastest, mediocre |
| `base` / `base.en` | 142 MB | ~0.5 s | Decent for clean speech |
| `small` / `small.en` | 466 MB | ~1–1.5 s | **Default for English** |
| `medium` / `medium.en` | 1.5 GB | ~3–4 s | Big quality jump |
| `large-v3` | 3.1 GB | ~6–8 s | Best, slowest, multilingual |
| `large-v3-turbo` | 1.5 GB | ~3–4 s | **Default for multilingual** — distilled large, near-best quality |

`.en` variants exist for tiny/base/small/medium and are noticeably more accurate on English-only audio (same size, but model capacity isn't split across 99 languages).

## Troubleshooting

- **CapsLock does nothing.** Hammerspoon isn't running, or Accessibility/Input Monitoring isn't granted. Check the menubar; reload config.
- **CapsLock toggles caps-lock state again after a reboot.** Hammerspoon didn't launch at login → the hidutil remap wasn't reapplied. Enable launch-at-login in Hammerspoon Preferences.
- **Hold mode never triggers.** Check the hold threshold (`HOLD_THRESHOLD` in `init.lua`); some users press too quickly. Try `0.5`.
- **Persian/Arabic transcription is gibberish.** Confirm you have the multilingual model (`ggml-large-v3-turbo.bin`) — `small.en` cannot transcribe non-English. Confirm the recording banner shows `● FA (multi)` (or your language) before speaking.
- **Wrong language transcribed.** The macOS keyboard layout you had active when starting the recording determines the language. Switch input source before pressing-and-holding CapsLock.
- **No errors but no text.** Open Hammerspoon Console — `dictate.sh` stderr lands there.
- **Temporarily disable.** Quit Hammerspoon. Run `hidutil property --set '{"UserKeyMapping":[]}'` to immediately restore CapsLock to normal without reboot.

## License

MIT. Whisper models are MIT-licensed by OpenAI; whisper.cpp is MIT-licensed by Georgi Gerganov.
