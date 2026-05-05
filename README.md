# whisper-dictate

A free, fully **on-device** voice-to-text dictation tool for Apple Silicon Macs.

Tap **CapsLock** to start recording, tap **CapsLock** again to stop. The audio is transcribed locally with [`whisper.cpp`](https://github.com/ggerganov/whisper.cpp) and the resulting text is typed straight into whatever window/app currently has keyboard focus — including iTerm2, SSH sessions, browsers, editors, etc.

No cloud calls. No API keys. No subscriptions. Works offline.

## How it works

```
CapsLock tap ──▶ Hammerspoon eventtap ──▶ sox records /tmp/whisper_rec.wav
                                                  │
CapsLock tap ──▶ kills sox ──▶ dictate.sh ────────┘
                                  │
                                  ├─ whisper-cli (Metal) ─▶ text
                                  └─ osascript keystroke / clipboard paste
                                                  │
                                                  ▼
                                          focused window
```

- **Hammerspoon** owns the global hotkey. CapsLock can't be bound as a normal modifier, so we use `hs.eventtap` on `flagsChanged` events. The eventtap returns `true` to swallow the event entirely, which prevents macOS from toggling the real caps-lock state.
- **sox** captures 16 kHz mono 16-bit PCM WAV — whisper.cpp's preferred input format.
- **whisper-cpp** (`whisper-cli` binary) runs the **small** model on the Apple Silicon Metal backend.
- **osascript / System Events** types the result. Short snippets go via `keystroke`; longer text uses a clipboard-swap + `Cmd+V` paste so it lands instantly without a slow per-character keystroke storm.

## Install (clean machine)

> Tested on macOS Sonoma+ on Apple Silicon (M-series). Homebrew already installed.

### 1. Install dependencies

```bash
brew install sox whisper-cpp hammerspoon
```

### 2. Download the whisper small model (~465 MB)

```bash
mkdir -p ~/whisper-dictate/models
curl -L --fail --progress-bar \
  -o ~/whisper-dictate/models/ggml-small.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
```

### 3. Drop in the project files

Clone (or copy) this repo into `~/whisper-dictate/`:

```bash
git clone https://github.com/<your-user>/whisper-dictate.git ~/whisper-dictate
chmod +x ~/whisper-dictate/dictate.sh
```

The repo ships with `dictate.sh`, `init.lua` (the Hammerspoon config), and this README.

### 4. Install the Hammerspoon config

If you don't already have a Hammerspoon config:

```bash
mkdir -p ~/.hammerspoon
cp ~/whisper-dictate/init.lua ~/.hammerspoon/init.lua
```

If you already have a `~/.hammerspoon/init.lua`, append the contents of `init.lua` from this repo to your existing file. The block is fully self-contained and only uses local variables, so it won't conflict with other Hammerspoon code.

### 5. Launch Hammerspoon

```bash
open -a Hammerspoon
```

You should see a brief **"whisper-dictate ready"** banner.

### 6. Grant macOS permissions

Open **System Settings → Privacy & Security** and enable **Hammerspoon** in:

| Pane | Why |
|---|---|
| **Accessibility** | Lets Hammerspoon intercept CapsLock and lets osascript send keystrokes to the focused app |
| **Input Monitoring** | Required by `hs.eventtap` to read keyboard events on modern macOS |
| **Microphone** | Lets sox (launched by Hammerspoon) capture from the mic |

After granting these, quit & relaunch Hammerspoon (or right-click its menubar icon → **Reload Config**).

### 7. Test it

1. Click into any text field — TextEdit, a browser address bar, an iTerm2 terminal, your SSH session, anywhere.
2. Tap **CapsLock**. You'll see a red **"● Recording"** banner.
3. Speak.
4. Tap **CapsLock** again. The banner becomes **"Transcribing..."** for a second or two, then your spoken text appears in the focused window.

## Configuration

### Change the hotkey

Open `~/.hammerspoon/init.lua` and find the eventtap block. To use a different key — for example, **Right Option** instead of CapsLock — replace the `keyCode == 57` check with the keyCode of your chosen key (you can discover keycodes by adding `print(event:getKeyCode())` inside the callback and watching Hammerspoon's console). For non-modifier keys (letters, function keys), use `hs.hotkey.bind(...)` instead of an eventtap.

### Change the whisper model size

whisper.cpp ships several model sizes. Bigger = more accurate but slower and larger:

| Model | Size | Notes |
|---|---|---|
| `tiny` | ~75 MB | Fastest, lower accuracy |
| `base` | ~142 MB | Good speed/quality compromise |
| `small` | ~465 MB | **Default in this repo.** Solid quality, fast on M-series |
| `medium` | ~1.5 GB | Noticeably better quality, ~3× slower than small |
| `large-v3` | ~3.0 GB | Best quality, slowest |

To switch:

```bash
# Download the model you want, e.g.:
curl -L -o ~/whisper-dictate/models/ggml-medium.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
```

Then edit the `MODEL=` line near the top of `~/whisper-dictate/dictate.sh` to point at the new file. No other changes needed.

### English-only models (faster)

For the tiny/base/small/medium sizes there are `.en` variants (e.g. `ggml-small.en.bin`) trained only on English. They're smaller, faster, and more accurate for English-only use. Download the `.en` variant the same way and update `MODEL=` accordingly. The `-l en` flag in `dictate.sh` is fine either way.

## Troubleshooting

- **Nothing happens when I tap CapsLock.** Confirm Hammerspoon is running (menubar icon present), confirm Accessibility + Input Monitoring are granted, then **Reload Config** from the menubar.
- **CapsLock still toggles caps lock state.** The eventtap isn't being granted Accessibility / Input Monitoring. Re-grant and reload.
- **No transcription appears, no errors.** Open the Hammerspoon **Console** (menubar icon → Console). It'll show stderr from `dictate.sh` if anything failed.
- **Mic appears silent / WAV is empty.** Check `System Settings → Privacy & Security → Microphone` — Hammerspoon (or sox) must be allowed.
- **Text appears in the wrong app.** osascript types into whatever has keyboard focus *at the moment of paste*. Click into the target window before tapping CapsLock to stop.

## Files

| Path | What |
|---|---|
| `~/whisper-dictate/dictate.sh` | Transcribes a WAV and types the result into the focused app |
| `~/whisper-dictate/models/ggml-small.bin` | Whisper small model (binary; not in git) |
| `~/.hammerspoon/init.lua` | Hammerspoon config: CapsLock eventtap + recording state machine |

## License

MIT. Whisper models are MIT-licensed by OpenAI; whisper.cpp is MIT-licensed by Georgi Gerganov.
