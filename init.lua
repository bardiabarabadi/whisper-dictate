-- =============================================================
-- whisper-dictate :: CapsLock push-to-toggle dictation
-- =============================================================
-- Tap CapsLock once  -> start recording (sox -> /tmp/whisper_rec.wav)
-- Tap CapsLock again -> stop recording, run whisper.cpp, type result
--
-- CapsLock cannot be bound via hs.hotkey, so we watch flagsChanged
-- events and detect the moment the capslock flag toggles ON. We
-- return `true` from the eventtap callback to swallow the event,
-- which prevents macOS from toggling the actual capslock state.
-- =============================================================

-- ---- Config ----------------------------------------------------
local DICTATE_SCRIPT = os.getenv("HOME") .. "/whisper-dictate/dictate.sh"
local WAV_PATH       = "/tmp/whisper_rec.wav"
local SOX_BIN        = "/opt/homebrew/bin/sox"
-- ---------------------------------------------------------------

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

-- Eventtap: watch flagsChanged for the CapsLock flag.
-- Returning true swallows the event so macOS does NOT toggle the
-- actual caps-lock state.
local capsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
  local flags = event:getFlags()
  local keyCode = event:getKeyCode()

  -- keyCode 57 == CapsLock. We only react to the flagsChanged event whose
  -- keyCode is the capslock key itself (otherwise we'd react to shift/cmd/etc).
  if keyCode ~= 57 then
    return false
  end

  -- A flagsChanged event for CapsLock fires both when it "turns on" and
  -- "turns off" in the OS's view. We treat *every* such event as a single
  -- "tap": flip our recording state machine.
  if working then
    -- Ignore taps while a transcription is in flight to avoid races.
    return true
  end

  if not recording then
    startRecording()
  else
    stopAndTranscribe()
  end

  -- Swallow the event entirely so macOS doesn't toggle caps-lock.
  return true
end)

capsTap:start()

-- Friendly notice on (re)load.
hs.alert.show("whisper-dictate ready", 1)
