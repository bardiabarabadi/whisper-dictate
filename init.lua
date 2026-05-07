-- =============================================================
-- whisper-dictate :: CapsLock-driven dictation (single mode)
-- =============================================================
-- Tap CapsLock once  -> start recording
-- Tap CapsLock again -> stop + transcribe + paste into focused app
--
-- Always uses the multilingual large-v3-turbo model, with the Whisper
-- language code derived from the active macOS keyboard layout
-- (Persian keyboard -> fa, Arabic -> ar, English -> en, etc.).
-- Layouts not in LAYOUT_TO_LANG fall through to whisper -l auto.
--
-- CapsLock can't be reliably bound directly (flagsChanged races the
-- OS LED toggle). Canonical workaround: at startup, hidutil-remap the
-- physical CapsLock (HID 0x700000039) to F18 (HID 0x70000006D), then
-- bind F18 with hs.hotkey. macOS never sees a CapsLock press, so the
-- LED never toggles. The remap is reapplied on each Hammerspoon launch
-- (it doesn't persist across reboot — Hammerspoon must launch at login).
-- =============================================================

-- ---- Config ----------------------------------------------------
local PROJ_DIR        = os.getenv("HOME") .. "/.hammerspoon/whisper-dictate"
local DICTATE_SCRIPT  = PROJ_DIR .. "/dictate.sh"
local MODEL           = PROJ_DIR .. "/models/ggml-large-v3-turbo.bin"
local WAV_PATH        = "/tmp/whisper_rec.wav"
local SOX_BIN         = "/opt/homebrew/bin/sox"
-- ---------------------------------------------------------------

-- ---- Remap CapsLock -> F18 at the HID layer --------------------
hs.execute([[/usr/bin/hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}']])

-- ---- macOS keyboard layout -> Whisper language code ------------
local LAYOUT_TO_LANG = {
  ["com.apple.keylayout.US"]                       = "en",
  ["com.apple.keylayout.ABC"]                      = "en",
  ["com.apple.keylayout.Australian"]               = "en",
  ["com.apple.keylayout.British"]                  = "en",
  ["com.apple.keylayout.Canadian"]                 = "en",
  ["com.apple.keylayout.Irish"]                    = "en",

  ["com.apple.keylayout.Persian"]                  = "fa",
  ["com.apple.keylayout.Persian-ISIRI2901"]        = "fa",
  ["com.apple.keylayout.Persian-QWERTY"]           = "fa",
  ["com.apple.keylayout.PersianStandard"]          = "fa",

  ["com.apple.keylayout.Arabic"]                   = "ar",
  ["com.apple.keylayout.ArabicQWERTY"]             = "ar",

  ["com.apple.keylayout.French"]                   = "fr",
  ["com.apple.keylayout.FrenchPro"]                = "fr",
  ["com.apple.keylayout.French-numerical"]         = "fr",
  ["com.apple.keylayout.German"]                   = "de",
  ["com.apple.keylayout.German-DIN-2137"]          = "de",
  ["com.apple.keylayout.Spanish"]                  = "es",
  ["com.apple.keylayout.Spanish-ISO"]              = "es",
  ["com.apple.keylayout.Italian"]                  = "it",
  ["com.apple.keylayout.Italian-Pro"]              = "it",
  ["com.apple.keylayout.Russian"]                  = "ru",
  ["com.apple.keylayout.Russian-Phonetic"]         = "ru",
  ["com.apple.keylayout.Dutch"]                    = "nl",
  ["com.apple.keylayout.Portuguese"]               = "pt",
  ["com.apple.keylayout.Brazilian"]                = "pt",
  ["com.apple.keylayout.Turkish"]                  = "tr",
  ["com.apple.keylayout.Turkish-QWERTY"]           = "tr",
  ["com.apple.keylayout.Polish"]                   = "pl",
  ["com.apple.keylayout.Hebrew"]                   = "he",
  ["com.apple.keylayout.Hebrew-QWERTY"]            = "he",
}
local IME_PREFIXES = {
  { "com.apple.inputmethod.SCIM",    "zh" },
  { "com.apple.inputmethod.TCIM",    "zh" },
  { "com.apple.inputmethod.Korean",  "ko" },
  { "com.apple.inputmethod.Kotoeri", "ja" },
}

local function detectLanguage()
  local id = hs.keycodes.currentSourceID()
  if not id then return nil end
  local lang = LAYOUT_TO_LANG[id]
  if lang then return lang end
  for _, p in ipairs(IME_PREFIXES) do
    if id:sub(1, #p[1]) == p[1] then return p[2] end
  end
  return nil    -- nil -> dictate.sh runs whisper with -l auto
end

-- ---- Recording state -------------------------------------------
local recording      = false
local soxTask        = nil
local recordingAlert = nil
local working        = false   -- true while transcription is in flight

-- ---- Mic selection (menu bar) ----------------------------------
-- Persisted via hs.settings; nil = use system default input.
local MIC_SETTING_KEY = "whisperDictate.micDevice"

local function selectedMicName()
  return hs.settings.get(MIC_SETTING_KEY)
end

local function listInputDeviceNames()
  local names = {}
  for _, d in ipairs(hs.audiodevice.allInputDevices()) do
    table.insert(names, d:name())
  end
  table.sort(names)
  return names
end

local micMenu = hs.menubar.new()
if micMenu then
  micMenu:setTitle("🎙")
  micMenu:setTooltip("whisper-dictate input device")
  micMenu:setMenu(function()
    local current = selectedMicName()
    local items = {
      {
        title = "System default",
        checked = (current == nil),
        fn = function() hs.settings.set(MIC_SETTING_KEY, nil) end,
      },
      { title = "-" },
    }
    for _, name in ipairs(listInputDeviceNames()) do
      table.insert(items, {
        title = name,
        checked = (current == name),
        fn = function() hs.settings.set(MIC_SETTING_KEY, name) end,
      })
    end
    return items
  end)
end

local function startRecording()
  os.remove(WAV_PATH)

  -- Pick the input. If a specific device is selected but no longer
  -- attached, fall back to system default rather than failing the run.
  local mic = selectedMicName()
  local inputArgs = { "-d" }
  if mic then
    for _, name in ipairs(listInputDeviceNames()) do
      if name == mic then
        inputArgs = { "-t", "coreaudio", mic }
        break
      end
    end
  end

  local args = {}
  for _, v in ipairs(inputArgs) do table.insert(args, v) end
  for _, v in ipairs({
    "-t", "wav", "-r", "16000", "-c", "1", "-b", "16", "-e", "signed", WAV_PATH,
  }) do table.insert(args, v) end

  soxTask = hs.task.new(SOX_BIN, nil, args)
  soxTask:start()

  -- Banner shows the detected language so the user knows which one whisper
  -- will use before they start speaking. "AUTO" = layout not mapped,
  -- whisper will sniff from audio.
  local lang  = detectLanguage()
  local label = "● " .. (lang and lang:upper() or "AUTO")
  recordingAlert = hs.alert.show(label, {
    textSize = 28, radius = 12,
    fillColor   = { red = 0.7, green = 0, blue = 0, alpha = 0.85 },
    strokeColor = { white = 1, alpha = 0 },
    textColor   = { white = 1, alpha = 1 },
  }, 86400)

  recording = true
end

local function stopAndTranscribe()
  recording = false
  if soxTask then soxTask:terminate(); soxTask = nil end
  if recordingAlert then
    hs.alert.closeSpecific(recordingAlert)
    recordingAlert = nil
  end

  -- Re-detect at stop time too (handles the edge case where the user
  -- switched keyboard layout mid-recording — they probably want the
  -- final layout to win).
  local lang  = detectLanguage()
  local label = "Transcribing" .. (lang and (" (" .. lang .. ")") or "") .. "..."
  local transcribingAlert = hs.alert.show(label, {
    textSize = 22, radius = 10,
    fillColor   = { red = 0, green = 0.3, blue = 0.7, alpha = 0.85 },
    strokeColor = { white = 1, alpha = 0 },
    textColor   = { white = 1, alpha = 1 },
  }, 86400)

  working = true
  local args = { DICTATE_SCRIPT, "--model", MODEL, "--wav", WAV_PATH }
  if lang then table.insert(args, "--lang"); table.insert(args, lang) end

  hs.task.new("/bin/bash", function(exitCode, _stdOut, stdErr)
    hs.alert.closeSpecific(transcribingAlert)
    working = false
    if exitCode ~= 0 then
      hs.alert.show("Dictation failed (" .. tostring(exitCode) .. ")", 2)
      if stdErr and #stdErr > 0 then
        print("[whisper-dictate] stderr:", stdErr)
      end
    end
  end, args):start()
end

-- Tap-to-toggle. F18 is the hidutil-remapped CapsLock; Ctrl+F12 is an
-- explicit alias for keyboards / RDP sessions where intercepting CapsLock
-- isn't possible. Both call the same toggle.
local function toggleDictation()
  if working then return end       -- ignore taps during transcription
  if recording then
    stopAndTranscribe()
  else
    startRecording()
  end
end

hs.hotkey.bind({},        "F18", toggleDictation)
hs.hotkey.bind({"ctrl"},  "F12", toggleDictation)

hs.alert.show("whisper-dictate ready", 1)
