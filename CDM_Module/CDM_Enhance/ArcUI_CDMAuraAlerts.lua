-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_CDMAuraAlerts.lua
-- ALERT SOUNDS + TTS for CDM aura icons (buffs/debuffs tracked by Blizzard's
-- Cooldown Manager).
--
-- WHY CDM GETS TTS AND 12.1 AURA ICONS DO NOT: on a CDM frame the aura's
-- active state IS knowable in Lua without touching a secret — ns.FrameActive
-- derives it from the frame's own shown/bound signals (the same authority
-- that drives every aura visual in the addon, secrecy-safe by construction).
-- So here we get a real gain/drop transition in Lua and can do ANYTHING with
-- it, speech included. The 12.1 engine aura icons have no such signal, which
-- is why those use engine-registered sound files instead.
--
-- Stacks are deliberately NOT offered here: application counts are secret on
-- CDM frames, so a "stacks increased" trigger cannot be built honestly.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...
ns.CDMAuraAlerts = ns.CDMAuraAlerts or {}
local CAA = ns.CDMAuraAlerts

-- Settle window: auras already up at login/zone-in flip to active as frames
-- bind. Without this every reload would replay the whole alert set.
local settledAt = 0
local function Settled()
    return GetTime() >= settledAt
end

-- Legacy sentinel: the edge used to be ONE dropdown holding either a sound or
-- "speak the paired line". Sound and speech are now independent controls, so
-- this only survives as a value to IGNORE on old configs.
local ALERT_TTS = "__tts__"

-- Sound and speech are independent: either, both, or neither can be set.
-- `channel` is one of WoW's output channels (Master/SFX/Music/Ambience/Dialog).
-- Master is the default because it ignores the other sliders, which is what an
-- alert wants; the engine lane in ArcUI_ArcAurasAuraSounds reads the same
-- per-icon setting and feeds it to AddAuraSound as outputChannel.
local function PlayAlert(choice, ttsText, channel)
    if type(ttsText) == "string" and ttsText ~= "" and ns.Sounds and ns.Sounds.SpeakText then
        ns.Sounds.SpeakText(ttsText)
    end
    if type(choice) ~= "string" or choice == "" or choice == "None" or choice == ALERT_TTS then
        return
    end
    local ch = (type(channel) == "string" and channel ~= "") and channel or "Master"
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    local value = LSM and LSM.Fetch and LSM:Fetch("sound", choice, true) or nil
    if type(value) == "number" and value > 0 then
        PlaySound(value, ch)
    elseif type(value) == "string" and value ~= "" then
        PlaySoundFile(value, ch)
    end
end
CAA.PlayAlert = PlayAlert

-- callback(frame, isActive, wasActive) from ns.FrameActive
local function OnActiveChanged(frame, isActive, wasActive)
    if isActive == wasActive then return end
    if not Settled() then return end
    -- read the ID LIVE: CDM recycles frames between cooldowns
    local cdID = frame and frame.cooldownID
    if not cdID then return end
    local cfg = ns.CDMEnhance and ns.CDMEnhance.GetIconSettings
        and ns.CDMEnhance.GetIconSettings(cdID)
    local a = cfg and cfg.auraAlerts
    if not a then return end
    if isActive then
        PlayAlert(a.gainedSound, a.gainedTTS, a.channel)
    else
        PlayAlert(a.removedSound, a.removedTTS, a.channel)
    end
end

-- Aura frames only (Applications is the CDM aura-frame marker); cooldown
-- frames have their own alert path.
function CAA.Hook(frame)
    if not frame or frame._arcAuraAlertHooked then return end
    if frame.Applications == nil then return end
    if not (ns.FrameActive and ns.FrameActive.OnChanged) then return end
    frame._arcAuraAlertHooked = true
    ns.FrameActive.OnChanged(frame, OnActiveChanged)
end

function CAA.Sweep()
    local frames = ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrames
        and ns.CDMEnhance.GetEnhancedFrames()
    if not frames then return end
    -- The registry is [cooldownID] = { frame =, viewerType =, ... }. Walking it
    -- as a frame list (`for frame in pairs`) yielded the NUMERIC KEYS, so the
    -- table check below never passed and NOTHING was ever hooked -- the whole
    -- feature was inert from day one. Iterate the values.
    for _, data in pairs(frames) do
        local frame = type(data) == "table" and data.frame or nil
        if frame and frame.Applications ~= nil then
            CAA.Hook(frame)
        end
    end
end

local sweepQueued = false
function CAA.QueueSweep(delay)
    if sweepQueued then return end
    sweepQueued = true
    C_Timer.After(delay or 0.5, function()
        sweepQueued = false
        CAA.Sweep()
    end)
end

-- CDM creates/rebinds item frames as viewers grow and on every rebuild (all
-- the time in dungeons). The login sweeps only cover frames that already
-- exist, so ride the controller's rebind callback for the rest. Hook is
-- idempotent per frame; the settle window still guards the bind storm.
local rebindHooked = false
local function ArmRebind()
    if rebindHooked then return end
    if not (ns.FrameController and ns.FrameController.OnFrameRebind) then return end
    rebindHooked = true
    ns.FrameController.OnFrameRebind(function(frame)
        if frame and frame.Applications ~= nil then CAA.Hook(frame) end
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
    -- hold alerts through the bind storm, then start listening
    settledAt = GetTime() + 5
    ArmRebind()
    CAA.QueueSweep(2)
    CAA.QueueSweep(6)
end)

-- new/rebound frames after option edits or CDM rebuilds
if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
    ns.CDMShared.RegisterPanelCallback("ArcCDMAuraAlerts", {
        onClose = function() CAA.QueueSweep(0.2) end,
    })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF ArcUI_CDMAuraAlerts.lua
-- ═══════════════════════════════════════════════════════════════════════════
