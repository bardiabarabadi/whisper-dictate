-- =============================================================
-- whisper-dictate :: CapsLock push-to-toggle dictation
-- =============================================================
-- Tap CapsLock once  -> start recording (sox -> /tmp/whisper_rec.wav)
-- Tap CapsLock again -> stop recording, run whisper.cpp, type result
--
-- Implementation: we cannot reliably bind CapsLock directly (the
-- eventtap-on-flagsChanged approach races macOS's own LED/state
-- toggle and the "No Action" setting kills the events entirely).
--
-- Instead we use the canonical Hammerspoon trick: at startup,
-- ask `hidutil` to remap the CapsLock key (HID usage 0x700000039)
-- to F18 (HID usage 0x70000006D) at the HID layer, BEFORE macOS
-- ever sees it as CapsLock. F18 isn't on any normal keyboard, so
-- it's safe to bind globally. Then we bind F18 with hs.hotkey.
--
-- The remap persists until the next reboot, so we re-apply it on
-- every Hammerspoon launch. The CapsLock LED will not flicker
-- because macOS never receives a CapsLock keypress at all.
-- =============================================================

-- ---- Config ----------------------------------------------------
local DICTATE_SCRIPT = os.getenv("HOME") .. "/whisper-dictate/dictate.sh"
local WAV_PATH       = "/tmp/whisper_rec.wav"
local SOX_BIN        = "/opt/homebrew/bin/sox"
-- ---------------------------------------------------------------

-- ---- Remap CapsLock -> F18 at the HID layer --------------------
-- Source:      0x700000039  (Keyboard Caps Lock)
-- Destination: 0x70000006D  (Keyboard F18)
-- Run via /bin/sh so we don't have to worry about quoting the JSON.
hs.execute([[/usr/bin/hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}']])

-- Runtime state
local recording      = false   -- are we currently capturing audio?
local soxTask        = nil     -- hs.task handle for the running sox process
local recordingAlert = nil     -- id of the persistent "● Recording" alert
local working        = false   -- guard against double-fires while transcribing

-- Start sox capturing 16 kHz mono WAV (whisper.cpp's preferred format).
local function startRecording()
  -- Remove any stale file from a previous session
  os.remove(WAV_PATH)

  -- sox: -d = default input device (the system mic),
  --      -c 1 = mono, -r 16000 = 16 kHz, -b 16 = 16-bit PCM, -e signed = signed int
  soxTask = hs.task.new(SOX_BIN, nil, {
    "-d",
    "-t", "wav",
    "-r", "16000",
    "-c", "1",
    "-b", "16",
    "-e", "signed",
    WAV_PATH,
  })
  soxTask:start()

  -- Persistent on-screen alert so we know recording is active.
  -- Pass a huge duration so it stays up until we explicitly close it.
  recordingAlert = hs.alert.show("● Recording", {
    textSize = 28,
    radius   = 12,
    fillColor = { red = 0.7, green = 0, blue = 0, alpha = 0.85 },
    strokeColor = { white = 1, alpha = 0 },
    textColor = { white = 1, alpha = 1 },
  }, 86400)

  recording = true
end

-- Stop sox, dismiss the recording banner, transcribe asynchronously.
local function stopAndTranscribe()
  recording = false

  -- Stop sox cleanly (SIGTERM lets it flush the WAV header).
  if soxTask then
    soxTask:terminate()
    soxTask = nil
  end

  if recordingAlert then
    hs.alert.closeSpecific(recordingAlert)
    recordingAlert = nil
  end

  -- Brief "Transcribing..." indicator (auto-dismissed after a long timeout
  -- and explicitly closed when dictate.sh finishes).
  local transcribingAlert = hs.alert.show("Transcribing...", {
    textSize = 22,
    radius   = 10,
    fillColor = { red = 0, green = 0.3, blue = 0.7, alpha = 0.85 },
    strokeColor = { white = 1, alpha = 0 },
    textColor = { white = 1, alpha = 1 },
  }, 86400)

  working = true

  -- Run dictate.sh asynchronously so the UI stays responsive.
  hs.task.new("/bin/bash", function(exitCode, _stdOut, stdErr)
    hs.alert.closeSpecific(transcribingAlert)
    working = false
    if exitCode ~= 0 then
      hs.alert.show("Dictation failed (" .. tostring(exitCode) .. ")", 2)
      if stdErr and #stdErr > 0 then
        print("[whisper-dictate] stderr:", stdErr)
      end
    end
  end, { DICTATE_SCRIPT, WAV_PATH }):start()
end

-- Single tap handler: toggle recording state.
local function toggle()
  if working then
    -- Ignore taps while a transcription is in flight to avoid races.
    return
  end
  if not recording then
    startRecording()
  else
    stopAndTranscribe()
  end
end

-- Bind F18 globally. Because of the hidutil remap above, every CapsLock
-- press now arrives here as F18 instead.
hs.hotkey.bind({}, "F18", toggle)

-- Friendly notice on (re)load.
hs.alert.show("whisper-dictate ready", 1)
