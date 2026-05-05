# whisper-dictate

A free, fully **on-device** voice-to-text dictation tool for Apple Silicon Macs.

- Tap **CapsLock** → start recording
- Tap **CapsLock** again → stop, transcribe, paste into the focused window

Always uses Whisper's `large-v3-turbo` (multilingual). The transcription language is picked from your **active macOS keyboard layout** at the moment you tap. Switch your input source to Persian → next dictation transcribes Farsi. Switch to English → English. Switch to French → French. Anything not in the built-in mapping table falls back to Whisper's audio-based auto-detection.

No cloud calls. No API keys. No subscriptions. Works offline.

## How it works

```
CapsLock tap         -> Hammerspoon F18 hotkey -> sox records WAV
CapsLock tap (again) ->                         -> dictate.sh + large-v3-turbo
                                                    └─ language = active keyboard layout
                                                    └─ pastes into focused window
```

**Why F18?** CapsLock can't be reliably bound through Hammerspoon — `flagsChanged` events race the OS's caps-lock LED toggle. The canonical workaround: at startup we use `hidutil` to remap CapsLock (HID `0x700000039`) to F18 (HID `0x70000006D`) at the HID layer. macOS never sees a CapsLock press, so the LED never toggles, and Hammerspoon binds F18 with a normal `hs.hotkey`. The remap is reapplied on each Hammerspoon launch (it doesn't survive reboot — that's why **Hammerspoon must launch at login**).

**Why paste via key code 9?** macOS's `osascript ... keystroke "v"` translates the *character* "v" through the active keyboard layout to find a key. With Persian / Arabic / Cyrillic / Chinese layouts active, "v" doesn't exist on the layout at all and the synthesized event never registers as Cmd+V. We use `key code 9` instead (the physical V key on US ANSI), which is layout-independent — paste works no matter what input source is active.

**Clipboard behavior.** The transcribed text is written to the clipboard *and* pasted into the focused window — it stays on the clipboard afterwards, so you can paste it again elsewhere. The previous clipboard contents are not preserved.

## File layout

Everything lives under `~/.hammerspoon/`:

```
~/.hammerspoon/
├── init.lua                              # active Hammerspoon config (hotkey + state machine)
└── whisper-dictate/                      # this repo
    ├── dictate.sh                        # transcription + text-injection script
    ├── init.lua                          # repo copy of the Hammerspoon block
    ├── README.md
    ├── .gitignore
    └── models/
        └── ggml-large-v3-turbo.bin       # multilingual model (~1.5 GB, gitignored)
```

There is intentionally **no folder under `~/`** — the dependency on `.hammerspoon` is explicit, and you can't accidentally delete the project from `$HOME` and break dictation.

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

### 3. Download the model (~1.5 GB)

```bash
mkdir -p ~/.hammerspoon/whisper-dictate/models
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
| **Accessibility** | Lets osascript send Cmd+V to the focused app |
| **Input Monitoring** | Required for `hs.hotkey` to receive F18 (remapped CapsLock) events |
| **Microphone** | Lets `sox` (launched by Hammerspoon) capture from the mic |

After granting, **right-click the Hammerspoon menubar icon → Reload Config** (or quit + relaunch).

### 7. Test it

1. Click into any text field.
2. Tap **CapsLock**. A red banner shows the detected language (`● EN`, `● FA`, `● AUTO`, etc.).
3. Speak.
4. Tap **CapsLock** again. Banner switches to **Transcribing (xx)...**, then your text is pasted into the focused window.

For non-English: switch your macOS input source (Globe key / Ctrl+Space) **before** tapping CapsLock to start.

## Configuration

### Add languages to the keyboard-layout map

The mapping table `LAYOUT_TO_LANG` in `~/.hammerspoon/init.lua` translates macOS input-source IDs to Whisper language codes. To find the ID of your current keyboard, open the Hammerspoon Console (menubar → Console) and run:

```lua
print(hs.keycodes.currentSourceID())
```

Add that ID to the table mapped to the appropriate Whisper language code. Anything not mapped falls through to `whisper -l auto`, which sniffs the language from the audio — usually fine but slightly slower and occasionally wrong on short clips. The banner will show **● AUTO** when no mapping was found.

### Change the model

Edit `MODEL` in `~/.hammerspoon/init.lua` to point at a different `ggml-*.bin` file. Sizes & trade-offs (M1 Max latency for ~10 s of audio):

| Model | Size | Latency | Notes |
|---|---|---|---|
| `tiny` / `tiny.en` | 75 MB | ~0.3 s | Fastest, mediocre quality |
| `base` / `base.en` | 142 MB | ~0.5 s | Decent for clean speech |
| `small` / `small.en` | 466 MB | ~1–1.5 s | Solid for English |
| `medium` / `medium.en` | 1.5 GB | ~3–4 s | Big quality jump |
| `large-v3` | 3.1 GB | ~6–8 s | Best, slowest, multilingual |
| `large-v3-turbo` | 1.5 GB | ~3–4 s | **Default** — distilled large, near-best quality, multilingual |

`.en` variants exist for tiny/base/small/medium and are noticeably more accurate on English-only audio (same size, but model capacity isn't split across 99 languages). Note that English-only models cannot transcribe other languages.

### Change the hotkey

CapsLock is the hotkey because we hidutil-remap it to F18. To switch to a different physical key, replace `0x700000039` (CapsLock HID) in the `hidutil` line with the HID code of your chosen key — e.g. `0x70000006A` for Right Option, `0x700000064` for the section/§ key. The bound `hs.hotkey.bind({}, "F18", ...)` line stays as is.

## Troubleshooting

- **CapsLock does nothing.** Hammerspoon isn't running, or Accessibility / Input Monitoring isn't granted. Check the menubar; reload config.
- **CapsLock toggles caps-lock state again after a reboot.** Hammerspoon didn't launch at login → the hidutil remap wasn't reapplied. Enable launch-at-login in Hammerspoon Preferences.
- **Transcription is gibberish.** The banner showed the wrong language (or `AUTO` and audio was too short for confident detection). Make sure your macOS input source is set to the language you're speaking *before* you tap CapsLock to start.
- **Paste fails / nothing appears.** Check `/tmp/whisper-dictate.log` — every run logs the cleaned text, pbcopy result, and osascript exit code. (`tail -50 /tmp/whisper-dictate.log`.)
- **Pasting into iTerm2 with non-Latin script looks weird.** Terminal emulators don't reliably handle bidi RTL text — use a real text app (TextEdit, Notes, browser) for Persian / Arabic / Hebrew dictation.
- **Pasting into a Windows RDP session pastes the wrong text, or the RDP clipboard wedges until reconnect.** Microsoft Remote Desktop syncs the Mac pasteboard to the Windows host over a virtual channel asynchronously (~150–500 ms). If the paste keystroke arrives before that sync completes, Windows pastes its previous clipboard, and on some sessions the channel locks up entirely. `dictate.sh` sleeps `0.35 s` between `pbcopy` and Cmd+V to let the sync settle. On high-latency links (VPN, slow Wi-Fi) you may need to bump that — edit the `sleep 0.35` line in `dictate.sh` to `0.6` or higher.
- **Temporarily disable.** Quit Hammerspoon. Run `hidutil property --set '{"UserKeyMapping":[]}'` to immediately restore CapsLock to normal without reboot.

## License

MIT. Whisper models are MIT-licensed by OpenAI; whisper.cpp is MIT-licensed by Georgi Gerganov.
