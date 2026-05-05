-- =============================================================
-- whisper-dictate :: CapsLock-driven dictation
-- =============================================================
-- Gestures (after the hidutil remap below, every CapsLock event
-- arrives at Hammerspoon as F18):
--
--   Quick tap (press + release < HOLD_THRESHOLD)
--     -> English mode, model = small.en
--     -> Toggle: tap to start recording, tap again to stop+transcribe
--
--   Press & hold (held > HOLD_THRESHOLD)
--     -> Multilingual mode, model = large-v3-turbo
--     -> Push-to-talk: records while held; release stops + transcribes
--     -> Language is auto-selected from the macOS active keyboard layout
--        (e.g. switch to Persian keyboard -> dictation transcribes Farsi)
--
-- Option B semantics: hold-to-multilingual only triggers from idle.
-- If you're already mid-English-recording, any CapsLock press just
-- stops it.
-- =============================================================

-- ---- Config ----------------------------------------------------
local PROJ_DIR        = os.getenv("HOME") .. "/.hammerspoon/whisper-dictate"
local DICTATE_SCRIPT  = PROJ_DIR .. "/dictate.sh"
local MODEL_EN        = PROJ_DIR .. "/models/ggml-small.en.bin"
local MODEL_MULTI     = PROJ_DIR .. "/models/ggml-large-v3-turbo.bin"
local WAV_PATH        = "/tmp/whisper_rec.wav"
local SOX_BIN         = "/opt/homebrew/bin/sox"
local HOLD_THRESHOLD  = 0.35   -- seconds; press longer than this = "hold"
-- ---------------------------------------------------------------

-- ---- Remap CapsLock -> F18 at the HID layer --------------------
-- Source:      0x700000039  (Keyboard Caps Lock)
-- Destination: 0x70000006D  (Keyboard F18)
hs.execute([[/usr/bin/hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}']])

-- ---- macOS keyboard layout -> Whisper language code ------------
-- Used only in multilingual (hold) mode. Anything not listed here
-- falls through to whisper's audio-based auto-detection.
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
-- IME prefixes (East-Asian input methods report long IDs that vary).
local IME_PREFIXES = {
  { "com.apple.inputmethod.SCIM",     "zh" },  -- Simplified Chinese
  { "com.apple.inputmethod.TCIM",     "zh" },  -- Traditional Chinese
  { "com.apple.inputmethod.Korean",   "ko" },
  { "com.apple.inputmethod.Kotoeri",  "ja" },
}

local function detectLanguage()
  local id = hs.keycodes.currentSourceID()
  if not id then return nil end
  local lang = LAYOUT_TO_LANG[id]
  if lang then return lang end
  for _, p in ipairs(IME_PREFIXES) do
    if id:sub(1, #p[1]) == p[1] then return p[2] end
  end
  return nil   -- nil -> dictate.sh runs whisper with -l auto
end

-- ---- Recording state machine -----------------------------------
local mode           = "idle"  -- "idle" | "english" | "multilingual"
local soxTask        = nil
local recordingAlert = nil
local working        = false   -- true while a transcription is in flight
local pressTimer     = nil     -- pending tap-vs-hold timer (nil = not waiting)

local function startRecordingUI(label, color)
  os.remove(WAV_PATH)
  soxTask = hs.task.new(SOX_BIN, nil, {
    "-d", "-t", "wav",
    "-r", "16000", "-c", "1", "-b", "16", "-e", "signed",
    WAV_PATH,
  })
  soxTask:start()
  recordingAlert = hs.alert.show(label, {
    textSize = 28, radius = 12,
    fillColor   = color,
    strokeColor = { white = 1, alpha = 0 },
    textColor   = { white = 1, alpha = 1 },
  }, 86400)
end

local function stopAndTranscribe(model, lang)
  if soxTask then soxTask:terminate(); soxTask = nil end
  if recordingAlert then
    hs.alert.closeSpecific(recordingAlert)
    recordingAlert = nil
  end

  local label = "Transcribing..."
  if lang then label = "Transcribing (" .. lang .. ")..." end
  local transcribingAlert = hs.alert.show(label, {
    textSize = 22, radius = 10,
    fillColor   = { red = 0, green = 0.3, blue = 0.7, alpha = 0.85 },
    strokeColor = { white = 1, alpha = 0 },
    textColor   = { white = 1, alpha = 1 },
  }, 86400)

  working = true
  local args = { DICTATE_SCRIPT, "--model", model, "--wav", WAV_PATH }
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

local function startEnglish()
  mode = "english"
  startRecordingUI("● English", { red = 0.7, green = 0, blue = 0, alpha = 0.85 })
end

local function startMultilingual()
  mode = "multilingual"
  local lang = detectLanguage()
  local label = "● Multilingual"
  if lang then label = "● " .. lang:upper() .. " (multi)" end
  startRecordingUI(label, { red = 0.55, green = 0.15, blue = 0.55, alpha = 0.85 })
end

local function stopEnglish()
  mode = "idle"
  stopAndTranscribe(MODEL_EN, "en")
end

local function stopMultilingual()
  mode = "idle"
  stopAndTranscribe(MODEL_MULTI, detectLanguage())   -- nil lang -> auto-detect
end

-- ---- Tap-vs-hold detection on F18 (= remapped CapsLock) --------
hs.hotkey.bind({}, "F18",
  -- onPress
  function()
    if working then return end          -- ignore presses during transcription

    if mode == "english" then
      -- Option B: any press while recording-english just stops it.
      -- We stop on press (not release) so the user gets immediate feedback.
      stopEnglish()
      return
    end

    if mode == "multilingual" then
      -- Shouldn't normally happen (we entered multilingual via the
      -- timer firing while still held). Defensive: ignore.
      return
    end

    -- mode == "idle". Schedule a hold-detection timer; if it fires
    -- before release, the user is holding -> start multilingual PTT.
    pressTimer = hs.timer.doAfter(HOLD_THRESHOLD, function()
      pressTimer = nil
      if mode == "idle" then
        startMultilingual()
      end
    end)
  end,
  -- onRelease
  function()
    if pressTimer then
      -- Released before threshold -> it was a tap.
      pressTimer:stop()
      pressTimer = nil
      if mode == "idle" then
        startEnglish()      -- tap from idle -> start english recording
      end
      -- (mode==english case is impossible: stopEnglish on press set mode=idle,
      --  and nothing in this branch starts english from non-idle.)
      return
    end

    -- pressTimer is nil. Either it already fired (we're in multilingual
    -- PTT and the user just let go), or this is a release with no matching
    -- press we tracked.
    if mode == "multilingual" then
      stopMultilingual()
    end
  end
)

hs.alert.show("whisper-dictate ready", 1)
