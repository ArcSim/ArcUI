-- ===================================================================
-- ArcUI_Core.lua
-- Core tracking system supporting multiple bar slots
-- v3.0.0: Event-driven CDM hook architecture
--   - Hooks CDM frame OnAuraInstanceInfoSet/OnAuraInstanceInfoCleared/
--     OnUnitAuraUpdatedEvent for direct bar updates (no UNIT_AURA polling).
--   - PLAYER_TOTEM_UPDATE handler for totem/pet/ground bars.
--   - Cached frame refs from ValidateAllBarTracking with O(1) cooldownID validation.
-- v2.13.0: Fix debuff stack tracking lag ("one behind" on target)
-- v2.12.0: Fix empty CDM bar frames after spec change
-- v2.11.0: Secret-safe auraInstanceID protection
-- v2.7.0: Added sound utilities for conditional events system
-- 
-- DEBUFF DURATION FIX (v2.2.1):
-- - For debuffs, use CDM frame's auraInstanceID with "target" unit
-- - CDM bar frame provides duration data via Bar:GetValue()
-- ===================================================================

local ADDON, ns = ...
ns = ns or {}
ns.API = ns.API or {}

-- Optional dev tooling: hand our namespace to !ArcUIProfiler for opt-in deep
-- per-module CPU profiling. No-op unless that profiler addon is installed (it
-- loads first and defines the global). We pass the reference; it is only walked
-- on demand via /arcprof deep, never automatically.
if _G.ArcUIProfiler_RegisterNamespace then _G.ArcUIProfiler_RegisterNamespace(ns) end

ns.devMode = false
ns.debugMode = false  -- Stack tracking debug output

-- ===================================================================
-- LIBPLEEBUG PROFILING SETUP
-- ===================================================================
local MemDebug = LibStub and LibStub("LibPleebug-1", true)
local P, TrackThis
if MemDebug then
  P, TrackThis = MemDebug:DropIn(ns.API)
end
ns.API._TrackThis = TrackThis

-- ===================================================================
-- SECRET-SAFE AURAINSTANCEID HELPERS
-- v2.11.0: Protects against future Blizzard change making auraInstanceID secret
-- Uses issecretvalue() to test presence without direct comparison
-- ===================================================================

-- Check if an auraInstanceID is present (handles potential secret values)
-- Returns: true if aura is active, false if nil/0/absent
local function HasAuraInstanceID(value)
  if value == nil then return false end
  -- issecretvalue returns true if the value is a secret value
  -- A secret auraInstanceID means the aura IS present (just can't compare it)
  if issecretvalue and issecretvalue(value) then
    return true
  end
  -- Non-secret: treat 0 as "no aura" (default value in saved variables)
  if type(value) == "number" and value == 0 then return false end
  -- Non-nil, non-zero, non-secret = valid auraInstanceID
  return true
end

-- Expose for other modules
ns.API.HasAuraInstanceID = HasAuraInstanceID

-- Spec change grace period - don't hide bars due to trackingOK=false for a few seconds after spec change
local specChangeGraceUntil = 0
local SPEC_CHANGE_GRACE_DURATION = 3.0  -- seconds

-- ===================================================================
-- REGISTER ADDON SOUNDS WITH LIBSHAREDMEDIA
-- v2.7.0: Added for conditional events system
-- ===================================================================
local LSM = LibStub("LibSharedMedia-3.0", true)

if LSM then
  local SOUND_PATH = "Interface\\AddOns\\ArcUI\\Sounds\\"
  
  local addonSounds = {
    -- Animals
    ["ArcUI: Bleat"]             = "Bleat.ogg",
    ["ArcUI: Cat Meow"]          = "CatMeow2.ogg",
    ["ArcUI: Chicken Alarm"]     = "ChickenAlarm.ogg",
    ["ArcUI: Cow Mooing"]        = "CowMooing.ogg",
    ["ArcUI: Goat Bleating"]     = "GoatBleating.ogg",
    ["ArcUI: Kitten Meow"]       = "KittenMeow.ogg",
    ["ArcUI: Roaring Lion"]      = "RoaringLion.ogg",
    ["ArcUI: Rooster Chicken"]   = "RoosterChickenCalls.ogg",
    ["ArcUI: Sheep Bleat"]       = "SheepBleat.ogg",
    -- Alerts
    ["ArcUI: Air Horn"]          = "AirHorn.ogg",
    ["ArcUI: Bike Horn"]         = "BikeHorn.ogg",
    ["ArcUI: Error Beep"]        = "ErrorBeep.ogg",
    ["ArcUI: Ringing Phone"]     = "RingingPhone.ogg",
    ["ArcUI: Robot Blip"]        = "RobotBlip.ogg",
    ["ArcUI: Warning Siren"]     = "WarningSiren.ogg",
    -- Musical
    ["ArcUI: Acoustic Guitar"]   = "AcousticGuitar.ogg",
    ["ArcUI: Brass"]             = "Brass.mp3",
    ["ArcUI: Drums"]             = "Drums.ogg",
    ["ArcUI: Glass"]             = "Glass.mp3",
    ["ArcUI: Synth Chord"]       = "SynthChord.ogg",
    ["ArcUI: Tada Fanfare"]      = "TadaFanfare.ogg",
    ["ArcUI: Temple Bell"]       = "TempleBellHuge.ogg",
    ["ArcUI: Xylophone"]         = "Xylophone.ogg",
    -- Effects
    ["ArcUI: Applause"]          = "Applause.ogg",
    ["ArcUI: Banana Peel Slip"]  = "BananaPeelSlip.ogg",
    ["ArcUI: Batman Punch"]      = "BatmanPunch.ogg",
    ["ArcUI: Blast"]             = "Blast.ogg",
    ["ArcUI: Boxing Arena"]      = "BoxingArenaSound.ogg",
    ["ArcUI: Double Whoosh"]     = "DoubleWhoosh.ogg",
    ["ArcUI: Heartbeat"]         = "HeartbeatSingle.ogg",
    ["ArcUI: Sharp Punch"]       = "SharpPunch.ogg",
    ["ArcUI: Shotgun"]           = "Shotgun.ogg",
    ["ArcUI: Squeaky Toy"]       = "SqueakyToyShort.ogg",
    ["ArcUI: Squish"]            = "SquishFart.ogg",
    ["ArcUI: Torch"]             = "Torch.ogg",
    ["ArcUI: Water Drop"]        = "WaterDrop.ogg",
    -- Voice
    ["ArcUI: Cartoon Voice"]     = "CartoonVoiceBaritone.ogg",
    ["ArcUI: Cartoon Walking"]   = "CartoonWalking.ogg",
    ["ArcUI: Oh No"]             = "OhNo.ogg",
  }
  
  for name, file in pairs(addonSounds) do
    LSM:Register("sound", name, SOUND_PATH .. file)
  end
end

-- ===================================================================
-- SOUND UTILITIES
-- ===================================================================
ns.Sounds = ns.Sounds or {}

-- Built-in WoW SoundKit IDs
ns.Sounds.builtInSounds = {
  [567]   = "Snarl",
  [569]   = "Growl",
  [3081]  = "Direct Message",
  [5274]  = "Auction Window",
  [8959]  = "Raid Warning",
  [11466] = "Not Prepared",
  [12867] = "Drumroll Ding",
  [23404] = "PvP Warning",
  [25477] = "Countdown",
}

local currentSoundHandle = nil

-- Play a sound from settings table
-- settings = { soundType = "lsm"|"soundkit"|"custom", lsmSound = name, soundKitID = id, customPath = path }
function ns.Sounds.PlaySound(settings)
  if not settings then return end
  
  local willPlay, soundHandle
  
  if settings.soundType == "soundkit" and settings.soundKitID then
    willPlay, soundHandle = PlaySound(settings.soundKitID, "Master")
  elseif settings.soundType == "lsm" and settings.lsmSound then
    if LSM then
      local soundPath = LSM:Fetch("sound", settings.lsmSound)
      if soundPath then
        willPlay, soundHandle = PlaySoundFile(soundPath, "Master")
      end
    end
  elseif settings.soundType == "custom" and settings.customPath and settings.customPath ~= "" then
    willPlay, soundHandle = PlaySoundFile(settings.customPath, "Master")
  end
  
  -- Handle TTS if enabled
  if settings.ttsEnabled and settings.ttsText and settings.ttsText ~= "" then
    ns.Sounds.SpeakText(settings.ttsText, settings.ttsVoice)
  end
  
  return willPlay, soundHandle
end

-- Preview a sound (for options panel)
function ns.Sounds.PreviewSound(settings)
  ns.Sounds.StopPreview()
  local willPlay, soundHandle = ns.Sounds.PlaySound(settings)
  currentSoundHandle = soundHandle
  return willPlay
end

-- Stop the current preview
function ns.Sounds.StopPreview()
  if currentSoundHandle then
    StopSound(currentSoundHandle)
    currentSoundHandle = nil
  end
end

-- Text-to-speech wrapper
function ns.Sounds.SpeakText(text, voiceID)
  if not text or text == "" then return end
  if not C_VoiceChat or not C_VoiceChat.SpeakText then return end
  -- voiceID 0 = default, Enum.TtsVoiceType.Standard = 0
  C_VoiceChat.SpeakText(voiceID or 0, text, Enum.TtsVoiceType.Standard, 100, 100)
end

-- Get dropdown values for sound selection
-- Returns: { ["lsm:soundName"] = "Sound Name", ["soundkit:123"] = "Built-in Name", ... }
function ns.Sounds.GetSoundDropdown()
  local sounds = {}
  
  -- Add LSM sounds
  if LSM then
    local lsmSounds = LSM:List("sound")
    for _, soundName in ipairs(lsmSounds) do
      sounds["lsm:" .. soundName] = soundName
    end
  end
  
  -- Add built-in SoundKit sounds
  for id, name in pairs(ns.Sounds.builtInSounds) do
    sounds["soundkit:" .. id] = name .. " (Built-in)"
  end
  
  return sounds
end

-- Parse a dropdown key into a settings table
function ns.Sounds.ParseSoundKey(key)
  if not key then return nil end
  
  if key:match("^lsm:") then
    return { soundType = "lsm", lsmSound = key:gsub("^lsm:", "") }
  elseif key:match("^soundkit:") then
    return { soundType = "soundkit", soundKitID = tonumber(key:gsub("^soundkit:", "")) }
  end
  
  return nil
end

-- Create a dropdown key from a settings table
function ns.Sounds.CreateSoundKey(settings)
  if not settings then return nil end
  
  if settings.soundType == "lsm" and settings.lsmSound then
    return "lsm:" .. settings.lsmSound
  elseif settings.soundType == "soundkit" and settings.soundKitID then
    return "soundkit:" .. settings.soundKitID
  end
  
  return nil
end

-- ===================================================================
-- CUSTOM EDITBOX WIDGET WITHOUT OK BUTTON
-- ===================================================================
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if AceGUI then
  local Type = "ArcUI_EditBox"
  local Version = 3
  local function Constructor()
    local widget = AceGUI:Create("EditBox")
    local originalOnAcquire = widget.OnAcquire
    widget.OnAcquire = function(self)
      if originalOnAcquire then originalOnAcquire(self) end
      self:DisableButton(true)
      if self.editbox then self.editbox:SetJustifyH("CENTER") end
    end
    widget:DisableButton(true)
    if widget.editbox then widget.editbox:SetJustifyH("CENTER") end
    return widget
  end
  AceGUI:RegisterWidgetType(Type, Constructor, Version)
end

-- ===================================================================
-- FORWARD DECLARATIONS
-- ===================================================================
local UpdateAllBars
local UpdateBarBuffInfo

local hookedAuraFrames = {}    -- [frame] = { barNumbers = {barNum = true} }

-- Per-bar set of bar numbers that have opted into high-frequency SetAuraInstanceInfo updates.
-- Stored separately so the hook can check cheaply without reading barConfig on every fire.
local highFreqBars = {}  -- [barNumber] = true

local totemBarNumbers = {}     -- [barNum] = true, for PLAYER_TOTEM_UPDATE

-- ===================================================================
-- v3.7.2 AURA-ENGINE REWORK: auraInstanceID → bars reverse map (per unit)
-- ===================================================================
-- CDM frames remain the source of truth for WHICH aura is on a tracked spell
-- (the OnAuraInstanceInfoSet hook / RefreshData / bind all drive an immediate
-- UpdateBarBuffInfo). This map exists so the single UNIT_AURA consumer can
-- refresh ONLY the bars whose specific aura instance changed (O(changed)),
-- instead of every bar bound to a frame.
--
-- SINGLE WRITER: UpdateBarBuffInfo maps the exact instance each bar resolved to
-- DISPLAY (frame-current, cached, or trackedSpellID cross-spell) via
-- SetBarAuraMapping. This is authoritative — it doesn't matter how the bar
-- found its aura, only what it's showing. Per-bar (not per-frame) keying means
-- two bars on one frame, or a bar showing a cached sibling instance, are all
-- tracked correctly.
--
-- Secret auraInstanceIDs (can occur in instances) cannot be used as table keys,
-- so those bars are bucketed in secretAuraBars and refreshed on any UNIT_AURA
-- for their unit — a rare, correctness-preserving fallback.
local auraEntries   = { player = {}, target = {} }  -- [unit][auraInstanceID] = { [barNum] = true }
local secretAuraBars = { player = {}, target = {} } -- [unit] = { [barNum] = true }

-- Record (or, with nil aiid, clear) the aura instance a bar is currently
-- displaying. Removes any previous mapping for the bar first, so it's safe to
-- call every UpdateBarBuffInfo. `state` is the bar's barStates entry (carries
-- the previous mapping so cleanup is O(1)).
local function SetBarAuraMapping(barNumber, state, unit, aiid)
  local valid = (unit == "player" or unit == "target") and HasAuraInstanceID(aiid)
  local isSecret = false
  if valid and issecretvalue and issecretvalue(aiid) then isSecret = true end

  local pu, pa, ps = state._mapUnit, state._mapAiid, state._mapSecret

  -- Is the new mapping the same as the previous one? Compare SECRET-SAFELY:
  -- only do a numeric == when BOTH ids are plain (non-secret) numbers; never
  -- compare a secret against a number (that yields a secret boolean → throws).
  local same = false
  if valid and pu == unit then
    if isSecret and ps then
      same = true                       -- both secret on the same unit: leave as-is
    elseif (not isSecret) and (not ps) and pa ~= nil then
      same = (pa == aiid)               -- both plain numbers: safe to compare
    end
  end
  if same then return end

  -- Remove the previous mapping, if any.
  if pu then
    if ps then
      if secretAuraBars[pu] then secretAuraBars[pu][barNumber] = nil end
    elseif pa ~= nil then
      local b = auraEntries[pu] and auraEntries[pu][pa]
      if b then
        b[barNumber] = nil
        if not next(b) then auraEntries[pu][pa] = nil end
      end
    end
    state._mapUnit, state._mapAiid, state._mapSecret = nil, nil, nil
  end

  if not valid then return end

  if isSecret then
    secretAuraBars[unit][barNumber] = true
    state._mapUnit, state._mapAiid, state._mapSecret = unit, nil, true
  else
    local bucket = auraEntries[unit][aiid]
    if not bucket then bucket = {}; auraEntries[unit][aiid] = bucket end
    bucket[barNumber] = true
    state._mapUnit, state._mapAiid, state._mapSecret = unit, aiid, nil
  end
end

-- Hook CDM frame's OnAuraInstanceInfoSet / OnAuraInstanceInfoCleared / RefreshData
-- for direct bar updates. Only hooks once per frame. Live stack/duration changes
-- on an already-shown aura are handled by the single UNIT_AURA consumer
-- (HandleUnitAura) via the reverse map above — NOT by per-frame hooks.
-- When aura gained → update bar
-- When aura stack/duration updated → update bar
-- When aura lost → unregister + update bar to hide
-- When totem updates → update bar (totemData already current at hook time)
local function HookCDMFrameForAuraMap(frame, barNumber)
  if not frame then return end

  if not hookedAuraFrames[frame] then
    hookedAuraFrames[frame] = { barNumbers = {} }

    -- OnAuraInstanceInfoSet: fires on real aura gained (player buffs/target
    -- debuffs) — binds WHICH auraInstanceID is on this frame and shows the bar.
    if frame.OnAuraInstanceInfoSet then
      hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
        local hookData = hookedAuraFrames[self]
        if not hookData or not next(hookData.barNumbers) then return end
        self._arcAuraActive = true
        -- Bump the aura token. A Set arriving after a Cleared (same UNIT_AURA
        -- batch: removed pass fires Cleared, added pass fires Set, OR a full CDM
        -- layout refresh re-populates auraInstanceID) means the buff is present
        -- again — so any deferred "cleared" hide that captured an older token
        -- must abort instead of hiding a still-active aura.
        self._arcAuraToken = (self._arcAuraToken or 0) + 1
        -- Refresh drives UpdateBarBuffInfo, which (re)maps each bar's resolved
        -- aura instance into the reverse map for UNIT_AURA targeting.
        for barNum in pairs(hookData.barNumbers) do
          UpdateBarBuffInfo(barNum)
        end
      end)
    end

    -- OnAuraInstanceInfoCleared: fires on real aura lost (player buffs).
    if frame.OnAuraInstanceInfoCleared then
      hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
        local hookData = hookedAuraFrames[self]
        if not hookData or not next(hookData.barNumbers) then return end
        self._arcAuraActive = false
        -- Capture the token at schedule time. If OnAuraInstanceInfoSet fires
        -- before this deferred update runs (same-batch remove+add, or a CDM full
        -- layout refresh re-setting the aura), the token will have advanced and
        -- we abort — the buff is back, so the bar should NOT process a hide.
        local tokenAtSchedule = self._arcAuraToken or 0
        local bars = {}
        for barNum in pairs(hookData.barNumbers) do bars[barNum] = true end
        C_Timer.After(0, function()
          if (self._arcAuraToken or 0) ~= tokenAtSchedule then return end
          for barNum in pairs(bars) do
            UpdateBarBuffInfo(barNum)
          end
        end)
      end)
    end

    -- NOTE (v3.7.2 rework): the per-frame OnNewTarget and OnUnitAuraUpdatedEvent
    -- hooks were removed here. Live stack/duration changes on an already-shown
    -- aura — for BOTH player buffs and target debuffs — are now driven by the
    -- single UNIT_AURA("player","target") consumer (HandleUnitAura) through the
    -- auraInstanceID→bars reverse map, so only the bars whose aura actually
    -- changed get refreshed (was: every bar bound to the frame, fired several
    -- times per UNIT_AURA batch). RefreshData (below) stays for the same-id
    -- duration-extend case that fires no UNIT_AURA id.

    -- RefreshData: the ONE signal that fires on a same-instance-ID aura refresh.
    -- CDM's SetAuraInstanceInfo only fires OnAuraInstanceInfoSet when the auraInstanceID
    -- or spellID CHANGES (CooldownViewerItemData.lua:230). A buff reapplied with the same
    -- instance ID (duration extended, ID unchanged) fires NEITHER Set NOR a guaranteed
    -- UpdatedEvent — so the bar never re-pushes the new duration and drains to the old
    -- expiration. RefreshData runs on every refresh including this case. Coalesce per tick
    -- (CDM calls RefreshData several times per UNIT_AURA batch) and only act when the frame
    -- currently holds a valid aura instance, so this is a no-op on inactive frames.
    if frame.RefreshData then
      hooksecurefunc(frame, "RefreshData", function(self)
        local hookData = hookedAuraFrames[self]
        if not hookData or not next(hookData.barNumbers) then return end
        if not HasAuraInstanceID(self.auraInstanceID) then return end
        if self._arcRefreshPending then return end
        self._arcRefreshPending = true
        local bars = {}
        for barNum in pairs(hookData.barNumbers) do bars[barNum] = true end
        C_Timer.After(0, function()
          self._arcRefreshPending = false
          for barNum in pairs(bars) do
            UpdateBarBuffInfo(barNum)
          end
        end)
      end)
    end

    -- SetAuraInstanceInfo: HIGH FREQUENCY — fires on every CDM aura refresh (~50-70x/session).
    -- Opt-in only via cfg.tracking.highFrequencyUpdates. Disabled by default.
    -- Only calls UpdateBarBuffInfo for bars that have the flag enabled.
    if frame.SetAuraInstanceInfo then
      hooksecurefunc(frame, "SetAuraInstanceInfo", function(self)
        local hookData = hookedAuraFrames[self]
        if not hookData then return end
        for barNum in pairs(hookData.barNumbers) do
          if highFreqBars[barNum] then
            UpdateBarBuffInfo(barNum)
          end
        end
      end)
    end

    -- OnPlayerTotemUpdateEvent: totem gained/lost/refreshed.
    if frame.OnPlayerTotemUpdateEvent then
      hooksecurefunc(frame, "OnPlayerTotemUpdateEvent", function(self)
        local hookData = hookedAuraFrames[self]
        if not hookData or not next(hookData.barNumbers) then return end
        for barNum in pairs(hookData.barNumbers) do
          UpdateBarBuffInfo(barNum)
        end
      end)
    end

    -- Cooldown widget OnCooldownDone: per Blizzard's own line-712 comment in
    -- CooldownViewer.lua: "No external event is dispatched when a totem
    -- finishes". CDM uses the cooldown widget's OnCooldownDone as its
    -- internal totem-expiry signal — when totem duration runs out,
    -- OnCooldownDone fires, then CDM's mixin handler clears totemData and
    -- runs RefreshData. Without hooking this, bars wait ~350ms for the
    -- followup OnPlayerTotemUpdateEvent (confirmed by probe: totem expired
    -- at 230.036s → CDDone fired immediately, but TotemUpd fired only at
    -- 230.382s). HookScript chains additively after Blizzard's SetScript.
    -- Defer one tick so CDM's mixin handler clears totemData before our
    -- UpdateBarBuffInfo reads frame.totemData.
    if frame.Cooldown then
      frame.Cooldown:HookScript("OnCooldownDone", function()
        local hookData = hookedAuraFrames[frame]
        if not hookData or not next(hookData.barNumbers) then return end
        local bars = {}
        for barNum in pairs(hookData.barNumbers) do bars[barNum] = true end
        C_Timer.After(0, function()
          for barNum in pairs(bars) do
            UpdateBarBuffInfo(barNum)
          end
        end)
      end)
    end
  end

  -- Register this bar as using this frame. The reverse map is populated by
  -- UpdateBarBuffInfo (the single writer) on the bar's next update, which the
  -- caller triggers right after binding.
  hookedAuraFrames[frame].barNumbers[barNumber] = true
end

-- Unregister a bar from a frame's aura hooks
local function UnhookBarFromAuraFrame(frame, barNumber)
  if not frame or not hookedAuraFrames[frame] then return end
  hookedAuraFrames[frame].barNumbers[barNumber] = nil
end

-- Clear all bar registrations on spec change
-- (hooksecurefunc hooks persist but become no-ops with empty barNumbers)
local function ClearAllAuraHookRegistrations()
  for frame, data in pairs(hookedAuraFrames) do
    wipe(data.barNumbers)
  end
  wipe(totemBarNumbers)
  wipe(highFreqBars)
  -- Reverse map is rebuilt as bars re-resolve; barStates (with _map* fields)
  -- are wiped by the spec-change handler, so just clear the shared tables.
  for _, t in pairs(auraEntries) do wipe(t) end
  for _, t in pairs(secretAuraBars) do wipe(t) end
end

-- Register frame hooks appropriate for the bar's track type
local function RegisterBarFrameHooks(frame, barNumber, trackType)
  if not frame then return end
  -- Sync highFreqBars for this bar based on its current config flag
  local barCfg = ns.API.GetBarConfig and ns.API.GetBarConfig(barNumber)
  if barCfg and barCfg.tracking and barCfg.tracking.highFrequencyUpdates then
    highFreqBars[barNumber] = true
  else
    highFreqBars[barNumber] = nil
  end
  if trackType == "pet" or trackType == "totem" or trackType == "ground" then
    -- Totem/pet/ground: tracked via PLAYER_TOTEM_UPDATE event
    totemBarNumbers[barNumber] = true
    -- Also hook SetAuraInstanceInfo in case CDM sets aura data on totem frames
    HookCDMFrameForAuraMap(frame, barNumber)
  else
    -- Buff (default) AND Debuff: hook CDM frame directly for aura updates.
    HookCDMFrameForAuraMap(frame, barNumber)
  end
end

-- ===================================================================
-- STATE VARIABLES
-- ===================================================================
local barStates = {}

local function GetBarState(barNumber)
  if not barStates[barNumber] then
    barStates[barNumber] = {
      cooldownID = nil,
      cachedFrame = nil,
      cachedBarFrame = nil,
      stacks = 0,
      active = false,
      trackingOK = false
    }
  end
  return barStates[barNumber]
end

-- Forward declaration for ClearBarState (needs AllowCDMFrameVisible which is defined later)
local ClearBarState

-- ===================================================================
-- CROSS-SPEC COOLDOWNID RESOLUTION SYSTEM
-- Handles bars that need to work across multiple specs where the
-- same spell has different cooldownIDs per spec
-- ===================================================================

-- Cache for spellID → cooldownID mapping (rebuilt on spec change)
local spellToCooldownIDCache = nil
local spellToCooldownIDCacheSpec = nil  -- Track which spec the cache was built for

-- Build mapping of spellID → cooldownID for current spec
-- Scans all CDM categories to find what cooldownIDs are available
local function BuildSpellToCooldownIDMapping()
  local mapping = {}
  
  if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCategorySet then
    return mapping
  end
  
  -- Scan all aura categories (TrackedBuff=2, TrackedBar=3)
  -- We only care about auras for this cross-spec feature
  local auraCategories = {2, 3}  -- Enum.CooldownViewerCategory.TrackedBuff, TrackedBar
  
  for _, category in ipairs(auraCategories) do
    local cooldownIDs = C_CooldownViewer.GetCooldownViewerCategorySet(category, true)  -- allowUnlearned=true
    if cooldownIDs then
      for _, cdID in ipairs(cooldownIDs) do
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        if info and info.spellID and info.spellID > 0 then
          -- Store mapping: spellID → cooldownID
          -- Note: A spellID might map to multiple cooldownIDs (e.g., different ranks)
          -- We store the first one found; the validation loop will find the right frame
          if not mapping[info.spellID] then
            mapping[info.spellID] = cdID
          end
          
          -- Also check linkedSpellIDs for auras that might have variant spell IDs
          if info.linkedSpellIDs then
            for _, linkedSpellID in ipairs(info.linkedSpellIDs) do
              if linkedSpellID and linkedSpellID > 0 and not mapping[linkedSpellID] then
                mapping[linkedSpellID] = cdID
              end
            end
          end
        end
      end
    end
  end
  
  return mapping
end

-- Get or rebuild the spellID → cooldownID cache
local function GetSpellToCooldownIDMapping()
  local currentSpec = GetSpecialization() or 0
  
  -- Rebuild cache if spec changed or cache is empty
  if not spellToCooldownIDCache or spellToCooldownIDCacheSpec ~= currentSpec then
    spellToCooldownIDCache = BuildSpellToCooldownIDMapping()
    spellToCooldownIDCacheSpec = currentSpec
    
    if ns.devMode then
      local count = 0
      for _ in pairs(spellToCooldownIDCache) do count = count + 1 end
      print(string.format("|cff00FF00[ArcUI]|r Built spellID→cooldownID mapping: %d entries for spec %d", count, currentSpec))
    end
  end
  
  return spellToCooldownIDCache
end

-- Invalidate the cache (call on spec change)
local function InvalidateSpellToCooldownIDCache()
  spellToCooldownIDCache = nil
  spellToCooldownIDCacheSpec = nil
end

-- Find a cooldownID for a spellID on current spec
local function FindCooldownIDForSpellID(spellID)
  if not spellID or spellID <= 0 then return nil end
  
  local mapping = GetSpellToCooldownIDMapping()
  return mapping[spellID]
end

-- Get the active (working) cooldownID for a bar
-- Tries: primary cooldownID → alternateCooldownIDs → auto-discover via spellID
-- Returns: cooldownID, sourceType ("primary", "alternate", "discovered", or nil)
function ns.API.GetActiveCooldownIDForBar(barNum, validCooldownIDs)
  local barConfig = ns.API.GetBarConfig(barNum)
  if not barConfig or not barConfig.tracking then return nil, nil end
  
  local tracking = barConfig.tracking
  local trackType = tracking.trackType
  
  -- If validCooldownIDs not provided, check bar state for what's currently active
  -- This is used by UI to display which cooldownID is currently working
  if not validCooldownIDs then
    local state = barStates[barNum]
    if state and state.trackingOK and state.cooldownID then
      -- Determine if it's primary or alternate
      if state.cooldownID == tracking.cooldownID then
        return state.cooldownID, "primary"
      elseif tracking.alternateCooldownIDs then
        for _, altCdID in ipairs(tracking.alternateCooldownIDs) do
          if state.cooldownID == altCdID then
            return state.cooldownID, "alternate"
          end
        end
      end
      return state.cooldownID, "discovered"
    end
    return nil, nil
  end
  
  -- Helper to check if a cooldownID has a valid frame
  -- Uses validCooldownIDs which is built by scanning all viewers + CDMGroups containers
  local function hasValidFrame(cdID)
    if not cdID or (type(cdID) == "number" and cdID <= 0) then return false end
    
    -- Check validCooldownIDs map (built by ValidateAllBarTracking's initial scan)
    if validCooldownIDs and validCooldownIDs[cdID] then
      return true
    end
    
    return false
  end
  
  -- 1. Try primary cooldownID
  if hasValidFrame(tracking.cooldownID) then
    return tracking.cooldownID, "primary"
  end
  
  -- 2. Try alternate cooldownIDs
  if tracking.alternateCooldownIDs then
    for _, altCdID in ipairs(tracking.alternateCooldownIDs) do
      if hasValidFrame(altCdID) then
        return altCdID, "alternate"
      end
    end
  end
  
  -- 3. Auto-discover removed — use ns.API.DiscoverAlternateCooldownID(barNum) explicitly
  
  -- No valid cooldownID found
  return nil, nil
end

-- Manually add a cooldownID to a bar's alternate list
function ns.API.AddAlternateCooldownID(barNum, cooldownID)
  local barConfig = ns.API.GetBarConfig(barNum)
  if not barConfig or not barConfig.tracking then return false, "Invalid bar" end
  
  if not cooldownID or type(cooldownID) ~= "number" or cooldownID <= 0 then
    return false, "Invalid cooldownID"
  end
  
  -- Initialize if needed
  if not barConfig.tracking.alternateCooldownIDs then
    barConfig.tracking.alternateCooldownIDs = {}
  end
  
  -- Check if already exists (in primary or alternates)
  if barConfig.tracking.cooldownID == cooldownID then
    return false, "Already the primary cooldownID"
  end
  
  for _, existingCdID in ipairs(barConfig.tracking.alternateCooldownIDs) do
    if existingCdID == cooldownID then
      return false, "Already in alternate list"
    end
  end
  
  -- Add it
  table.insert(barConfig.tracking.alternateCooldownIDs, cooldownID)
  
  -- Re-validate tracking
  if ns.API.ValidateAllBarTracking then
    ns.API.ValidateAllBarTracking()
  end
  
  return true, string.format("Added cooldownID %d to bar %d", cooldownID, barNum)
end

-- Remove a cooldownID from a bar's alternate list and add to excluded list
function ns.API.RemoveAlternateCooldownID(barNum, cooldownID)
  local barConfig = ns.API.GetBarConfig(barNum)
  if not barConfig or not barConfig.tracking then return false, "Invalid bar" end
  
  if not barConfig.tracking.alternateCooldownIDs then
    return false, "No alternate cooldownIDs"
  end
  
  local removed = false
  for i, existingCdID in ipairs(barConfig.tracking.alternateCooldownIDs) do
    if existingCdID == cooldownID then
      table.remove(barConfig.tracking.alternateCooldownIDs, i)
      removed = true
      break
    end
  end
  
  if not removed then
    return false, string.format("CooldownID %d not found in alternate list", cooldownID)
  end
  
  -- Add to excluded list so auto-discover never re-adds it
  if not barConfig.tracking.excludedCooldownIDs then
    barConfig.tracking.excludedCooldownIDs = {}
  end
  local alreadyExcluded = false
  for _, exID in ipairs(barConfig.tracking.excludedCooldownIDs) do
    if exID == cooldownID then alreadyExcluded = true; break end
  end
  if not alreadyExcluded then
    table.insert(barConfig.tracking.excludedCooldownIDs, cooldownID)
  end
  
  -- Re-validate tracking
  if ns.API.ValidateAllBarTracking then
    ns.API.ValidateAllBarTracking()
  end
  
  return true, string.format("Removed cooldownID %d from bar %d (excluded from future discovery)", cooldownID, barNum)
end

-- Get all cooldownIDs for a bar (primary + alternates)
function ns.API.GetAllCooldownIDsForBar(barNum)
  local barConfig = ns.API.GetBarConfig(barNum)
  if not barConfig or not barConfig.tracking then return {} end
  
  local result = {}
  
  -- Add primary
  if barConfig.tracking.cooldownID and barConfig.tracking.cooldownID > 0 then
    table.insert(result, {
      cooldownID = barConfig.tracking.cooldownID,
      isPrimary = true,
      isActive = false  -- Will be set by caller if needed
    })
  end
  
  -- Add alternates
  if barConfig.tracking.alternateCooldownIDs then
    for _, cdID in ipairs(barConfig.tracking.alternateCooldownIDs) do
      table.insert(result, {
        cooldownID = cdID,
        isPrimary = false,
        isActive = false
      })
    end
  end
  
  return result
end

-- Manually trigger alt cooldown ID discovery for a bar (button-driven, never automatic)
-- Skips excluded IDs. Returns discovered cooldownID or nil, plus a status message.
function ns.API.DiscoverAlternateCooldownID(barNum)
  local barConfig = ns.API.GetBarConfig(barNum)
  if not barConfig or not barConfig.tracking then return nil, "Invalid bar" end
  
  local tracking = barConfig.tracking
  if not tracking.spellID or tracking.spellID <= 0 then
    return nil, "No spellID set for this bar"
  end
  
  -- Build valid cooldown ID set (requires a current CDM scan)
  local validCooldownIDs = {}
  if ns.API.ScanAllCDMIcons then
    ns.API.ScanAllCDMIcons(function(cdID)
      validCooldownIDs[cdID] = true
    end)
  elseif ns.cdmIconCache then
    for cdID in pairs(ns.cdmIconCache) do
      validCooldownIDs[cdID] = true
    end
  end
  
  local discoveredCdID = FindCooldownIDForSpellID(tracking.spellID)
  if not discoveredCdID or not validCooldownIDs[discoveredCdID] then
    return nil, string.format("No CDM frame found for spellID %d", tracking.spellID)
  end
  
  -- Skip if it's the primary
  if discoveredCdID == tracking.cooldownID then
    return nil, string.format("CooldownID %d is already the primary", discoveredCdID)
  end
  
  -- Skip if excluded
  if tracking.excludedCooldownIDs then
    for _, exID in ipairs(tracking.excludedCooldownIDs) do
      if exID == discoveredCdID then
        return nil, string.format("CooldownID %d is excluded — un-exclude it first to re-add", discoveredCdID)
      end
    end
  end
  
  -- Skip if already in alternates
  if tracking.alternateCooldownIDs then
    for _, altID in ipairs(tracking.alternateCooldownIDs) do
      if altID == discoveredCdID then
        return nil, string.format("CooldownID %d is already in the alternate list", discoveredCdID)
      end
    end
  end
  
  -- Add it
  if not tracking.alternateCooldownIDs then tracking.alternateCooldownIDs = {} end
  table.insert(tracking.alternateCooldownIDs, discoveredCdID)
  
  if ns.API.ValidateAllBarTracking then ns.API.ValidateAllBarTracking() end
  
  return discoveredCdID, string.format("Found and added cooldownID %d for bar %d", discoveredCdID, barNum)
end

-- Remove a cooldownID from the excluded list so discovery can find it again
function ns.API.UnexcludeCooldownID(barNum, cooldownID)
  local barConfig = ns.API.GetBarConfig(barNum)
  if not barConfig or not barConfig.tracking then return false, "Invalid bar" end
  if not barConfig.tracking.excludedCooldownIDs then return false, "No excluded IDs" end
  
  for i, exID in ipairs(barConfig.tracking.excludedCooldownIDs) do
    if exID == cooldownID then
      table.remove(barConfig.tracking.excludedCooldownIDs, i)
      return true, string.format("CooldownID %d removed from excluded list", cooldownID)
    end
  end
  return false, string.format("CooldownID %d not in excluded list", cooldownID)
end

-- Expose cache invalidation for spec change handlers
ns.API.InvalidateSpellToCooldownIDCache = InvalidateSpellToCooldownIDCache

-- ===================================================================
-- CDM ICON HIDING SYSTEM
-- ===================================================================
local hiddenCDMFrames = {}  -- [frame] = expectedCooldownID
local hiddenCDMFramesByCD = {}  -- [cooldownID] = frame (reverse lookup for O(1) dedup)
local hiddenByBarOverlays = {}  -- [frame] = overlayFrame

-- Forward declaration for ForceHideCDMFrame (needed by RefreshHiddenCDMFrames)
local ForceHideCDMFrame

-- ═══════════════════════════════════════════════════════════════════════════
-- CDM HIDE REQUEST REGISTRY
-- Tracks which bars are actively requesting each cooldownID to be hidden.
-- Prevents flickering when multiple bars track the same CDM icon with
-- different hideBuffIcon settings: "hide" wins if ANY bar requests it.
-- ═══════════════════════════════════════════════════════════════════════════
local cdmHideRequestsByCD = {}  -- [cooldownID] = { [barNumber] = true, ... }

-- Register a bar's request to hide a specific cooldownID.
-- INVARIANT: a bar is registered under at most ONE cooldownID at a time. If this
-- bar's resolved cooldownID flipped (cross-spec alternate, SelectBuff re-point),
-- drop its prior entries first — otherwise a stale entry would keep force-hiding
-- the OLD icon and AnyCDMHideRequestForCD would wrongly report it still wanted.
-- (Re-showing a now-orphaned frame is handled by ReassertCDMHideRequests; keeping
-- this single-entry invariant also keeps UnregisterCDMHideRequest's one-shot
-- removal correct.) Removing the current iteration key during pairs() is allowed.
local function RegisterCDMHideRequest(barNumber, cooldownID)
  if not cooldownID then return end
  for cdID, bars in pairs(cdmHideRequestsByCD) do
    if cdID ~= cooldownID and bars[barNumber] then
      bars[barNumber] = nil
      if not next(bars) then cdmHideRequestsByCD[cdID] = nil end
    end
  end
  if not cdmHideRequestsByCD[cooldownID] then
    cdmHideRequestsByCD[cooldownID] = {}
  end
  cdmHideRequestsByCD[cooldownID][barNumber] = true
end

-- Unregister a bar's hide request (bar disabled, spec filtered, cleared, etc.)
-- Returns the cooldownID that was unregistered (or nil if none)
local function UnregisterCDMHideRequest(barNumber)
  for cooldownID, bars in pairs(cdmHideRequestsByCD) do
    if bars[barNumber] then
      bars[barNumber] = nil
      -- Clean up empty tables
      if not next(bars) then
        cdmHideRequestsByCD[cooldownID] = nil
      end
      return cooldownID
    end
  end
  return nil
end

-- Check if ANY bar (other than excludeBar) is still requesting a cooldownID be hidden
local function AnyCDMHideRequestForCD(cooldownID, excludeBar)
  if not cooldownID then return false end
  local bars = cdmHideRequestsByCD[cooldownID]
  if not bars then return false end
  for barNum, _ in pairs(bars) do
    if barNum ~= excludeBar then return true end
  end
  return false
end

-- Helper to get frame's current cooldownID
local function GetFrameCooldownID(frame)
  if not frame then return nil end
  local cdID = frame.cooldownID
  if not cdID and frame.cooldownInfo then
    cdID = frame.cooldownInfo.cooldownID
  end
  if not cdID and frame.Icon and frame.Icon.cooldownID then
    cdID = frame.Icon.cooldownID
  end
  return cdID
end

-- Helper to clean up hiding state from a frame (overlay, flags, tracking table)
local function CleanupFrameHidingState(frame)
  if not frame then return end
  -- Clean reverse map before removing from primary
  local cdID = hiddenCDMFrames[frame]
  if cdID and hiddenCDMFramesByCD[cdID] == frame then
    hiddenCDMFramesByCD[cdID] = nil
  end
  hiddenCDMFrames[frame] = nil
  frame._arcHiddenByBar = nil
  frame._arcHiddenByBarCdID = nil
  if hiddenByBarOverlays[frame] then
    hiddenByBarOverlays[frame]:Hide()
    hiddenByBarOverlays[frame] = nil
  end
end

-- Create or retrieve the red "Hidden" overlay for a CDM frame.
-- CDM bar frames have children at very high frame levels (e.g. .Bar at 511)
-- while the parent frame sits low (e.g. 2). We scan children to ensure the
-- overlay renders above everything.
local function GetOrCreateHiddenOverlay(frame)
  if hiddenByBarOverlays[frame] then return hiddenByBarOverlays[frame] end
  
  local overlay = CreateFrame("Frame", nil, frame)
  overlay:SetAllPoints(frame)
  
  local maxChildLevel = frame:GetFrameLevel()
  for _, child in ipairs({frame:GetChildren()}) do
    local cl = child:GetFrameLevel()
    if cl > maxChildLevel then maxChildLevel = cl end
  end
  overlay:SetFrameLevel(maxChildLevel + 10)
  
  overlay.tint = overlay:CreateTexture(nil, "OVERLAY")
  overlay.tint:SetAllPoints()
  overlay.tint:SetColorTexture(0.9, 0.1, 0.1, 0.6)
  
  overlay.text = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  overlay.text:SetPoint("CENTER", 0, 0)
  overlay.text:SetText("Hidden")
  overlay.text:SetTextColor(1, 1, 1, 1)
  
  hiddenByBarOverlays[frame] = overlay
  return overlay
end

-- Hide (but KEEP cached) the red "Hidden" overlay on a frame CDM is reshuffling,
-- so a stale overlay doesn't linger on an icon that no longer holds the hidden
-- cooldownID. Does NOT drop the cached overlay (RefreshHiddenCDMFrames /
-- CleanupFrameHidingState nils it later) so GetOrCreateHiddenOverlay can reuse it.
-- Called (guarded) from FrameController's reshuffle hooks. Safe sink (Hide on an
-- ArcUI-created child frame); no Blizzard-frame writes.
local function HideOverlayOnFrame(frame)
  if frame and hiddenByBarOverlays[frame] then
    hiddenByBarOverlays[frame]:Hide()
  end
end
ns.API.HideOverlayOnFrame = HideOverlayOnFrame

-- Helper to find a CDM frame by cooldownID across all viewers,
-- CDMGroups containers (reparented frames), and free icons.
local function FindCDMFrameForCooldownID(targetCdID)
  if not targetCdID then return nil end
  
  -- 1. CDMGroups members (frames reparented into group containers by FrameController)
  if ns.CDMGroups and ns.CDMGroups.groups then
    for _, group in pairs(ns.CDMGroups.groups) do
      if group.members then
        local member = group.members[targetCdID]
        if member and member.frame then
          return member.frame
        end
      end
    end
  end
  
  -- 2. CDMGroups free icons (frames reparented to UIParent by FrameController)
  if ns.CDMGroups and ns.CDMGroups.freeIcons then
    local freeData = ns.CDMGroups.freeIcons[targetCdID]
    if freeData and freeData.frame then
      return freeData.frame
    end
  end
  
  -- 3. Standard CDM viewer children (frames NOT reparented)
  local viewerNames = {"BuffIconCooldownViewer", "BuffBarCooldownViewer",
                       "CooldownIconCooldownViewer", "CooldownBarCooldownViewer"}
  for _, vName in ipairs(viewerNames) do
    local viewer = _G[vName]
    if viewer then
      local children = {viewer:GetChildren()}
      for _, child in ipairs(children) do
        local cdID = child.cooldownID
        if not cdID and child.cooldownInfo then
          cdID = child.cooldownInfo.cooldownID
        end
        if not cdID and child.Icon and child.Icon.cooldownID then
          cdID = child.Icon.cooldownID
        end
        if cdID == targetCdID then
          return child
        end
      end
    end
  end
  
  return nil
end

-- Refresh hidden CDM frames: detect stale entries where CDM recycled a frame,
-- clean them up, and re-scan viewers to find the new frame for that cooldownID.
-- Called before options open/close and from FrameController on SetCooldownID.
local function RefreshHiddenCDMFrames()
  -- Collect stale entries: frame's cdID no longer matches what we intended to hide
  local staleEntries = {}  -- { {frame=, expectedCdID=}, ... }
  for frame, expectedCdID in pairs(hiddenCDMFrames) do
    local frameCdID = GetFrameCooldownID(frame)
    -- Stale if: frame cdID is nil (cleared/released) OR changed to different spell
    if expectedCdID and (not frameCdID or frameCdID ~= expectedCdID) then
      staleEntries[#staleEntries + 1] = { frame = frame, expectedCdID = expectedCdID }
    end
  end
  
  if #staleEntries == 0 then return end
  
  -- Clean up stale entries and re-find correct frames
  for _, entry in ipairs(staleEntries) do
    -- Release the old (wrong) frame
    CleanupFrameHidingState(entry.frame)
    entry.frame:Show()  -- Let CDM show it again
    
    -- Find the new frame for that cooldownID and hide it properly
    -- using ForceHideCDMFrame which installs Show + SetCooldownID hooks
    local newFrame = FindCDMFrameForCooldownID(entry.expectedCdID)
    if newFrame and not hiddenCDMFrames[newFrame] then
      ForceHideCDMFrame(newFrame, entry.expectedCdID)
    end
  end
end

ForceHideCDMFrame = function(frame, expectedCooldownID)
  if not frame then return end
  
  -- Require expectedCooldownID - without it we can't verify the frame is correct
  if not expectedCooldownID then return end
  
  -- Verify frame's current cooldownID matches what we expect
  -- CRITICAL: If frameCdID is nil (frame cleared during CDM reshuffle),
  -- we MUST NOT hide it - the bar update ticker would re-add stale entries.
  local frameCdID = GetFrameCooldownID(frame)
  if not frameCdID then return end  -- Can't confirm match, skip
  if frameCdID ~= expectedCooldownID then
    -- Frame was recycled for a different cooldown - clean up any stale state
    CleanupFrameHidingState(frame)
    return
  end
  
  -- DEDUP: If a DIFFERENT frame is already tracked for this same cooldownID,
  -- clean it up. O(1) via reverse lookup instead of iterating hiddenCDMFrames.
  local existingFrame = hiddenCDMFramesByCD[expectedCooldownID]
  if existingFrame and existingFrame ~= frame then
    CleanupFrameHidingState(existingFrame)
    existingFrame:Show()  -- Let CDM show the now-unrelated frame
  end
  
  hiddenCDMFrames[frame] = expectedCooldownID
  hiddenCDMFramesByCD[expectedCooldownID] = frame
  
  -- ═══════════════════════════════════════════════════════════════════
  -- PROTECTION HOOKS: Prevent CDM from re-showing hidden frames.
  -- Three hooks work together:
  --   Show hook: catches CDM calling Show() directly
  --   SetShown hook: catches CDM calling SetShown(true) which is a
  --     C-level call that does NOT trigger the Show() hook
  --   SetCooldownID hook: catches CDM assigning a hidden cooldownID to
  --     a different frame during layout reshuffle/recycling
  -- Only hook once per frame (flag guards).
  -- ═══════════════════════════════════════════════════════════════════
  if not frame._arcHideByBarShowHooked then
    frame._arcHideByBarShowHooked = true
    hooksecurefunc(frame, "Show", function(self)
      if self._arcHiddenByBar then
        -- Verify cooldownID still matches (frame may have been recycled)
        if self._arcHiddenByBarCdID then
          local currentCdID = GetFrameCooldownID(self)
          if currentCdID and currentCdID ~= self._arcHiddenByBarCdID then
            -- Frame was recycled for a different cooldown — clear stale flag
            self._arcHiddenByBar = nil
            self._arcHiddenByBarCdID = nil
            return  -- Let it show
          end
        end
        self:Hide()
      end
    end)
    
    -- SetShown(true) is a C-level visibility call that bypasses Show().
    -- CDM's UpdateShownState (CooldownViewer.lua:319) uses SetShown(true),
    -- which our Show hook never sees. This closes that gap.
    hooksecurefunc(frame, "SetShown", function(self, shown)
      if shown and self._arcHiddenByBar then
        if self._arcHiddenByBarCdID then
          local currentCdID = GetFrameCooldownID(self)
          if currentCdID and currentCdID ~= self._arcHiddenByBarCdID then
            self._arcHiddenByBar = nil
            self._arcHiddenByBarCdID = nil
            return
          end
        end
        self:Hide()
      end
    end)
  end
  
  if not frame._arcSetCdIDHooked and frame.SetCooldownID then
    frame._arcSetCdIDHooked = true
    hooksecurefunc(frame, "SetCooldownID", function(self, newCdID)
      -- When CDM assigns a cooldownID to this frame, check if any bar
      -- wants that cooldownID hidden. If so, immediately ForceHide.
      -- This catches layout reshuffles that move cooldownIDs between frames.
      if newCdID and cdmHideRequestsByCD[newCdID] then
        -- Defer slightly: CDM hasn't finished OnCooldownIDSet yet.
        -- Our ForceHideCDMFrame needs cooldownID set on the frame,
        -- which it already is at this point (posthook).
        ForceHideCDMFrame(self, newCdID)
      end
    end)
  end
  
  -- If options panel is open, Show with overlay so user can see what's hidden
  -- Don't set _arcHiddenByBar here - the Show hook would re-hide it
  -- HideAllHiddenByBarOverlays will set the flag when options close
  if ns._arcUIOptionsOpen then
    frame._arcHiddenByBar = nil
    frame._arcHiddenByBarCdID = nil
    frame:Show()
    
    -- Create/show overlay
    GetOrCreateHiddenOverlay(frame):Show()
  else
    -- Set shared flags BEFORE Hide - CDMEnhance Show hook verifies these
    frame._arcHiddenByBar = true
    frame._arcHiddenByBarCdID = expectedCooldownID
    frame:Hide()
    -- Hide overlay if it exists
    if hiddenByBarOverlays[frame] then
      hiddenByBarOverlays[frame]:Hide()
    end
  end
end

local function AllowCDMFrameVisible(frame)
  if not frame then return end
  if not hiddenCDMFrames[frame] then return end
  CleanupFrameHidingState(frame)
  -- Only Show if CDM still has valid data on this frame.
  -- During spec change CDM clears frames (cooldownID becomes nil),
  -- showing a cleared frame produces an empty shell (hollow bar).
  local cdID = GetFrameCooldownID(frame)
  if cdID then
    frame:Show()
  end
end

-- Called when options panel closes to re-hide all frames
local function HideAllHiddenByBarOverlays()
  -- Refresh first: fix any stale entries from CDM frame recycling
  RefreshHiddenCDMFrames()
  
  for frame, overlay in pairs(hiddenByBarOverlays) do
    overlay:Hide()
  end
  -- Re-apply Hide to all tracked frames
  for frame, expectedCdID in pairs(hiddenCDMFrames) do
    frame._arcHiddenByBar = true
    frame._arcHiddenByBarCdID = expectedCdID
    frame:Hide()
  end
end

-- Called when options panel opens to show overlays on already-hidden frames
local function ShowAllHiddenByBarOverlays()
  -- Refresh first: fix any stale entries from CDM frame recycling
  RefreshHiddenCDMFrames()
  
  for frame, _ in pairs(hiddenCDMFrames) do
    frame._arcHiddenByBar = nil  -- Clear so Show hook doesn't re-hide
    frame._arcHiddenByBarCdID = nil
    frame:Show()
    -- Create overlay if needed
    GetOrCreateHiddenOverlay(frame):Show()
  end
end

-- Expose for Options.lua and FrameController
ns.API = ns.API or {}
ns.API.ShowHiddenByBarOverlays = ShowAllHiddenByBarOverlays
ns.API.HideHiddenByBarOverlays = HideAllHiddenByBarOverlays
ns.API.RefreshHiddenCDMFrames = RefreshHiddenCDMFrames

-- The cooldownID a bar is currently hiding on this frame (nil if none). Lets
-- FrameController distinguish a same-id refresh (re-assert) from a real
-- reassignment (release) in BOTH options-open and options-closed modes:
-- hiddenCDMFrames is the mode-independent source of truth (the per-frame
-- _arcHiddenByBar flag is nil while the options panel is showing overlays).
local function GetCDMHiddenCooldownID(frame)
  if not frame then return nil end
  return hiddenCDMFrames[frame]
end
ns.API.GetCDMHiddenCooldownID = GetCDMHiddenCooldownID

-- Re-assert the correct hidden state for a single CDM frame that CDM just
-- (re)assigned to a cooldownID a bar is hiding. FrameController calls this from
-- its SetCooldownID hook on a same-id/no-op refresh — CDM's RefreshData re-sets
-- each frame's CURRENT cooldownID every cycle and hooksecurefunc fires even
-- though SetCooldownID's body no-ops, so without re-asserting, the frame
-- force-shows (options closed) or loses its overlay (options open) between bar
-- updates. Routes through ForceHideCDMFrame, which re-applies the right state
-- (hide vs show+overlay) and re-installs the protection hooks. Only acts on
-- frames this addon is actually hiding (guards against hiding arbitrary frames).
local function ReassertCDMHideForFrame(frame, cooldownID)
  if not frame or not cooldownID then return end
  if hiddenCDMFrames[frame] ~= cooldownID then return end
  ForceHideCDMFrame(frame, cooldownID)
end
ns.API.ReassertCDMHideForFrame = ReassertCDMHideForFrame

-- Hide a frame CDM just assigned a cooldownID that a bar has requested hidden,
-- even if we've never hidden THIS frame before. FrameController calls this from
-- its SetCooldownID hook for fresh/untracked frames, so a buff icon CDM creates
-- at login/reload (or a buff reappearing on a new pool frame) is hidden in the
-- same tick CDM binds it — instead of staying visible until the next bar update
-- (which only runs on combat/target/etc., the "hidden only after I right-clicked
-- a mob" symptom). O(1) registry lookup; no-op unless a bar wants this cooldownID.
local function HideCDMFrameIfRequested(frame, cooldownID)
  if not frame or not cooldownID then return end
  if not cdmHideRequestsByCD[cooldownID] then return end
  ForceHideCDMFrame(frame, cooldownID)
end
ns.API.HideCDMFrameIfRequested = HideCDMFrameIfRequested

-- Is this bar shown in the current spec? Mirrors UpdateBarBuffInfo's spec gate so
-- a wrong-spec bar never hides (or keeps hidden) the Blizzard frame.
local function BarShownInCurrentSpec(barConfig)
  local b = barConfig.behavior
  if not b then return true end
  local cur = (ns.Display and ns.Display.GetCachedSpec and ns.Display.GetCachedSpec()) or GetSpecialization() or 0
  if b.showOnSpecs and #b.showOnSpecs > 0 then
    for _, s in ipairs(b.showOnSpecs) do
      if s == cur then return true end
    end
    return false
  elseif b.showOnSpec and b.showOnSpec > 0 then
    return cur == b.showOnSpec
  end
  return true
end

-- Authoritatively reconcile the persistent CDM hide-request registry against
-- current bar config, then hide any buff-viewer frame already showing a requested
-- cooldownID. Runs from ValidateAllBarTracking (login/reload/spec/data-loaded/
-- config change) so the registry is populated the moment we know what to hide —
-- BEFORE any bar update or combat — which (together with FrameController's
-- HideCDMFrameIfRequested on later assignments) makes the icon hidden on load.
-- Independent of whether the tracked aura is currently active.
local function ReassertCDMHideRequests()
  local db = ns.API.GetDB and ns.API.GetDB()
  if not db or not db.bars then return end

  for barNum = 1, 30 do
    local bc = db.bars[barNum]
    local wants = bc and bc.tracking and bc.tracking.enabled
                  and bc.behavior and bc.behavior.hideBuffIcon
                  and BarShownInCurrentSpec(bc)
    if wants then
      -- Prefer the resolved cooldownID (cross-spec alternates), else the configured
      -- primary — exactly what the hide block registers.
      local st = ns.API.GetBarState and ns.API.GetBarState(barNum)
      local cdID = (st and st.cooldownID) or bc.tracking.cooldownID
      if cdID and type(cdID) == "number" and cdID > 0 then
        RegisterCDMHideRequest(barNum, cdID)
      end
    else
      -- Bar no longer wants to hide (disabled / toggled off / wrong spec): drop its
      -- request and re-show the freed frame if nothing else still hides it.
      local freed = UnregisterCDMHideRequest(barNum)
      if freed and not AnyCDMHideRequestForCD(freed, barNum) then
        local f = FindCDMFrameForCooldownID(freed)
        if f then AllowCDMFrameVisible(f) end
      end
    end
  end

  -- Re-show any frame we still have hidden whose cooldownID NO bar requests anymore
  -- (a bar's resolved cooldownID flipped and orphaned the old icon). Without this
  -- the old Blizzard icon would stay stuck hidden until reload/spec change. Snapshot
  -- first — AllowCDMFrameVisible mutates hiddenCDMFrames via CleanupFrameHidingState.
  local orphans
  for frame, cdID in pairs(hiddenCDMFrames) do
    if not (cdID and cdmHideRequestsByCD[cdID]) then
      orphans = orphans or {}
      orphans[#orphans + 1] = frame
    end
  end
  if orphans then
    for _, frame in ipairs(orphans) do
      AllowCDMFrameVisible(frame)
    end
  end

  -- Hide the frame currently bound to each requested cooldownID, wherever it lives:
  -- a standard CDM viewer, a CDMGroups container, OR a reparented FREE ICON.
  -- CRITICAL: use FindCDMFrameForCooldownID (which checks group members + free
  -- icons + viewers), NOT a BuffBar/BuffIconCooldownViewer children scan. Free and
  -- grouped icons are reparented OUT of those viewers, so a children scan misses
  -- them — which is exactly why a free-icon buff stayed visible on reload until
  -- combat re-bound it (RefreshData -> SetCooldownID -> HideCDMFrameIfRequested).
  -- Once ForceHideCDMFrame runs, its Show/SetShown hooks keep it hidden against
  -- any later show (including Core's own restore step and CDM refreshes).
  for cdID in pairs(cdmHideRequestsByCD) do
    local f = FindCDMFrameForCooldownID(cdID)
    if f and not hiddenCDMFrames[f] then
      ForceHideCDMFrame(f, cdID)
    end
  end
end
ns.API.ReassertCDMHideRequests = ReassertCDMHideRequests

-- Release all hidden CDM frame tracking for spec change.
-- CDM will manage its own frame visibility during the transition;
-- we just clean our bookkeeping without calling frame:Show() on
-- frames that may already be cleared/recycled by CDM (prevents
-- empty shell bars from becoming visible).
local function ClearAllHiddenCDMFramesForSpecChange()
  for frame in pairs(hiddenCDMFrames) do
    frame._arcHiddenByBar = nil
    frame._arcHiddenByBarCdID = nil
    if hiddenByBarOverlays[frame] then
      hiddenByBarOverlays[frame]:Hide()
      hiddenByBarOverlays[frame] = nil
    end
  end
  wipe(hiddenCDMFrames)
  wipe(hiddenCDMFramesByCD)
  wipe(cdmHideRequestsByCD)
end
-- Expose internal tables for ArcUI_Debugger OverlayInspector (accessed via ArcUI_NS)
ns.API._hiddenCDMFrames = hiddenCDMFrames
ns.API._hiddenByBarOverlays = hiddenByBarOverlays
ns.API._GetFrameCooldownID = GetFrameCooldownID
ns.API._FindCDMFrameForCooldownID = FindCDMFrameForCooldownID

-- Now define ClearBarState (needs AllowCDMFrameVisible)
ClearBarState = function(barNumber)
  local state = barStates[barNumber]
  if state then
    -- Unregister this bar's CDM hide request
    local wasHidingCD = UnregisterCDMHideRequest(barNumber)
    
    -- Only restore CDM frame visibility if no other bar is still hiding that cooldownID
    if state.cachedFrame then
      local cdID = wasHidingCD or GetFrameCooldownID(state.cachedFrame)
      if not AnyCDMHideRequestForCD(cdID, barNumber) then
        AllowCDMFrameVisible(state.cachedFrame)
      end
    end
    if state.cachedBarFrame then
      local cdID = wasHidingCD or GetFrameCooldownID(state.cachedBarFrame)
      if not AnyCDMHideRequestForCD(cdID, barNumber) then
        AllowCDMFrameVisible(state.cachedBarFrame)
      end
    end
    -- Drop this bar from the auraInstanceID→bar reverse map.
    SetBarAuraMapping(barNumber, state, nil, nil)
  end
  barStates[barNumber] = nil
end

local function IsOptionsOpen()
  return ns.optionsPanelOpen
end


-- ===================================================================
-- DURATION BAR TICKER
-- ===================================================================
ns.API.StartDurationBarTicker = function() end  -- no-op, kept for any external callers
ns.API.StopDurationBarTicker = function() end


-- ===================================================================
-- DATABASE ACCESS
-- ===================================================================
function ns.API.GetDB()
  return ns.db and ns.db.char
end

function ns.API.GetGlobalDB()
  return ns.db and ns.db.global
end

-- Returns the DB table that owns the ACTIVE castbar config (.castbars): the account-wide
-- global table when shared-castbar mode is on, otherwise this character's own. Single
-- chokepoint so the castbar runtime, options, import/export and skin auto-switch all
-- resolve to the same store.
function ns.API.GetCastbarStore()
  if ns.db and ns.db.global and ns.db.global.castbarShared then
    return ns.db.global
  end
  return ns.db and ns.db.char
end

-- ===================================================================
-- HELPER FUNCTIONS
-- ===================================================================
local function GetAllBuffFrames()
  local viewer = _G["BuffIconCooldownViewer"]
  if not viewer then return {}, "BuffIconCooldownViewer not found" end
  local allFrames = {}
  local seenFrames = {}  -- Track frames we've already added
  local seenCdIDs = {}   -- Track cooldownIDs we've found
  
  -- 1. Scan direct children of BuffIconCooldownViewer
  local children = {viewer:GetChildren()}
  for _, child in ipairs(children) do
    local cdID = child.cooldownID or (child.cooldownInfo and child.cooldownInfo.cooldownID)
    -- Handle both numeric CDM IDs and string Arc Aura IDs
    local isValidCdID = cdID and ((type(cdID) == "number" and cdID > 0) or type(cdID) == "string")
    if isValidCdID then
      table.insert(allFrames, child)
      seenFrames[child] = true
      seenCdIDs[cdID] = true
    end
  end
  
  -- 2. Check _customIcons
  if viewer._customIcons then
    for _, icon in pairs(viewer._customIcons) do
      if not seenFrames[icon] then
        local cdID = icon.cooldownID or (icon.cooldownInfo and icon.cooldownInfo.cooldownID)
        -- Handle both numeric CDM IDs and string Arc Aura IDs
        local isValidCdID = cdID and ((type(cdID) == "number" and cdID > 0) or type(cdID) == "string")
        if isValidCdID then
          table.insert(allFrames, icon)
          seenFrames[icon] = true
          seenCdIDs[cdID] = true
        end
      end
    end
  end
  
  -- 3. Include detached frames (reparented to UIParent for free positioning)
  if ns.CDMEnhance and ns.CDMEnhance.GetDetachedFrames then
    local detached = ns.CDMEnhance.GetDetachedFrames()
    for cdID, data in pairs(detached) do
      if data.viewerType == "aura" and data.frame and not seenFrames[data.frame] then
        if data.viewerName == "BuffIconCooldownViewer" or data.frame._arcOriginalParent == viewer then
          if not seenCdIDs[cdID] then
            table.insert(allFrames, data.frame)
            seenFrames[data.frame] = true
            seenCdIDs[cdID] = true
          end
        end
      end
    end
  end
  
  -- 4. FALLBACK: Search enhancedFrames for any aura frames we might have missed
  if ns.CDMEnhance then
    local enhancedFrames = ns.CDMEnhance.GetEnhancedFrames and ns.CDMEnhance.GetEnhancedFrames()
    if enhancedFrames then
      for cdID, data in pairs(enhancedFrames) do
        if data.viewerType == "aura" and data.frame and not seenFrames[data.frame] then
          -- CRITICAL: Use cdID (the key) not data.frame.cooldownID
          -- frame.cooldownID might be nil but the key is always valid
          -- Handle both numeric CDM IDs and string Arc Aura IDs
          local isValidCdID = cdID and ((type(cdID) == "number" and cdID > 0) or type(cdID) == "string")
          if isValidCdID and not seenCdIDs[cdID] then
            table.insert(allFrames, data.frame)
            seenFrames[data.frame] = true
            seenCdIDs[cdID] = true
          end
        end
      end
    end
    
    -- 5. Also check freePositionFrames - CRITICAL: use cdID key, not frame.cooldownID
    local freeFrames = ns.CDMEnhance.GetFreePositionFrames and ns.CDMEnhance.GetFreePositionFrames()
    if freeFrames then
      for cdID, frame in pairs(freeFrames) do
        if frame and not seenFrames[frame] then
          -- Verify it's an aura frame (originally from BuffIconCooldownViewer)
          local origParent = frame._arcOriginalParent
          if origParent == viewer or (origParent and origParent:GetName() == "BuffIconCooldownViewer") then
            -- Use cdID (our tracking key), not frame.cooldownID
            -- Handle both numeric CDM IDs and string Arc Aura IDs
            local isValidCdID = cdID and ((type(cdID) == "number" and cdID > 0) or type(cdID) == "string")
            if isValidCdID and not seenCdIDs[cdID] then
              table.insert(allFrames, frame)
              seenFrames[frame] = true
              seenCdIDs[cdID] = true
            end
          end
        end
      end
    end
  end
  
  return allFrames, nil
end

local function GetAllBarFrames()
  local viewer = _G["BuffBarCooldownViewer"]
  if not viewer then return {}, "BuffBarCooldownViewer not found" end
  local allFrames = {}
  local seenFrames = {}
  local seenCdIDs = {}
  
  -- 1. Scan direct children of BuffBarCooldownViewer
  local children = {viewer:GetChildren()}
  for _, child in ipairs(children) do
    local cdID = child.cooldownID
    if not cdID and child.cooldownInfo then
      cdID = child.cooldownInfo.cooldownID
    end
    if not cdID and child.Icon and child.Icon.cooldownID then
      cdID = child.Icon.cooldownID
    end
    -- Handle both numeric CDM IDs and string Arc Aura IDs
    local isValidCdID = cdID and ((type(cdID) == "number" and cdID > 0) or type(cdID) == "string")
    if isValidCdID then
      table.insert(allFrames, child)
      seenFrames[child] = true
      seenCdIDs[cdID] = true
    end
  end
  
  -- 2. Include detached frames (reparented to UIParent for free positioning)
  if ns.CDMEnhance and ns.CDMEnhance.GetDetachedFrames then
    local detached = ns.CDMEnhance.GetDetachedFrames()
    for cdID, data in pairs(detached) do
      if data.frame and not seenFrames[data.frame] then
        -- Check if this was originally from BuffBarCooldownViewer
        if data.viewerName == "BuffBarCooldownViewer" or data.frame._arcOriginalParent == viewer then
          table.insert(allFrames, data.frame)
          seenFrames[data.frame] = true
          seenCdIDs[cdID] = true
        end
      end
    end
  end
  
  -- 3. FALLBACK: Search enhancedFrames for any bar frames we might have missed
  if ns.CDMEnhance then
    local enhancedFrames = ns.CDMEnhance.GetEnhancedFrames and ns.CDMEnhance.GetEnhancedFrames()
    if enhancedFrames then
      for cdID, data in pairs(enhancedFrames) do
        if data.frame and not seenFrames[data.frame] then
          local origParent = data.frame._arcOriginalParent or data.frame:GetParent()
          if origParent == viewer or (origParent and origParent:GetName() == "BuffBarCooldownViewer") then
            -- CRITICAL: Use cdID (the key) not frame.cooldownID
            -- Handle both numeric CDM IDs and string Arc Aura IDs
            local isValidCdID = cdID and ((type(cdID) == "number" and cdID > 0) or type(cdID) == "string")
            if isValidCdID and not seenCdIDs[cdID] then
              table.insert(allFrames, data.frame)
              seenFrames[data.frame] = true
              seenCdIDs[cdID] = true
            end
          end
        end
      end
    end
  end
  
  return allFrames, nil
end


-- ===================================================================
-- CACHED cooldownID → FRAME INDEX  (v3.7.2 aura-engine rework)
-- ===================================================================
-- Replaces the per-call GetChildren scans in FindBuffFrameByCooldownID /
-- FindBarFrameByCooldownID and the O(bars × frames) rescans inside
-- ValidateAllBarTracking with O(1) lookups. Built ONCE per invalidation from a
-- single pass over the buff/bar frame collectors (+ grouped frames), and
-- rebuilt lazily only when marked dirty by an actual frame change:
--   • FrameController SetCooldownID/ClearCooldownID rebinds
--   • PLAYER_SPECIALIZATION_CHANGED
--   • COOLDOWN_VIEWER_DATA_LOADED
--   • ScanAllCDMIcons completion
-- Frame-recycle safe: every consumer re-verifies frame.cooldownID == expected
-- (non-secret) before trusting an indexed frame, since CDM pools frames.
local cdIndex = {}          -- [cooldownID] = { icon = frame, bar = frame }
local cdIndexDirty = true

local function RebuildCDMIndex()
  wipe(cdIndex)
  -- Icon-side frames (BuffIconCooldownViewer + detached/enhanced/free)
  local iconFrames = GetAllBuffFrames()
  if iconFrames then
    for _, frame in ipairs(iconFrames) do
      local cdID = GetFrameCooldownID(frame)
      if cdID then
        local e = cdIndex[cdID]; if not e then e = {}; cdIndex[cdID] = e end
        e.icon = frame
      end
    end
  end
  -- Bar-side frames (BuffBarCooldownViewer + detached/enhanced)
  local barFrames = GetAllBarFrames()
  if barFrames then
    for _, frame in ipairs(barFrames) do
      local cdID = GetFrameCooldownID(frame)
      if cdID then
        local e = cdIndex[cdID]; if not e then e = {}; cdIndex[cdID] = e end
        e.bar = frame
      end
    end
  end
  -- Grouped frames (reparented into CDMGroups containers); may be either kind.
  if ns.CDMGroups and ns.CDMGroups.GetAllGroupedFrames then
    local grouped = ns.CDMGroups.GetAllGroupedFrames()
    if grouped then
      for cdID, data in pairs(grouped) do
        if data.frame then
          local e = cdIndex[cdID]; if not e then e = {}; cdIndex[cdID] = e end
          if data.viewerType == "bar" then
            if not e.bar then e.bar = data.frame end
          else
            if not e.icon then e.icon = data.frame end
          end
        end
      end
    end
  end
  cdIndexDirty = false
end

local function EnsureCDMIndex()
  if cdIndexDirty then RebuildCDMIndex() end
end

local function InvalidateCDMIndex()
  cdIndexDirty = true
end
ns.API.InvalidateCDMIndex = InvalidateCDMIndex

-- Self-heal helpers: when a fallback scan finds a frame the index missed
-- (timing), record it so the next lookup is O(1) without a full rebuild.
local function StoreBarIndex(cdID, frame)
  if frame then local e = cdIndex[cdID]; if not e then e = {}; cdIndex[cdID] = e end; e.bar = frame end
  return frame
end
local function StoreIconIndex(cdID, frame)
  if frame then local e = cdIndex[cdID]; if not e then e = {}; cdIndex[cdID] = e end; e.icon = frame end
  return frame
end


local function FindBarFrameByCooldownID(cooldownID)
  if not cooldownID then return nil end
  -- O(1) fast path via the cached index (recycle-verified).
  EnsureCDMIndex()
  local ent = cdIndex[cooldownID]
  if ent and ent.bar and GetFrameCooldownID(ent.bar) == cooldownID then
    return ent.bar
  end
  local frames, err = GetAllBarFrames()
  if err then return nil end
  for _, frame in ipairs(frames) do
    -- Try multiple sources for cooldownID
    local frameCdID = frame.cooldownID
    if not frameCdID and frame.cooldownInfo then
      frameCdID = frame.cooldownInfo.cooldownID
    end
    if not frameCdID and frame.Icon and frame.Icon.cooldownID then
      frameCdID = frame.Icon.cooldownID
    end
    if frameCdID == cooldownID then return StoreBarIndex(cooldownID, frame) end
  end

  -- FALLBACK: Direct scan of BuffBarCooldownViewer
  local viewer = _G["BuffBarCooldownViewer"]
  if viewer then
    local children = {viewer:GetChildren()}
    for _, child in ipairs(children) do
      local frameCdID = child.cooldownID
      if not frameCdID and child.cooldownInfo then
        frameCdID = child.cooldownInfo.cooldownID
      end
      if not frameCdID and child.Icon and child.Icon.cooldownID then
        frameCdID = child.Icon.cooldownID
      end
      if frameCdID == cooldownID then return StoreBarIndex(cooldownID, child) end
    end
  end

  return nil
end

local function FindBuffFrameByCooldownID(cooldownID)
  if not cooldownID then return nil end

  -- O(1) fast path via the cached index (recycle-verified).
  EnsureCDMIndex()
  local ent = cdIndex[cooldownID]
  if ent and ent.icon and GetFrameCooldownID(ent.icon) == cooldownID then
    return ent.icon
  end

  -- SIMPLE: Use CDMEnhance.FindFrameByCooldownID if available
  if ns.CDMEnhance and ns.CDMEnhance.FindFrameByCooldownID then
    local frame, vType, viewerName = ns.CDMEnhance.FindFrameByCooldownID(cooldownID, "aura")
    if frame and frame.cooldownID == cooldownID then
      return StoreIconIndex(cooldownID, frame)
    end
  end

  -- Scan BuffIconCooldownViewer children
  local viewer = _G["BuffIconCooldownViewer"]
  if viewer then
    local children = {viewer:GetChildren()}
    for _, child in ipairs(children) do
      local frameCdID = child.cooldownID
      if not frameCdID and child.cooldownInfo then
        frameCdID = child.cooldownInfo.cooldownID
      end
      if frameCdID == cooldownID then return StoreIconIndex(cooldownID, child) end
    end
  end

  -- Check enhanced frames (includes detached ones)
  if ns.CDMEnhance then
    local enhancedFrames = ns.CDMEnhance.GetEnhancedFrames and ns.CDMEnhance.GetEnhancedFrames()
    if enhancedFrames then
      -- Direct key lookup - verify frame's actual cooldownID matches (frame may be recycled)
      local data = enhancedFrames[cooldownID]
      if data and data.frame then
        local frameCdID = data.frame.cooldownID
        if not frameCdID and data.frame.cooldownInfo then
          frameCdID = data.frame.cooldownInfo.cooldownID
        end
        if frameCdID == cooldownID then
          return StoreIconIndex(cooldownID, data.frame)
        end
      end

      -- Fallback: Scan all frames checking frame.cooldownID property
      for cdID, frameData in pairs(enhancedFrames) do
        if frameData.frame and frameData.frame.cooldownID == cooldownID then
          return StoreIconIndex(cooldownID, frameData.frame)
        end
      end
    end
  end

  -- Scan CDMGroups containers (frames reparented for grouping)
  if ns.CDMGroups and ns.CDMGroups.GetAllGroupedFrames then
    local groupedFrames = ns.CDMGroups.GetAllGroupedFrames()
    if groupedFrames then
      local data = groupedFrames[cooldownID]
      if data and data.frame then
        local frameCdID = data.frame.cooldownID
        if not frameCdID and data.frame.cooldownInfo then
          frameCdID = data.frame.cooldownInfo.cooldownID
        end
        if frameCdID == cooldownID then
          return StoreIconIndex(cooldownID, data.frame)
        end
      end
    end
  end

  return nil
end


-- 12.1 (PTR4): the instance-id C_UnitAuras APIs (GetAuraDataByAuraInstanceID / GetAuraDuration /
-- GetAuraApplicationDisplayCount / GetUnitAuraInstanceIDs) all THROW "Auras cannot be accessed
-- when secret while tainted" if the UNIT carries ANY secret aura -- EVEN when reading a NON-secret
-- aura on it. Secrecy is PER-AURA (Blizzard whitelists some, e.g. Maelstrom Weapon), but the block
-- is UNIT-WIDE: reading whitelisted MSW still throws while the same unit also has a secret aura
-- (e.g. Crash Lightning). And NO C_UnitAuras call can detect the state (they all throw). Two
-- non-throwing signals, OR'd:
--   (1) SCAN the CDM aura frames for the unit: any active frame whose auraInstanceID is SECRET
--       means the unit has a secret aura. Pure field reads -> never throw; immediate (works at
--       login before any UNIT_AURA). Catches CDM-tracked secret auras and self-clears when gone.
--   (2) STICKY flag set from a secret UNIT_AURA payload -> catches secret auras with no CDM frame
--       (and target auras). Set-true-only (a non-secret partial update must NOT clear it); wiped
--       on combat-end / zone via ns.API.ClearAuraSecrecyCache.
-- Default false -> inert on live (no secret auras -> both signals false -> reads pass through).
local AURA_VIEWERS_FOR_SECRECY = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }
local aurasSecretSticky = {}                       -- [unit] = true (sticky within combat/zone)
local _scanSecretCache, _scanSecretStamp = {}, {}  -- [unit] -> bool, GetTime()
local _rawReadCount = 0                             -- DIAG: how many times a raw aura read actually executed
local function ScanUnitHasSecretAura(unit)
  for _, vname in ipairs(AURA_VIEWERS_FOR_SECRECY) do
    local viewer = _G[vname]
    local pool = viewer and viewer.itemFramePool
    if pool and pool.EnumerateActive then
      for f in pool:EnumerateActive() do
        local aiid = f.auraInstanceID
        if aiid ~= nil and (f.auraDataUnit or "player") == unit
           and issecretvalue and issecretvalue(aiid) then
          return true
        end
      end
    end
  end
  return false
end
-- The engine puts aura access into "secret mode" whenever the unit is restricted -- which is true
-- even at login/setup with NO secret aura currently active (e.g. the six RestrictionsForced CVars,
-- or a real M+/instance/encounter/PvP context). In that mode the instance-id APIs throw regardless
-- of the specific aura. The forced-test CVars are readable (non-secret) so we check them directly;
-- this catches the login-before-first-UNIT_AURA window the scan/sticky can't. (Real restrictions
-- don't set these CVars -> covered by the scan + sticky once auras/UNIT_AURA arrive.)
local RESTRICTION_CVARS = {
  "addonCombatRestrictionsForced", "addonChallengeModeRestrictionsForced",
  "addonEncounterRestrictionsForced", "addonMapRestrictionsForced", "addonPvPMatchRestrictionsForced",
}
local function ForcedRestriction()
  local get = C_CVar and C_CVar.GetCVar
  if not get then return false end
  for i = 1, #RESTRICTION_CVARS do
    if get(RESTRICTION_CVARS[i]) == "1" then return true end
  end
  return false
end
-- 120100 = 12.1. STOP-GAP: no fully-reliable non-throwing per-call secrecy signal has held up -- a
-- SYNCHRONOUS action-button read (UseAction -> UpdateGroupVisibility -> RefreshDisplay) beats the
-- scan/sticky/UNIT_AURA before any signal materializes -- so on 12.1 conservatively treat auras as
-- ALWAYS secret: every instance-id aura read is skipped -> zero crashes. Value-derived aura features
-- are off on 12.1 (they cannot work under secrecy anyway) until the sanctioned AuraContainer rework
-- lands. Inert on 12.0.x.
-- HISTORY: this was previously OR'd with (Enum.ForbiddenAspect ~= nil) as a "version-proof" 12.1
-- marker, on the belief that the enum was 12.1-only. It was NOT -- Blizzard seeded it on live 12.0.7
-- (present on 12.0.7.68453, absent from the earlier 68275 UI-source dump that was checked), so it
-- flagged live as 12.1 and blanked every stack/duration display. Interface version is the honest gate.
-- 12.1 (Midnight) = interface 120100. Detect strictly by interface version.
-- Do NOT also test Enum.ForbiddenAspect: that enum was seeded on LIVE 12.0.7 as
-- 12.1 groundwork, so testing for it flagged live clients as 12.1 -> AurasSecret
-- returned true for every unit -> every stack/duration secret-gate blanked out on
-- live (icons showed, stacks/counts did not). Interface version is the reliable gate.
local IS_121 = (tonumber((select(4, GetBuildInfo()))) or 0) >= 120100
-- On-demand diagnostic (/arcsec) + one-shot on first call: prints the raw secrecy signals so
-- detection can be checked against ground truth instead of guessed.
local function DumpAuraSecrecy()
  local g = C_CVar and C_CVar.GetCVar
  local function cv(n) return (g and tostring(g(n))) or "?" end
  print(("|cffff8800[ArcSecDbg BUILD=trip4]|r iface=%s IS_121=%s ForbiddenAspect=%s rawReads=%d | forcedCVar=%s (combat=%s mplus=%s map=%s enc=%s pvp=%s) | sticky.player=%s scan.player=%s"):format(
    tostring(tonumber((select(4, GetBuildInfo())))), tostring(IS_121),
    tostring(Enum and Enum.ForbiddenAspect ~= nil), _rawReadCount, tostring(ForcedRestriction()),
    cv("addonCombatRestrictionsForced"), cv("addonChallengeModeRestrictionsForced"), cv("addonMapRestrictionsForced"),
    cv("addonEncounterRestrictionsForced"), cv("addonPvPMatchRestrictionsForced"),
    tostring(aurasSecretSticky.player), tostring(ScanUnitHasSecretAura("player"))))
end
local function AurasSecret(unit)
  unit = unit or "player"
  -- The ONLY environment where the C_UnitAuras aura APIs actually THROW is 12.1 (they
  -- blanket-throw "cannot be accessed when secret while tainted"). On live 12.0.x those same
  -- calls return secret-SAFE values, and every AurasSecret gate feeds the result only to a safe
  -- sink (SetText / SetTimerDuration / SetAlpha), never a compare -- so on live they must run and
  -- DISPLAY (a secret stack/duration is still showable). Gating on live-secrecy (the old
  -- sticky/scan/forced paths) wrongly blanked displayable stacks/durations in M+ -- the "lost
  -- functionality on live" regression. So the gate is 12.1-only. The sticky/scan/forced signals
  -- are kept (populated by NoteUnitAuraSecrecy / used by the /arcsec dump) for diagnostics only.
  return IS_121
end
local function NoteUnitAuraSecrecy(unit, updateInfo)
  -- Set-true-only: a non-secret partial update (e.g. an MSW stack tick) must not clear a unit that
  -- still has a secret aura. The sticky is cleared on combat-end/zone instead.
  if unit and updateInfo and issecretvalue and issecretvalue(updateInfo.isFullUpdate) then
    aurasSecretSticky[unit] = true
  end
end
ns.API = ns.API or {}
ns.API.AurasSecret = AurasSecret
ns.API.IS_121 = IS_121   -- true on a 12.1 client (Midnight); used to disable secret-broken options
ns.API.NoteUnitAuraSecrecy = NoteUnitAuraSecrecy
ns.API.DumpAuraSecrecy = DumpAuraSecrecy
ns.API.ClearAuraSecrecyCache = function() wipe(aurasSecretSticky); wipe(_scanSecretCache); wipe(_scanSecretStamp) end
SLASH_ARCSEC1 = "/arcsec"
SlashCmdList["ARCSEC"] = function() DumpAuraSecrecy() end

-- Secret-safe wrappers: skip the read entirely when the unit's auras are secret (the API would
-- throw). All C_UnitAuras.GetAuraDataByAuraInstanceID / GetAuraDurationRemaining CALL sites in
-- this file route through these (existence-checks untouched).
local _C_GetAuraData   = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
local _C_GetAuraDurRem  = C_UnitAuras and C_UnitAuras.GetAuraDurationRemaining
local function SafeGetAuraData(unit, aiid)
  if aiid == nil or AurasSecret(unit) then return nil end
  _rawReadCount = _rawReadCount + 1
  if IS_121 and _rawReadCount <= 3 then print(("|cffff0000[ArcSec TRIPWIRE]|r SafeGetAuraData raw read #%d on 12.1 unit=%s | %s"):format(_rawReadCount, tostring(unit), tostring(debugstack(2, 3, 0)))) end
  return _C_GetAuraData and _C_GetAuraData(unit, aiid)
end
local function SafeGetAuraDurationRemaining(unit, aiid)
  if aiid == nil or AurasSecret(unit) then return nil end
  _rawReadCount = _rawReadCount + 1
  if IS_121 and _rawReadCount <= 3 then print(("|cffff0000[ArcSec TRIPWIRE]|r SafeGetAuraDurationRemaining raw read #%d on 12.1 unit=%s | %s"):format(_rawReadCount, tostring(unit), tostring(debugstack(2, 3, 0)))) end
  return _C_GetAuraDurRem and _C_GetAuraDurRem(unit, aiid)
end

-- 12.1 STACK-BAR SWITCH-OVER. When the unit's auras are secret, SafeGetAuraData returns nil
-- (the C_UnitAuras read would throw). The CDM frame still holds a NON-secret auraDataCached
-- table for the aura it is CURRENTLY showing: its .applications is a SECRET number that is
-- safe to feed StatusBar:SetValue, and .icon a secret safe for SetTexture. Returning it lets
-- stack bars keep working (with a user-set max) on 12.1. This is the SAME kind of secret the
-- Core->Display pipeline already carries on live in M+ (applications is SecretWhenUnitAura-
-- Restricted there too), so nothing downstream needs to change -- only the source.
-- ONLY valid at call sites reading the frame's OWN current aura (aiid == frame.auraInstanceID);
-- auraDataCached reflects the frame's shown aura, not an arbitrary cached/cross-spell aiid.
-- Live (IS_121 false): the cached branch is dead code -> behaviour identical to SafeGetAuraData.
local function SafeGetFrameAuraData(frame, unit, aiid)
  local d = SafeGetAuraData(unit, aiid)
  if d then return d end
  if IS_121 and frame and frame.auraDataCached ~= nil then return frame.auraDataCached end
  return nil
end

local function GetBuffStacks(frame, unit)
  if not frame or not HasAuraInstanceID(frame.auraInstanceID) then return 0 end
  -- 12.1: GetAuraDataByAuraInstanceID Lua-errors when auras are secret (a secret id is that
  -- signal). HasAuraInstanceID returns TRUE for secret, so this extra guard is required. Inert on live.
  if issecretvalue and issecretvalue(frame.auraInstanceID) then return 0 end
  unit = unit or "player"
  local auraData = SafeGetAuraData(unit, frame.auraInstanceID)
  if not auraData then return 0 end
  return auraData.applications or 0
end

-- Auto-detect which unit has the aura and return data + unit
-- Tries player first (buffs), then target (debuffs)
local function GetAuraDataAutoUnit(auraInstanceID)
  if not HasAuraInstanceID(auraInstanceID) then return nil, nil end
  -- 12.1: GetAuraDataByAuraInstanceID Lua-errors when auras are secret; a secret id is that
  -- signal (HasAuraInstanceID returns TRUE for secret). Inert on live.
  if issecretvalue and issecretvalue(auraInstanceID) then return nil, nil end

  -- Try player first (most common for buffs)
  local auraData = SafeGetAuraData("player", auraInstanceID)
  if auraData then return auraData, "player" end
  
  -- Try target (for debuffs)
  auraData = SafeGetAuraData("target", auraInstanceID)
  if auraData then return auraData, "target" end
  
  return nil, nil
end

-- ===================================================================
-- API: SCAN AND VALIDATE
-- ===================================================================
function ns.API.ScanAvailableBuffs()
  if InCombatLockdown() then return nil, "Cannot scan in combat" end
  
  local frames, err = GetAllBuffFrames()
  if err then return nil, err end
  
  local availableBuffs = {}
  local seenNames = {}
  local validCooldownIDs = {}
  
  for slotNum, frame in ipairs(frames) do
    -- Try multiple sources for cooldownID
    local cdID = frame and frame.cooldownID
    if not cdID and frame and frame.cooldownInfo then
      cdID = frame.cooldownInfo.cooldownID
    end
    
    if cdID then
      -- Get spell info from API (same approach as ScanAllCDMIcons)
      local spellID, spellName, iconTextureID
      local info = type(cdID) == "number" and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
      
      if info then
        local baseSpellID = info.spellID or 0
        local overrideSpellID = info.overrideSpellID
        local linkedSpellIDs = info.linkedSpellIDs
        local firstLinkedSpellID = linkedSpellIDs and linkedSpellIDs[1]
        
        -- Priority: first linkedSpellID > overrideSpellID > baseSpellID
        local displaySpellID = firstLinkedSpellID or overrideSpellID or baseSpellID
        
        spellID = displaySpellID or baseSpellID
        spellName = displaySpellID and C_Spell.GetSpellName(displaySpellID)
        iconTextureID = displaySpellID and C_Spell.GetSpellTexture(displaySpellID)
        
        -- Fallbacks
        if not spellName and overrideSpellID then
          spellName = C_Spell.GetSpellName(overrideSpellID)
          iconTextureID = iconTextureID or C_Spell.GetSpellTexture(overrideSpellID)
        end
        if not spellName and baseSpellID > 0 then
          spellName = C_Spell.GetSpellName(baseSpellID)
          iconTextureID = iconTextureID or C_Spell.GetSpellTexture(baseSpellID)
        end
      end
      
      -- Fallback to frame.cooldownInfo if API didn't work
      if not spellName and frame.cooldownInfo then
        spellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
        if spellID and spellID > 0 then
          spellName = C_Spell.GetSpellName(spellID)
          iconTextureID = C_Spell.GetSpellTexture(spellID)
        end
      end
      
      if spellName then
        validCooldownIDs[cdID] = true
        if not seenNames[spellName] then
          seenNames[spellName] = true
          table.insert(availableBuffs, {
            slotNumber = slotNum,
            buffName = spellName,
            spellID = spellID,
            iconTextureID = iconTextureID or 134400,
            cooldownID = cdID,
            maxStacks = 10,
            isActive = HasAuraInstanceID(frame.auraInstanceID)
          })
        end
      end
    end
  end
  
  ns.API.ValidateAllBarTracking(validCooldownIDs)
  return availableBuffs
end

function ns.API.ValidateAllBarTracking(validCooldownIDs, debugMode)
  -- Build comprehensive list of valid cooldownIDs from ALL sources
  if not validCooldownIDs then
    validCooldownIDs = {}
  end
  
  local debugPrint = debugMode and print or function() end
  
  debugPrint("|cff00CCFF[ValidateAllBarTracking]|r Starting validation...")
  
  -- Build validCooldownIDs from the cached cooldownID→frame index in a single
  -- pass (was five separate full GetChildren scans). "icon"/"bar"/"both" reflect
  -- which side(s) currently have a live frame; any caller-supplied entries are
  -- upgraded to "both" the same way the old per-step merge did. The index is
  -- sourced from the same frame collectors (+ grouped frames) the old steps
  -- used, so coverage is unchanged — it's just computed once and cached.
  -- ValidateAllBarTracking is the authoritative re-bind entry point (config
  -- change / spec / import / login), so rebuild the index fresh here rather
  -- than trust a possibly-stale cache after CDM reshuffled its frames.
  RebuildCDMIndex()
  for cdID, e in pairs(cdIndex) do
    local kind = (e.icon and e.bar) and "both" or (e.bar and "bar") or "icon"
    local prev = validCooldownIDs[cdID]
    if prev == "icon" and kind ~= "icon" then
      kind = "both"
    elseif prev == "bar" and kind ~= "bar" then
      kind = "both"
    end
    validCooldownIDs[cdID] = kind
  end

  -- Debug: show total validCooldownIDs
  local totalValid = 0
  for _ in pairs(validCooldownIDs) do totalValid = totalValid + 1 end
  debugPrint(string.format("  Total validCooldownIDs: %d", totalValid))
  
  -- Now validate each bar's tracking
  local db = ns.API.GetDB()
  if db and db.bars then
    for barNum = 1, 30 do
      local barConfig = db.bars[barNum]
      if barConfig and barConfig.tracking.enabled then
        local state = GetBarState(barNum)
        local configSourceType = barConfig.tracking.sourceType or "icon"
        local trackType = barConfig.tracking.trackType
        
        -- Restore visibility of old cached frames before clearing them
          -- (in case hideBuffIcon was enabled and frames were hidden)
          if state.cachedFrame then AllowCDMFrameVisible(state.cachedFrame) end
          if state.cachedBarFrame then AllowCDMFrameVisible(state.cachedBarFrame) end
          
          state.cachedFrame = nil
          state.cachedBarFrame = nil
          
          -- Use cross-spec resolution: tries primary → alternates → auto-discover
          local activeCooldownID, sourceType = ns.API.GetActiveCooldownIDForBar(barNum, validCooldownIDs)
          debugPrint(string.format("  Bar %d: GetActiveCooldownIDForBar returned cdID=%s, source=%s", 
            barNum, tostring(activeCooldownID), tostring(sourceType)))
          
          if activeCooldownID then
            state.cooldownID = activeCooldownID
            local viewerSourceType = validCooldownIDs[activeCooldownID]
            debugPrint(string.format("    viewerSourceType=%s, configSourceType=%s", 
              tostring(viewerSourceType), tostring(configSourceType)))
            
            if viewerSourceType then
              if configSourceType == "bar" then
                if viewerSourceType == "bar" or viewerSourceType == "both" then
                  state.cachedBarFrame = FindBarFrameByCooldownID(activeCooldownID)
                  state.cachedFrame = FindBuffFrameByCooldownID(activeCooldownID)
                  -- Verify the cached frames actually have the right cooldownID
                  -- Check both frame.cooldownID and frame.cooldownInfo.cooldownID
                  local barValid = false
                  if state.cachedBarFrame then
                    local barCdID = state.cachedBarFrame.cooldownID or (state.cachedBarFrame.Icon and state.cachedBarFrame.Icon.cooldownID)
                    if not barCdID and state.cachedBarFrame.cooldownInfo then
                      barCdID = state.cachedBarFrame.cooldownInfo.cooldownID
                    end
                    barValid = (barCdID == activeCooldownID)
                    -- v3.0.0: Register frame hooks for event-driven updates
                    if barValid then
                      RegisterBarFrameHooks(state.cachedBarFrame, barNum, trackType)
                    end
                  end
                  local iconValid = false
                  if state.cachedFrame then
                    local iconCdID = state.cachedFrame.cooldownID
                    if not iconCdID and state.cachedFrame.cooldownInfo then
                      iconCdID = state.cachedFrame.cooldownInfo.cooldownID
                    end
                    iconValid = (iconCdID == activeCooldownID)
                    -- v3.0.0: Register frame hooks for event-driven updates
                    if iconValid then
                      RegisterBarFrameHooks(state.cachedFrame, barNum, trackType)
                    end
                  end
                  state.trackingOK = barValid or iconValid
                  if not state.trackingOK then
                    state.cachedBarFrame = nil
                    state.cachedFrame = nil
                  end
                else
                  state.trackingOK = false
                end
              else
                if viewerSourceType == "icon" or viewerSourceType == "both" then
                  state.cachedFrame = FindBuffFrameByCooldownID(activeCooldownID)
                  debugPrint(string.format("    FindBuffFrameByCooldownID(%d) = %s", 
                    activeCooldownID, state.cachedFrame and "FOUND" or "nil"))
                  -- Verify the cached frame actually has the right cooldownID
                  -- Check both frame.cooldownID and frame.cooldownInfo.cooldownID
                  if state.cachedFrame then
                    local frameCdID = state.cachedFrame.cooldownID
                    if not frameCdID and state.cachedFrame.cooldownInfo then
                      frameCdID = state.cachedFrame.cooldownInfo.cooldownID
                    end
                    debugPrint(string.format("    frame.cooldownID=%s, matches=%s", 
                      tostring(frameCdID), tostring(frameCdID == activeCooldownID)))
                    if frameCdID == activeCooldownID then
                      state.trackingOK = true
                      -- v3.0.0: Register frame hooks for event-driven updates
                      RegisterBarFrameHooks(state.cachedFrame, barNum, trackType)
                    else
                      state.trackingOK = false
                      state.cachedFrame = nil
                    end
                  else
                    state.trackingOK = false
                  end
                else
                  debugPrint(string.format("    viewerSourceType=%s not icon/both, trackingOK=false", tostring(viewerSourceType)))
                  state.trackingOK = false
                end
              end
            else
              -- FALLBACK: Try to find the frame directly even if not in validCooldownIDs
              local frame = FindBuffFrameByCooldownID(activeCooldownID)
              if frame then
                local frameCdID = frame.cooldownID
                if not frameCdID and frame.cooldownInfo then
                  frameCdID = frame.cooldownInfo.cooldownID
                end
                if frameCdID == activeCooldownID then
                  state.trackingOK = true
                  state.cachedFrame = frame
                  validCooldownIDs[activeCooldownID] = "icon"
                  -- v3.0.0: Register frame hooks for event-driven updates
                  RegisterBarFrameHooks(frame, barNum, trackType)
                else
                  -- Try bar frame
                  local barFrame = FindBarFrameByCooldownID(activeCooldownID)
                  if barFrame then
                    local barCdID = barFrame.cooldownID or (barFrame.Icon and barFrame.Icon.cooldownID)
                    if not barCdID and barFrame.cooldownInfo then
                      barCdID = barFrame.cooldownInfo.cooldownID
                    end
                    if barCdID == activeCooldownID then
                      state.trackingOK = true
                      state.cachedBarFrame = barFrame
                      validCooldownIDs[activeCooldownID] = "bar"
                      -- v3.0.0: Register frame hooks for event-driven updates
                      RegisterBarFrameHooks(barFrame, barNum, trackType)
                    else
                      state.trackingOK = false
                    end
                  else
                    state.trackingOK = false
                  end
                end
              else
                local barFrame = FindBarFrameByCooldownID(activeCooldownID)
                if barFrame then
                  local barCdID = barFrame.cooldownID or (barFrame.Icon and barFrame.Icon.cooldownID)
                  if not barCdID and barFrame.cooldownInfo then
                    barCdID = barFrame.cooldownInfo.cooldownID
                  end
                  if barCdID == activeCooldownID then
                    state.trackingOK = true
                    state.cachedBarFrame = barFrame
                    validCooldownIDs[activeCooldownID] = "bar"
                    -- v3.0.0: Register frame hooks for event-driven updates
                    RegisterBarFrameHooks(barFrame, barNum, trackType)
                  else
                    state.trackingOK = false
                  end
                else
                  state.trackingOK = false
                end
              end
            end
          else
            -- No valid cooldownID found (primary, alternate, or discovered)
            state.cooldownID = barConfig.tracking.cooldownID  -- Keep original for reference
            state.trackingOK = false
            debugPrint(string.format("    NO activeCooldownID found, trackingOK=false"))
            
            -- LAST RESORT: Try CDMEnhance recovery function with original cooldownID
            local originalCdID = barConfig.tracking.cooldownID
            if originalCdID and originalCdID > 0 then
              if ns.CDMEnhance and ns.CDMEnhance.RecoverFrameForCooldownID then
                local recoveredFrame = ns.CDMEnhance.RecoverFrameForCooldownID(originalCdID)
                if recoveredFrame and recoveredFrame.cooldownID == originalCdID then
                  state.trackingOK = true
                  state.cachedFrame = recoveredFrame
                  validCooldownIDs[originalCdID] = "icon"
                  debugPrint(string.format("    RECOVERED via CDMEnhance, trackingOK=true"))
                  -- v3.0.0: Register frame hooks for event-driven updates
                  RegisterBarFrameHooks(recoveredFrame, barNum, trackType)
                end
              end
            end
          end
          
          debugPrint(string.format("  Bar %d RESULT: trackingOK=%s, cachedFrame=%s",
            barNum, tostring(state.trackingOK), state.cachedFrame and "YES" or "nil"))
        
        -- Setup multi-icon textures out of combat
        if not InCombatLockdown() then
          if barConfig.display.displayType == "icon" and barConfig.display.iconMultiMode then
            if ns.Display and ns.Display.SetupMultiIconTextures then
              ns.Display.SetupMultiIconTextures(barNum)
            end
          end
        end
      end
    end
  end
  
  -- Populate the persistent hide registry + hide already-shown frames now, so the
  -- icon is hidden on load/spec change without waiting for a bar update (combat/
  -- target). FrameController hides any later assignment via HideCDMFrameIfRequested.
  ReassertCDMHideRequests()
  UpdateAllBars()
end

function ns.API.ScanAvailableBarsWithDuration()
  if InCombatLockdown() then return nil, "Cannot scan in combat" end
  
  local frames, err = GetAllBarFrames()
  if err then return nil, err end
  
  local availableBars = {}
  local seenNames = {}
  
  for slotNum, frame in ipairs(frames) do
    -- Try multiple sources for cooldownID
    local cdID = frame and frame.cooldownID
    if not cdID and frame and frame.cooldownInfo then
      cdID = frame.cooldownInfo.cooldownID
    end
    -- For bar frames, also check nested Icon frame
    if not cdID and frame and frame.Icon and frame.Icon.cooldownID then
      cdID = frame.Icon.cooldownID
    end
    
    if cdID then
      -- Get spell info from API (same approach as ScanAllCDMIcons)
      local spellID, spellName, iconTextureID
      local info = type(cdID) == "number" and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
      
      if info then
        local baseSpellID = info.spellID or 0
        local overrideSpellID = info.overrideSpellID
        local linkedSpellIDs = info.linkedSpellIDs
        local firstLinkedSpellID = linkedSpellIDs and linkedSpellIDs[1]
        
        -- Priority: first linkedSpellID > overrideSpellID > baseSpellID
        local displaySpellID = firstLinkedSpellID or overrideSpellID or baseSpellID
        
        spellID = displaySpellID or baseSpellID
        spellName = displaySpellID and C_Spell.GetSpellName(displaySpellID)
        iconTextureID = displaySpellID and C_Spell.GetSpellTexture(displaySpellID)
        
        -- Fallbacks
        if not spellName and overrideSpellID then
          spellName = C_Spell.GetSpellName(overrideSpellID)
          iconTextureID = iconTextureID or C_Spell.GetSpellTexture(overrideSpellID)
        end
        if not spellName and baseSpellID > 0 then
          spellName = C_Spell.GetSpellName(baseSpellID)
          iconTextureID = iconTextureID or C_Spell.GetSpellTexture(baseSpellID)
        end
      end
      
      -- Fallback to frame.cooldownInfo if API didn't work
      if not spellName and frame.cooldownInfo then
        spellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
        if spellID and spellID > 0 then
          spellName = C_Spell.GetSpellName(spellID)
          iconTextureID = C_Spell.GetSpellTexture(spellID)
        end
      end
      
      if spellName and not seenNames[spellName] then
        seenNames[spellName] = true
        local maxDuration = 0
        if frame.Bar and frame.Bar.GetMinMaxValues then
          local _, maxVal = frame.Bar:GetMinMaxValues()
          maxDuration = maxVal or 0
        end
        -- Try to get icon from bar frame itself
        if frame.Icon and frame.Icon.Icon and frame.Icon.Icon.GetTexture then
          local barIconTexture = frame.Icon.Icon:GetTexture()
          if barIconTexture then iconTextureID = barIconTexture end
        end
        table.insert(availableBars, {
          slotNumber = slotNum,
          buffName = spellName,
          spellID = spellID,
          iconTextureID = iconTextureID or 134400,
          cooldownID = cdID,
          maxDuration = maxDuration,
          isActive = HasAuraInstanceID(frame.auraInstanceID),
          sourceType = "bar"
        })
      end
    end
  end
  
  return availableBars
end

ns.scannedBarBuffs = {}

function ns.API.SelectBuff(buffInfo, barNumber)
  local db = ns.API.GetDB()
  if not db or not buffInfo then return false end
  
  barNumber = barNumber or db.selectedBar or 1
  local barConfig = ns.API.GetBarConfig(barNumber)
  if not barConfig then return false end
  
  barConfig.tracking.spellID = buffInfo.spellID
  barConfig.tracking.buffName = buffInfo.buffName
  barConfig.tracking.iconTextureID = buffInfo.iconTextureID
  barConfig.tracking.cooldownID = buffInfo.cooldownID
  barConfig.tracking.slotNumber = buffInfo.slotNumber
  barConfig.tracking.maxStacks = buffInfo.maxStacks
  barConfig.tracking.enabled = true
  
  local state = GetBarState(barNumber)
  -- Restore visibility of old cached frame before reconfiguring
  if state.cachedFrame then AllowCDMFrameVisible(state.cachedFrame) end
  if state.cachedBarFrame then AllowCDMFrameVisible(state.cachedBarFrame) end
  state.cooldownID = buffInfo.cooldownID
  state.cachedFrame = nil
  
  UpdateBarBuffInfo(barNumber)
  return true
end

-- ===================================================================
-- UPDATE SPECIFIC BAR'S BUFF INFO
-- ===================================================================
UpdateBarBuffInfo = function(barNumber)
  local barConfig = ns.API.GetBarConfig(barNumber)
  if not barConfig or not barConfig.tracking.enabled then
    -- Clean up CDM hide request: disabled bar shouldn't control CDM visibility
    local wasHidingCD = UnregisterCDMHideRequest(barNumber)
    if wasHidingCD and not AnyCDMHideRequestForCD(wasHidingCD, barNumber) then
      local cdmFrame = FindCDMFrameForCooldownID(wasHidingCD)
      if cdmFrame then AllowCDMFrameVisible(cdmFrame) end
    end
    return
  end
  
  -- Skip frame scan for wrong-spec bars to avoid setting trackingOK=false
  -- (Display.UpdateBar handles visibility; we just don't want to pollute state)
  local showOnSpecs = barConfig.behavior and barConfig.behavior.showOnSpecs
  if showOnSpecs and #showOnSpecs > 0 then
    local currentSpec = (ns.Display and ns.Display.GetCachedSpec and ns.Display.GetCachedSpec()) or GetSpecialization() or 0
    local specOK = false
    for _, spec in ipairs(showOnSpecs) do
      if spec == currentSpec then specOK = true; break end
    end
    if not specOK then return end
  elseif barConfig.behavior and barConfig.behavior.showOnSpec and barConfig.behavior.showOnSpec > 0 then
    local currentSpec = (ns.Display and ns.Display.GetCachedSpec and ns.Display.GetCachedSpec()) or GetSpecialization() or 0
    if currentSpec ~= barConfig.behavior.showOnSpec then return end
  end
  
  local trackType = barConfig.tracking.trackType or "buff"
  local state = GetBarState(barNumber)
  local sourceType = barConfig.tracking.sourceType or "icon"
  local useDurationBar = barConfig.tracking.useDurationBar
  
    -- Check if state.cooldownID is a valid cooldownID for this bar
  -- (either primary OR an alternate) before resetting
  local primaryCdID = barConfig.tracking.cooldownID
  local isValidCdIDForBar = (state.cooldownID == primaryCdID)
  if not isValidCdIDForBar and state.cooldownID then
    -- Check alternates
    local alts = barConfig.tracking.alternateCooldownIDs
    if alts then
      for _, altCdID in ipairs(alts) do
        if state.cooldownID == altCdID then
          isValidCdIDForBar = true
          break
        end
      end
    end
  end
  
  -- Only reset if state.cooldownID is NOT a valid cooldownID for this bar
  -- This preserves alternate cooldownIDs set by ValidateAllBarTracking
  if not state.cooldownID or (not isValidCdIDForBar and not state.cachedFrame) then
    -- Restore visibility of old cached frames before clearing
    if state.cachedFrame then AllowCDMFrameVisible(state.cachedFrame) end
    if state.cachedBarFrame then AllowCDMFrameVisible(state.cachedBarFrame) end
    
    state.cooldownID = barConfig.tracking.cooldownID
    state.cachedFrame = nil
    state.cachedBarFrame = nil
    -- Clear cached aura instance IDs too — a stale aiid from a previous spell/spec
    -- must not resurrect this bar after the tracked cooldownID changes.
    state.buffAuraInstanceID = nil
    state.buffAuraUnit = nil
    state.trackedAuraInstanceID = nil
    state.trackedAuraUnit = nil
    state.debuffAuraInstanceID = nil
  end
  
  -- For buff/debuff tracking, validate cached frames (O(1) check)
  -- Frames are discovered by ValidateAllBarTracking; we just verify
  -- they haven't been recycled by checking cooldownID still matches.
  -- cooldownID is non-secret, direct comparison is safe.
  local frame = state.cachedFrame
  local barFrame = state.cachedBarFrame
  
  -- Validate cached icon frame still matches our cooldownID
  if frame then
    local frameCdID = frame.cooldownID
    if not frameCdID and frame.cooldownInfo then
      frameCdID = frame.cooldownInfo.cooldownID
    end
    if frameCdID ~= state.cooldownID then
      state.cachedFrame = nil
      frame = nil
    end
  end
  
  -- Validate cached bar frame still matches our cooldownID
  if barFrame then
    local barCdID = barFrame.cooldownID
    if not barCdID and barFrame.Icon and barFrame.Icon.cooldownID then
      barCdID = barFrame.Icon.cooldownID
    end
    if not barCdID and barFrame.cooldownInfo then
      barCdID = barFrame.cooldownInfo.cooldownID
    end
    if barCdID ~= state.cooldownID then
      state.cachedBarFrame = nil
      barFrame = nil
    end
  end
  
  -- FALLBACK: If both cached frames are invalid, try re-scanning to recover.
  -- CDM can recycle frames, making our cached refs stale. Also handles the
  -- case where ValidateAllBarTracking hasn't run yet for this bar.
  -- This scan only runs on cache miss, not every call (O(1) when cache valid).
  if not frame and not barFrame and state.cooldownID then
    local freshBarFrame = FindBarFrameByCooldownID(state.cooldownID)
    local freshFrame = FindBuffFrameByCooldownID(state.cooldownID)
    if freshBarFrame then
      state.cachedBarFrame = freshBarFrame
      barFrame = freshBarFrame
      -- Re-register hooks for the new frame
      RegisterBarFrameHooks(freshBarFrame, barNumber, trackType)
    end
    if freshFrame then
      state.cachedFrame = freshFrame
      frame = freshFrame
      RegisterBarFrameHooks(freshFrame, barNumber, trackType)
    end
  end
    
  if ns.debugMode and state.cooldownID and state.cooldownID > 0 and not frame and not barFrame then
    print(string.format("|cffFF6600[ArcUI Debug]|r Bar %d: No cached frame for cdID %d", barNumber, state.cooldownID))
  end
    
    -- Accept either bar OR icon source
    if frame or barFrame then
      state.trackingOK = true
    else
      state.trackingOK = false
    end
  
  -- Check if we're in the spec change grace period
  local inGracePeriod = GetTime() < specChangeGraceUntil
  
  -- Skip during spec change grace period to allow CDM frames time to load
  if not state.trackingOK and not IsOptionsOpen() and not inGracePeriod then
    -- Don't hide if the aura is still active — CDM may have just reassigned its frame
    -- (e.g. pressing a spell that changes what CDM shows, or a full layout refresh).
    -- The aura is still up, the cached frame just became stale. Verify the cached
    -- auraInstanceID against the live API: only keep showing if the API confirms it.
    local auraStillActive = false
    local checkID = state.trackedAuraInstanceID or state.buffAuraInstanceID or state.debuffAuraInstanceID
    if HasAuraInstanceID(checkID) then
      local checkUnit = state.trackedAuraUnit or state.buffAuraUnit or state.detectedUnit or "player"
      if SafeGetAuraData(checkUnit, checkID) then
        auraStillActive = true
      elseif SafeGetAuraData("target", checkID) then
        auraStillActive = true
      end
    end
    if not auraStillActive then
      if ns.Display and ns.Display.HideBar then ns.Display.HideBar(barNumber) end
      return
    end
  end
  
  local hasCooldownID = barConfig.tracking.cooldownID and barConfig.tracking.cooldownID > 0
  if not state.trackingOK and IsOptionsOpen() and hasCooldownID then
    local maxStacks = barConfig.tracking.maxStacks or 10
    if useDurationBar then
      if ns.Display and ns.Display.UpdateDurationBar then
        ns.Display.UpdateDurationBar(barNumber, 0, maxStacks, false, nil, nil, nil, nil, barConfig)
      end
    else
      if ns.Display and ns.Display.UpdateBar then
        ns.Display.UpdateBar(barNumber, 0, maxStacks, false, nil, nil, nil, barConfig)
      end
    end
    return
  end
  
  -- During grace period, also skip hiding for missing cooldownID 
  -- (CDM might not have loaded the bar config yet)
  if not hasCooldownID and not inGracePeriod then
    if ns.Display and ns.Display.HideBar then ns.Display.HideBar(barNumber) end
    return
  end
  
  local frame = state.cachedFrame
  local barFrame = state.cachedBarFrame
  local active = false
  local stacks = 0
  local auraIconFromData = nil  -- icon from GetAuraDataByAuraInstanceID, passed directly to SetTexture (secret-safe)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- PET/TOTEM/GROUND EFFECT TRACKING - Use preferredTotemUpdateSlot from CDM frame
  -- WoW 12.0: frame.totemData AND GetTotemInfo() returns are SECRET!
  -- Use issecretvalue() to detect existence: secret = data exists = totem active
  -- "pet" = guardians/pets (Dreadstalkers, Wild Imps, etc.)
  -- "totem" = actual totems (Healing Stream, Capacitor, etc.)
  -- "ground" = ground effects (Consecration, Efflorescence, Death and Decay, etc.)
  -- ═══════════════════════════════════════════════════════════════════
  if trackType == "pet" or trackType == "totem" or trackType == "ground" then
    local cdmFrame = sourceType == "bar" and barFrame or frame or barFrame
    
    -- WoW 12.0: totemData ONLY EXISTS when totem/pet is currently active
    -- When it expires, totemData becomes nil but preferredTotemUpdateSlot persists
    -- This matches CDMEnhance.GetTotemState() and CooldownState detection
    if cdmFrame and cdmFrame.totemData ~= nil then
      active = true
      stacks = 0  -- Totems/pets don't have stacks
      -- Store cdmFrame reference - query slot fresh each time!
      -- This handles frame recycling where preferredTotemUpdateSlot changes
      state.totemCdmFrame = cdmFrame
    else
      active = false
      stacks = 0
      state.totemCdmFrame = nil
    end
  -- ═══════════════════════════════════════════════════════════════════
  -- DEBUFF TRACKING - Check if CDM frame has auraInstanceID set
  -- Stacks/duration come from target unit (not player!)
  -- Uses linkedSpellID (non-secret!) to handle CDM override situations
  -- ═══════════════════════════════════════════════════════════════════
  elseif trackType == "debuff" then
    local trackedSpellID = barConfig.tracking.trackedSpellID
    local useBaseSpell = barConfig.tracking.useBaseSpell  -- Legacy support
    -- Respect sourceType preference: use icon frame for icon source, bar frame for bar source
    local cdmFrame = sourceType == "bar" and barFrame or frame or barFrame
    local debuffAuraID = nil  -- v2.13.0: Track which auraInstanceID we resolved
    
    -- NEW: trackedSpellID approach for debuffs
    -- When user selects a specific spell, we track it using CDM's auraInstanceID
    -- Note: linkedSpellID is secret when there's only 1 linked spell, non-secret when 2+
    if trackedSpellID and trackedSpellID > 0 and cdmFrame then
      local auraInstanceID = cdmFrame.auraInstanceID
      local auraDataUnit = cdmFrame.auraDataUnit or "target"
      local linkedSpellID = cdmFrame.cooldownInfo and cdmFrame.cooldownInfo.linkedSpellID
      
      -- Check if CDM is currently showing OUR tracked spell.
      -- linkedSpellID is secret when there's only 1 linked spell — use issecretvalue
      -- instead of pcall (much cheaper: single C call vs full pcall overhead).
      local isOurSpell = false
      if linkedSpellID then
        if issecretvalue and issecretvalue(linkedSpellID) then
          -- Secret = only 1 linked spell, CDM always shows ours
          isOurSpell = true
        else
          isOurSpell = (linkedSpellID == trackedSpellID)
        end
      end
      
      if isOurSpell and HasAuraInstanceID(auraInstanceID) then
        -- CDM is showing our tracked spell! Use this auraInstanceID
        local auraData = SafeGetFrameAuraData(cdmFrame, auraDataUnit, auraInstanceID)
        if auraData then
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          -- Cache this auraInstanceID for when CDM switches to different spell
          state.trackedAuraInstanceID = auraInstanceID
          state.trackedAuraUnit = auraDataUnit
          debuffAuraID = auraInstanceID
        else
          active = false
          stacks = 0
        end
      elseif HasAuraInstanceID(state.trackedAuraInstanceID) then
        -- CDM is showing a DIFFERENT spell, use our cached auraInstanceID
        local unit = state.trackedAuraUnit or "target"
        local auraData = SafeGetAuraData(unit, state.trackedAuraInstanceID)
        if auraData then
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          debuffAuraID = state.trackedAuraInstanceID
        else
          -- Cached aura expired - clear it
          state.trackedAuraInstanceID = nil
          state.trackedAuraUnit = nil
          active = false
          stacks = 0
        end
      else
        -- No cached auraInstanceID and CDM showing different spell
        active = false
        stacks = 0
      end
      
    -- LEGACY: useBaseSpell approach (auraDataUnit-based) for debuffs
    elseif useBaseSpell and cdmFrame then
      local auraDataUnit = cdmFrame.auraDataUnit
      local auraInstanceID = cdmFrame.auraInstanceID
      
      if auraDataUnit == "target" and HasAuraInstanceID(auraInstanceID) then
        state.debuffAuraInstanceID = auraInstanceID
        local auraData = SafeGetFrameAuraData(cdmFrame, "target", auraInstanceID)
        if auraData then
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          debuffAuraID = auraInstanceID
        else
          active = false
          stacks = 0
        end
      elseif HasAuraInstanceID(state.debuffAuraInstanceID) then
        local auraData = SafeGetAuraData("target", state.debuffAuraInstanceID)
        if auraData then
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          debuffAuraID = state.debuffAuraInstanceID
        else
          state.debuffAuraInstanceID = nil
          active = false
          stacks = 0
        end
      else
        active = false
        stacks = 0
      end
      
    else
      -- Default behavior: use CDM frame's auraInstanceID directly
      if sourceType == "bar" and barFrame then
        active = HasAuraInstanceID(barFrame.auraInstanceID)
        if active then
          local unit = barFrame.auraDataUnit or "target"
          local auraData = SafeGetFrameAuraData(barFrame, unit, barFrame.auraInstanceID)
          if auraData then 
            stacks = auraData.applications or 0
            auraIconFromData = auraData.icon
          auraIconFromData = auraData.icon
            debuffAuraID = barFrame.auraInstanceID
          end
        end
      elseif frame then
        active = HasAuraInstanceID(frame.auraInstanceID)
        if active then
          local unit = frame.auraDataUnit or "target"
          local auraData = SafeGetFrameAuraData(frame, unit, frame.auraInstanceID)
          if auraData then
            stacks = auraData.applications or 0
            auraIconFromData = auraData.icon
          auraIconFromData = auraData.icon
            debuffAuraID = frame.auraInstanceID
          end
        end
      end
    end
    
  -- ═══════════════════════════════════════════════════════════════════
  -- BUFF TRACKING (default) - Auto-detect unit (player or target)
  -- Uses linkedSpellID (non-secret!) to handle CDM override situations
  -- ═══════════════════════════════════════════════════════════════════
  else
    local detectedUnit = nil
    local trackedSpellID = barConfig.tracking.trackedSpellID
    local useBaseSpell = barConfig.tracking.useBaseSpell  -- Legacy support
    -- Respect sourceType preference: use icon frame for icon source, bar frame for bar source
    local cdmFrame = sourceType == "bar" and barFrame or frame or barFrame
    local buffAuraID = nil  -- v3.0.0: Track which auraInstanceID we resolved
    
    -- NEW: trackedSpellID approach for buffs
    -- When user selects a specific spell, we track it using CDM's auraInstanceID
    -- Note: linkedSpellID is secret when there's only 1 linked spell, non-secret when 2+
    if trackedSpellID and trackedSpellID > 0 and cdmFrame then
      local auraInstanceID = cdmFrame.auraInstanceID
      local auraDataUnit = cdmFrame.auraDataUnit or "player"
      local linkedSpellID = cdmFrame.cooldownInfo and cdmFrame.cooldownInfo.linkedSpellID
      
      -- Check if CDM is currently showing OUR tracked spell.
      -- linkedSpellID is secret when there's only 1 linked spell — use issecretvalue
      -- instead of pcall (much cheaper: single C call vs full pcall overhead).
      local isOurSpell = false
      if linkedSpellID then
        if issecretvalue and issecretvalue(linkedSpellID) then
          -- Secret = only 1 linked spell, CDM always shows ours
          isOurSpell = true
        else
          isOurSpell = (linkedSpellID == trackedSpellID)
        end
      end
      
      if isOurSpell and HasAuraInstanceID(auraInstanceID) then
        -- CDM is showing our tracked spell! Use this auraInstanceID
        local auraData = SafeGetFrameAuraData(cdmFrame, auraDataUnit, auraInstanceID)
        if auraData then
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          detectedUnit = auraDataUnit
          -- Cache this auraInstanceID for when CDM switches to different spell
          state.trackedAuraInstanceID = auraInstanceID
          state.trackedAuraUnit = auraDataUnit
          buffAuraID = auraInstanceID
        else
          active = false
          stacks = 0
        end
      elseif HasAuraInstanceID(state.trackedAuraInstanceID) then
        -- CDM is showing a DIFFERENT spell, use our cached auraInstanceID
        local unit = state.trackedAuraUnit or "player"
        local auraData = SafeGetAuraData(unit, state.trackedAuraInstanceID)
        if auraData then
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          detectedUnit = unit
          buffAuraID = state.trackedAuraInstanceID
        else
          -- Cached aura expired - clear it
          state.trackedAuraInstanceID = nil
          state.trackedAuraUnit = nil
          active = false
          stacks = 0
        end
      else
        -- No cached auraInstanceID and CDM showing different spell
        active = false
        stacks = 0
      end
      
    -- LEGACY: useBaseSpell approach (auraDataUnit-based) for buffs
    elseif useBaseSpell and cdmFrame then
      local auraDataUnit = cdmFrame.auraDataUnit
      local auraInstanceID = cdmFrame.auraInstanceID
      
      if auraDataUnit == "player" and HasAuraInstanceID(auraInstanceID) then
        state.buffAuraInstanceID = auraInstanceID
        detectedUnit = "player"
        local auraData = SafeGetFrameAuraData(cdmFrame, "player", auraInstanceID)
        if auraData then
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          buffAuraID = auraInstanceID
        else
          active = false
          stacks = 0
        end
      elseif HasAuraInstanceID(state.buffAuraInstanceID) then
        detectedUnit = "player"
        local auraData = SafeGetAuraData("player", state.buffAuraInstanceID)
        if auraData then
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          buffAuraID = state.buffAuraInstanceID
        else
          state.buffAuraInstanceID = nil
          active = false
          stacks = 0
        end
      else
        active = false
        stacks = 0
      end
      
    else
      -- Default behavior: use auraInstanceID from any CDM frame
      local auraInstanceID = cdmFrame and cdmFrame.auraInstanceID
      local auraDataUnit = cdmFrame and cdmFrame.auraDataUnit
      
      if HasAuraInstanceID(auraInstanceID) then
        active = true
        local auraData = nil
        
        if auraDataUnit then
          auraData = SafeGetFrameAuraData(cdmFrame, auraDataUnit, auraInstanceID)
          detectedUnit = auraDataUnit
        else
          auraData, detectedUnit = GetAuraDataAutoUnit(auraInstanceID)
          -- 12.1: the auto-unit read is nil under secrecy -> fall back to the frame's own
          -- cached data (auraDataCached is the frame's currently-shown aura). Inert on live.
          if not auraData and IS_121 and cdmFrame and cdmFrame.auraDataCached ~= nil then
            auraData = cdmFrame.auraDataCached
            detectedUnit = detectedUnit or auraDataUnit or "player"
          end
        end
        
        if auraData then
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          buffAuraID = auraInstanceID
          -- Cache the resolved aura instance ID + unit. CDM blanks frame.auraInstanceID
          -- transiently during a full layout refresh (and during same-batch remove+add).
          -- Holding the last-known-good aiid lets us verify against the live API below
          -- instead of hiding a buff that is still genuinely on the unit.
          state.buffAuraInstanceID = auraInstanceID
          state.buffAuraUnit = detectedUnit
          if ns.debugMode then
            print(string.format("|cff00ff00[ArcUI Debug]|r Bar %d BUFF: auraInstID=%s, unit=%s, stacks=%s", 
              barNumber, tostring(auraInstanceID), tostring(detectedUnit), tostring(auraData.applications)))
          end
        else
          active = false
          stacks = 0
        end
      elseif HasAuraInstanceID(state.buffAuraInstanceID) then
        -- Frame's auraInstanceID read nil, but we have a cached one. This happens
        -- when CDM is mid-rebuild (full layout refresh / spec change / override
        -- swap) — the frame state is torn down for a few frames while the buff is
        -- still up. VERIFY against the live API before trusting the nil frame read.
        local unit = state.buffAuraUnit or "player"
        local auraData = SafeGetAuraData(unit, state.buffAuraInstanceID)
        if auraData then
          -- Live API confirms the aura is still present — the frame was just stale.
          active = true
          stacks = auraData.applications or 0
          auraIconFromData = auraData.icon
          buffAuraID = state.buffAuraInstanceID
          detectedUnit = unit
        else
          -- Live API agrees the aura is gone — now it's safe to clear + hide.
          state.buffAuraInstanceID = nil
          state.buffAuraUnit = nil
          active = false
          stacks = 0
        end
      else
        active = false
        stacks = 0
      end
    end
    
    -- Store detected unit for durationStacksRef creation later
    state.detectedUnit = detectedUnit
  end
  
  state.stacks = stacks
  state.active = active
  

  
  -- Get icon texture from appropriate CDM frame
  -- auraIconFromData comes from GetAuraDataByAuraInstanceID above — it's already the correct
  -- icon for the current aura and is secret-safe (SetTexture accepts secrets). Use it first
  -- to avoid the stale frame.Icon:GetTexture() which reads CDM's painted texture that may
  -- not have updated yet when our hook fired.
  local iconTexture = auraIconFromData  -- nil if no active aura, set below from fallbacks
  local useBaseSpell = barConfig.tracking.useBaseSpell
  local trackedSpellID = barConfig.tracking.trackedSpellID
  
  if not iconTexture then
  if trackedSpellID and trackedSpellID > 0 then
    if active then
      local cdmFrame = sourceType == "bar" and barFrame or frame or barFrame
      if cdmFrame and cdmFrame._arcLiveIcon then
        iconTexture = cdmFrame._arcLiveIcon
      end
    end
    if not iconTexture then
      iconTexture = C_Spell.GetSpellTexture(trackedSpellID)
    end
  elseif not useBaseSpell then
    -- Default behavior: get icon from CDM frame (may be override spell)
    -- Respect sourceType preference
    if sourceType == "icon" then
      -- Prefer icon frame for icon source
      if frame then
        if frame.Icon and frame.Icon.GetTexture then
          iconTexture = frame.Icon:GetTexture()
        end
        if not iconTexture and frame.cooldownInfo and frame.cooldownInfo.overrideSpellID then
          iconTexture = C_Spell.GetSpellTexture(frame.cooldownInfo.overrideSpellID)
        end
      end
      if not iconTexture and barFrame then
        if barFrame.Icon and barFrame.Icon.Icon and barFrame.Icon.Icon.GetTexture then
          iconTexture = barFrame.Icon.Icon:GetTexture()
        end
      end
    else
      -- Prefer bar frame for bar source
      if useDurationBar and barFrame then
        if barFrame.Icon and barFrame.Icon.Icon and barFrame.Icon.Icon.GetTexture then
          iconTexture = barFrame.Icon.Icon:GetTexture()
        end
      end
      if not iconTexture and frame then
        if frame.Icon and frame.Icon.GetTexture then
          iconTexture = frame.Icon:GetTexture()
        end
        if not iconTexture and frame.cooldownInfo and frame.cooldownInfo.overrideSpellID then
          iconTexture = C_Spell.GetSpellTexture(frame.cooldownInfo.overrideSpellID)
        end
      end
    end
  else
    -- useBaseSpell enabled: use base spellID from cooldownInfo, not override
    -- Respect sourceType preference
    if sourceType == "icon" then
      if frame and frame.cooldownInfo and frame.cooldownInfo.spellID then
        iconTexture = C_Spell.GetSpellTexture(frame.cooldownInfo.spellID)
      elseif barFrame and barFrame.cooldownInfo and barFrame.cooldownInfo.spellID then
        iconTexture = C_Spell.GetSpellTexture(barFrame.cooldownInfo.spellID)
      end
    else
      if barFrame and barFrame.cooldownInfo and barFrame.cooldownInfo.spellID then
        iconTexture = C_Spell.GetSpellTexture(barFrame.cooldownInfo.spellID)
      elseif frame and frame.cooldownInfo and frame.cooldownInfo.spellID then
        iconTexture = C_Spell.GetSpellTexture(frame.cooldownInfo.spellID)
      end
    end
  end
  
  -- Fallback to saved iconTextureID or spellID
  if not iconTexture and barConfig.tracking.iconTextureID then
    iconTexture = barConfig.tracking.iconTextureID
  end
  if not iconTexture and barConfig.tracking.spellID then
    iconTexture = C_Spell.GetSpellTexture(barConfig.tracking.spellID)
  end
  end -- close: if not iconTexture (auraIconFromData fast path)

  -- Icon override: user-specified spell ID or texture ID replaces resolved texture
  local iconOverride = barConfig.display and barConfig.display.iconOverride
  if iconOverride and iconOverride > 0 then
    iconTexture = C_Spell.GetSpellTexture(iconOverride) or iconOverride
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- DYNAMIC AURA NAME - mirrors how icon reads frame.Icon:GetTexture()
  -- Active: auraSpellID exists (secret) → C_Spell.GetSpellName passthrough
  -- Inactive: no auraSpellID → read base spell from cooldownInfo
  -- Uses sourceType-resolved frame (same pattern as cdmFrame elsewhere)
  -- ═══════════════════════════════════════════════════════════════════
  local auraName = nil
  local nameFrame_cdm = sourceType == "bar" and barFrame or frame or barFrame
  if nameFrame_cdm then
    if nameFrame_cdm.auraSpellID then
      -- Active aura: secret-safe passthrough (SetText accepts secret strings)
      auraName = C_Spell.GetSpellName(nameFrame_cdm.auraSpellID)
    elseif nameFrame_cdm.cooldownInfo then
      -- Inactive: derive base spell name from cooldownInfo
      -- Priority: overrideSpellID > spellID (matches how icon texture resolves)
      local baseID = nameFrame_cdm.cooldownInfo.overrideSpellID or nameFrame_cdm.cooldownInfo.spellID
      if baseID and baseID > 0 then
        auraName = C_Spell.GetSpellName(baseID)
      end
    end
  end
  
  -- Duration bar tracking - create wrapper for stacks/duration from auraInstanceID
  local durationBarRef = nil
  local durationStacksRef = nil
  -- NOTE: useBaseSpell and trackedSpellID already declared above (lines 2091-2092)
  -- Respect sourceType preference: use icon frame for icon source, bar frame for bar source
  local cdmFrame = sourceType == "bar" and barFrame or frame or barFrame
  
  -- Get bar reference if available (for legacy CDM bar duration passthrough)
  if barFrame and barFrame.Bar then 
    durationBarRef = barFrame.Bar 
  end
  
  -- Create stacks/duration wrapper using auraInstanceID
  -- NEW: trackedSpellID uses state.trackedAuraInstanceID/Unit
  if trackedSpellID and trackedSpellID > 0 and state.trackedAuraInstanceID then
    local cachedAuraInstanceID = state.trackedAuraInstanceID
    local cachedUnit = state.trackedAuraUnit or "player"
    durationStacksRef = {
      GetText = function()
        local auraData = SafeGetAuraData(cachedUnit, cachedAuraInstanceID)
        if auraData then
          return auraData.applications
        end
        return 0
      end,
      GetDuration = function()
        local auraData = SafeGetAuraData(cachedUnit, cachedAuraInstanceID)
        if auraData then
          return auraData.duration, auraData.expirationTime
        end
        return 0, 0
      end
    }
    
  elseif trackType == "debuff" then
    -- LEGACY: For debuff with useBaseSpell
    local auraInstIDToUse = nil
    if useBaseSpell and HasAuraInstanceID(state.debuffAuraInstanceID) then
      auraInstIDToUse = state.debuffAuraInstanceID
    elseif not useBaseSpell and cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID) then
      auraInstIDToUse = cdmFrame.auraInstanceID
    end
    
    if HasAuraInstanceID(auraInstIDToUse) then
      local cachedAuraInstanceID = auraInstIDToUse
      local cachedUnit = cdmFrame and cdmFrame.auraDataUnit or "target"
      durationStacksRef = {
        GetText = function()
          local auraData = SafeGetAuraData(cachedUnit, cachedAuraInstanceID)
          if auraData then
            return auraData.applications
          end
          return 0
        end,
        GetDuration = function()
          local auraData = SafeGetAuraData(cachedUnit, cachedAuraInstanceID)
          if auraData then
            return auraData.duration, auraData.expirationTime
          end
          return 0, 0
        end
      }
    end
    
  else
    -- LEGACY: For buff with useBaseSpell or default
    local auraInstIDToUse = nil
    local unitToUse = state.detectedUnit or "player"
    
    if useBaseSpell and HasAuraInstanceID(state.buffAuraInstanceID) then
      auraInstIDToUse = state.buffAuraInstanceID
      unitToUse = "player"
    elseif not useBaseSpell and cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID) then
      auraInstIDToUse = cdmFrame.auraInstanceID
      unitToUse = cdmFrame.auraDataUnit or state.detectedUnit or "player"
    elseif not useBaseSpell and HasAuraInstanceID(state.buffAuraInstanceID) then
      -- CDM frame id transiently nil during a rebuild — use cached id for stack text.
      auraInstIDToUse = state.buffAuraInstanceID
      unitToUse = state.buffAuraUnit or state.detectedUnit or "player"
    end
    
    if HasAuraInstanceID(auraInstIDToUse) then
      local cachedAuraInstanceID = auraInstIDToUse
      local cachedUnit = unitToUse
      local liveFrame = (not useBaseSpell) and cdmFrame or nil
      local function resolve()
        if liveFrame and HasAuraInstanceID(liveFrame.auraInstanceID) then
          return liveFrame.auraInstanceID, (liveFrame.auraDataUnit or cachedUnit)
        end
        return cachedAuraInstanceID, cachedUnit
      end
      durationStacksRef = {
        GetText = function()
          local id, unit = resolve()
          local auraData = SafeGetAuraData(unit, id)
          if auraData then
            return auraData.applications
          end
          return 0
        end,
        GetDuration = function()
          local id, unit = resolve()
          local auraData = SafeGetAuraData(unit, id)
          if auraData then
            return auraData.duration, auraData.expirationTime
          end
          return 0, 0
        end
      }
    end
  end
  
  -- Fallback to CDM's FontString if no auraInstanceID wrapper AND not tracking specific spell
  local blockCDMFallback = (trackedSpellID and trackedSpellID > 0) or useBaseSpell
  if not durationStacksRef and not blockCDMFallback then
    if barFrame and barFrame.Icon and barFrame.Icon.Applications then
      durationStacksRef = barFrame.Icon.Applications
    elseif frame and frame.Icon and frame.Icon.Applications then
      durationStacksRef = frame.Icon.Applications
    end
  end
  
  -- Update display
  if ns.Display and ns.Display.UpdateBar then
    -- Create duration wrapper using auraInstanceID for accurate duration
    -- This works for ANY CDM source (icon or bar) and handles override situations
    local effectiveDurationRef = nil
    local trackedSpellID = barConfig.tracking.trackedSpellID
    -- Respect sourceType preference: use icon frame for icon source, bar frame for bar source
    local cdmFrame = sourceType == "bar" and barFrame or frame or barFrame
    
    -- NEW: trackedSpellID approach - use state.trackedAuraInstanceID/Unit
    if trackedSpellID and trackedSpellID > 0 and HasAuraInstanceID(state.trackedAuraInstanceID) then
      local cachedAuraInstanceID = state.trackedAuraInstanceID
      local cachedUnit = state.trackedAuraUnit or "player"
      effectiveDurationRef = {
        GetValue = function()
          -- CRITICAL: Validate aura still exists before calling GetAuraDurationRemaining
          -- Calling with stale auraInstanceID causes client crash in Beta 4
          local auraData = SafeGetAuraData(cachedUnit, cachedAuraInstanceID)
          if not auraData then
            return 0
          end
          if C_UnitAuras.GetAuraDurationRemaining then
            return SafeGetAuraDurationRemaining(cachedUnit, cachedAuraInstanceID)
          end
          return 0
        end,
        GetMinMaxValues = function()
          local auraData = SafeGetAuraData(cachedUnit, cachedAuraInstanceID)
          if auraData and auraData.duration then
            return 0, auraData.duration
          end
          return 0, 30
        end,
        -- v2.8.0: For ColorCurve support - expose aura info
        GetAuraInfo = function()
          return cachedAuraInstanceID, cachedUnit
        end
      }
      
    elseif trackType == "debuff" then
      -- LEGACY: For debuff tracking with useBaseSpell
      local auraInstIDToUse = nil
      local unitToUse = "target"
      
      if useBaseSpell and HasAuraInstanceID(state.debuffAuraInstanceID) then
        auraInstIDToUse = state.debuffAuraInstanceID
      elseif not useBaseSpell and cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID) then
        -- Default: use CDM's current ID
        auraInstIDToUse = cdmFrame.auraInstanceID
        unitToUse = cdmFrame.auraDataUnit or "target"
      elseif not useBaseSpell and HasAuraInstanceID(state.debuffAuraInstanceID) then
        -- CDM frame id transiently nil during a rebuild — use the cached id so the
        -- duration sweep stays in sync with the active path. Verified live below.
        auraInstIDToUse = state.debuffAuraInstanceID
      end
      
      if HasAuraInstanceID(auraInstIDToUse) then
        local cachedAuraInstanceID = auraInstIDToUse
        local cachedUnit = unitToUse
        -- liveFrame: read auraInstanceID live when CDM is the source (not useBaseSpell)
        -- Aura refreshes change auraInstanceID on the CDM frame — cached copy goes stale
        local liveFrame = (not useBaseSpell) and cdmFrame or nil
        effectiveDurationRef = {
          GetValue = function()
            local id = liveFrame and liveFrame.auraInstanceID or cachedAuraInstanceID
            local unit = (liveFrame and liveFrame.auraDataUnit) or cachedUnit
            local auraData = SafeGetAuraData(unit, id)
            if not auraData then return 0 end
            if C_UnitAuras.GetAuraDurationRemaining then
              return SafeGetAuraDurationRemaining(unit, id)
            end
            return 0
          end,
          GetMinMaxValues = function()
            local id = liveFrame and liveFrame.auraInstanceID or cachedAuraInstanceID
            local unit = (liveFrame and liveFrame.auraDataUnit) or cachedUnit
            local auraData = SafeGetAuraData(unit, id)
            if auraData and auraData.duration then
              return 0, auraData.duration
            end
            return 0, 30
          end,
          GetAuraInfo = function()
            if liveFrame and HasAuraInstanceID(liveFrame.auraInstanceID) then
              return liveFrame.auraInstanceID, (liveFrame.auraDataUnit or cachedUnit)
            end
            return cachedAuraInstanceID, cachedUnit
          end
        }
      end
      
    elseif trackType == "buff" or trackType == nil then
      -- LEGACY: For buff tracking with useBaseSpell
      local auraInstIDToUse = nil
      local unitToUse = state.detectedUnit or "player"
      
      if useBaseSpell and HasAuraInstanceID(state.buffAuraInstanceID) then
        auraInstIDToUse = state.buffAuraInstanceID
        unitToUse = "player"
      elseif not useBaseSpell and cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID) then
        -- Default: use CDM's current ID
        auraInstIDToUse = cdmFrame.auraInstanceID
        unitToUse = cdmFrame.auraDataUnit or state.detectedUnit or "player"
      elseif not useBaseSpell and HasAuraInstanceID(state.buffAuraInstanceID) then
        -- CDM frame's auraInstanceID is transiently nil (full layout refresh /
        -- same-batch remove+add). The active path keeps the bar shown using this
        -- cached id; the duration wrapper must use the SAME cache or the bar shows
        -- active with no sweep. Verified live in GetValue before use.
        auraInstIDToUse = state.buffAuraInstanceID
        unitToUse = state.buffAuraUnit or state.detectedUnit or "player"
      end
      
      if HasAuraInstanceID(auraInstIDToUse) then
        local cachedAuraInstanceID = auraInstIDToUse
        local cachedUnit = unitToUse
        local liveFrame = (not useBaseSpell) and cdmFrame or nil
        -- Resolve id/unit each call: prefer the live CDM frame id when present
        -- (aura refresh reassigns auraInstanceID), fall back to the cached id+unit
        -- when the frame is transiently nil during a CDM rebuild.
        local function resolve()
          if liveFrame and HasAuraInstanceID(liveFrame.auraInstanceID) then
            return liveFrame.auraInstanceID, (liveFrame.auraDataUnit or cachedUnit)
          end
          return cachedAuraInstanceID, cachedUnit
        end
        effectiveDurationRef = {
          GetValue = function()
            local id, unit = resolve()
            local auraData = SafeGetAuraData(unit, id)
            if not auraData then return 0 end
            if C_UnitAuras.GetAuraDurationRemaining then
              return SafeGetAuraDurationRemaining(unit, id)
            end
            return 0
          end,
          GetMinMaxValues = function()
            local id, unit = resolve()
            local auraData = SafeGetAuraData(unit, id)
            if auraData and auraData.duration then
              return 0, auraData.duration
            end
            return 0, 30
          end,
          GetAuraInfo = function()
            return resolve()
          end
        }
      end
    elseif trackType == "pet" or trackType == "totem" or trackType == "ground" then
      -- PET/TOTEM/GROUND EFFECT TRACKING: Create duration reference
      -- 12.0.5+: GetTotemDuration(slot) returns a duration object.
      -- GetTotemDuration returns nil when the slot is inactive, valid durObj when active.
      -- The durObj itself never goes nil mid-life; don't nil-check it after acquisition.
      if state.totemCdmFrame then
        local totemCdmFrame = state.totemCdmFrame
        local originalCooldownID = totemCdmFrame.cooldownID

        -- Resolve totem slot from CDM frame. Returns nil if frame is stale or inactive.
        local function ResolveSlot()
          if totemCdmFrame.cooldownID ~= originalCooldownID then return nil end
          if totemCdmFrame.totemData == nil then return nil end
          local slot = totemCdmFrame.preferredTotemUpdateSlot
          -- totemData is a SECRET table in instances; indexing it (.slot) while tainted
          -- throws. Only read from it when non-secret (open world). preferredTotemUpdateSlot
          -- covers the usual case; otherwise slot stays nil this tick.
          if not slot then
            local td = totemCdmFrame.totemData
            if td and not issecretvalue(td) then
              slot = td.slot
            end
          end
          if not slot then return nil end
          if not issecretvalue(slot) and slot <= 0 then return nil end
          return slot
        end

        effectiveDurationRef = {
          -- GetTotemInfo: presence signal used by Display to identify the totem bar branch.
          -- Returns slot (may be secret) when active, nil when stale/expired.
          GetTotemInfo = function()
            return ResolveSlot()
          end,
          -- GetDurationObject: calls GetTotemDuration(slot).
          -- Returns nil when slot is inactive (API contract), valid durObj when active.
          -- Display uses this for SetTimerDuration (bar) and GetRemainingDuration (text).
          GetDurationObject = function()
            local slot = ResolveSlot()
            if not slot then return nil end
            return GetTotemDuration and GetTotemDuration(slot) or nil
          end,
        }
      end
    end
    
    -- Determine final duration source:
    -- 1. effectiveDurationRef (our auraInstanceID wrapper - works for any source)
    -- 2. durationBarRef (CDM bar - legacy fallback, but NOT when trackedSpellID/useBaseSpell is on)
    -- 3. durationFontString (CDM icon fontstring - legacy fallback, but NOT when trackedSpellID/useBaseSpell is on)
    
    -- Don't fall back to CDM duration if we're tracking a specific spell
    local preventCDMFallback = (trackedSpellID and trackedSpellID > 0) or useBaseSpell
    
    -- Store dynamic aura name on state so Display.lua can read it directly
    -- (bypasses profiler wrapper P:Def that may drop extra function parameters)
    -- Only store when active - auraSpellID persists as stale secret on CDM frame after aura fades
    state.dynamicAuraName = active and auraName or nil
    
    if useDurationBar then
      -- Duration bar mode - ALWAYS use UpdateDurationBar
      local durationSource = effectiveDurationRef
      if not durationSource and not preventCDMFallback then
        durationSource = durationBarRef  -- Only use CDM bar when not tracking specific spell
      end
      -- Debug: trace active state
      if ns.debugMode then
        print(string.format("|cffff9900[ArcUI Debug]|r Bar %d calling UpdateDurationBar: active=%s, stacks=%s, hideWhenInactive=%s",
          barNumber, tostring(active), tostring(stacks), tostring(barConfig.behavior and barConfig.behavior.hideWhenInactive)))
      end
      ns.Display.UpdateDurationBar(barNumber, stacks, barConfig.tracking.maxStacks, active,
                                    durationSource, durationStacksRef, iconTexture, auraName, barConfig)
    elseif effectiveDurationRef then
      ns.Display.UpdateBar(barNumber, stacks, barConfig.tracking.maxStacks, active, effectiveDurationRef, iconTexture, auraName, barConfig)
    elseif durationBarRef and not preventCDMFallback then
      ns.Display.UpdateBar(barNumber, stacks, barConfig.tracking.maxStacks, active, durationBarRef, iconTexture, auraName, barConfig)
    else
      ns.Display.UpdateBar(barNumber, stacks, barConfig.tracking.maxStacks, active, nil, iconTexture, auraName, barConfig)
    end
  end
  
  -- Hide CDM icon if enabled (ForceHideCDMFrame verifies cooldownID matches before hiding)
  if barConfig.behavior.hideBuffIcon then
    local expectedCdID = state.cooldownID or barConfig.tracking.cooldownID
    -- Register this bar's hide request for the cooldownID
    RegisterCDMHideRequest(barNumber, expectedCdID)
    
    if frame then ForceHideCDMFrame(frame, expectedCdID) end
    if barFrame then ForceHideCDMFrame(barFrame, expectedCdID) end
    
    -- Fallback: If cached frames were nil or rejected by verification,
    -- do a direct viewer scan to find and hide the correct CDM frame.
    -- This handles stale cache after profile import/spec change.
    -- Also installs SetCooldownID hooks on ALL siblings so if CDM later
    -- shuffles a hidden cooldownID to a different frame, we catch it.
    if expectedCdID and (not frame or not hiddenCDMFrames[frame]) then
      local viewer = _G["BuffIconCooldownViewer"]
      if viewer then
        local children = {viewer:GetChildren()}
        for _, child in ipairs(children) do
          -- Install SetCooldownID hook on every sibling (lightweight, one-time)
          if not child._arcSetCdIDHooked and child.SetCooldownID then
            child._arcSetCdIDHooked = true
            hooksecurefunc(child, "SetCooldownID", function(self, newCdID)
              if newCdID and cdmHideRequestsByCD[newCdID] then
                ForceHideCDMFrame(self, newCdID)
              end
            end)
          end
          local cdID = child.cooldownID
          if not cdID and child.cooldownInfo then
            cdID = child.cooldownInfo.cooldownID
          end
          if cdID == expectedCdID then
            ForceHideCDMFrame(child, expectedCdID)
          end
        end
      end
    end
    if expectedCdID and (not barFrame or not hiddenCDMFrames[barFrame]) then
      local viewer = _G["BuffBarCooldownViewer"]
      if viewer then
        local children = {viewer:GetChildren()}
        for _, child in ipairs(children) do
          -- Install SetCooldownID hook on every sibling (lightweight, one-time)
          if not child._arcSetCdIDHooked and child.SetCooldownID then
            child._arcSetCdIDHooked = true
            hooksecurefunc(child, "SetCooldownID", function(self, newCdID)
              if newCdID and cdmHideRequestsByCD[newCdID] then
                ForceHideCDMFrame(self, newCdID)
              end
            end)
          end
          local cdID = child.cooldownID
          if not cdID and child.cooldownInfo then
            cdID = child.cooldownInfo.cooldownID
          end
          if not cdID and child.Icon and child.Icon.cooldownID then
            cdID = child.Icon.cooldownID
          end
          if cdID == expectedCdID then
            ForceHideCDMFrame(child, expectedCdID)
          end
        end
      end
    end
  else
    -- This bar does NOT want to hide the CDM icon.
    -- Unregister any previous hide request from this bar.
    local wasHidingCD = UnregisterCDMHideRequest(barNumber)
    
    -- Only allow CDM frame visible if NO other bar is still requesting it hidden.
    -- This prevents Bar B (hideBuffIcon=false) from undoing Bar A's (hideBuffIcon=true) hide.
    local checkCdID = wasHidingCD or (state and state.cooldownID) or (barConfig.tracking and barConfig.tracking.cooldownID)
    if not AnyCDMHideRequestForCD(checkCdID, barNumber) then
      if frame then AllowCDMFrameVisible(frame) end
      if barFrame then AllowCDMFrameVisible(barFrame) end
    end
  end

  -- ─────────────────────────────────────────────────────────────────
  -- v3.7.2: maintain the auraInstanceID→bar reverse map from the aura this
  -- bar actually resolved to display, so the single UNIT_AURA consumer can
  -- refresh exactly this bar when that instance's stacks/duration change.
  -- Totem/pet/ground bars are event-driven (PLAYER_TOTEM_UPDATE), not auras.
  -- ─────────────────────────────────────────────────────────────────
  local mUnit, mAiid
  if active and trackType ~= "pet" and trackType ~= "totem" and trackType ~= "ground" then
    local mapFrame = (sourceType == "bar") and barFrame or frame or barFrame
    local tSpell = barConfig.tracking.trackedSpellID
    if tSpell and tSpell > 0 then
      mAiid = state.trackedAuraInstanceID
      mUnit = state.trackedAuraUnit
    elseif trackType == "debuff" then
      mAiid = state.debuffAuraInstanceID or (mapFrame and mapFrame.auraInstanceID)
      mUnit = (mapFrame and mapFrame.auraDataUnit) or "target"
    else
      mAiid = state.buffAuraInstanceID or (mapFrame and mapFrame.auraInstanceID)
      mUnit = state.buffAuraUnit or state.detectedUnit or (mapFrame and mapFrame.auraDataUnit) or "player"
    end
  end
  SetBarAuraMapping(barNumber, state, mUnit, mAiid)
end

-- ===================================================================
-- UPDATE ALL ACTIVE BARS
-- ===================================================================
UpdateAllBars = function()
  if not ns.API.GetActiveBars then return end
  local activeBars = ns.API.GetActiveBars()
  for _, barNumber in ipairs(activeBars) do
    UpdateBarBuffInfo(barNumber)
  end
end

-- ===================================================================
-- SINGLE UNIT_AURA CONSUMER  (v3.7.2 aura-engine rework)
-- ===================================================================
-- The one live-refresh signal for already-shown auras. UpdateBarBuffInfo binds
-- WHICH auraInstanceID each bar displays (SetBarAuraMapping); this consumer
-- reads UNIT_AURA's updatedAuraInstanceIDs and refreshes ONLY the bars tracking
-- those instances (O(changed)). Replaces the per-frame OnUnitAuraUpdatedEvent +
-- OnNewTarget fan-out.
local function RefreshBarsForUnit(unit)
  -- Full update / fallback: refresh every bar mapped on this unit.
  for _aiid, bucket in pairs(auraEntries[unit]) do
    for barNum in pairs(bucket) do UpdateBarBuffInfo(barNum) end
  end
  for barNum in pairs(secretAuraBars[unit]) do
    UpdateBarBuffInfo(barNum)
  end
end

local function HandleUnitAura(unit, updateInfo)
  local e = auraEntries[unit]
  if not e then return end

  if not updateInfo then
    RefreshBarsForUnit(unit)
    return
  end
  -- 12.1: the UNIT_AURA payload is fully secret in restricted content -- isFullUpdate is a
  -- secret boolean and the id vectors are secret tables, so we can neither boolean-test nor
  -- iterate them (and a refresh would hit secret C_UnitAuras). Bail; bars hold last state.
  -- Inert on live (issecretvalue false -> normal path below).
  if issecretvalue and issecretvalue(updateInfo.isFullUpdate) then return end

  if updateInfo.isFullUpdate then
    RefreshBarsForUnit(unit)
    return
  end

  -- Stack/duration changes on tracked instances. auraInstanceID is non-secret
  -- (per the 12.0 value rules), but guard defensively so a secret id is never
  -- used as a table key — those bars are covered by the secretAuraBars pass.
  local updated = updateInfo.updatedAuraInstanceIDs
  if updated then
    for _, aiid in ipairs(updated) do
      if not (issecretvalue and issecretvalue(aiid)) then
        local bucket = e[aiid]
        if bucket then
          for barNum in pairs(bucket) do UpdateBarBuffInfo(barNum) end
        end
      end
    end
  end

  -- Removed auras: refresh those bars (they go inactive) then drop the mapping.
  local removed = updateInfo.removedAuraInstanceIDs
  if removed then
    for _, aiid in ipairs(removed) do
      if not (issecretvalue and issecretvalue(aiid)) then
        local bucket = e[aiid]
        if bucket then
          for barNum in pairs(bucket) do UpdateBarBuffInfo(barNum) end
          e[aiid] = nil
        end
      end
    end
  end

  -- Secret-id bars on this unit can't be matched by id; refresh on any change.
  for barNum in pairs(secretAuraBars[unit]) do
    UpdateBarBuffInfo(barNum)
  end
end

-- ===================================================================
-- EVENT HANDLING
-- ===================================================================
local eventFrame = CreateFrame("Frame")
_G.ArcUICoreEventFrame = eventFrame  -- profiler
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_TOTEM_UPDATE")
eventFrame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
-- v3.7.2: single live-refresh signal for already-shown auras (player + target).
eventFrame:RegisterUnitEvent("UNIT_AURA", "player", "target")

eventFrame:SetScript("OnEvent", function(self, event, ...)
  if event == "UNIT_AURA" then
    local unit, updateInfo = ...
    -- 12.1: cache this unit's aura secrecy from isFullUpdate (the ONLY non-throwing signal) BEFORE
    -- anything else, so every subsequent aura-read guard (AurasSecret) has a fresh answer.
    NoteUnitAuraSecrecy(unit, updateInfo)
    if unit == "player" or unit == "target" then
      HandleUnitAura(unit, updateInfo)
    end
  elseif event == "COOLDOWN_VIEWER_DATA_LOADED" then
    -- CDM rebuilt its viewer layout — frame↔cooldownID bindings may have moved.
    InvalidateCDMIndex()
    ns.API.ValidateAllBarTracking()
  elseif event == "PLAYER_TOTEM_UPDATE" then
    if next(totemBarNumbers) then
      for barNum in pairs(totemBarNumbers) do
        UpdateBarBuffInfo(barNum)
      end
    end
  elseif event == "PLAYER_TARGET_CHANGED" then
    -- CDM handles UNIT_TARGET → RefreshActiveFramesForTargetChange → RefreshData
    -- on all frames. UpdateAllBars refreshes all debuff bars for new target.
    UpdateAllBars()
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- 12.1: fresh zone -> clear sticky aura-secrecy; the per-frame scan re-detects live state.
    if ns.API.ClearAuraSecrecyCache then ns.API.ClearAuraSecrecyCache() end
    -- Bars stay hidden until initialization completes (prevents flash on reload)
    -- Delay allows frames to be created and positioned before showing
    C_Timer.After(0.5, function()
      ns.API.ValidateAllBarTracking()
      -- Mark initialization complete - bars can now show
      if ns.Display and ns.Display.MarkInitializationComplete then
        ns.Display.MarkInitializationComplete()
      end
      -- Now refresh all bars with proper appearance
      if ns.Display and ns.Display.RefreshAllBars then
        ns.Display.RefreshAllBars()
      end
      UpdateAllBars()
    end)
  elseif event == "PLAYER_REGEN_ENABLED" then
    -- Left combat - invalidate visibility cache
    if ns.Display and ns.Display.InvalidateVisibilityCache then
      ns.Display.InvalidateVisibilityCache()
    end
    -- 12.1: clear the sticky aura-secrecy flags; the per-frame scan re-detects any that persist.
    if ns.API.ClearAuraSecrecyCache then ns.API.ClearAuraSecrecyCache() end
    -- Refresh icon textures while out of combat (they might have been secret during combat)
    C_Timer.After(0.2, function()
      local db = ns.API.GetDB()
      if db and db.bars then
        for barNumber, barConfig in pairs(db.bars) do
          if barConfig.tracking then
            -- Update iconTextureID - respect trackedSpellID if set
            local sourceSpellID = nil
            if barConfig.tracking.trackedSpellID and barConfig.tracking.trackedSpellID > 0 then
              sourceSpellID = barConfig.tracking.trackedSpellID
            elseif barConfig.tracking.spellID then
              sourceSpellID = barConfig.tracking.spellID
            end
            
            if sourceSpellID then
              local texture = C_Spell.GetSpellTexture(sourceSpellID)
              if texture then
                barConfig.tracking.iconTextureID = texture
              end
            end
          end
          -- Setup multi-icon textures (must be done out of combat)
          if barConfig.tracking and barConfig.tracking.enabled then
            if barConfig.display.displayType == "icon" and barConfig.display.iconMultiMode then
              if ns.Display and ns.Display.SetupMultiIconTextures then
                ns.Display.SetupMultiIconTextures(barNumber)
              end
            end
          end
        end
      end
    end)
    C_Timer.After(0.5, UpdateAllBars)
  elseif event == "PLAYER_REGEN_DISABLED" then
    if ns.Display and ns.Display.InvalidateVisibilityCache then
      ns.Display.InvalidateVisibilityCache()
    end
    UpdateAllBars()
  elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
    -- Invalidate cross-spec cooldownID cache first
    InvalidateSpellToCooldownIDCache()
    
    -- v3.0.0: Clear aura hook registrations on spec change (frames may change)
    ClearAllAuraHookRegistrations()
    -- v3.7.2: frame↔cooldownID bindings change with spec — drop the cached index.
    InvalidateCDMIndex()

    -- v2.12.0: Release all hidden CDM frame tracking.
    -- CDM will manage its own frame visibility during the transition.
    -- Prevents empty shell bars from becoming visible when AllowCDMFrameVisible
    -- is called on frames CDM has already cleared/recycled.
    ClearAllHiddenCDMFramesForSpecChange()
    
    -- Clear all bar states to prevent stale frame references
    -- (old spec's frames get released cleanly without calling Show)
    for barNum in pairs(barStates) do
      barStates[barNum] = nil
    end
    
    -- Invalidate spec cache in Display module
    if ns.Display and ns.Display.InvalidateSpecCache then
      ns.Display.InvalidateSpecCache()
    end
    -- Invalidate visibility cache (spec affects visibility)
    if ns.Display and ns.Display.InvalidateVisibilityCache then
      ns.Display.InvalidateVisibilityCache()
    end
    
    -- Set grace period immediately - don't hide bars due to trackingOK=false
    -- CDM frames may not have loaded new spec's abilities yet
    specChangeGraceUntil = GetTime() + SPEC_CHANGE_GRACE_DURATION
    
    -- Full refresh on spec change:
    -- 1. Validate tracking (checks CDM frames, etc.)
    -- 2. RefreshAllBars (ApplyAppearance + RefreshDisplay for each bar)
    -- 3. UpdateAllBars to ensure all states are current
    C_Timer.After(0.2, function() 
      ns.API.ValidateAllBarTracking()
      -- RefreshAllBars calls ApplyAppearance then RefreshDisplay for proper setup
      if ns.Display and ns.Display.RefreshAllBars then
        ns.Display.RefreshAllBars()
      end
      -- Also trigger a full update cycle to catch any stragglers
      UpdateAllBars()
    end)
    
    -- Schedule another refresh after grace period to clean up any bars
    -- that didn't load properly
    C_Timer.After(SPEC_CHANGE_GRACE_DURATION + 0.5, function()
      ns.API.ValidateAllBarTracking()
      if ns.Display and ns.Display.RefreshAllBars then
        ns.Display.RefreshAllBars()
      end
      UpdateAllBars()
    end)
  end
end)

-- ===================================================================
-- API FUNCTIONS
-- ===================================================================
function ns.API.GetCurrentStacks(barNumber)
  barNumber = barNumber or ns.API.GetSelectedBar()
  local state = GetBarState(barNumber)
  return state.stacks
end

function ns.API.GetMaxStacks(barNumber)
  barNumber = barNumber or ns.API.GetSelectedBar()
  local barConfig = ns.API.GetBarConfig(barNumber)
  return barConfig and barConfig.tracking.maxStacks or 10
end

function ns.API.IsBuffActive(barNumber)
  barNumber = barNumber or ns.API.GetSelectedBar()
  local state = GetBarState(barNumber)
  return state.active
end

function ns.API.RefreshDisplay(barNumber)
  if barNumber then UpdateBarBuffInfo(barNumber) else UpdateAllBars() end
end

function ns.API.RefreshAll() UpdateAllBars() end

function ns.API.ClearBarState(barNumber)
  ClearBarState(barNumber)
end

function ns.API.IsTrackingOK(barNumber)
  barNumber = barNumber or ns.API.GetSelectedBar()
  local state = GetBarState(barNumber)
  return state.trackingOK == true
end

-- Expose GetBarState for debuggers
function ns.API.GetBarState(barNumber)
  barNumber = barNumber or ns.API.GetSelectedBar()
  return GetBarState(barNumber)
end

function ns.API.GetTrackingStatus(barNumber)
  if not ns.API.GetSelectedBar or not ns.API.GetBarConfig then
    return "initializing", "Addon initializing...", false
  end
  barNumber = barNumber or ns.API.GetSelectedBar()
  local barConfig = ns.API.GetBarConfig(barNumber)
  if not barConfig or not barConfig.tracking.enabled then
    return "not_configured", "Bar slot not configured", false
  end
  local viewer = _G["BuffIconCooldownViewer"]
  if not viewer then
    return "no_viewer", "BuffIconCooldownViewer not found", false
  end
  local state = GetBarState(barNumber)
  if state.trackingOK and state.cooldownID then
    return "ok", barConfig.tracking.buffName .. " tracked", true
  elseif state.cooldownID then
    return "pending", barConfig.tracking.buffName .. " (waiting for CD Manager)", false
  end
  return "not_found", "Buff not found in CD Manager", false
end

function ns.API.ForceRecheck(barNumber)
  if InCombatLockdown() then return false end
  barNumber = barNumber or ns.API.GetSelectedBar()
  local barConfig = ns.API.GetBarConfig(barNumber)
  if not barConfig or not barConfig.tracking.enabled then return false end
  local state = GetBarState(barNumber)
  -- Restore visibility of old cached frame before clearing
  if state.cachedFrame then AllowCDMFrameVisible(state.cachedFrame) end
  state.cachedFrame = nil
  local frame = FindBuffFrameByCooldownID(state.cooldownID)
  if frame then
    UpdateBarBuffInfo(barNumber)
    return true
  end
  return false
end

function ns.API.SetHideBuffIcon(hide, barNumber)
  barNumber = barNumber or ns.API.GetSelectedBar()
  local barConfig = ns.API.GetBarConfig(barNumber)
  if barConfig then
    barConfig.behavior.hideBuffIcon = hide
    UpdateBarBuffInfo(barNumber)
  end
end

function ns.API.DisableBar(barNumber)
  local barConfig = ns.API.GetBarConfig(barNumber)
  if barConfig then
    barConfig.tracking.enabled = false
    if ns.Display and ns.Display.HideBar then ns.Display.HideBar(barNumber) end
  end
end

-- ===================================================================
-- SLASH COMMANDS
-- ===================================================================
SLASH_ARCBARS1 = "/arcbars"
SLASH_ARCBARS2 = "/ab"

SlashCmdList["ARCBARS"] = function(msg)
  local command, arg = msg:match("^(%S+)%s*(.*)$")
  command = command or msg
  command = command:lower()
  
  if command == "config" or command == "" then
    if ns.API.OpenOptions then ns.API.OpenOptions() end
  elseif command == "debug" then
    ns.devMode = not ns.devMode
    print("|cff00ccffArcUI|r Debug mode: " .. (ns.devMode and "|cff00ff00ON|r" or "|cffff6b6bOFF|r"))
  elseif command == "texinfo" then
    -- Print texture info for all bars
    local db = ns.db
    if db and db.profile and db.profile.bars then
      print("|cff00ccffArcUI|r Texture info for all bars:")
      for barNumber, barConfig in pairs(db.profile.bars) do
        if barConfig.tracking and barConfig.tracking.enabled then
          print(string.format("  Bar %d: iconTextureID=%s, spellID=%s",
            barNumber,
            tostring(barConfig.tracking.iconTextureID),
            tostring(barConfig.tracking.spellID)))
        end
      end
    end
  elseif command == "scan" then
    print("|cff00ccffArcUI|r Scanning tracked buffs...")
    local buffs, err = ns.API.ScanAvailableBuffs()
    if not buffs then
      print("|cff00ccffArcUI|r |cffff6b6bError:|r " .. (err or "Unknown"))
      return
    end
    if #buffs == 0 then
      print("|cff00ccffArcUI|r No buffs found")
      return
    end
    print("|cff00ccffArcUI|r Found " .. #buffs .. " buff(s):")
    for i, buff in ipairs(buffs) do
      local status = buff.isActive and "|cff00ff00(Active)|r" or "|cffaaaaaa(Inactive)|r"
      print(string.format("  %d. |cff00ff00%s|r %s", i, buff.buffName, status))
    end
  elseif command == "status" then
    local activeBars = ns.API.GetActiveBars()
    if #activeBars == 0 then
      print("|cff00ccffArcUI|r No active bars")
    else
      print("|cff00ccffArcUI|r Active bars:")
      for _, barNum in ipairs(activeBars) do
        local barConfig = ns.API.GetBarConfig(barNum)
        local state = GetBarState(barNum)
        print(string.format("  Bar %d: %s - %s", barNum, barConfig.tracking.buffName,
          state.active and "|cff00ff00Active|r" or "|cffaaaaaa(Inactive)|r"))
      end
    end
  elseif command == "dev" or command == "devmode" then
    ns.devMode = not ns.devMode
    print("|cff00ccffArcUI|r Dev Mode: " .. (ns.devMode and "|cff00ff00ON|r" or "|cffff6b6bOFF|r"))
  elseif command == "stackdebug" then
    ns.debugMode = not ns.debugMode
    print("|cff00ccffArcUI|r Stack Debug: " .. (ns.debugMode and "|cff00ff00ON|r (watch for debug output)" or "|cffff6b6bOFF|r"))
  elseif command == "dump" or command == "trackdebug" then
    -- Comprehensive debug dump for tracking issues
    print("|cff00ccff=== ArcUI Tracking Debug Dump ===|r")
    
    -- 1. Show all enabled bars with their cooldownIDs
    local db = ns.API.GetDB()
    if db and db.bars then
      print("|cffFFCC00[Enabled Bars]|r")
      for barNum = 1, 30 do
        local barConfig = db.bars[barNum]
        if barConfig and barConfig.tracking and barConfig.tracking.enabled then
          local state = GetBarState(barNum)
          local cdID = barConfig.tracking.cooldownID
          print(string.format("  Bar %d: cdID=%s, trackingOK=%s, cachedFrame=%s", 
            barNum, 
            tostring(cdID),
            tostring(state.trackingOK),
            state.cachedFrame and "YES" or "nil"))
          if state.cachedFrame then
            local frame = state.cachedFrame
            print(string.format("    frame.cooldownID=%s, frame._arcFreeCdID=%s, parent=%s",
              tostring(frame.cooldownID),
              tostring(frame._arcFreeCdID),
              frame:GetParent() and (frame:GetParent():GetName() or tostring(frame:GetParent())) or "nil"))
          end
        end
      end
    end
    
    -- 2. Show all frames in BuffIconCooldownViewer
    print("|cffFFCC00[BuffIconCooldownViewer Children]|r")
    local viewer = _G["BuffIconCooldownViewer"]
    if viewer then
      local children = {viewer:GetChildren()}
      for i, child in ipairs(children) do
        local cdID = child.cooldownID
        local arcFreeCdID = child._arcFreeCdID
        local info = cdID and type(cdID) == "number" and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        local spellName = info and info.spellID and C_Spell.GetSpellName(info.spellID)
        print(string.format("  %d: cdID=%s, _arcFreeCdID=%s, spell=%s",
          i, tostring(cdID), tostring(arcFreeCdID), spellName or "?"))
      end
    else
      print("  (viewer not found)")
    end
    
    -- 3. Show CDMEnhance tracking tables
    if ns.CDMEnhance then
      print("|cffFFCC00[CDMEnhance.enhancedFrames]|r")
      local enhanced = ns.CDMEnhance.GetEnhancedFrames and ns.CDMEnhance.GetEnhancedFrames()
      if enhanced then
        for cdID, data in pairs(enhanced) do
          local frame = data.frame
          local frameCdID = frame and frame.cooldownID
          local arcFreeCdID = frame and frame._arcFreeCdID
          local parent = frame and frame:GetParent()
          local parentName = parent and (parent:GetName() or tostring(parent)) or "nil"
          print(string.format("  cdID=%d: frame.cooldownID=%s, _arcFreeCdID=%s, parent=%s, viewerType=%s",
            cdID, tostring(frameCdID), tostring(arcFreeCdID), parentName, data.viewerType or "?"))
        end
      else
        print("  (nil)")
      end
      
      print("|cffFFCC00[CDMEnhance.freePositionFrames]|r")
      local freeFrames = ns.CDMEnhance.GetFreePositionFrames and ns.CDMEnhance.GetFreePositionFrames()
      if freeFrames then
        for cdID, frame in pairs(freeFrames) do
          local frameCdID = frame and frame.cooldownID
          local arcFreeCdID = frame and frame._arcFreeCdID
          local parent = frame and frame:GetParent()
          local parentName = parent and (parent:GetName() or tostring(parent)) or "nil"
          print(string.format("  cdID=%d: frame.cooldownID=%s, _arcFreeCdID=%s, parent=%s",
            cdID, tostring(frameCdID), tostring(arcFreeCdID), parentName))
        end
      else
        print("  (nil)")
      end
      
      -- 4. Show iconSettings with free position
      print("|cffFFCC00[Free Position Settings in DB]|r")
      local cdmDb = ns.CDMEnhance.GetDB and ns.CDMEnhance.GetDB()
      if cdmDb and cdmDb.iconSettings then
        for cdIDStr, settings in pairs(cdmDb.iconSettings) do
          if settings.position and settings.position.mode == "free" then
            local cdID = tonumber(cdIDStr)
            local info = cdID and type(cdID) == "number" and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
            local spellName = info and info.spellID and C_Spell.GetSpellName(info.spellID)
            print(string.format("  cdID=%s (%s): freeX=%.1f, freeY=%.1f",
              cdIDStr, spellName or "?",
              settings.position.freeX or 0, settings.position.freeY or 0))
          end
        end
      else
        print("  (no free position settings)")
      end
    else
      print("|cffFF6600[CDMEnhance not loaded]|r")
    end
    
    print("|cff00ccff=== End Debug Dump ===|r")
  else
    print("|cff00ccffArcUI|r Commands:")
    print("  /arcbars config - Open configuration")
    print("  /arcbars scan - Scan for tracked buffs")
    print("  /arcbars status - Show all active bars")
    print("  /arcbars dev - Toggle dev mode")
    print("  /arcbars stackdebug - Toggle stack tracking debug output")
    print("  /arcbars dump - Debug dump of tracking state")
  end
end

-- ===================================================================
-- CENTRALIZED CDM ICON SCANNER
-- Single source of truth for all CDM icon data
-- Scans all 4 viewers and provides unified API for all modules
-- v2.8.0: Consolidated from Catalog.lua and CDMEnhance.lua
-- ===================================================================
ns.CDMIcons = ns.CDMIcons or {}

-- Master icon catalog: { [cooldownID] = iconData }
local cdmIconCache = {}
local lastScanTime = 0

-- Viewer configuration
local CDM_VIEWERS = {
  { name = "BuffIconCooldownViewer", category = "TrackedBuff", viewerType = "aura", isAura = true },
  { name = "BuffBarCooldownViewer", category = "TrackedBar", viewerType = "aura", isAura = true },
  { name = "EssentialCooldownViewer", category = "Essential", viewerType = "cooldown", isAura = false },
  { name = "UtilityCooldownViewer", category = "Utility", viewerType = "utility", isAura = false },
}

-- Category display names
local CATEGORY_NAMES = {
  TrackedBuff = "Tracked Buffs",
  TrackedBar = "Tracked Bars",
  Essential = "Essential Cooldowns",
  Utility = "Utility Cooldowns",
  ["TrackedBuff+Bar"] = "Tracked Buffs + Bars",
}

-- ===================================================================
-- MASTER CDM SCANNER
-- Scans all CDM viewers and builds unified icon catalog
-- Also includes detached frames (moved to UIParent via free positioning)
-- ===================================================================
function ns.API.ScanAllCDMIcons()
  if InCombatLockdown() then
    if ns.devMode then
      print("|cffFF6600[ArcUI CDM]|r Scan skipped - in combat")
    end
    return 0
  end
  
  wipe(cdmIconCache)
  local totalCount = 0
  
  for _, viewerInfo in ipairs(CDM_VIEWERS) do
    local viewer = _G[viewerInfo.name]
    if viewer then
      local children = {viewer:GetChildren()}
      
      -- Sort by X position for consistent slot indexing
      table.sort(children, function(a, b)
        local ax = a:GetLeft() or 0
        local bx = b:GetLeft() or 0
        return ax < bx
      end)
      
      local slotIndex = 0
      for _, frame in ipairs(children) do
        -- Try multiple sources for cooldownID
        local cdID = frame.cooldownID
        
        -- Fallback 1: Check cooldownInfo table
        if not cdID and frame.cooldownInfo then
          cdID = frame.cooldownInfo.cooldownID
        end
        
        -- Fallback 2: For bar frames, check nested Icon frame
        if not cdID and frame.Icon and frame.Icon.cooldownID then
          cdID = frame.Icon.cooldownID
        end
        
        -- NO IsShown() filter - include ALL frames with cooldownID
        if cdID then
          -- Verify with CDM API that this cooldown actually exists
          local info = type(cdID) == "number" and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
          
          -- CRITICAL: If CDM API returns nil, this cooldown was removed - skip it
          if not info then
            -- Skip frames with no CDM info
          else
            slotIndex = slotIndex + 1
            
            -- Get spell info from API
            local spellID, name, icon
            local baseSpellID = info.spellID or 0
            local overrideSpellID = info.overrideSpellID
            local overrideTooltipSpellID = info.overrideTooltipSpellID
            local linkedSpellIDs = info.linkedSpellIDs
            local firstLinkedSpellID = linkedSpellIDs and linkedSpellIDs[1]
            
            -- Priority: first linkedSpellID > overrideSpellID > baseSpellID
            local displaySpellID = firstLinkedSpellID or overrideSpellID or baseSpellID
            
            spellID = baseSpellID
            name = displaySpellID and C_Spell.GetSpellName(displaySpellID)
            
            -- ICON PRIORITY: Read from frame first (shows actual CDM texture)
            -- Then fall back to API calls with smart ordering
            -- Icon viewers: frame.Icon:GetTexture() or frame.Icon:GetTextureFileID()
            -- Bar viewers: frame.Icon.Icon:GetTexture()
            -- NOTE: In combat, GetTexture() may return secret values - use issecretvalue() to check
            if frame.Icon then
              -- Try GetTexture first (returns path or ID)
              if frame.Icon.GetTexture then
                local tex = frame.Icon:GetTexture()
                -- Validate texture is actually set (not nil, not 0, not empty, not secret)
                if tex and not issecretvalue(tex) and tex ~= 0 and tex ~= "" then
                  icon = tex
                end
              end
              -- Try GetTextureFileID as fallback (returns numeric ID)
              if not icon and frame.Icon.GetTextureFileID then
                local texID = frame.Icon:GetTextureFileID()
                if texID and not issecretvalue(texID) and texID > 0 then
                  icon = texID
                end
              end
              -- Bar viewer structure: frame.Icon.Icon
              if not icon and frame.Icon.Icon then
                if frame.Icon.Icon.GetTexture then
                  local tex = frame.Icon.Icon:GetTexture()
                  if tex and not issecretvalue(tex) and tex ~= 0 and tex ~= "" then
                    icon = tex
                  end
                end
                if not icon and frame.Icon.Icon.GetTextureFileID then
                  local texID = frame.Icon.Icon:GetTextureFileID()
                  if texID and not issecretvalue(texID) and texID > 0 then
                    icon = texID
                  end
                end
              end
            end
            
            -- Fallback to API - try different spell ID sources
            -- For auras: CDM uses overrideTooltipSpellID for display
            -- For cooldowns: CDM uses the override/linked spell icon
            if not icon then
              if viewerInfo.isAura then
                -- Auras: try overrideTooltipSpellID first (this is what CDM uses for display)
                if overrideTooltipSpellID and overrideTooltipSpellID > 0 then
                  icon = C_Spell.GetSpellTexture(overrideTooltipSpellID)
                end
                -- Then try base spellID
                if not icon and baseSpellID > 0 then
                  icon = C_Spell.GetSpellTexture(baseSpellID)
                end
                if not icon and overrideSpellID then
                  icon = C_Spell.GetSpellTexture(overrideSpellID)
                end
                if not icon and displaySpellID then
                  icon = C_Spell.GetSpellTexture(displaySpellID)
                end
              else
                -- Cooldowns: use override/linked chain (existing logic)
                icon = displaySpellID and C_Spell.GetSpellTexture(displaySpellID)
                if not icon and overrideSpellID then
                  icon = C_Spell.GetSpellTexture(overrideSpellID)
                end
                if not icon and baseSpellID > 0 then
                  icon = C_Spell.GetSpellTexture(baseSpellID)
                end
              end
            end
            
            -- Fallbacks for name
            if not name and overrideSpellID then
              name = C_Spell.GetSpellName(overrideSpellID)
            end
            if not name and baseSpellID > 0 then
              name = C_Spell.GetSpellName(baseSpellID)
            end
          
            -- Check if already exists (for TrackedBuff+Bar case)
            local existing = cdmIconCache[cdID]
            if existing then
              -- Update category to show it's in both buff viewers
              if existing.category == "TrackedBuff" and viewerInfo.category == "TrackedBar" then
                existing.category = "TrackedBuff+Bar"
                existing.categoryName = CATEGORY_NAMES["TrackedBuff+Bar"]
                existing.isTrackedBar = true
                existing.barFrame = frame
              elseif existing.category == "TrackedBar" and viewerInfo.category == "TrackedBuff" then
                existing.category = "TrackedBuff+Bar"
                existing.categoryName = CATEGORY_NAMES["TrackedBuff+Bar"]
                existing.isTrackedBuff = true
                existing.iconFrame = frame
              end
            else
              -- Create new entry
              cdmIconCache[cdID] = {
                cooldownID = cdID,
                spellID = spellID or 0,
                name = name or "Unknown",
                icon = icon or 134400,
                category = viewerInfo.category,
                categoryName = CATEGORY_NAMES[viewerInfo.category] or viewerInfo.category,
                viewerType = viewerInfo.viewerType,
                viewerName = viewerInfo.name,
                isAura = viewerInfo.isAura,
                isTrackedBuff = viewerInfo.category == "TrackedBuff",
                isTrackedBar = viewerInfo.category == "TrackedBar",
                isEssential = viewerInfo.category == "Essential",
                isUtility = viewerInfo.category == "Utility",
                frame = frame,
                iconFrame = viewerInfo.category == "TrackedBuff" and frame or nil,
                barFrame = viewerInfo.category == "TrackedBar" and frame or nil,
                slotIndex = slotIndex,
                isDetached = false,
                -- API info
                hasAura = info.hasAura,
                selfAura = info.selfAura,
                charges = info.charges,
                flags = info.flags,
              }
              totalCount = totalCount + 1
            end
          
            -- Store slot index on frame for CDMEnhance
            frame._arcSlotIndex = slotIndex - 1
          end  -- end else (info exists)
        end  -- end if cdID
      end  -- end for frame
    end  -- end if viewer
  end  -- end for viewerInfo
  
  -- Include detached frames from CDMEnhance (frames moved to UIParent via free positioning)
  if ns.CDMEnhance and ns.CDMEnhance.GetDetachedFrames then
    local detached = ns.CDMEnhance.GetDetachedFrames()
    
    for cdID, data in pairs(detached) do
      if not cdmIconCache[cdID] then
        -- Get spell info from API
        local info = type(cdID) == "number" and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        
        -- CRITICAL: If CDM API returns nil, this cooldown was removed from CDM - skip it entirely
        if info then
          local spellID, name, icon
          local baseSpellID = info.spellID or 0
          local overrideSpellID = info.overrideSpellID
          local overrideTooltipSpellID = info.overrideTooltipSpellID
          local linkedSpellIDs = info.linkedSpellIDs
          local firstLinkedSpellID = linkedSpellIDs and linkedSpellIDs[1]
          local displaySpellID = firstLinkedSpellID or overrideSpellID or baseSpellID
          
          spellID = baseSpellID
          name = displaySpellID and C_Spell.GetSpellName(displaySpellID)
          
          -- Determine if this is an aura (for icon priority logic)
          local isAuraType = data.viewerType == "aura"
          
          -- ICON PRIORITY: Read from frame first (shows actual CDM texture)
          -- NOTE: In combat, GetTexture() may return secret values - use issecretvalue() to check
          local frame = data.frame
          if frame and frame.Icon then
            -- Try GetTexture first
            if frame.Icon.GetTexture then
              local tex = frame.Icon:GetTexture()
              if tex and not issecretvalue(tex) and tex ~= 0 and tex ~= "" then
                icon = tex
              end
            end
            -- Try GetTextureFileID as fallback
            if not icon and frame.Icon.GetTextureFileID then
              local texID = frame.Icon:GetTextureFileID()
              if texID and not issecretvalue(texID) and texID > 0 then
                icon = texID
              end
            end
            -- Bar viewer structure
            if not icon and frame.Icon.Icon then
              if frame.Icon.Icon.GetTexture then
                local tex = frame.Icon.Icon:GetTexture()
                if tex and not issecretvalue(tex) and tex ~= 0 and tex ~= "" then
                  icon = tex
                end
              end
            end
          end
          
          -- Fallback to API with aura-aware ordering
          if not icon then
            if isAuraType then
              -- Auras: try overrideTooltipSpellID first (this is what CDM uses for display)
              if overrideTooltipSpellID and overrideTooltipSpellID > 0 then
                icon = C_Spell.GetSpellTexture(overrideTooltipSpellID)
              end
              if not icon and baseSpellID > 0 then
                icon = C_Spell.GetSpellTexture(baseSpellID)
              end
              if not icon and overrideSpellID then
                icon = C_Spell.GetSpellTexture(overrideSpellID)
              end
              if not icon and displaySpellID then
                icon = C_Spell.GetSpellTexture(displaySpellID)
              end
            else
              -- Cooldowns: use override/linked chain
              icon = displaySpellID and C_Spell.GetSpellTexture(displaySpellID)
              if not icon and overrideSpellID then
                icon = C_Spell.GetSpellTexture(overrideSpellID)
              end
              if not icon and baseSpellID > 0 then
                icon = C_Spell.GetSpellTexture(baseSpellID)
              end
            end
          end
          
          -- Name fallbacks
          if not name and overrideSpellID then
            name = C_Spell.GetSpellName(overrideSpellID)
          end
          if not name and baseSpellID > 0 then
            name = C_Spell.GetSpellName(baseSpellID)
          end
        
          -- Determine category based on viewerType AND viewerName
          local category, isAura = "TrackedBuff", true
          if data.viewerType == "cooldown" then
            category = "Essential"
            isAura = false
          elseif data.viewerType == "utility" then
            category = "Utility"
            isAura = false
          elseif data.viewerType == "aura" then
            -- Check viewerName to distinguish TrackedBuff from TrackedBar
            if data.viewerName == "BuffBarCooldownViewer" then
              category = "TrackedBar"
            else
              category = "TrackedBuff"
            end
            isAura = true
          end
          
          cdmIconCache[cdID] = {
            cooldownID = cdID,
            spellID = spellID or 0,
            name = name or "Unknown",
            icon = icon or 134400,
            category = category,
            categoryName = CATEGORY_NAMES[category] or category,
            viewerType = data.viewerType,
            viewerName = data.viewerName,
            isAura = isAura,
            isTrackedBuff = category == "TrackedBuff",
            isTrackedBar = category == "TrackedBar",
            isEssential = category == "Essential",
            isUtility = category == "Utility",
            frame = data.frame,
            iconFrame = category == "TrackedBuff" and data.frame or nil,
            barFrame = category == "TrackedBar" and data.frame or nil,
            slotIndex = -1,  -- Detached frames don't have a slot index
            isDetached = true,
            hasAura = info.hasAura,
            selfAura = info.selfAura,
            charges = info.charges,
            flags = info.flags,
          }
          totalCount = totalCount + 1
        end  -- end if info
      end
    end
  end
  
  -- Include frames from CDMGroups (frames in group containers)
  if ns.CDMGroups and ns.CDMGroups.GetAllGroupedFrames then
    local groupedFrames = ns.CDMGroups.GetAllGroupedFrames()
    
    for cdID, data in pairs(groupedFrames) do
      -- Get spell info from API
      local info = type(cdID) == "number" and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
      
      if info then
        local spellID, name, icon
        local baseSpellID = info.spellID or 0
        local overrideSpellID = info.overrideSpellID
        local overrideTooltipSpellID = info.overrideTooltipSpellID
        local linkedSpellIDs = info.linkedSpellIDs
        local firstLinkedSpellID = linkedSpellIDs and linkedSpellIDs[1]
        local displaySpellID = firstLinkedSpellID or overrideSpellID or baseSpellID
        
        spellID = baseSpellID
        name = displaySpellID and C_Spell.GetSpellName(displaySpellID)
        
        -- Determine if this is an aura (for icon priority logic)
        local isAuraType = data.viewerType == "aura"
        
        -- ICON PRIORITY: Read from frame first (shows actual CDM texture)
        -- NOTE: In combat, GetTexture() may return secret values - use issecretvalue() to check
        local frame = data.frame
        if frame and frame.Icon then
          -- Try GetTexture first
          if frame.Icon.GetTexture then
            local tex = frame.Icon:GetTexture()
            if tex and not issecretvalue(tex) and tex ~= 0 and tex ~= "" then
              icon = tex
            end
          end
          -- Try GetTextureFileID as fallback
          if not icon and frame.Icon.GetTextureFileID then
            local texID = frame.Icon:GetTextureFileID()
            if texID and not issecretvalue(texID) and texID > 0 then
              icon = texID
            end
          end
          -- Bar viewer structure
          if not icon and frame.Icon.Icon then
            if frame.Icon.Icon.GetTexture then
              local tex = frame.Icon.Icon:GetTexture()
              if tex and not issecretvalue(tex) and tex ~= 0 and tex ~= "" then
                icon = tex
              end
            end
          end
        end
        
        -- Fallback to API with aura-aware ordering
        if not icon then
          if isAuraType then
            -- Auras: try overrideTooltipSpellID first (this is what CDM uses for display)
            if overrideTooltipSpellID and overrideTooltipSpellID > 0 then
              icon = C_Spell.GetSpellTexture(overrideTooltipSpellID)
            end
            if not icon and baseSpellID > 0 then
              icon = C_Spell.GetSpellTexture(baseSpellID)
            end
            if not icon and overrideSpellID then
              icon = C_Spell.GetSpellTexture(overrideSpellID)
            end
            if not icon and displaySpellID then
              icon = C_Spell.GetSpellTexture(displaySpellID)
            end
          else
            -- Cooldowns: use override/linked chain
            icon = displaySpellID and C_Spell.GetSpellTexture(displaySpellID)
            if not icon and overrideSpellID then
              icon = C_Spell.GetSpellTexture(overrideSpellID)
            end
            if not icon and baseSpellID > 0 then
              icon = C_Spell.GetSpellTexture(baseSpellID)
            end
          end
        end
        
        -- Name fallbacks
        if not name and overrideSpellID then
          name = C_Spell.GetSpellName(overrideSpellID)
        end
        if not name and baseSpellID > 0 then
          name = C_Spell.GetSpellName(baseSpellID)
        end
        
        -- Determine category based on viewerType
        local category, isAura = "TrackedBuff", true
        if data.viewerType == "cooldown" then
          category = "Essential"
          isAura = false
        elseif data.viewerType == "utility" then
          category = "Utility"
          isAura = false
        elseif data.viewerType == "aura" then
          category = "TrackedBuff"
          isAura = true
        end
        
        -- Update existing entry or create new one
        if cdmIconCache[cdID] then
          -- Update frame reference (it may have been reparented)
          cdmIconCache[cdID].frame = data.frame
          cdmIconCache[cdID].trackingType = "group"
          cdmIconCache[cdID].groupName = data.groupName
          cdmIconCache[cdID].gridPosition = data.gridPosition
        else
          cdmIconCache[cdID] = {
            cooldownID = cdID,
            spellID = spellID or 0,
            name = name or "Unknown",
            icon = icon or 134400,
            category = category,
            categoryName = CATEGORY_NAMES[category] or category,
            viewerType = data.viewerType,
            viewerName = data.originalViewerName,
            isAura = isAura,
            isTrackedBuff = category == "TrackedBuff",
            isTrackedBar = category == "TrackedBar",
            isEssential = category == "Essential",
            isUtility = category == "Utility",
            frame = data.frame,
            iconFrame = category == "TrackedBuff" and data.frame or nil,
            barFrame = category == "TrackedBar" and data.frame or nil,
            slotIndex = -1,
            isDetached = false,
            trackingType = "group",
            groupName = data.groupName,
            gridPosition = data.gridPosition,
            hasAura = info.hasAura,
            selfAura = info.selfAura,
            charges = info.charges,
            flags = info.flags,
          }
          totalCount = totalCount + 1
        end
      end
    end
  end
  
  lastScanTime = GetTime()
  -- A fresh CDM scan means frames may have been (re)created/repositioned —
  -- mark the cooldownID→frame index stale so the next lookup rebuilds it.
  InvalidateCDMIndex()

  if ns.devMode then
    local auraCount, cdCount, detachedCount = 0, 0, 0
    for _, data in pairs(cdmIconCache) do
      if data.isAura then auraCount = auraCount + 1 else cdCount = cdCount + 1 end
      if data.isDetached then detachedCount = detachedCount + 1 end
    end
    print(string.format("|cff00FF00[ArcUI CDM]|r Scan complete: %d auras, %d cooldowns (%d detached)", auraCount, cdCount, detachedCount))
  end
  
  -- Notify listeners that scan completed
  if ns.CDMEnhance and ns.CDMEnhance.OnCDMScanComplete then
    ns.CDMEnhance.OnCDMScanComplete()
  end
  if ns.Catalog and ns.Catalog.OnCDMScanComplete then
    ns.Catalog.OnCDMScanComplete()
  end
  
  return totalCount
end

-- ===================================================================
-- CDM ICON API - Unified access for all modules
-- ===================================================================

-- Get all CDM icons
function ns.API.GetAllCDMIcons()
  return cdmIconCache
end

-- Get single icon by cooldownID
function ns.API.GetCDMIcon(cooldownID)
  return cdmIconCache[cooldownID]
end

-- Get icon frame by cooldownID
function ns.API.GetCDMIconFrame(cooldownID)
  local data = cdmIconCache[cooldownID]
  return data and data.frame
end

-- Get all aura icons (BuffIcon + BuffBar viewers)
function ns.API.GetCDMAuraIcons()
  local result = {}
  for cdID, data in pairs(cdmIconCache) do
    if data.isAura then
      result[cdID] = data
    end
  end
  return result
end

-- Get all cooldown icons (Essential + Utility viewers)
function ns.API.GetCDMCooldownIcons()
  local result = {}
  for cdID, data in pairs(cdmIconCache) do
    if not data.isAura then
      result[cdID] = data
    end
  end
  return result
end

-- Get icons by category
function ns.API.GetCDMIconsByCategory(category)
  local result = {}
  for cdID, data in pairs(cdmIconCache) do
    if data.category == category or data.category == "TrackedBuff+Bar" and 
       (category == "TrackedBuff" or category == "TrackedBar") then
      result[cdID] = data
    end
  end
  return result
end

-- Get icons by viewer type ("aura", "cooldown", "utility")
function ns.API.GetCDMIconsByViewerType(viewerType)
  local result = {}
  for cdID, data in pairs(cdmIconCache) do
    if data.viewerType == viewerType then
      result[cdID] = data
    end
  end
  return result
end

-- Check if a cooldownID is displayed
function ns.API.IsCDMIconDisplayed(cooldownID)
  return cdmIconCache[cooldownID] ~= nil
end

-- Get displayed cooldownIDs (legacy compatibility)
function ns.API.GetDisplayedCooldownIDs()
  local displayed = {}
  for cdID, data in pairs(cdmIconCache) do
    displayed[cdID] = data.category
  end
  return displayed
end

-- Check if a specific cooldownID is displayed (in any viewer)
function ns.API.IsCooldownDisplayed(cooldownID)
  return cdmIconCache[cooldownID] ~= nil
end

-- Check if cooldownID is in Essential or Utility viewers
function ns.API.IsCooldownInEssentialOrUtility(cooldownID)
  local data = cdmIconCache[cooldownID]
  return data and (data.isEssential or data.isUtility)
end

-- Check if cooldownID is in TrackedBuff or TrackedBar viewers
function ns.API.IsAuraDisplayed(cooldownID)
  local data = cdmIconCache[cooldownID]
  return data and data.isAura
end

-- Get last scan time
function ns.API.GetCDMScanTime()
  return lastScanTime
end

-- Get sorted list of all icons (for options panels)
function ns.API.GetSortedCDMIcons(filterType)
  local sorted = {}
  for cdID, data in pairs(cdmIconCache) do
    local include = true
    if filterType == "aura" and not data.isAura then include = false end
    if filterType == "cooldown" and data.isAura then include = false end
    if filterType == "essential" and not data.isEssential then include = false end
    if filterType == "utility" and not data.isUtility then include = false end
    
    if include then
      table.insert(sorted, data)
    end
  end
  
  table.sort(sorted, function(a, b)
    return (a.name or "") < (b.name or "")
  end)
  
  return sorted
end

-- Get icon count by type
function ns.API.GetCDMIconCount()
  local auraCount, cooldownCount = 0, 0
  for _, data in pairs(cdmIconCache) do
    if data.isAura then
      auraCount = auraCount + 1
    else
      cooldownCount = cooldownCount + 1
    end
  end
  return auraCount, cooldownCount
end

-- Legacy compatibility aliases
ns.API.ScanCatalog = ns.API.ScanAllCDMIcons
ns.API.ScanCDM = ns.API.ScanAllCDMIcons

-- ===================================================================
-- INITIALIZATION
-- ===================================================================
local function InitializeTracking()
  if not ns.API.GetDB or not ns.API.GetBarConfig then
    C_Timer.After(0.5, InitializeTracking)
    return
  end
  if InCombatLockdown() then
    C_Timer.After(2.0, InitializeTracking)
    return
  end
  ns.API.ValidateAllBarTracking()
end

C_Timer.After(1.5, InitializeTracking)

-- ===================================================================
-- LIBPLEEBUG FUNCTION WRAPPING
-- Wrap heavy functions for CPU profiling
-- ===================================================================
if P then
  -- Config Lookups (called frequently)
  ns.API.GetBarConfig = P:Def("GetBarConfig", ns.API.GetBarConfig, "Config")
  ns.API.GetActiveBars = P:Def("GetActiveBars", ns.API.GetActiveBars, "Config")
  ns.API.GetActiveResourceBars = P:Def("GetActiveResourceBars", ns.API.GetActiveResourceBars, "Config")
  
  -- Tracking (RefreshAll wraps UpdateAllBars; it's the public API)
  if ns.API.RefreshAll then
    ns.API.RefreshAll = P:Def("RefreshAll", ns.API.RefreshAll, "Tracking")
  end
  ns.API.ValidateAllBarTracking = P:Def("ValidateAllBarTracking", ns.API.ValidateAllBarTracking, "Tracking")
end

-- ===================================================================
-- GLOBAL BRIDGE - Expose API for external debugger addons
-- ArcUI_Debugger is a separate addon with its own namespace,
-- it needs a global reference to access barStates, GetDB, etc.
-- ===================================================================
_G.ArcUI_API = ns.API
_G.ArcUI_Display = ns.Display

-- ===================================================================
-- FRAME REBIND SUBSCRIBER
--
-- Core caches CDM frame references in TWO places:
--   1. barStates[barNum].cachedFrame / cachedBarFrame  — per-bar source
--      frame for UpdateBarBuffInfo. When CDM repools (spec change, pet
--      summon, instance enter, etc.), the OLD frame's cooldownID becomes
--      nil; reads of cdmFrame.auraInstanceID return nil and the bar
--      shows wrong/no duration / wrong opacity. THIS IS the actual root
--      cause of the "bar loses visual" reports.
--   2. hookedAuraFrames[frame].barNumbers — bars subscribed to a frame's
--      events. When a frame is released (newCdID=nil), barNumbers entries
--      stay until the bar re-resolves and re-subscribes; meanwhile,
--      hooks fire on the released frame and try to update bars whose
--      cached frame may also be that dead one.
--
-- FrameController dispatches synchronously inside the SetCooldownID /
-- ClearCooldownID mixin hooks — same tick as the rebind. We invalidate
-- the per-bar caches AND clear the bar's registration on the rebinding
-- frame. The next UpdateAllBars cycle will re-resolve via
-- FindBuffFrameByCooldownID / FindBarFrameByCooldownID and re-register
-- via RegisterBarFrameHooks, picking up the new pool frame.
--
-- CPU cost: barStates iteration is bounded by max bar count (30). The
-- hookedAuraFrames lookup is O(1). Called only on actual rebinds, which
-- are rare events (login, spec change, talent change, instance enter,
-- vehicle exit, pet (un)summon).
-- ===================================================================
if ns.FrameController and ns.FrameController.OnFrameRebind then
  ns.FrameController.OnFrameRebind(function(frame, oldCdID, newCdID)
    if not frame then return end

    -- v3.7.2: a rebind changes this frame's cooldownID — drop the cached
    -- cooldownID→frame index. Affected bars below get cachedFrame=nil and
    -- re-resolve on their next update, where SetBarAuraMapping fixes their
    -- reverse-map entry.
    InvalidateCDMIndex()

    -- Invalidate any bar cache pointing at this frame so the next
    -- UpdateAllBars re-resolves against the live cdID → frame mapping.
    -- We only nil the pointers; we don't trigger an immediate re-resolve
    -- here because UpdateAllBars runs on its own cadence and CDMEnhance's
    -- 0.15s reconcile will follow up to refresh us anyway.
    for _barNum, state in pairs(barStates) do
      if state.cachedFrame == frame then
        state.cachedFrame = nil
        state.trackingOK = false
      end
      if state.cachedBarFrame == frame then
        state.cachedBarFrame = nil
        state.trackingOK = false
      end
    end

    -- Clear this frame's bar registrations. Stale entries would cause
    -- the released frame's hook callbacks (which still fire on any later
    -- aura event for whatever new cdID it gets bound to) to trigger
    -- UpdateBarBuffInfo for the wrong bar. The bars will re-register on
    -- their next UpdateAllBars cycle when they re-resolve.
    local hookData = hookedAuraFrames[frame]
    if hookData and hookData.barNumbers then
      wipe(hookData.barNumbers)
    end
  end)
end

-- ===================================================================
-- END OF ArcUI_Core.lua
-- ===================================================================
-- Register local functions for profiler visibility
if _G.ArcUIProfiler_RegisterLocals then
    _G.ArcUIProfiler_RegisterLocals("Core", {
        UpdateBarBuffInfo = UpdateBarBuffInfo,
        UpdateAllBars     = UpdateAllBars,
    })
end