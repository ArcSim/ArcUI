-- ===================================================================
-- ArcUI_CooldownReminder.lua
-- Cooldown Reminder module for ArcUI.
--
-- Architecture:
--   ns.CooldownReminder        - public API (pulse, test, apply)
--   ns.CooldownReminder.Engine - detection engine (self-contained)
--   ns.CooldownReminder.Log    - lightweight log buffer
--
-- DB lives at: ns.API.GetDB().cooldownReminder  (AceDB char scope)
-- Tooltip colour: ArcUI cyan #00ccff
--
-- DETECTION METHOD (shadow-frame binary):
--   Per-record dual Cooldown widget fed with duration objects:
--     SPELLS:
--       cdWidget     ← C_Spell.GetSpellCooldownDuration(sid, true)
--       chargeWidget ← C_Spell.GetSpellChargeDuration(sid, true)
--     ITEMS (unified INV path, research-proven via ArcUI_CDMItemShadowTest):
--       cdWidget     ← reusable durObj from:
--                        equipped in slot 13/14: GetInventoryItemCooldown
--                        bag item              : C_Container.GetItemCooldown
--                      wrapped via C_DurationUtil.CreateDuration +
--                      SetTimeFromStart(start, duration)
--       chargeWidget ← always cleared (items don't have spell-style charges)
--   State derived from IsShown() on both widgets:
--     !main & !charge  → READY
--     main & !charge   → ON_COOLDOWN
--     !main & charge   → RECHARGING (charge avail)
--     main & charge    → DEPLETED (all charges gone)
--   Pulse fires on transition into a "charge available" state from a
--   "not available" state. OnCooldownDone on each widget drives the ready
--   transition naturally — no polling, no debounce, no isActive heuristic.
--
-- WHY INV PATH (items): the spell-cooldown API applied to an item's
-- use-spell LIES for equipped trinkets during the 20-30s shared-slot-CD
-- window (reports shared CD instead of real multi-minute item CD). The
-- raw C_Item.GetItemCooldownDuration API was empirically dead for equipped
-- trinkets. Only GetInventoryItemCooldown/C_Container.GetItemCooldown
-- report the truthful cooldown in every scenario tested (fresh use,
-- shared-slot CD, swap CD, bag consumables, pre-existing CD at startup).
--
-- ITEM RESET EVENTS: ENCOUNTER_END, PLAYER_REGEN_ENABLED,
-- CHALLENGE_MODE_START/RESET, ARENA_OPPONENT_UPDATE handle Blizzard-side
-- cooldown resets (boss kills, combat end, keys, arena). PLAYER_EQUIPMENT_
-- CHANGED re-detects the slot when trinkets move bag↔slot13↔slot14.
-- PLAYER_EQUIPED_SPELLS_CHANGED is per-record 0.1s debounced (Blizzard
-- fires it ~24 times per swap).
-- ===================================================================

local ADDON, ns = ...
ns.CooldownReminder = ns.CooldownReminder or {}
local CR = ns.CooldownReminder

-- ===================================================================
-- TOOLTIP COLOUR (ArcUI cyan)
-- ===================================================================
CR.TOOLTIP_R = 0.0
CR.TOOLTIP_G = 0.8
CR.TOOLTIP_B = 1.0  -- #00ccff

-- ===================================================================
-- DB DEFAULTS  (merged into char DB at init)
-- ===================================================================
local DB_DEFAULTS = {
    enabled          = false,   -- opt-in
    whitelist        = {},
    size             = 64,
    iconOpacity      = 1,
    point            = "CENTER",
    relPoint         = "CENTER",
    x                = 0,
    y                = 120,
    pulseDuration    = 1.00,
    animStyle        = "fade",  -- global default animation; per-trigger animStyle overrides
    -- Per-style animation parameters. Each affects the entrance phase
    -- only — the trailing fade (or the holding period for "no_fade") is
    -- always pulseDuration minus the entrance time. All defaults match
    -- the original baked-in values so behavior is unchanged unless the
    -- user adjusts these sliders.
    animFadeSmoothing = "OUT",  -- fade-out smoothing curve: NONE/OUT/IN/IN_OUT
    animFlashSpeed   = 0.10,    -- seconds per flash step (4 steps fixed)
    animZoomStart    = 0.70,    -- starting scale for the pop-in
    animZoomPeak     = 1.15,    -- overshoot scale at end of phase 1
    animZoomPopTime  = 0.12,    -- seconds for phase 1 (pop)
    animZoomSettleTime = 0.08,  -- seconds for phase 2 (settle to 1.0)
    iconEnabled      = true,    -- show the pulsing icon on ready
    soundName        = "Default",
    soundChannel     = "Master",
    fallbackSoundKitID = 12867,
    soundEnabled     = true,    -- play sound/TTS on ready
    cutoffPreviousSound = false, -- when ON: a new alert sound stops the previous one
    cutoffFadeTime   = 0.1,     -- seconds of fade-out applied when cutting off (smoother than a hard cut)
    spellSounds      = {},      -- per-spell sound name override
    spellTTS         = {},      -- per-spell TTS text; takes priority over sound when set
    spellIconDisabled = {},     -- per-spell: when true, skip the pulse icon for this spell (sound/TTS only)
    spellSoundDisabled = {},    -- per-spell: when true, skip sound/TTS for this spell (icon only)
    spellDelayMode     = {},    -- per-spell: "off" | "afterCast" | "afterReady"
    spellDelaySeconds  = {},    -- per-spell: seconds for the delayed reminder
    ttsVoiceOverride = "default", -- "default" (WoW TTS setting), "male", or "female"
    ttsRateOverride  = nil,     -- nil = use WoW TTS setting, otherwise -10..10
    locked           = true,
    sortByName       = true,
    noOverlapAlerts  = true,    -- legacy (kept for migration); use queueMode
    queueMode        = "queue", -- "replace" / "queue" / "stack"
    stackDirection   = "right", -- "left" / "right"
    stackSpacing     = 4,       -- px between stacked icons
    replaceGuard     = 0.4,     -- minimum seconds a "replace" pulse must stay on screen before it can be replaced by a newer one
    queueMaxLen      = 3,       -- max queued alerts in "queue" mode
    queueInterDelay  = 0,       -- seconds of gap between queue-drain pulses (0 = back-to-back)
    cancelOnCast     = true,    -- kill a visible pulse immediately when the spell is cast
    enabledInWorld   = true,
    enabledInDungeons = true,
    enabledInRaids   = true,
    enabledInArena   = true,
    debug            = false,
    learnedGates     = {},
    showSpellIDsInTooltips = false,
    classFilterEnabled = false,
}

local function GetDB()
    local charDB = ns.API and ns.API.GetDB and ns.API.GetDB()
    if not charDB then return nil end
    if not charDB.cooldownReminder then
        charDB.cooldownReminder = {}
    end
    local db = charDB.cooldownReminder
    for k, v in pairs(DB_DEFAULTS) do
        if db[k] == nil then
            db[k] = type(v) == "table" and {} or v
        end
    end
    -- Normalise numeric keys to string keys
    if db.whitelist then
        for k, val in pairs(db.whitelist) do
            if type(k) == "number" then
                local sk = tostring(k)
                if db.whitelist[sk] == nil then db.whitelist[sk] = val end
                db.whitelist[k] = nil
            end
        end
    end
    if db.spellSounds then
        for k, val in pairs(db.spellSounds) do
            if type(k) == "number" then
                local sk = tostring(k)
                if db.spellSounds[sk] == nil then db.spellSounds[sk] = val end
                db.spellSounds[k] = nil
            end
        end
    end
    if db.spellTTS then
        for k, val in pairs(db.spellTTS) do
            if type(k) == "number" then
                local sk = tostring(k)
                if db.spellTTS[sk] == nil then db.spellTTS[sk] = val end
                db.spellTTS[k] = nil
            end
        end
    end
    if db.spellIconDisabled then
        for k, val in pairs(db.spellIconDisabled) do
            if type(k) == "number" then
                local sk = tostring(k)
                if db.spellIconDisabled[sk] == nil then db.spellIconDisabled[sk] = val end
                db.spellIconDisabled[k] = nil
            end
        end
    end
    if db.spellSoundDisabled then
        for k, val in pairs(db.spellSoundDisabled) do
            if type(k) == "number" then
                local sk = tostring(k)
                if db.spellSoundDisabled[sk] == nil then db.spellSoundDisabled[sk] = val end
                db.spellSoundDisabled[k] = nil
            end
        end
    end
    if db.spellDelayMode then
        for k, val in pairs(db.spellDelayMode) do
            if type(k) == "number" then
                local sk = tostring(k)
                if db.spellDelayMode[sk] == nil then db.spellDelayMode[sk] = val end
                db.spellDelayMode[k] = nil
            end
        end
    end
    if db.spellDelaySeconds then
        for k, val in pairs(db.spellDelaySeconds) do
            if type(k) == "number" then
                local sk = tostring(k)
                if db.spellDelaySeconds[sk] == nil then db.spellDelaySeconds[sk] = val end
                db.spellDelaySeconds[k] = nil
            end
        end
    end
    if type(db.learnedGates) ~= "table" then db.learnedGates = {} end
    -- One-time migration from legacy noOverlapAlerts bool to queueMode string.
    -- If queueMode is missing but noOverlapAlerts is present, translate:
    --   noOverlapAlerts=true  -> "queue"
    --   noOverlapAlerts=false -> "replace"
    if db.queueMode == nil then
        if db.noOverlapAlerts == false then
            db.queueMode = "replace"
        else
            db.queueMode = "queue"
        end
    end
    return db
end
CR.GetDB = GetDB

-- ===================================================================
-- SPELL / ITEM NAME CACHES
-- ===================================================================
local _spellNameCache = {}
local function GetSpellNameCached(spellID)
    if not spellID then return nil end
    if _spellNameCache[spellID] then return _spellNameCache[spellID] end
    if C_Spell and C_Spell.GetSpellName then
        local name = C_Spell.GetSpellName(spellID)
        if name then _spellNameCache[spellID] = name; return name end
    end
    local fb = tostring(spellID)
    _spellNameCache[spellID] = fb
    return fb
end
CR.GetSpellNameCached = GetSpellNameCached

local _itemNameCache = {}
local function GetItemNameCached(itemID)
    if not itemID then return nil end
    if _itemNameCache[itemID] then return _itemNameCache[itemID] end
    if C_Item and C_Item.GetItemNameByID then
        local name = C_Item.GetItemNameByID(itemID)
        if name and name ~= "" then
            _itemNameCache[itemID] = name
            return name
        end
    end
    if Item and Item.CreateFromItemID then
        local item = Item:CreateFromItemID(itemID)
        if item then
            item:ContinueOnItemLoad(function()
                local n = item:GetItemName()
                if n and n ~= "" then
                    _itemNameCache[itemID] = n
                    if CR.RefreshOptionsRows then CR.RefreshOptionsRows() end
                end
            end)
        end
    end
    return nil
end
CR.GetItemNameCached = GetItemNameCached

local function ParseItemID(input)
    if not input then return nil end
    local id = tonumber(input)
    if id and id > 0 then return id end
    if type(input) == "string" then
        local linkID = input:match("item:(%d+)")
        if linkID then
            id = tonumber(linkID)
            if id and id > 0 then return id end
        end
    end
    return nil
end
CR.ParseItemID = ParseItemID

-- Accepts a numeric spell ID, a spell hyperlink (|Hspell:123|h...), or a plain
-- number pasted from Wowhead/etc. Symmetric with ParseItemID.
local function ParseSpellID(input)
    if not input then return nil end
    local id = tonumber(input)
    if id and id > 0 then return id end
    if type(input) == "string" then
        local linkID = input:match("spell:(%d+)")
        if linkID then
            id = tonumber(linkID)
            if id and id > 0 then return id end
        end
    end
    return nil
end
CR.ParseSpellID = ParseSpellID

-- ===================================================================
-- LOG MODULE
-- ===================================================================
local Log = {}
CR.Log = Log
Log.MAX_ENTRIES = 2000
Log.entries = {}
Log._seq = 0
Log.filterSpellID = nil
Log.filterText = nil

local function safeString(v)
    if v == nil then return "" end
    -- issecretvalue is the 12.0.1+ native check for Midnight secret values.
    -- Any value flagged as secret is unsafe to print/concat — return a
    -- sentinel instead of attempting tostring on it.
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    local tv = type(v)
    if tv == "string"  then return v end
    if tv == "number"  then return tostring(v) end
    if tv == "boolean" then return v and "true" or "false" end
    return tostring(v)
end

function Log:IsDebugEnabled()
    local db = GetDB()
    return db and db.debug or false
end

function Log:Write(level, spellID, msg)
    level = level or "INFO"
    if not self:IsDebugEnabled() and (level == "DEBUG" or level == "TRACE") then return end
    self._seq = self._seq + 1
    self.entries[#self.entries + 1] = {
        time = GetTime(), seq = self._seq, level = level,
        spellID = spellID, msg = safeString(msg),
    }
    while #self.entries > self.MAX_ENTRIES do table.remove(self.entries, 1) end
    -- Forward DEBUG/TRACE entries to the active _debugTrace consumer
    -- (e.g. ArcUI_CRDebugger) so external tracers can see queue/replace/
    -- proc/glow events without the engine having to dual-instrument every
    -- log call. The debugger filters on spellID itself.
    if CR._debugTrace and (level == "DEBUG" or level == "TRACE") then
        CR._debugTrace(level, spellID, safeString(msg))
    end
end

function Log:WriteAlways(level, spellID, msg)
    level = level or "INFO"
    if (level == "DEBUG" or level == "TRACE") and not self:IsDebugEnabled() then return end
    self:Write(level, spellID, msg)
end

function Log:Clear() wipe(self.entries); self._seq = 0 end

-- ===================================================================
-- ENGINE
-- ===================================================================
local Engine = {}
CR.Engine = Engine

local KIND_COOLDOWN = "CD"
local KIND_CHARGE   = "CHARGE"
local BIND_TIMEOUT_SECONDS       = 60
local INIT_GRACE_PERIOD          = 2.0
local CHARGE_NATURAL_PULSE_WINDOW = 0.25
--[[ DISABLED: legacy aura-gate system. Our isActive-based
     detection doesn't have the "buff window fires false ready" problem the
     gate was solving, so this entire subsystem is dead weight. Commented out
     rather than deleted — the self-learning logic (detect spell→aura pairing
     within 0.35s) is worth reviving for future features.
local AURA_DETECTION_WINDOW      = 0.35
local GATE_REOPEN_DELAY          = 0.8
local GATE_DEFER_PULSE           = "defer_pulse"
local GATE_AFTER_AURA            = "after_aura"
--]]

Engine.records       = {}
Engine.spellIDToRecord = {}

-- ===================================================================
-- PROC GLOW TRACKING (Spell Activation Overlay)
-- ===================================================================
-- Tracks which spellIDs currently have a proc glow / spell activation
-- overlay active. Driven by SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE
-- events (the action-button overlay events — same ones CDMEnhance hooks
-- to drive its proc glow visuals).
-- Used by the per-trigger "Only fire when proc is active" gate so a
-- reminder trigger can be conditioned on the spell being procced.
--
-- Map shape: Engine.activeProcs[spellID] = true | nil  (NEVER false —
-- absence of key means no proc, presence with true means proc active).
-- spellIDs from SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE are non-secret
-- per the WoW 12.0 secret-value rules (same as event arg payloads).
Engine.activeProcs = Engine.activeProcs or {}

function Engine:OnSpellActivationOverlayShow(spellID)
    spellID = tonumber(spellID)
    if not spellID then return end
    local wasActive = self.activeProcs[spellID] == true
    self.activeProcs[spellID] = true
    Log:Write("DEBUG", spellID, "PROC ON")
    -- Don't re-fire on duplicate SHOW events for the same proc cycle.
    -- (Blizzard occasionally fires _GLOW_SHOW twice for the same proc.)
    if wasActive then return end
    -- Walk tracked records and fire any on_proc triggers for records
    -- whose proc-source spell matches this event's spellID. For items,
    -- the proc-source is the item's resolved use-spell.
    if not self.records then return end
    for _, rec in pairs(self.records) do
        local procSid = rec.isItem and rec._useSpellID or rec.spellID
        if procSid == spellID then
            local triggers = self:_GetTriggerArray(rec)
            if triggers then
                for i = 1, #triggers do
                    local t = triggers[i]
                    if t.type == "on_proc" then
                        self:_FireTrigger(rec, t, "proc")
                    end
                end
            end
        end
    end
end

function Engine:OnSpellActivationOverlayHide(spellID)
    spellID = tonumber(spellID)
    if not spellID then return end
    self.activeProcs[spellID] = nil
    Log:Write("DEBUG", spellID, "PROC OFF")
end

-- Is the proc glow currently active for the spell tied to this record?
-- For spell records: checks rec.spellID. For item records: checks the
-- item's use-spell ID (rec._useSpellID). Returns true ONLY if a proc
-- entry exists for that spell. Items without a use-spell return false.
function Engine:_IsProcActiveForRecord(rec)
    if not rec then return false end
    local sid
    if rec.isItem then
        sid = rec._useSpellID
    else
        sid = rec.spellID
    end
    if not sid then return false end
    return self.activeProcs[sid] == true
end

local function safeSpellID(id) local n = tonumber(id); return (n and n > 0) and n or nil end
local function safeItemID(id)  local n = tonumber(id); return (n and n > 0) and n or nil end
local function getSpellName(id) return GetSpellNameCached(id) end
local function getItemName(id)  return GetItemNameCached(id) or tostring(id) end

-- ===================================================================
-- Small helpers (no pcalls — all fields read are non-secret)
-- ===================================================================

local function spellHasCharges(spellID)
    if not spellID then return false end
    if not C_Spell or not C_Spell.GetSpellCharges then return false end
    local info = C_Spell.GetSpellCharges(spellID)
    return info ~= nil
end

-- A "real" charge spell has maxCharges > 1. maxCharges is NON-SECRET per
-- 12.0.1. Pcall not needed — a false positive from a single-charge spell
-- (where maxCharges might briefly be nil at load) is self-correcting when
-- the shadow feed reads zero-span for GetSpellChargeDuration.
local function isRealChargeSpell(spellID)
    if not spellID then return false end
    if C_Spell and C_Spell.GetSpellCharges then
        local info = C_Spell.GetSpellCharges(spellID)
        if info and info.maxCharges and info.maxCharges > 1 then return true end
    end
    if C_Spell and C_Spell.GetSpellCooldown then
        local cdi = C_Spell.GetSpellCooldown(spellID)
        if cdi and cdi.maxCharges and cdi.maxCharges > 1 then return true end
    end
    return false
end

local function getItemCooldownDurationObject(itemID)
    if not itemID then return nil end
    if C_Item and C_Item.GetItemCooldownDuration then
        return C_Item.GetItemCooldownDuration(itemID)
    end
    return nil
end

-- ===================================================================
-- ITEM-PATH HELPERS  (proven unified INV detection — see research)
-- ===================================================================
-- Research (ArcUI_CDMItemShadowTest) proved the inventory-cooldown path is
-- authoritative for ALL items, where:
--   - equipped trinket (slot 13/14): GetInventoryItemCooldown("player", slot)
--   - bag item                     : C_Container.GetItemCooldown(itemID)
-- Wrapped into a reusable DurationObject via C_DurationUtil.CreateDuration
-- so we can feed it to a shadow Cooldown widget.
--
-- The spell-cooldown path (C_Spell.GetSpellCooldownDuration on the use-spell)
-- LIES for equipped trinkets during the shared-slot-CD window (reports 20s
-- instead of the real multi-minute CD). The raw item-durObj path
-- (C_Item.GetItemCooldownDuration) was empirically dead for equipped
-- trinkets. INV works for both scenarios.

-- Use-spell ID cache keyed by itemID. Non-secret (GetItemSpell returns the
-- use-spell or nil for passive items). Populated lazily in ResolveItemUseSpell.
local _itemUseSpellCache = {}

local function ResolveItemUseSpell(itemID)
    if not itemID then return nil end
    local cached = _itemUseSpellCache[itemID]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    local _, spellID = GetItemSpell(itemID)
    spellID = tonumber(spellID)
    _itemUseSpellCache[itemID] = spellID or false
    return spellID
end
CR._ResolveItemUseSpell = ResolveItemUseSpell

-- Detect whether the item is currently equipped in trinket slot 13 or 14.
-- Non-secret (inventory queries on the player unit). Returns slot or nil.
local function DetectEquippedSlot(itemID)
    if not itemID then return nil end
    if GetInventoryItemID("player", 13) == itemID then return 13 end
    if GetInventoryItemID("player", 14) == itemID then return 14 end
    return nil
end
CR._DetectEquippedSlot = DetectEquippedSlot

-- Feed a record's cdWidget from the authoritative INV path:
--   equipped in slot  → GetInventoryItemCooldown("player", slot)
--   bag item          → C_Container.GetItemCooldown(itemID)
-- Writes into rec._invDurObj (per-record reusable durObj, created lazily)
-- and calls SetCooldownFromDurationObject on cdWidget. Clears cdWidget when
-- duration is zero (item is ready).
--
-- GCD FILTER: The INV APIs return GCD duration (~1-1.5s) when the item-use
-- triggered a GCD and the real item CD hasn't started reporting yet, or when
-- the item has a pre-effect windup phase (like Algar Puzzle Box's triangle).
-- Without filtering, the widget expires after 1s → _OnTimerComplete fires →
-- _EmitPulse fires → user hears a false "ready" sound every time they use
-- the item (sometimes TWICE if the trinket has multiple windup phases).
--
-- Filter rule: any reported duration under ITEM_MIN_REAL_CD_SECONDS is
-- treated as GCD/windup noise and cleared. GCD caps at 1.5s (unhasted);
-- real item cooldowns are always much longer (trinkets ≥ 30s, potions ≥ 60s,
-- shared trinket slot ≥ 20s). This matches the CooldownPanels / ArcAuras
-- approach (they do the same effective filter, just via matching
-- gcdInfo.startTime/duration).
local ITEM_MIN_REAL_CD_SECONDS = 1.5

local function FeedItemInvShadow(rec)
    if not rec or not rec.itemID or not rec.cdWidget then return end

    -- Lazy-create per-record reusable durObj
    if not rec._invDurObj and C_DurationUtil and C_DurationUtil.CreateDuration then
        rec._invDurObj = C_DurationUtil.CreateDuration()
    end

    local startTime, duration
    if rec._equippedSlot then
        startTime, duration = GetInventoryItemCooldown("player", rec._equippedSlot)
    elseif C_Container and C_Container.GetItemCooldown then
        startTime, duration = C_Container.GetItemCooldown(rec.itemID)
    end
    startTime = startTime or 0
    duration  = duration  or 0

    -- Short-duration filter: anything below the real-CD threshold is GCD
    -- or windup noise. Treat as ready (Clear widget). When the real CD
    -- eventually starts, a subsequent BAG_UPDATE_COOLDOWN will re-feed
    -- with the actual long duration and we'll pick it up correctly.
    if duration > 0 and duration <= ITEM_MIN_REAL_CD_SECONDS then
        rec.cdWidget:Clear()
        rec._invLastEndTime = nil
        return
    end

    if rec._invDurObj and duration > 0 then
        -- Real cooldown reading. Stamp the projected end time so we can
        -- detect false-zero readings later (zone transitions, loading
        -- screens, brief data unavailability after combat). The end time
        -- is non-secret arithmetic on non-secret API outputs.
        rec._invDurObj:SetTimeFromStart(startTime, duration)
        rec.cdWidget:SetCooldownFromDurationObject(rec._invDurObj, true)
        rec._invLastEndTime = (startTime or 0) + duration
    else
        -- API reports duration == 0. This is normally "the item is ready"
        -- — but during zone transitions / loading screens, the inventory
        -- API momentarily returns 0 even when the real cooldown is still
        -- ticking. Without protection, the widget would clear, IsShown()
        -- would flip true→false, and _EvaluateRecord would interpret the
        -- transition as a ready event and fire a spurious pulse.
        --
        -- Guard: if we previously saw a real cooldown that hasn't reached
        -- its projected end yet, distrust the zero reading. Keep the
        -- widget's existing state intact. A subsequent BAG_UPDATE_COOLDOWN
        -- after the loading screen finishes will re-feed with the real
        -- remaining duration. If the cooldown HAS legitimately ended (we
        -- passed the projected end time), clear normally.
        local lastEnd = rec._invLastEndTime
        if lastEnd and GetTime() < lastEnd then
            -- False zero during a real cooldown — keep widget as-is.
            -- Don't touch cdWidget; don't clear _invLastEndTime.
            Log:Write("DEBUG", rec.spellID,
                "FeedItemInvShadow: false-zero during cooldown, keeping widget")
            return
        end
        rec.cdWidget:Clear()
        rec._invLastEndTime = nil
    end
end
CR._FeedItemInvShadow = FeedItemInvShadow

-- Timer widget factory
local function CreateTimerWidget(rec, kind)
    local widget = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
    widget:SetSize(1, 1)
    widget:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -100, -100)
    widget:SetAlpha(0)
    widget:EnableMouse(false)
    widget:SetHideCountdownNumbers(true)
    widget:SetDrawEdge(false)
    widget:SetDrawBling(false)
    widget:Show()
    widget._rec = rec
    widget._kind = kind
    widget._bindToken = nil
    widget:SetScript("OnCooldownDone", function(w) Engine:_OnTimerComplete(w) end)
    return widget
end

--[[ DISABLED with aura-gate system.
local function UpdateEffectiveReadiness(rec, reason)
    if not rec.gateAuraSpellID and not rec.gateMode then return end
    local gateOpen = rec.gateOpen and true or false
    rec.lastGateOpen = gateOpen
    if rec.gateMode == GATE_AFTER_AURA then return end
    local cooldownReady = rec.lastCooldownReady and true or false
    local nowReady  = cooldownReady and gateOpen
    local wasReady  = rec.lastEffectiveReady
    if wasReady ~= nowReady then
        rec.lastEffectiveReady = nowReady
        if Engine._enabled and (wasReady == false or wasReady == nil) and nowReady == true then
            Engine:_EmitPulse(rec.spellID, KIND_COOLDOWN, "aura ended", rec.isItem)
        end
    end
end
--]]
-- Stub so commented-out aura-gate call sites don't error if uncommented.
local function UpdateEffectiveReadiness(rec, reason) end

-- ===================================================================
-- SHADOW-FRAME DETECTION CORE
-- Single source of truth: feed both widgets with ignoreGCD=true durObjs,
-- read IsShown() on each, classify the (main, charge) bool pair.
--
-- State grid:
--   (false, false) → READY         (fully castable, stop watching)
--   (true,  false) → ON_COOLDOWN   (normal spell on real CD)
--   (false, true ) → RECHARGING    (charge spell, at least 1 charge avail)
--   (true,  true ) → DEPLETED      (charge spell, all charges gone)
--
-- Pulse fires on transition INTO a charge-available state (READY or
-- RECHARGING) FROM a not-available state (ON_COOLDOWN or DEPLETED).
-- OnCooldownDone on each widget fires naturally when the timer expires;
-- SPELL_UPDATE_COOLDOWN / SPELL_UPDATE_CHARGES also trigger a re-feed
-- to catch talent CDR / proc resets.
-- ===================================================================

-- Feed both shadow widgets from the spell's duration objects.
-- ignoreGCD=true ensures GCD contamination is stripped at the source —
-- the widget's IsShown() reflects only real cooldown / real recharge state.
function Engine:_FeedRecordShadows(rec)
    if not rec then return end

    local cdWidget     = rec.cdWidget
    local chargeWidget = rec.chargeWidget
    if not cdWidget or not chargeWidget then return end

    -- Items: feed cdWidget from the INV path (equipped slot or container).
    -- Charge widget stays cleared (items don't have charges in the
    -- spell-system sense; charge-based items like Healthstone are handled
    -- by PLAYER_EQUIPED_SPELLS_CHANGED + BAG_UPDATE_COOLDOWN triggers).
    if rec.isItem then
        FeedItemInvShadow(rec)
        chargeWidget:Clear()
        return
    end

    -- Spells: feed both widgets with ignoreGCD=true durObjs.
    -- Use rec.spellID — the canonical tracked spell. That's the ONLY spell
    -- we care about; the user entered this ID, nothing else.
    local spellID = rec.spellID
    if not spellID then return end

    if C_Spell.GetSpellCooldownDuration then
        local dur = C_Spell.GetSpellCooldownDuration(spellID, true)
        if dur then
            cdWidget:SetCooldownFromDurationObject(dur, true)
        else
            cdWidget:Clear()
        end
    end

    if C_Spell.GetSpellChargeDuration then
        local dur = C_Spell.GetSpellChargeDuration(spellID, true)
        if dur then
            chargeWidget:SetCooldownFromDurationObject(dur, true)
        else
            chargeWidget:Clear()
        end
    end
end

-- Read IsShown() on both widgets and classify to a state name.
local function _ClassifyShadowState(mainShown, chargeShown)
    if not mainShown and not chargeShown then return "READY"       end
    if     mainShown and not chargeShown then return "ON_COOLDOWN" end
    if not mainShown and     chargeShown then return "RECHARGING"  end
    return "DEPLETED"
end

-- Single evaluator replacing _EvaluateChargeState and _EvaluateNormalSpell.
-- Called from every trigger (SPELL_UPDATE_COOLDOWN, SPELL_UPDATE_CHARGES,
-- widget OnCooldownDone). Always feeds shadows first then reads state.
function Engine:_EvaluateRecord(rec, source)
    if not rec or not rec.watchToken then return end

    self:_FeedRecordShadows(rec)

    local mainShown   = rec.cdWidget     and rec.cdWidget:IsShown()     or false
    local chargeShown = rec.chargeWidget and rec.chargeWidget:IsShown() or false
    local state       = _ClassifyShadowState(mainShown, chargeShown)
    local lastState   = rec._lastShadowState
    rec._lastShadowState = state

    if CR._debugTrace then
        CR._debugTrace("SHADOW_EVAL", rec.spellID, string.format(
            "src=%s state=%s last=%s main=%s charge=%s",
            tostring(source), state, tostring(lastState),
            tostring(mainShown), tostring(chargeShown)))
    end

    -- Pulse trigger: transition into a charge-available state from a
    -- not-available state. Charge-available = READY or RECHARGING
    -- (RECHARGING means at least 1 charge is usable). Not-available =
    -- ON_COOLDOWN or DEPLETED.
    local nowAvailable  = (state == "READY" or state == "RECHARGING")
    local wasUnavailable = (lastState == "ON_COOLDOWN" or lastState == "DEPLETED")

    -- RESET LATCH on transitions BACK to unavailable. Without this, a single
    -- watch session could only fire ONE ready-pulse — but real spells can
    -- legitimately go through multiple available→unavailable→available
    -- cycles within one watch session. Crash Lightning is the canonical
    -- example: cast → ON_COOLDOWN → proc gives a temp 2nd charge so state
    -- briefly flips to RECHARGING (fires the proc reminder, sets latch),
    -- then user consumes the proc → state goes back to ON_COOLDOWN →
    -- finally the original CD ends → state goes to READY. Without resetting
    -- the latch on the RECHARGING → ON_COOLDOWN transition, the final READY
    -- transition is blocked because _readyPulseFired is still true. Clearing
    -- the latch every time we re-enter an unavailable state lets each new
    -- available-transition fire its own pulse.
    local wasAvailable    = (lastState == "READY" or lastState == "RECHARGING")
    local nowUnavailable  = (state == "ON_COOLDOWN" or state == "DEPLETED")
    if wasAvailable and nowUnavailable then
        rec._readyPulseFired = false
    end

    if nowAvailable and wasUnavailable and not rec._readyPulseFired then
        rec._readyPulseFired = true
        local kind   = rec.isChargeRecord and KIND_CHARGE or KIND_COOLDOWN
        local reason = rec.isChargeRecord and "charge"    or "cooldown"

        -- Multi-trigger system: if the user has defined per-spell triggers,
        -- fire any "when_ready" entries instead of the default pulse. Each
        -- entry has its own sound/TTS/icon settings. If NO trigger array
        -- exists, fall through to the legacy _EmitPulse path so existing
        -- user configs (per-spell sounds, delay modes, etc.) continue to
        -- work unchanged. If a trigger array exists but has no when_ready
        -- entries, the user has explicitly chosen NOT to fire on ready —
        -- we suppress the legacy pulse in that case.
        local triggers = self:_GetTriggerArray(rec)
        if triggers then
            local fired = false
            for i = 1, #triggers do
                local t = triggers[i]
                if t.type == "when_ready" then
                    self:_FireTrigger(rec, t, nil)
                    fired = true
                elseif t.type == "after_ready" then
                    -- Schedule a delayed pulse N seconds AFTER the ready
                    -- transition. Reuses the trigger token so a re-cast
                    -- (which bumps the token in _CancelTriggerTimers via
                    -- _StartWatching) cancels any pending after_ready
                    -- pulses from the previous cycle.
                    -- Default 3 when seconds was never written (same nil-
                    -- seconds trap as into_cooldown; matches the UI slider).
                    local secs = tonumber(t.seconds) or 3
                    if secs > 0 then
                        local capturedT = t
                        local token = rec._triggerToken or 0
                        C_Timer.After(secs, function()
                            if not Engine or not Engine.records then return end
                            if (rec._triggerToken or 0) ~= token then return end
                            Engine:_FireTrigger(rec, capturedT,
                                tostring(secs) .. "s_after_ready")
                        end)
                    end
                end
            end
            -- Even if no when_ready trigger fired, we DON'T fall through to
            -- _EmitPulse. The user's trigger array represents their full
            -- intent — silence on ready is a valid choice when they only
            -- defined on_use / before_ready / into_cooldown triggers.
            if not fired then
                Log:Write("DEBUG", rec.spellID, "READY (multi-trigger, no when_ready entries)")
            end
        else
            Log:Write("INFO", rec.spellID, string.format(
                "PULSE %s -> %s via %s", tostring(lastState), state, tostring(source)))
            self:_EmitPulse(rec.spellID, kind, reason, rec.isItem)
        end
    end

    -- Stop watching when fully ready.
    if state == "READY" then
        self:_StopWatching(rec, "ready")
    end
end

function Engine:OnCooldownUpdate(event, arg1, arg2, arg3, arg4)
    if not self.records then return end
    if event == "SPELL_UPDATE_COOLDOWN" then
        -- Payload: spellID, baseSpellID, category, startRecoveryCategory
        -- Mirror CDM/ArcAuras NeedsCooldownUpdate filter:
        --   arg1 == nil                              — bulk update (refresh all)
        --   arg1 == our spell (or arg2 == our spell) — our spell's CD changed
        --   arg4 == GLOBAL_RECOVERY_CATEGORY         — GCD event
        --
        -- The GCD-event branch is CRITICAL for charge spells with maxCharges=1
        -- (and effectively any spell whose CD reading interacts with the GCD).
        -- Without this filter, when another spell is cast and triggers GCD,
        -- our shadow feed never refeeds, so the swipe state can desync and
        -- the readiness transition is missed. ArcAurasCooldown documents
        -- this exact issue: "without this filter, our charge spells miss
        -- GCD updates from other spells' casts and the swipe only shows
        -- intermittently when other events happen to trigger a feed."
        local isBulkNil  = (arg1 == nil)
        local isGCDEvent = false
        if Constants and Constants.SpellCooldownConsts
           and Constants.SpellCooldownConsts.GLOBAL_RECOVERY_CATEGORY then
            isGCDEvent = (arg4 == Constants.SpellCooldownConsts.GLOBAL_RECOVERY_CATEGORY)
        end
        for _, rec in pairs(self.records) do
            if not rec.isItem and rec.watchToken then
                local isOurSpell = (arg1 == rec.spellID) or (arg2 == rec.spellID)
                if isOurSpell or isBulkNil or isGCDEvent then
                    self:_EvaluateRecord(rec, "SPELL_UPDATE_COOLDOWN")
                end
            end
        end
    elseif event == "SPELL_UPDATE_CHARGES" then
        -- SPELL_UPDATE_CHARGES has no arg1 in most WoW versions — it's a
        -- global "something about charges changed" signal. Re-evaluate all
        -- watched charge records; normal-spell records bail early in
        -- _EvaluateRecord when their charge shadow stays hidden.
        for _, rec in pairs(self.records) do
            if not rec.isItem and rec.watchToken then
                self:_EvaluateRecord(rec, "SPELL_UPDATE_CHARGES")
            end
        end
    elseif event == "SPELL_UPDATE_USES" then
        -- arg1 = spellID, arg2 = baseSpellID. Fires for "uses" tracking
        -- (charge-like mechanics that aren't on a regular cooldown). Mirror
        -- ArcAurasCooldown: refeed any matching record. Cheap iteration —
        -- only refeeds if the event's spellID matches a tracked record.
        local sid1, sid2 = arg1, arg2
        for _, rec in pairs(self.records) do
            if not rec.isItem and rec.watchToken then
                if rec.spellID == sid1 or rec.spellID == sid2 then
                    self:_EvaluateRecord(rec, "SPELL_UPDATE_USES")
                end
            end
        end
    end
    self:_ProcessPendingBinds(event)
end

-- _CheckExternalChargeGrants removed — the shadow-frame feed handles proc
-- CDR and external charge grants naturally. When a talent proc refunds a
-- charge, SPELL_UPDATE_CHARGES or SPELL_UPDATE_COOLDOWN fires, the shadow
-- refeeds with the new (shorter) duration, and IsShown() flips correctly.
-- No debounce, no polling, no lastKnownCharges bookkeeping.

local function CreateRecord(spellID, isItem)
    local rec = {
        spellID = spellID,
        spellName = isItem and getItemName(spellID) or getSpellName(spellID),
        isItem = isItem or false,
        itemID = isItem and spellID or nil,
        watchToken = nil, watchTokenCounter = 0,
        cdWidget = nil, chargeWidget = nil,
        bindStartTime = nil,
        -- Classify once at creation. maxCharges is non-secret at load time;
        -- transient fluctuations (procs/talents) don't change record type.
        isChargeRecord = (not isItem) and isRealChargeSpell(spellID) or false,
        -- Shadow detection state (owned by _EvaluateRecord)
        _lastShadowState = nil,
        _readyPulseFired = false,
        -- Item-path fields (nil for spell records)
        _useSpellID       = nil,
        _equippedSlot     = nil,
        _invDurObj        = nil,
        _lastEquipedSpellsTime = 0,
    }
    if isItem then
        rec._useSpellID   = ResolveItemUseSpell(spellID)
        rec._equippedSlot = DetectEquippedSlot(spellID)
    end
    rec.cdWidget     = CreateTimerWidget(rec, KIND_COOLDOWN)
    rec.chargeWidget = CreateTimerWidget(rec, KIND_CHARGE)
    return rec
end

local function DestroyRecord(rec)
    rec._delayToken = (rec._delayToken or 0) + 1
    rec._delayPending = nil
    if rec.cdWidget then
        rec.cdWidget:SetScript("OnCooldownDone", nil)
        rec.cdWidget:SetParent(nil); rec.cdWidget:ClearAllPoints(); rec.cdWidget:Hide()
        rec.cdWidget = nil
    end
    if rec.chargeWidget then
        rec.chargeWidget:SetScript("OnCooldownDone", nil)
        rec.chargeWidget:SetParent(nil); rec.chargeWidget:ClearAllPoints(); rec.chargeWidget:Hide()
        rec.chargeWidget = nil
    end
end

function Engine:_StartWatching(rec)
    -- If already watching (e.g. double-cast on a charge spell mid-recharge),
    -- just re-feed shadows to capture any duration change. Keep the existing
    -- watch token so delayed reminders aren't disrupted.
    if rec.watchToken then
        self:_FeedRecordShadows(rec)
        -- Re-anchor into_cooldown ("N sec after cast") triggers to THIS cast
        -- and cancel stale pending trigger timers from the previous cycle.
        -- Without this, only the cast that STARTED the watch session ever
        -- armed the after-cast timer (recasts mid-watch were silently ignored).
        self:_ScheduleTriggerArray(rec)
        return
    end

    rec.watchTokenCounter = rec.watchTokenCounter + 1
    rec.watchToken        = rec.watchTokenCounter
    rec.bindStartTime     = GetTime()
    rec._lastShadowState  = nil
    rec._readyPulseFired  = false

    -- Feed shadows immediately so the initial IsShown() state is correct.
    self:_FeedRecordShadows(rec)

    Log:Write("INFO", rec.spellID, "Cast -> watching (" ..
        (rec.isChargeRecord and "charge" or "cooldown") .. ")")

    -- Delayed reminder: afterCast mode. Schedules a pulse N seconds after the
    -- spell goes on cooldown. Cancelled automatically if the spell is recast.
    self:_CancelDelayedReminder(rec)
    self:_ScheduleDelayedReminder(rec, "afterCast")

    -- Multi-trigger system: schedule any time-delayed triggers (before_ready,
    -- into_cooldown) defined in db.spellTriggers for this spell. on_use
    -- triggers fire from OnPlayerCastSucceeded directly; when_ready triggers
    -- fire from _EvaluateRecord on the ready transition.
    self:_ScheduleTriggerArray(rec)
end

-- ===================================================================
-- DELAYED REMINDER SCHEDULER  (afterCast / afterReady)
-- ===================================================================
-- Fires an _EmitPulse N seconds after either (a) the spell goes on cooldown
-- (afterCast) or (b) the spell comes off cooldown (afterReady). Only ONE
-- delayed timer is active per record at a time -- rescheduling cancels any
-- prior pending timer. Uses a monotonic token so late callbacks from a
-- cancelled timer are ignored.
local function _GetDelaySettings(rec)
    local db = GetDB(); if not db then return nil, nil end
    local dbKey = rec.isItem and ("i:" .. tostring(rec.spellID)) or tostring(rec.spellID)
    local mode = db.spellDelayMode and db.spellDelayMode[dbKey] or "off"
    local secs = tonumber(db.spellDelaySeconds and db.spellDelaySeconds[dbKey]) or 0
    return mode, secs
end

function Engine:_CancelDelayedReminder(rec)
    if not rec then return end
    rec._delayToken = (rec._delayToken or 0) + 1
    rec._delayPending = nil
end

function Engine:_ScheduleDelayedReminder(rec, triggerMode)
    if not rec then return end
    local mode, secs = _GetDelaySettings(rec)
    -- "both" mode schedules afterCast alongside the natural ready-pulse.
    -- afterReady in "both" mode is ignored (would double-fire right after ready).
    local matches = (mode == triggerMode) or (mode == "both" and triggerMode == "afterCast")
    if not matches then return end
    if not (secs and secs > 0) then return end
    rec._delayToken = (rec._delayToken or 0) + 1
    local token = rec._delayToken
    rec._delayPending = triggerMode
    local spellID = rec.spellID
    local isItem  = rec.isItem or false
    local kind    = rec.isChargeRecord and KIND_CHARGE or KIND_COOLDOWN
    local reason  = "delayed_" .. tostring(triggerMode)
    C_Timer.After(secs, function()
        if not Engine or not Engine.records then return end
        if rec._delayToken ~= token then return end
        rec._delayPending = nil
        Log:Write("INFO", spellID, "PULSE via " .. reason .. " (" .. tostring(secs) .. "s)")
        Engine:_EmitPulse(spellID, kind, reason, isItem)
    end)
end

-- ===================================================================
-- MULTI-TRIGGER SYSTEM (per-spell trigger array)
-- ===================================================================
-- Each tracked spell can optionally have an array of trigger configs at
-- db.spellTriggers[key] (key shape mirrors spellSounds: "<spellID>" or
-- "i:<itemID>"). Each entry is a table:
--
--   { type = "on_use" | "when_ready" | "before_ready" | "into_cooldown",
--     seconds = N,            -- only for before_ready / into_cooldown
--     sound = "..." | nil,    -- per-trigger sound override
--     tts = "..." | nil,      -- per-trigger TTS override
--     showIcon = bool | nil,  -- per-trigger icon visibility override
--     soundDisabled = bool }  -- per-trigger sound suppression
--
-- BACKWARD COMPAT: if db.spellTriggers[key] is nil OR an empty array,
-- the legacy single-trigger code path runs (afterCast/afterReady delay
-- system + on-cooldown-done ready pulse). Existing user data unchanged.
-- ===================================================================

local function _MakeTriggerKey(rec)
    if not rec then return nil end
    return rec.isItem and ("i:" .. tostring(rec.spellID))
                       or tostring(rec.spellID)
end

-- Returns the trigger array for a record, or nil if none exists. Empty
-- arrays return nil so callers fall through to the legacy path.
function Engine:_GetTriggerArray(rec)
    local db = GetDB(); if not db or not db.spellTriggers then return nil end
    local key = _MakeTriggerKey(rec); if not key then return nil end
    local arr = db.spellTriggers[key]
    if type(arr) ~= "table" or #arr == 0 then return nil end
    return arr
end

-- Cancel any pending per-trigger timers for this rec. Called whenever the
-- watch cycle resets (cast → re-cast, manual stop, etc.) so we don't fire
-- stale "before_ready" pulses from a previous cast cycle.
function Engine:_CancelTriggerTimers(rec)
    if not rec then return end
    rec._triggerToken = (rec._triggerToken or 0) + 1
end

-- Fire ONE trigger config. Routes to DoPulse but with per-trigger
-- overrides (sound/tts/icon visibility). Reason is suffixed with the
-- trigger type for log clarity.
--
-- PROC GATE: when trigger.requireProc is set, the trigger fires ONLY if
-- the spell currently has a Spell Activation Overlay (proc glow) active
-- at the moment the trigger would fire. Items use their resolved
-- use-spell for the proc check.
function Engine:_FireTrigger(rec, trigger, reasonSuffix)
    if not rec or not trigger then return end
    if not CR.DoPulseFromTrigger then return end
    if trigger.requireProc and not self:_IsProcActiveForRecord(rec) then
        Log:Write("DEBUG", rec.spellID, "TRIGGER skipped (proc not active)")
        return
    end
    local kind   = rec.isChargeRecord and KIND_CHARGE or KIND_COOLDOWN
    local reason = "trigger_" .. tostring(trigger.type) .. (reasonSuffix and ("_" .. reasonSuffix) or "")
    Log:Write("INFO", rec.spellID, "PULSE via " .. reason)
    CR.DoPulseFromTrigger(rec.spellID, kind, rec.isItem or false, trigger)
end

-- Schedule the time-delayed triggers that fire from the cast event:
-- only "into_cooldown" needs scheduling here (N seconds after cast).
-- "after_ready" is scheduled from the ready-transition in _EvaluateRecord.
-- "on_use" fires synchronously from OnPlayerCastSucceeded.
-- "when_ready" fires from the ready-transition in _EvaluateRecord.
-- We do NOT read cooldown durations — those APIs return secret values,
-- and we have no need for them: every trigger anchors to either the cast
-- event (GetTime, non-secret) or the shadow-widget ready transition
-- (IsShown, non-secret).
function Engine:_ScheduleTriggerArray(rec)
    if not rec then return end
    local triggers = self:_GetTriggerArray(rec)
    if not triggers then return end

    self:_CancelTriggerTimers(rec)
    local token = rec._triggerToken or 0

    for i = 1, #triggers do
        local t = triggers[i]
        if t.type == "into_cooldown" then
            -- Default 3 when seconds was never written. The options slider
            -- only WRITES on user interaction while DISPLAYING 3 as fallback,
            -- and migration-built when_ready entries have no seconds field —
            -- switching their type left seconds=nil and the trigger silently
            -- never scheduled. 3 matches what the UI shows.
            local secs = tonumber(t.seconds) or 3
            if secs > 0 then
                local capturedT = t
                C_Timer.After(secs, function()
                    if not Engine or not Engine.records then return end
                    if (rec._triggerToken or 0) ~= token then return end
                    -- No watchToken guard: "N seconds after cast" anchors to
                    -- the cast event itself (non-secret, deterministic). The
                    -- spell cycling back to ready before N elapses must not
                    -- silently eat the pulse. Recasts still cancel via token.
                    Engine:_FireTrigger(rec, capturedT, tostring(secs) .. "s")
                end)
            end
        end
        -- on_use         → fired directly from OnPlayerCastSucceeded
        -- when_ready     → fired from _EvaluateRecord ready transition
        -- after_ready    → scheduled from _EvaluateRecord ready transition
    end
end

function Engine:_StopWatching(rec, reason)
    if not rec.watchToken then return end
    rec.watchToken        = nil
    rec._readyPulseFired  = false
    rec._lastShadowState  = nil
    -- Do NOT cancel trigger timers here. after_ready triggers are scheduled
    -- from the ready transition and need to survive _StopWatching("ready"),
    -- which is called immediately after the ready transition fires.
    -- Re-casts cancel old timers correctly via _StartWatching →
    -- _ScheduleTriggerArray → _CancelTriggerTimers.
    if rec.cdWidget     then rec.cdWidget:Clear()     end
    if rec.chargeWidget then rec.chargeWidget:Clear() end
    Log:Write("DEBUG", rec.spellID, "Cleanup: " .. tostring(reason))
end

function Engine:_GetWatchState(rec)
    if not rec.watchToken then return "IDLE" end
    return "WATCHING"
end

-- _GetOverrideSpell / _GetCooldownDuration / _GetChargeDuration /
-- _TryBindCooldown / _TryBindCharge / _VerifyBindings all removed.
-- Their work is now done by _FeedRecordShadows. Widgets are fed
-- unconditionally with ignoreGCD=true durObjs, and state is derived
-- from IsShown() — no binding bookkeeping required.

function Engine:_OnTimerComplete(widget)
    local rec  = widget._rec
    local kind = widget._kind
    if not rec or not rec.watchToken then return end
    if not self._enabled then return end
    -- Single path: let _EvaluateRecord re-feed and decide. It handles both
    -- spells and items, charge and non-charge, uniformly.
    self:_EvaluateRecord(rec, "OnCooldownDone[" .. tostring(kind) .. "]")
end

function Engine:_EvaluateZoneEnabled()
    local db = GetDB() or {}
    local _, instanceType = GetInstanceInfo()
    if instanceType == "party" then
        self._pulsesEnabled = (db.enabledInDungeons ~= false)
    elseif instanceType == "raid" then
        self._pulsesEnabled = (db.enabledInRaids ~= false)
    elseif instanceType == "arena" then
        self._pulsesEnabled = (db.enabledInArena ~= false)
    else
        self._pulsesEnabled = (db.enabledInWorld ~= false)
    end
end

function Engine:_EmitPulse(spellID, kind, reason, isItem)
    -- Check module enabled
    local db = GetDB()
    if not db or not db.enabled then return end
    if self._initTime and (GetTime() - self._initTime) < INIT_GRACE_PERIOD then return end
    if self._pulsesEnabled == false then return end
    if not isItem and type(IsPlayerSpell) == "function" then
        if IsPlayerSpell(spellID) == false then
            local rec = self.spellIDToRecord and self.spellIDToRecord[spellID] or nil
            local isKnownOverride = false
            if rec then
                if rec.spellID ~= spellID and IsPlayerSpell(rec.spellID) then
                    isKnownOverride = true
                end
                if rec.watchToken then isKnownOverride = true end
            end
            if not isKnownOverride then return end
        end
    end
    if isItem and type(IsEquippableItem) == "function" then
        if IsEquippableItem(spellID) and type(IsEquippedItem) == "function"
           and not IsEquippedItem(spellID) then
            return
        end
    end
    local rec = self.spellIDToRecord and self.spellIDToRecord[spellID] or nil
    -- Charge-spell pulse guard: a charge-kind pulse must come from either a
    -- natural charge transition ("charge"), a delayed reminder, a test, or
    -- a preview. Reject anything else (defensive — shouldn't fire with the
    -- new shadow-frame detection, but kept for safety).
    if rec and rec.isChargeRecord and tostring(kind) == "CHARGE" then
        local r = tostring(reason)
        local allowed = (r == "charge") or r:find("^delayed_") or (r == "TEST") or (r == "PREVIEW")
        if not allowed then return end
    end
    local now = GetTime()
    if rec then
        local last = rec.lastPulseTime or 0
        if (now - last) < 0.05 then return end
        rec.lastPulseTime = now
    end

    -- Schedule afterReady delayed reminder when the ready-pulse fires. Skipped
    -- for the delayed reminder's own re-emission (avoid recursion) and for any
    -- non-natural pulse reason (TEST, PREVIEW).
    if rec and (reason == "cooldown" or reason == "charge") then
        self:_ScheduleDelayedReminder(rec, "afterReady")
    end

    -- Suppress natural ready-pulse when the user wants ONLY the delayed
    -- reminder. afterCast / afterReady modes replace the ready-pulse entirely;
    -- "both" keeps it (afterCast+ready pulse), "off" keeps it (normal).
    if rec and (reason == "cooldown" or reason == "charge") then
        local mode = _GetDelaySettings(rec)
        if mode == "afterCast" or mode == "afterReady" then
            return
        end
    end
    Log:Write("INFO", spellID, "READY! (" .. tostring(reason) .. ")")
    if self._pulseHandler then
        self._pulseHandler(spellID, kind, isItem)
    end
end

function Engine:_ProcessPendingBinds(reason)
    -- With shadow-frame detection there's no "binding" phase — widgets are
    -- fed unconditionally on _StartWatching and re-fed on every evaluation.
    -- The only remaining responsibility here is watch-timeout cleanup:
    -- if a record has been watching for more than BIND_TIMEOUT_SECONDS
    -- without ever reaching the READY state (e.g. the spell silently
    -- disappeared from the spellbook), stop watching to avoid leaking state.
    local now = GetTime()
    for _, rec in pairs(self.records) do
        if rec.watchToken and rec.bindStartTime
           and (now - rec.bindStartTime) > BIND_TIMEOUT_SECONDS then
            self:_StopWatching(rec, "timeout")
        end
    end
end

function Engine:OnPlayerCastSucceeded(castSpellID)
    castSpellID = safeSpellID(castSpellID)
    if not castSpellID then return end

    -- Direct lookup first (spell records are keyed by spellID).
    local rec = self.spellIDToRecord[castSpellID]

    -- Item records: the cast spellID is the item's use-spell, not the itemID.
    -- Fall through to the use-spell reverse map built in RebuildTrackedSpells.
    if not rec and self.useSpellIDToItemRec then
        rec = self.useSpellIDToItemRec[castSpellID]
    end

    if not rec then return end

    -- ON_USE TRIGGERS (multi-trigger system)
    -- Iterate the per-spell trigger array and fire any "on_use" entries
    -- before the cancel-pending-pulse logic runs. Each entry has its own
    -- sound/TTS/icon overrides — _FireTrigger routes through DoPulseFromTrigger
    -- which honors them. on_use fires SYNCHRONOUSLY from this event handler.
    local db = GetDB()
    local triggers = self:_GetTriggerArray(rec)
    local firedOnUse = false
    if triggers then
        for i = 1, #triggers do
            local t = triggers[i]
            if t.type == "on_use" then
                self:_FireTrigger(rec, t, nil)
                firedOnUse = true
            end
        end
    end

    -- User cast the tracked spell/item → any pending pulse reminding them to
    -- cast it is stale. Kill it and start a new watch cycle.
    -- BUT: if we just fired an on_use trigger, that's the icon we want
    -- visible right now — don't cancel it. Only cancel if no on_use fired.
    if not firedOnUse and db and db.cancelOnCast ~= false and CR.CancelPulseForSpell then
        CR.CancelPulseForSpell(rec.spellID, rec.isItem)
    end

    self:_StartWatching(rec)
end

function Engine:OnUnitAura()
    -- DISABLED with aura-gate system — no-op. Entire logic preserved below.
    --[[
    for _, rec in pairs(self.records) do
        if rec._overrideAuraID and rec.detectAuraUntil and not rec.chargeSessionActive then
            if hasPlayerAura(rec._overrideAuraID) then
                rec.gateAuraSpellID = rec._overrideAuraID
                rec.gateModeLearned = GATE_AFTER_AURA; rec.gateMode = GATE_AFTER_AURA
                rec.gatePhase = "WAIT_OPEN"; rec.gateOpen = false
                rec.detectAuraUntil = nil; rec._overrideAuraID = nil
                rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                local db = GetDB()
                if db then db.learnedGates = db.learnedGates or {}; db.learnedGates[rec.spellID] = GATE_AFTER_AURA end
            end
        end
        if rec.gateAuraSpellID then
            local auraActive = hasPlayerAura(rec.gateAuraSpellID)
            if rec.gateMode == GATE_AFTER_AURA then
                if auraActive then
                    rec.gateOpen = false; rec.gateEverSeen = true
                    rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                    if rec.gatePhase == nil then rec.gatePhase = "WAIT_OPEN"
                    elseif rec.gatePhase == "WAIT_CLOSE" then rec.gatePhase = "WAIT_OPEN"
                    elseif rec.gatePhase == "WAIT_OPEN_DEBOUNCE" then rec.gatePhase = "WAIT_OPEN" end
                else
                    if rec.gateEverSeen and rec.gatePhase == "WAIT_OPEN" then
                        rec.gatePhase = "WAIT_OPEN_DEBOUNCE"
                        rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                        local token   = rec._gateDebounceToken
                        local spellID = rec.spellID
                        C_Timer.After(GATE_REOPEN_DELAY, function()
                            if rec._gateDebounceToken ~= token then return end
                            if rec.gatePhase ~= "WAIT_OPEN_DEBOUNCE" then return end
                            if hasPlayerAura(rec.gateAuraSpellID) then
                                rec.gatePhase = "WAIT_OPEN"; rec.gateOpen = false; return
                            end
                            rec.gatePhase = "READY"; rec.gateOpen = true; rec._gateOpenedAt = GetTime()
                            if rec.watchToken and not rec.cdBound then Engine:_TryBindCooldown(rec) end
                            Engine:_ProcessPendingBinds("gate_debounce")
                            UpdateEffectiveReadiness(rec, "gate_debounce")
                        end)
                    elseif rec.gatePhase == "READY" then
                        rec.gateOpen = true
                    else
                        rec.gateOpen = true
                    end
                end
            else
                -- GATE_DEFER_PULSE
                if auraActive then
                    rec.gateOpen = false
                    rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                    if rec._deferDebouncing then rec._deferDebouncing = false end
                elseif not rec.gateOpen and not rec._deferDebouncing then
                    rec._deferDebouncing = true
                    rec._gateDebounceToken = (rec._gateDebounceToken or 0) + 1
                    local token   = rec._gateDebounceToken
                    local spellID = rec.spellID
                    C_Timer.After(GATE_REOPEN_DELAY, function()
                        if rec._gateDebounceToken ~= token then return end
                        if not rec._deferDebouncing then return end
                        rec._deferDebouncing = false
                        if hasPlayerAura(rec.gateAuraSpellID) then rec.gateOpen = false; return end
                        rec.gateOpen = true
                        for kind, count in pairs(rec.pendingPulses) do
                            if count and count > 0 then
                                for i = 1, count do Engine:_EmitPulse(rec.spellID, kind, "aura ended", rec.isItem) end
                                rec.pendingPulses[kind] = 0
                            end
                        end
                        UpdateEffectiveReadiness(rec, "defer_debounce")
                    end)
                end
            end
        end
        UpdateEffectiveReadiness(rec, "aura_change")
    end
    --]]
end

function Engine:RebuildTrackedSpells(reason)
    local db = GetDB()
    if not db or not db.whitelist then return end

    -- Self-heal: ensure every whitelisted spell has a trigger array. This is
    -- belt-and-suspenders alongside Engine:Init's migration call — Init runs
    -- once at addon load, but if for any reason the whitelist was empty at
    -- that moment (e.g. profile swap) and gained entries afterward, those
    -- entries would be left without triggers. Running it here too guarantees
    -- every spell that goes through RebuildTrackedSpells has triggers.
    self:_MigrateLegacyTriggers()

    -- Parse whitelist into spell IDs and item IDs.
    -- One entry = one record. No name collapsing, no variant aliases.
    -- Whatever ID the user enters is THE ID we watch.
    local want, wantItems = {}, {}
    for k, enabled in pairs(db.whitelist) do
        if enabled then
            if type(k) == "string" and k:match("^i:(%d+)") then
                local id = safeItemID(k:match("^i:(%d+)"))
                if id then wantItems[id] = true end
            else
                local id = safeSpellID(k)
                if id then want[id] = true end
            end
        end
    end

    -- Remove unwanted records
    for spellID, rec in pairs(self.records) do
        local stillWanted = rec.isItem and wantItems[spellID] or want[spellID]
        if not stillWanted then DestroyRecord(rec); self.records[spellID] = nil end
    end
    -- Add wanted spells
    for spellID in pairs(want) do
        if not self.records[spellID] then
            self.records[spellID] = CreateRecord(spellID, false)
        end
    end
    -- Add wanted items
    for itemID in pairs(wantItems) do
        if not self.records[itemID] then
            self.records[itemID] = CreateRecord(itemID, true)
        end
    end

    -- Rebuild the single spellID → record lookup.
    wipe(self.spellIDToRecord)
    for spellID, rec in pairs(self.records) do
        self.spellIDToRecord[spellID] = rec
    end

    -- Rebuild use-spell → item-record reverse map. When the user casts an
    -- item's use-spell, UNIT_SPELLCAST_SUCCEEDED delivers the use-spell ID;
    -- we look up the owning item record via this map so cancel-on-cast and
    -- watch-start still work for items.
    self.useSpellIDToItemRec = self.useSpellIDToItemRec or {}
    wipe(self.useSpellIDToItemRec)
    for _, rec in pairs(self.records) do
        if rec.isItem and rec._useSpellID then
            self.useSpellIDToItemRec[rec._useSpellID] = rec
        end
    end
end

-- Seed a default trigger for a freshly-added spell/item so the multi-trigger
-- UI has something to display from the moment it's added. Idempotent — if
-- the spell already has a trigger array (from a prior session, profile copy,
-- legacy migration), it does nothing.
local function _SeedDefaultTrigger(db, key)
    if not db then return end
    db.spellTriggers = db.spellTriggers or {}
    if db.spellTriggers[key] and #db.spellTriggers[key] > 0 then return end
    db.spellTriggers[key] = {
        { type = "when_ready", seconds = 3 },
    }
end

function Engine:AddSpell(spellID)
    spellID = safeSpellID(spellID)
    if not spellID then return false, "invalid spellID" end
    local db = GetDB(); if not db then return false, "no database" end
    db.whitelist[tostring(spellID)] = true
    _SeedDefaultTrigger(db, tostring(spellID))
    self:RebuildTrackedSpells("add_spell"); return true
end

function Engine:AddItem(itemID)
    itemID = safeItemID(itemID)
    if not itemID then return false, "invalid itemID" end
    local db = GetDB(); if not db then return false, "no database" end
    db.whitelist["i:" .. tostring(itemID)] = true
    _SeedDefaultTrigger(db, "i:" .. tostring(itemID))
    self:RebuildTrackedSpells("add_item"); return true
end

function Engine:RemoveSpell(spellID)
    spellID = safeSpellID(spellID)
    if not spellID then return false, "invalid spellID" end
    local db = GetDB(); if not db or not db.whitelist then return false, "no whitelist" end
    db.whitelist[tostring(spellID)] = nil; db.whitelist[spellID] = nil
    self:RebuildTrackedSpells("remove_spell"); return true
end

function Engine:RemoveItem(itemID)
    itemID = safeItemID(itemID)
    if not itemID then return false, "invalid itemID" end
    local db = GetDB(); if not db or not db.whitelist then return false, "no whitelist" end
    db.whitelist["i:" .. tostring(itemID)] = nil
    self:RebuildTrackedSpells("remove_item"); return true
end

-- BAG_UPDATE_COOLDOWN: item cooldown state changed. For each tracked item:
--   if not watching, and the item is now on cooldown → start watching
--   if already watching → re-evaluate (shadow feed + state transition logic)
-- The INV path is authoritative for both equipped trinkets and bag items.
function Engine:OnItemCooldownUpdate()
    if not self._enabled or not self.records then return end
    for _, rec in pairs(self.records) do
        if rec.isItem and rec.itemID then
            if rec.watchToken then
                -- Already watching → run full evaluation (may transition to
                -- ready and emit pulse, or simply update swipe state).
                self:_EvaluateRecord(rec, "BAG_UPDATE_COOLDOWN")
            else
                -- Not watching → check if the item is now on cooldown.
                -- Feed the shadow and inspect cdWidget:IsShown() rather
                -- than making a separate API call.
                FeedItemInvShadow(rec)
                if rec.cdWidget and rec.cdWidget:IsShown() then
                    self:_StartWatching(rec)
                end
            end
        end
    end
end

-- Reset/sync events that may zero out item cooldowns on the Blizzard side
-- (ENCOUNTER_END, PLAYER_REGEN_ENABLED, CHALLENGE_MODE_START/RESET,
-- ARENA_OPPONENT_UPDATE, PLAYER_EQUIPED_SPELLS_CHANGED). Re-evaluate every
-- watched item record; if the shadow says READY, _EvaluateRecord will emit
-- the pulse and stop watching naturally.
--
-- PLAYER_EQUIPED_SPELLS_CHANGED is debounced per-record to 0.1s because
-- Blizzard fires it ~24 times in the same ms per trinket swap.
function Engine:OnItemReset(event)
    if not self._enabled or not self.records then return end
    local now = GetTime()
    for _, rec in pairs(self.records) do
        if rec.isItem and rec.itemID then
            if event == "PLAYER_EQUIPED_SPELLS_CHANGED" then
                if (now - (rec._lastEquipedSpellsTime or 0)) < 0.1 then
                    -- drop this fire for this record
                else
                    rec._lastEquipedSpellsTime = now
                    if rec.watchToken then
                        self:_EvaluateRecord(rec, event)
                    else
                        -- Not watching but charges may have just become
                        -- available again (e.g. Healthstone recharged).
                        -- Re-feed to refresh cached state.
                        FeedItemInvShadow(rec)
                    end
                end
            else
                if rec.watchToken then
                    self:_EvaluateRecord(rec, event)
                else
                    FeedItemInvShadow(rec)
                end
            end
        end
    end
end

-- GET_ITEM_INFO_RECEIVED: item data arrived (name, use-spell, etc.). If
-- this is one of our tracked items and its use-spell wasn't resolved at
-- creation (returned nil), re-resolve now so cancel-on-cast starts working.
function Engine:OnItemInfoReceived(itemID)
    itemID = safeItemID(itemID)
    if not itemID or not self.records then return end
    local rec = self.records[itemID]
    if not rec or not rec.isItem then return end
    if rec._useSpellID then return end  -- already resolved
    -- Bust the cache so ResolveItemUseSpell re-reads from GetItemSpell.
    _itemUseSpellCache[itemID] = nil
    local newUseSpell = ResolveItemUseSpell(itemID)
    if newUseSpell then
        rec._useSpellID = newUseSpell
        self.useSpellIDToItemRec = self.useSpellIDToItemRec or {}
        self.useSpellIDToItemRec[newUseSpell] = rec
        Log:Write("DEBUG", rec.spellID, string.format(
            "use-spell resolved late → %d", newUseSpell))
    end
    -- Also refresh the item name cache if it was the placeholder.
    if not rec.spellName or rec.spellName == tostring(itemID) then
        local name = getItemName(itemID)
        if name and name ~= tostring(itemID) then rec.spellName = name end
    end
end

-- PLAYER_EQUIPMENT_CHANGED: re-detect equipped slot for every item record.
-- If a tracked item moved bag↔slot13↔slot14, switch API path accordingly.
-- No pulse/state logic runs here — slot change by itself isn't a CD change.
function Engine:OnEquipmentChanged(slotChanged)
    if not self._enabled or not self.records then return end
    for _, rec in pairs(self.records) do
        if rec.isItem and rec.itemID then
            local newSlot = DetectEquippedSlot(rec.itemID)
            if newSlot ~= rec._equippedSlot then
                rec._equippedSlot = newSlot
                -- Re-evaluate so the INV shadow reflects the new path.
                if rec.watchToken then
                    self:_EvaluateRecord(rec, "PLAYER_EQUIPMENT_CHANGED")
                else
                    FeedItemInvShadow(rec)
                end
                Log:Write("DEBUG", rec.spellID, string.format(
                    "equipped slot → %s", tostring(newSlot)))
            end
        end
    end
end

function Engine:Init()
    self._enabled  = true
    self._initTime = GetTime()
    self:_MigrateLegacyTriggers()
    Log:WriteAlways("INFO", nil, "Cooldown Reminder engine initialized")
end

-- One-shot migration: for any whitelisted spell that has NO trigger array,
-- build a default one from the legacy delayMode/delaySeconds settings AND
-- fold the legacy per-spell sound (db.spellSounds[k]) and per-spell TTS
-- (db.spellTTS[k]) into each generated trigger's sound/tts fields. Runs
-- on Init.
--
-- ALSO runs a one-time fix-up on previously-migrated entries: if a trigger
-- array exists but its triggers lack sound/tts AND legacy spellSounds/
-- spellTTS still contain entries for this key, fold them in. This catches
-- users who upgraded through an earlier migration version that built
-- trigger arrays without folding sound/TTS. Marked with db.spellTriggersMigratedV2.
function Engine:_MigrateLegacyTriggers()
    local db = GetDB(); if not db or not db.whitelist then return end
    db.spellTriggers = db.spellTriggers or {}

    local function legacySoundFor(k, key)
        if not db.spellSounds then return nil end
        local s = db.spellSounds[k] or db.spellSounds[key]
        if s and s ~= "" and s ~= "Default" then return s end
        return nil
    end
    local function legacyTTSFor(k, key)
        if not db.spellTTS then return nil end
        local s = db.spellTTS[k] or db.spellTTS[key]
        if s and s ~= "" then return s end
        return nil
    end
    local function legacyShowIconFor(k, key)
        if not db.spellIconDisabled then return nil end
        if db.spellIconDisabled[k] or db.spellIconDisabled[key] then
            return false
        end
        return nil
    end

    -- Apply legacy sound/TTS/icon to every trigger in a list. Only sets
    -- fields that the trigger doesn't already have — never overwrites
    -- explicit per-trigger config the user set in the new UI.
    local function foldLegacyIntoTriggers(triggers, k, key)
        local snd  = legacySoundFor(k, key)
        local tts  = legacyTTSFor(k, key)
        local icon = legacyShowIconFor(k, key)
        for i = 1, #triggers do
            local t = triggers[i]
            if snd and not t.sound then t.sound = snd end
            if tts and not t.tts then t.tts = tts end
            if icon == false and t.showIcon == nil then t.showIcon = false end
        end
    end

    for key, v in pairs(db.whitelist) do
        if v then
            local k = tostring(key)
            local existing = db.spellTriggers[k]

            if not existing or #existing == 0 then
                -- Build new triggers from legacy delayMode/delaySeconds
                local mode = db.spellDelayMode and (db.spellDelayMode[k] or db.spellDelayMode[key])
                local secs = tonumber(db.spellDelaySeconds and (db.spellDelaySeconds[k] or db.spellDelaySeconds[key])) or 3
                local triggers = {}

                if mode == "afterCast" then
                    triggers[#triggers + 1] = { type = "into_cooldown", seconds = secs }
                elseif mode == "afterReady" then
                    triggers[#triggers + 1] = { type = "after_ready", seconds = secs }
                elseif mode == "both" then
                    triggers[#triggers + 1] = { type = "when_ready" }
                    triggers[#triggers + 1] = { type = "into_cooldown", seconds = secs }
                else
                    triggers[#triggers + 1] = { type = "when_ready" }
                end

                foldLegacyIntoTriggers(triggers, k, key)
                db.spellTriggers[k] = triggers
            elseif not db.spellTriggersMigratedV2 then
                -- One-shot fix-up: pre-existing trigger arrays from an
                -- earlier migration version that didn't fold sound/TTS.
                -- Add the legacy fields without overwriting any explicit
                -- per-trigger sound/TTS the user already set.
                foldLegacyIntoTriggers(existing, k, key)
            end
        end
    end

    db.spellTriggersMigratedV2 = true
end

function Engine:SetPulseHandler(fn)
    self._pulseHandler = fn
end

-- ===================================================================
-- PULSE UI
-- ===================================================================
-- Architecture: one "primary" pulseFrame (the user's configured position/anchor)
-- plus a pool of extra frames used only by the stack queue mode. In replace and
-- queue modes only the primary is ever visible; in stack mode the primary shows
-- the oldest still-animating icon, and extras fan out to the left or right.
local pulseFrame          -- primary, user-positioned
local anchorFrame
local pulseQueue = {}     -- queued pulses for "queue" mode (sound already fired)
local extraFramePool = {} -- unused extras available for stack mode
local activeStackFrames = {} -- ordered list of currently-visible stack frames (primary first)

local PULSE_QUEUE_MAX = 3  -- cap queue length (queue mode only)

local function GetSpellIcon(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.iconID then return info.iconID end
    end
    return nil
end

local function RelayoutStack(db)
    -- Reposition every currently-animating frame so slot 1 sits at the
    -- user's anchor point and subsequent slots fan out in stackDirection.
    -- Called after any add/remove from activeStackFrames.
    --
    -- IMPORTANT: extras anchor to the PREVIOUS slot in activeStackFrames,
    -- not to pulseFrame directly. When the primary ends and gets removed,
    -- the slot-1 frame becomes whatever was previously at slot 2, and the
    -- whole chain shifts visually because slot 2's anchor (now slot 3)
    -- references slot 2 (now slot 1) rather than the hidden primary.
    if not pulseFrame then return end
    local size    = tonumber(db.size) or 64
    local spacing = tonumber(db.stackSpacing) or 4
    local dir     = (db.stackDirection == "left") and -1 or 1
    local anchorSide = (dir > 0) and "RIGHT" or "LEFT"
    local oppSide    = (dir > 0) and "LEFT"  or "RIGHT"
    for i, f in ipairs(activeStackFrames) do
        f:ClearAllPoints()
        if i == 1 then
            f:SetPoint(db.point or "CENTER", UIParent, db.relPoint or "CENTER",
                tonumber(db.x) or 0, tonumber(db.y) or 120)
        else
            f:SetPoint(oppSide, activeStackFrames[i - 1], anchorSide, spacing * dir, 0)
        end
        f:SetSize(size, size)
    end
end

local function ReleaseStackFrame(f)
    -- Remove f from active list, hide it, return to the pool
    for i, entry in ipairs(activeStackFrames) do
        if entry == f then
            table.remove(activeStackFrames, i)
            break
        end
    end
    if f._ag and f._ag:IsPlaying() then f._ag:Stop() end
    f:Hide()
    if f ~= pulseFrame then
        extraFramePool[#extraFramePool + 1] = f
    end
    local db = GetDB()
    if db then RelayoutStack(db) end
end

local function BuildPulseFrameShell(name)
    -- Create the visual + animation scaffolding shared by the primary and all
    -- extras. Returns the frame. For the primary we pass a name; extras are
    -- anonymous.
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(64, 64)
    f:SetFrameStrata("HIGH")
    f:Hide()
    f:EnableMouse(false)
    local border = f:CreateTexture(nil, "BACKGROUND")
    border:SetColorTexture(0, 0, 0, 1)
    f._border = border
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f._tex = t

    -- Per-style animation groups. Each style owns its own AnimationGroup so
    -- we can swap between them per-pulse without rebuilding animations.
    -- f._ag is updated to point at whichever group is active for the
    -- current pulse so existing IsPlaying/Stop/OnFinished call sites all
    -- work transparently.
    f._animations = {}

    local function attachOnPlayShow(ag)
        ag:SetScript("OnPlay", function() f:Show() end)
        -- Dispatch OnFinished to a single per-frame callback so callers set
        -- f._onPulseFinished once and it works for any animation style.
        ag:SetScript("OnFinished", function()
            if f._onPulseFinished then f._onPulseFinished(f) end
        end)
    end

    -- "fade" — alpha 1 → 0, OUT smoothing (current default behavior)
    do
        local ag = f:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(1); a:SetToAlpha(0)
        a:SetDuration(0.6); a:SetSmoothing("OUT")
        attachOnPlayShow(ag)
        f._animations.fade = { group = ag, fade = a }
    end

    -- "no_fade" — icon stays at full alpha for the entire pulseDuration,
    -- then disappears instantly. Implemented as a single-keyframe Alpha
    -- animation that holds 1.0 for the duration. OnFinished fires
    -- normally so all the queue/replace cleanup paths still work.
    do
        local ag = f:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(1); a:SetToAlpha(1)
        a:SetDuration(0.6)
        attachOnPlayShow(ag)
        f._animations.no_fade = { group = ag, fade = a }
    end

    -- "flash" — alpha bounces 1 → 0.3 → 1 → 0.3 → 1 → 0 (urgent attention).
    -- The 4 step durations and the final fade are scaled together by
    -- SetFrameAnimStyle so the full sequence respects pulseDuration.
    do
        local ag = f:CreateAnimationGroup()
        local steps = {
            {1.0, 0.3, 0.08},
            {0.3, 1.0, 0.08},
            {1.0, 0.3, 0.08},
            {0.3, 1.0, 0.08},
        }
        local stepAnims = {}
        for i, s in ipairs(steps) do
            local a = ag:CreateAnimation("Alpha")
            a:SetFromAlpha(s[1]); a:SetToAlpha(s[2]); a:SetDuration(s[3]); a:SetOrder(i)
            stepAnims[i] = a
        end
        local final = ag:CreateAnimation("Alpha")
        final:SetFromAlpha(1.0); final:SetToAlpha(0.0)
        final:SetDuration(0.30); final:SetOrder(#steps + 1); final:SetSmoothing("OUT")
        attachOnPlayShow(ag)
        f._animations.flash = { group = ag, fade = final, flashSteps = stepAnims }
    end

    -- "zoom" — proc-glow style entrance: small → big-pop → settle, then
    -- linger and fade. Sequence (relative to total duration):
    --   t=0       scale 0.7 → 1.15 (pop in big), 12% of duration, OUT smoothing
    --   t=0.12    scale 1.15 → 1.00 (settle),    8% of duration, IN smoothing
    --   t=0.20+   alpha 1.0 → 0.0 (fade out),    80% of duration, OUT smoothing
    -- All three phases run in sequence via :SetOrder(1/2/3) so the user
    -- sees a real pop-in before the fade. SetFrameAnimStyle scales each
    -- phase's duration so the whole thing matches the user's pulseDuration.
    --
    -- The frame's :SetSize() is whatever ApplyFrameVisualSettings set; the
    -- Scale animation multiplies that. We use an OnPlay reset to guarantee
    -- the icon starts at 0.7 scale every play (without it, a re-Play during
    -- a previous zoom would start mid-animation).
    do
        local ag = f:CreateAnimationGroup()
        local s1 = ag:CreateAnimation("Scale")
        s1:SetScaleFrom(0.7, 0.7); s1:SetScaleTo(1.15, 1.15)
        s1:SetDuration(0.12); s1:SetOrder(1); s1:SetSmoothing("OUT")
        local s2 = ag:CreateAnimation("Scale")
        s2:SetScaleFrom(1.15, 1.15); s2:SetScaleTo(1.0, 1.0)
        s2:SetDuration(0.08); s2:SetOrder(2); s2:SetSmoothing("IN")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(1); a:SetToAlpha(0)
        a:SetDuration(0.6); a:SetOrder(3); a:SetSmoothing("OUT")
        attachOnPlayShow(ag)
        f._animations.zoom = { group = ag, fade = a, zoomS1 = s1, zoomS2 = s2 }
    end

    -- Default to fade so legacy callers reading f._ag / f._fadeOut work.
    f._ag       = f._animations.fade.group
    f._fadeOut  = f._animations.fade.fade
    f._animStyle = "fade"

    return f
end

-- Switch the active animation style on a frame. Sets f._ag to the chosen
-- group so OnFinished hookups (set externally) and IsPlaying checks keep
-- working. Falls back to "fade" if the style isn't recognised. Also scales
-- the timing of multi-phase styles (zoom, flash) so the entire sequence
-- respects the user's pulseDuration setting.
local PULSE_FADE_STYLES = {
    "fade", "no_fade", "flash", "zoom",
}
CR.PULSE_FADE_STYLES = PULSE_FADE_STYLES

-- Public list of supported glow types (mirrors ns.Glows.GetSupportedOpts but
-- captured statically here so the options panel can render the dropdown
-- without poking the Glows module). "none" disables the glow.
CR.PULSE_GLOW_TYPES = {
    "none", "pixel", "autocast", "button", "proc", "ants", "ach_proc",
}
-- Switch the active animation style on a frame. Sets f._ag to the chosen
-- group so OnFinished hookups (set externally) and IsPlaying checks keep
-- working. Falls back to "fade" if the style isn't recognised. Reads
-- per-style animation parameters (anim* fields) from db so the user's
-- Animation tab sliders take effect on the next play.
local function SetFrameAnimStyle(f, style, db)
    if not f or not f._animations then return end
    local entry = f._animations[style] or f._animations.fade
    -- If we're switching styles, stop the previous one first so it doesn't
    -- keep playing while the new one starts.
    if f._ag and f._ag ~= entry.group and f._ag:IsPlaying() then
        f._ag:Stop()
    end
    f._ag       = entry.group
    f._fadeOut  = entry.fade
    f._animStyle = style or "fade"

    local D = math.max(0.05, tonumber(db and db.pulseDuration) or 0.6)

    -- Per-style duration scaling. The whole sequence (entrance phases +
    -- fade-out) sums to D so the user's "Pulse Duration" slider controls
    -- the on-screen time regardless of style.
    if style == "zoom" and entry.zoomS1 and entry.zoomS2 then
        -- User-tunable: pop and settle durations. Both are clamped against
        -- D so the trailing fade always has at least 0.05s. Scale targets
        -- come from animZoomStart / animZoomPeak.
        local popReq    = math.max(0.02, tonumber(db and db.animZoomPopTime)    or 0.12)
        local settleReq = math.max(0.02, tonumber(db and db.animZoomSettleTime) or 0.08)
        -- Cap entrance to 80% of D so fade has at least 20%.
        local maxEntrance = D * 0.80
        if popReq + settleReq > maxEntrance then
            local k = maxEntrance / (popReq + settleReq)
            popReq    = popReq    * k
            settleReq = settleReq * k
        end
        local fadeDur = math.max(0.05, D - popReq - settleReq)
        local startScale = tonumber(db and db.animZoomStart) or 0.70
        local peakScale  = tonumber(db and db.animZoomPeak)  or 1.15
        entry.zoomS1:SetScaleFrom(startScale, startScale)
        entry.zoomS1:SetScaleTo(peakScale, peakScale)
        entry.zoomS1:SetDuration(popReq)
        entry.zoomS2:SetScaleFrom(peakScale, peakScale)
        entry.zoomS2:SetScaleTo(1.0, 1.0)
        entry.zoomS2:SetDuration(settleReq)
        entry.fade:SetDuration(fadeDur)
    elseif style == "flash" and entry.flashSteps then
        -- User-tunable: per-step flash speed. Total flash time = stepDur*4.
        -- Cap total flash time to 70% of D so trailing fade has 30%.
        local stepReq = math.max(0.03, tonumber(db and db.animFlashSpeed) or 0.10)
        local n = #entry.flashSteps
        local totalFlash = stepReq * n
        if totalFlash > D * 0.70 then
            stepReq = (D * 0.70) / n
        end
        local fadeDur = math.max(0.05, D - stepReq * n)
        for _, a in ipairs(entry.flashSteps) do a:SetDuration(stepReq) end
        entry.fade:SetDuration(fadeDur)
    elseif entry.fade then
        -- Single-phase styles (fade, no_fade): the whole duration is the
        -- single Alpha animation. For "fade" we also honor the user's
        -- chosen smoothing curve. "no_fade" stays at constant alpha so
        -- smoothing has no visible effect; we leave it at NONE.
        entry.fade:SetDuration(D)
        if style == "fade" then
            local smooth = (db and db.animFadeSmoothing) or "OUT"
            -- Only the four documented values are valid.
            if smooth ~= "NONE" and smooth ~= "OUT"
               and smooth ~= "IN" and smooth ~= "IN_OUT" then
                smooth = "OUT"
            end
            entry.fade:SetSmoothing(smooth)
        end
    end
end

-- Stop any per-pulse glow that was started for this frame. Called from the
-- OnFinished dispatcher and from CancelPulseForSpell so glows always end
-- with the icon. ns.Glows.Stop is a no-op if no glow is active for the key.
local function StopPulseGlow(f)
    if not f or not f._arcGlowKey then return end
    if ns and ns.Glows and ns.Glows.Stop then
        ns.Glows.Stop(f, f._arcGlowKey)
    end
    f._arcGlowKey = nil
end

local function GetExtraFrame(db)
    -- Grab a frame from the pool or create a new one. Used by stack mode.
    local f = table.remove(extraFramePool)
    if not f then
        f = BuildPulseFrameShell(nil)
        -- Extras fade out -> release back to pool. Wired through the
        -- shared OnFinished dispatcher so any animation style triggers it.
        f._onPulseFinished = function(self)
            StopPulseGlow(self)
            ReleaseStackFrame(self)
        end
    end
    return f
end

local function CreatePulseFrame()
    local f = BuildPulseFrameShell("ArcUICooldownReminderFrame")
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        local db = GetDB()
        if db and not db.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local db = GetDB()
        if db then
            local point, _, relPoint, x, y = self:GetPoint(1)
            db.point = point; db.relPoint = relPoint
            db.x = math.floor(x + 0.5); db.y = math.floor(y + 0.5)
        end
        if anchorFrame and anchorFrame:IsShown() then
            anchorFrame:ClearAllPoints(); anchorFrame:SetAllPoints(pulseFrame)
        end
    end)
    -- Primary's fade-finish behavior depends on which mode we're in, so we
    -- compute it at finish time. Wired through the shared OnFinished
    -- dispatcher so any animation style triggers it.
    f._onPulseFinished = function(self)
        StopPulseGlow(self)
        self:Hide()
        local db = GetDB()
        if not db then return end
        -- Remove the primary from the active stack if stack mode had it
        for i, entry in ipairs(activeStackFrames) do
            if entry == self then table.remove(activeStackFrames, i); break end
        end
        -- Queue mode: drain next queued pulse (icon only; sound already fired).
        -- If queueInterDelay is set, wait that long before firing the next one
        -- so the user has a gap to register the transition instead of a hard
        -- cut from one pulse to the next.
        --
        -- IMPORTANT: even when queueInterDelay is 0, we defer the drain via
        -- C_Timer.After(0, fire). Calling f._ag:Play() *synchronously* from
        -- within an OnFinished callback can leave Blizzard's animation
        -- system in a state where the new animation's OnFinished doesn't
        -- fire correctly — which manifests as the queue silently dropping
        -- pulses 2, 3, 4... after the first finish. Deferring by one frame
        -- lets the OnFinished callback fully exit before Play() runs.
        --
        -- The drain re-routes through RouteIconPulse so any pulse that
        -- arrived in the gap between OnFinished and the deferred fire is
        -- handled correctly (e.g. dedupes against this drain instead of
        -- being interrupted by it).
        if db.queueMode == "queue" and #pulseQueue > 0 then
            local nextPulse = table.remove(pulseQueue, 1)
            local delay = tonumber(db.queueInterDelay) or 0
            local fire = function()
                if not nextPulse then return end
                local d = GetDB(); if not d then return end
                Log:Write("DEBUG", nextPulse.spellID, "queue drain")
                -- Route through the full pipeline so a new pulse that
                -- arrived synchronously after this one was scheduled
                -- gets the right resolution (dedup, etc.).
                if CR._RouteIconPulse then
                    CR._RouteIconPulse(d, nextPulse.spellID, nextPulse.kind, nextPulse.isItem, nextPulse.trigger)
                end
            end
            C_Timer.After(math.max(delay, 0), fire)
        end
        -- Replace mode: drain the held pulse from the guard buffer. The
        -- buffer holds at most one pending pulse waiting for the primary
        -- to free up. If the primary's animation finished BEFORE the
        -- guard expired (rare, only when fadeDuration < replaceGuard),
        -- this drain fires earlier than the timer-scheduled drain. The
        -- token check inside CR._DrainReplaceHold prevents double-firing.
        --
        -- Deferred via C_Timer.After(0) for the same reason as the queue
        -- drain above: calling f._ag:Play() inside our own OnFinished
        -- can desync Blizzard's animation system.
        if db.queueMode == "replace" and CR._DrainReplaceHold then
            C_Timer.After(0, function()
                if CR._DrainReplaceHold then CR._DrainReplaceHold("primary_finished") end
            end)
        end
        -- Stack mode: relayout remaining frames so the oldest-remaining slides
        -- into the primary's slot. Note: in stack mode the primary often
        -- doesn't hold the "oldest" — we just relayout.
        if db.queueMode == "stack" then
            RelayoutStack(db)
        end
    end
    return f
end

local function ApplyFrameVisualSettings(f, db)
    -- Apply size/border/texture inset/opacity/fade-duration to a single frame.
    -- Used for both the primary and for extras when spawned in stack mode.
    local size = tonumber(db.size) or 64
    f:SetSize(size, size)
    local borderInset = math.max(1, math.floor(size * 0.04 + 0.5))
    f._border:ClearAllPoints(); f._border:SetAllPoints(f)
    f._tex:ClearAllPoints()
    f._tex:SetPoint("TOPLEFT",    f, "TOPLEFT",    borderInset,  -borderInset)
    f._tex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -borderInset, borderInset)
    f._tex:SetAlpha(tonumber(db.iconOpacity) or 1)
    f._fadeOut:SetDuration(tonumber(db.pulseDuration) or 0.60)
end

local function ApplyPulseSettings(db)
    if not pulseFrame then pulseFrame = CreatePulseFrame() end
    pulseFrame:ClearAllPoints()
    pulseFrame:SetPoint(db.point or "CENTER", UIParent, db.relPoint or "CENTER",
        tonumber(db.x) or 0, tonumber(db.y) or 120)
    ApplyFrameVisualSettings(pulseFrame, db)
    local locked = (db.locked ~= false)
    pulseFrame:SetMovable(not locked); pulseFrame:EnableMouse(not locked)
    if anchorFrame then
        if locked then anchorFrame:Hide() else anchorFrame:Show() end
    end
    -- Also refresh size/opacity on any active stack frames so slider changes
    -- take effect immediately on frames mid-animation.
    for _, f in ipairs(activeStackFrames) do
        if f ~= pulseFrame then ApplyFrameVisualSettings(f, db) end
    end
    -- And any frames sitting in the pool (they'll be resized anyway when
    -- pulled, but keep them consistent).
    for _, f in ipairs(extraFramePool) do
        ApplyFrameVisualSettings(f, db)
    end
    -- Stack mode: relayout so direction/spacing changes take effect live
    if db.queueMode == "stack" then RelayoutStack(db) end
end

-- Resolve TTS voice ID based on override. Returns voiceID number.
-- Voice objects returned by C_VoiceChat.GetTtsVoices() have only voiceID + name.
-- WoW's built-in voice names use "Masculine"/"Feminine" in the name (e.g.
-- "English Voice 1 (Masculine)", "English Voice 2 (Feminine)"), so that's our
-- primary signal. We also check "male"/"female" substrings as a fallback for
-- OS-provided voices that might be named differently. "Female" is checked
-- first because "female" contains "male" as a substring.
local function ResolveTTSVoiceID(override)
    -- Default: use whatever the user picked in WoW's TTS settings.
    if not override or override == "default" then
        if TextToSpeech_GetSelectedVoice and Enum and Enum.TtsVoiceType then
            local v = TextToSpeech_GetSelectedVoice(Enum.TtsVoiceType.Standard)
            if v and v.voiceID then return v.voiceID end
        end
        return 0
    end

    if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then return 0 end
    local voices = C_VoiceChat.GetTtsVoices()
    if type(voices) ~= "table" or #voices == 0 then return 0 end

    local wantMale = (override == "male")

    -- Pass 1: direct name match for WoW's built-in voice naming convention
    -- ("Masculine" / "Feminine"), plus substring fallback for "female"/"male".
    for _, v in ipairs(voices) do
        local name = (v and v.name) and string.lower(v.name) or ""
        if name ~= "" then
            local isFem = name:find("feminine", 1, true) or name:find("female", 1, true)
            local isMal
            if not isFem then
                isMal = name:find("masculine", 1, true) or name:find("male", 1, true)
            end
            if wantMale and isMal then return v.voiceID end
            if (not wantMale) and isFem then return v.voiceID end
        end
    end

    -- Pass 2: index alternation fallback (voice 1 = masculine, voice 2 = feminine)
    if wantMale then
        return (voices[1] and voices[1].voiceID) or 0
    else
        return (voices[2] and voices[2].voiceID) or (voices[1] and voices[1].voiceID) or 0
    end
end
CR.ResolveTTSVoiceID = ResolveTTSVoiceID

-- ── SOUND-CUTOFF HELPERS ─────────────────────────────────────────────
-- Tracks the handle of the most recent sound we played. PlaySoundFile
-- and PlaySound both return (success, soundHandle). When the user
-- enables `cutoffPreviousSound`, we stop the previous sound before
-- playing a new one — this kills the "sound pile-up" that happens
-- when many short cooldowns trigger reminders back-to-back.
--
-- StopSound takes an optional fade-out time which is much smoother
-- than a hard cut. We default to 100ms via db.cutoffFadeTime so the
-- previous sound trails off naturally instead of clipping.
--
-- TTS cutoff uses C_VoiceChat.StopSpeakingText() — there's no per-
-- utterance handle for TTS in WoW's API, so the cutoff is global
-- (whatever TTS line was speaking gets cancelled).
local _lastSoundHandle = nil  -- nil or a numeric soundHandle

local function StopPreviousSound(db)
    if not db or not db.cutoffPreviousSound then return end
    local fadeMS = math.floor((tonumber(db.cutoffFadeTime) or 0.1) * 1000)
    if _lastSoundHandle and StopSound then
        StopSound(_lastSoundHandle, fadeMS)
    end
    _lastSoundHandle = nil
    -- Also cut any in-flight TTS line. StopSpeakingText is harmless if
    -- nothing is currently speaking, so it's safe to call unconditionally.
    if C_VoiceChat and C_VoiceChat.StopSpeakingText then
        C_VoiceChat.StopSpeakingText()
    end
end

-- Wrappers around PlaySoundFile / PlaySound that capture the returned
-- handle so StopPreviousSound() can cancel them later. Both blizzard
-- functions return (success, soundHandle) — handle is what StopSound
-- needs. We only track when cutoff mode is on (no point holding refs
-- otherwise).
local function PlaySoundFileTracked(db, path, channel)
    local ok, handle = PlaySoundFile(path, channel)
    if db and db.cutoffPreviousSound then _lastSoundHandle = handle end
    return ok, handle
end

local function PlaySoundTracked(db, soundKitID, channel)
    local ok, handle = PlaySound(soundKitID, channel)
    if db and db.cutoffPreviousSound then _lastSoundHandle = handle end
    return ok, handle
end

-- Speak a TTS string. Uses C_VoiceChat.SpeakText which works regardless of
-- whether the user has WoW's Combat Audio Alerts feature enabled.
-- Signature: SpeakText(voiceID, text, rate, volume, overlap)
local function SpeakTTS(text, voiceID, rate)
    if not text or text == "" then return false end
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then return false end
    local volume = (C_TTSSettings and C_TTSSettings.GetSpeechVolume and C_TTSSettings.GetSpeechVolume()) or 100
    C_VoiceChat.SpeakText(voiceID or 0, text, rate or 0, volume, false)
    return true
end
CR.SpeakTTS = SpeakTTS

-- Forward declaration for PlayTriggerSound. The function body is defined
-- further down in the file (after PlayPulseSound and PlayIconOnFrame),
-- but PlayIconOnFrame's closure needs to be able to resolve it at the
-- time PlayIconOnFrame is created. Without this forward-decl, Lua treats
-- PlayTriggerSound as a global lookup which would always be nil because
-- the actual definition is a `local`. Declaring it as a local up here
-- and using `function PlayTriggerSound(...)` (no `local`) in the body
-- below assigns to the same upvalue.
local PlayTriggerSound

local function PlayPulseSound(db, spellID)
    if not db.soundEnabled then return end

    -- Per-spell sound-disabled flag: user can mute sound/TTS for this specific
    -- spell while keeping it on globally.
    if db.spellSoundDisabled then
        local key = tostring(spellID)
        if db.spellSoundDisabled[key] or db.spellSoundDisabled["i:" .. key] then
            return
        end
    end

    -- Stop any in-flight sound/TTS BEFORE playing this one (when the
    -- user has cutoffPreviousSound enabled). Done early so it applies
    -- to the TTS path below as well as the regular sound path.
    StopPreviousSound(db)

    -- Per-spell TTS takes priority over per-spell/global sound.
    if db.spellTTS then
        local key = tostring(spellID)
        local ttsText = db.spellTTS[key] or db.spellTTS["i:" .. key]
        if ttsText and ttsText ~= "" then
            local voiceID = ResolveTTSVoiceID(db.ttsVoiceOverride)
            local rate
            if db.ttsRateOverride ~= nil then
                rate = tonumber(db.ttsRateOverride) or 0
            elseif C_TTSSettings and C_TTSSettings.GetSpeechRate then
                rate = C_TTSSettings.GetSpeechRate()
            end
            if SpeakTTS(ttsText, voiceID, rate) then return end
            -- Fall through to sound if SpeakTTS failed
        end
    end

    local soundName = db.soundName
    if db.spellSounds then
        local ov = db.spellSounds[tostring(spellID)] or db.spellSounds[spellID]
                   or db.spellSounds["i:" .. tostring(spellID)]
        if ov and ov ~= "" then soundName = ov end
    end
    if not soundName or soundName == "None" then return end
    if soundName == "Default" then
        PlaySoundTracked(db, db.fallbackSoundKitID or 12867, db.soundChannel or "Master"); return
    end
    local channel = db.soundChannel or "Master"
    local path
    if LibStub then
        local lsm = LibStub("LibSharedMedia-3.0", true)
        if lsm then path = lsm:Fetch("sound", soundName, true) end
    end
    if path then PlaySoundFileTracked(db, path, channel)
    else PlaySoundTracked(db, db.fallbackSoundKitID or 12867, channel) end
end

-- Determine whether the icon should show for this specific spell/item.
-- Global db.iconEnabled is the master switch (default true). Per-spell
-- db.spellIconDisabled[dbKey] can force-disable the icon for individual
-- reminders regardless of the global. Lets you have icon+sound for most
-- spells but sound-only for others.
local function ShouldShowIconFor(db, spellID, isItem)
    if db.iconEnabled == false then return false end
    if not db.spellIconDisabled then return true end
    local dbKey = isItem and ("i:" .. tostring(spellID)) or tostring(spellID)
    return not db.spellIconDisabled[dbKey]
end

local function GetIconForSpell(spellID, isItem)
    local icon
    if isItem then
        if C_Item and C_Item.GetItemIconByID then
            icon = C_Item.GetItemIconByID(spellID)
        end
    else
        icon = GetSpellIcon(spellID)
        if not icon and C_Item and C_Item.GetItemIconByID then
            icon = C_Item.GetItemIconByID(spellID)
        end
    end
    return icon
end

-- Play an icon pulse on a specific frame. ALSO fires sound/TTS so audio
-- and animation start in the same frame — there is no path where the
-- sound plays but the icon doesn't (or vice-versa). This guarantee
-- holds across queue/replace/stack modes, the replace-mode hold, the
-- priority gate, and dedup-restart: sound is bound to the actual
-- on-screen pulse, not to the trigger event.
--
-- Sound-only paths (trigger.showIcon = false) bypass this function and
-- call PlayPulseSound / PlayTriggerSound directly at the trigger point,
-- because there's no icon for sound to ride alongside.
--
-- Tags the frame with _spellID/_isItem so DoPulse can detect duplicate alerts
-- for the same spell and restart the existing frame in place instead of
-- creating a second one. Also timestamps _playedAt so replace-mode can
-- enforce a minimum on-screen duration before a new pulse can replace.
--
-- trigger (optional): per-trigger config table. Honored fields:
--   animStyle      — one of PULSE_FADE_STYLES (defaults to db.animStyle or "fade")
--   glowType       — "none" / "pixel" / "autocast" / "button" / "proc" / "ants"
--                    / "ach_proc". nil = no glow.
--   glowColor      — {r,g,b,a} or {r=,g=,b=,a=} (defaults to ArcUI cyan).
--   pulseDuration  — total seconds on screen (overrides db.pulseDuration).
--   animFadeSmoothing / animFlashSpeed / animZoomStart / animZoomPeak /
--   animZoomPopTime / animZoomSettleTime — per-trigger overrides for the
--                    matching db anim* params.
--   priority       — 0 (default) or 1+; controls interrupt/drop behavior.
local function PlayIconOnFrame(f, db, spellID, isItem, trigger)
    local icon = GetIconForSpell(spellID, isItem)
    ApplyFrameVisualSettings(f, db)
    if icon then f._tex:SetTexture(icon) end
    f._spellID  = spellID
    f._isItem   = isItem or false
    f._playedAt = GetTime()
    -- Priority: 0 = no priority (default). Higher values resist replacement
    -- by lower-priority pulses and can interrupt lower-priority pulses
    -- regardless of mode/guard. See RouteIconPulse for full semantics.
    f._priority = (trigger and tonumber(trigger.priority)) or 0

    -- Resolve animation style: per-trigger > global > "fade".
    local style = (trigger and trigger.animStyle) or db.animStyle or "fade"

    -- Build a merged param table for SetFrameAnimStyle. The trigger may
    -- override pulseDuration and any of the anim* tuning params; nil
    -- means "inherit from db". Build a shallow merge so the engine
    -- doesn't have to know about per-trigger overrides — they look the
    -- same as global settings to SetFrameAnimStyle.
    local mergedDb = db
    if trigger and (trigger.pulseDuration ~= nil
                    or trigger.animFadeSmoothing ~= nil
                    or trigger.animFlashSpeed ~= nil
                    or trigger.animZoomStart ~= nil
                    or trigger.animZoomPeak ~= nil
                    or trigger.animZoomPopTime ~= nil
                    or trigger.animZoomSettleTime ~= nil) then
        mergedDb = {
            pulseDuration      = trigger.pulseDuration      or db.pulseDuration,
            animFadeSmoothing  = trigger.animFadeSmoothing  or db.animFadeSmoothing,
            animFlashSpeed     = trigger.animFlashSpeed     or db.animFlashSpeed,
            animZoomStart      = trigger.animZoomStart      or db.animZoomStart,
            animZoomPeak       = trigger.animZoomPeak       or db.animZoomPeak,
            animZoomPopTime    = trigger.animZoomPopTime    or db.animZoomPopTime,
            animZoomSettleTime = trigger.animZoomSettleTime or db.animZoomSettleTime,
        }
    end
    SetFrameAnimStyle(f, style, mergedDb)

    -- Stop any previous glow on this frame BEFORE starting a new one.
    -- Reused frames (pool extras, primary on replace) carry over the
    -- _arcGlowKey from their previous pulse — without stopping it first
    -- the glow from the previous spell would still be running.
    StopPulseGlow(f)

    -- Per-trigger glow: if trigger.glowType is set and not "none", start
    -- a glow on this frame for the duration of the pulse. The
    -- _onPulseFinished callback (in CreatePulseFrame / GetExtraFrame)
    -- and StopPulseGlow guarantee cleanup on natural finish, cancel,
    -- or flush.
    local glowType = trigger and trigger.glowType
    if glowType and glowType ~= "none" and ns and ns.Glows and ns.Glows.Start then
        local glowKey = "cr_pulse"
        local color = (trigger and trigger.glowColor)
                      or { 0.0, 0.8, 1.0, 1.0 }  -- ArcUI cyan default
        ns.Glows.Start(f, glowKey, glowType, { color = color })
        f._arcGlowKey = glowKey
    end

    -- Fire sound/TTS in lock-step with the animation. The trigger-aware
    -- variant honors per-trigger sound/TTS overrides; the legacy variant
    -- handles per-spell sound config. Both check db.soundEnabled and
    -- per-spell mute flags internally.
    if trigger and PlayTriggerSound then
        PlayTriggerSound(db, spellID, trigger)
    elseif PlayPulseSound then
        PlayPulseSound(db, spellID)
    end

    f._ag:Stop(); f._ag:Play()
end

function CR.DoPulseNow(spellID, kind, isItem, suppressSound, trigger)
    local db = GetDB(); if not db then return end

    if ShouldShowIconFor(db, spellID, isItem) then
        if not pulseFrame then pulseFrame = CreatePulseFrame() end
        ApplyPulseSettings(db)
        -- PlayIconOnFrame fires sound in lock-step with the animation
        -- (unless suppressSound is set — see below for the rationale).
        if suppressSound then
            -- Caller explicitly wants no sound. Temporarily mask the
            -- trigger's sound fields so PlayIconOnFrame's sound call
            -- becomes a no-op. We do this by passing a synthetic
            -- trigger (or db with soundEnabled=false) but the simplest
            -- correct path is to play the icon then NOT pass trigger
            -- so PlayPulseSound runs against a per-spell-disabled-or
            -- otherwise-muted setup. To keep this simple and obviously-
            -- correct, we just disable sound on the db copy:
            local dbCopy = {}
            for k, v in pairs(db) do dbCopy[k] = v end
            dbCopy.soundEnabled = false
            PlayIconOnFrame(pulseFrame, dbCopy, spellID, isItem, trigger)
        else
            PlayIconOnFrame(pulseFrame, db, spellID, isItem, trigger)
        end
    elseif not suppressSound then
        -- Icon disabled — sound-only path. Same as DoPulse's
        -- sound-only branch.
        if trigger then
            PlayTriggerSound(db, spellID, trigger)
        else
            PlayPulseSound(db, spellID)
        end
    end
end

-- Cancel any currently-visible or queued pulse for a specific spellID/item.
-- Called when the user actually casts the spell — the reminder's purpose is
-- over. Frees the primary frame (triggering OnFinished cleanup for stack-mode
-- relayout) and also clears any matching queue entries.
function CR.CancelPulseForSpell(spellID, isItem)
    if not spellID then return end
    isItem = isItem or false

    -- Primary: if it's currently showing this spell, stop the animation.
    -- OnFinished fires naturally (the fade Alpha animation doesn't call
    -- OnFinished on Stop() in all builds — to be safe we hide + relayout
    -- manually instead of relying on OnFinished being called by Stop).
    if pulseFrame and pulseFrame._ag and pulseFrame._ag:IsPlaying()
       and pulseFrame._spellID == spellID and (pulseFrame._isItem or false) == isItem then
        pulseFrame._ag:Stop()
        StopPulseGlow(pulseFrame)
        pulseFrame:Hide()
        -- Mirror the OnFinished cleanup: remove from stack, relayout if needed
        for i, entry in ipairs(activeStackFrames) do
            if entry == pulseFrame then table.remove(activeStackFrames, i); break end
        end
        local db = GetDB()
        if db and db.queueMode == "stack" then RelayoutStack(db) end
    end

    -- Replace mode: if a held pulse for this spell is waiting, drop it.
    -- The user has now cast the spell, so the reminder is moot.
    if CR._ClearReplaceHoldFor then CR._ClearReplaceHoldFor(spellID, isItem) end

    -- Stack extras: release any matching extra back to the pool
    local i = 1
    while i <= #activeStackFrames do
        local f = activeStackFrames[i]
        if f ~= pulseFrame
           and f._spellID == spellID and (f._isItem or false) == isItem then
            ReleaseStackFrame(f)  -- modifies activeStackFrames, don't increment
        else
            i = i + 1
        end
    end

    -- Queue: drop any matching queued entries
    local j = 1
    while j <= #pulseQueue do
        local q = pulseQueue[j]
        if q.spellID == spellID and (q.isItem or false) == isItem then
            table.remove(pulseQueue, j)
        else
            j = j + 1
        end
    end
end

-- Max queued icon animations in "queue" mode. Beyond this, oldest queued
-- entries are dropped so the user doesn't see reminders from 10s ago
-- chain-firing after a burst.
local PULSE_QUEUE_MAX = 3
-- Max simultaneous visible icons in "stack" mode.
local STACK_MAX = 5

-- ─────────────────────────────────────────────────────────────────────
-- PER-TRIGGER PULSE PIPELINE
-- ─────────────────────────────────────────────────────────────────────
-- Sister of PlayPulseSound that honors a trigger config's per-trigger
-- sound/TTS overrides. trigger.sound replaces the global soundName,
-- trigger.tts is preferred over the legacy spellTTS map, and
-- trigger.soundDisabled silences this trigger entirely. If a field on
-- the trigger is nil, we fall back to the global db settings (NOT the
-- per-spell maps — those are the legacy single-trigger system that the
-- new multi-trigger system supersedes for spells with a trigger array).
-- Defined without `local` because PlayTriggerSound is forward-declared
-- above (so PlayIconOnFrame's closure resolves it correctly).
function PlayTriggerSound(db, spellID, trigger)
    if not db.soundEnabled then return end
    if trigger.soundDisabled then return end

    -- Cut off any in-flight sound/TTS before this one (cutoffPreviousSound).
    StopPreviousSound(db)

    -- TTS first (priority over sound, matching PlayPulseSound).
    local ttsText = trigger.tts
    if ttsText and ttsText ~= "" then
        local voiceID = ResolveTTSVoiceID(db.ttsVoiceOverride)
        local rate
        if db.ttsRateOverride ~= nil then
            rate = tonumber(db.ttsRateOverride) or 0
        elseif C_TTSSettings and C_TTSSettings.GetSpeechRate then
            rate = C_TTSSettings.GetSpeechRate()
        end
        if SpeakTTS(ttsText, voiceID, rate) then return end
        -- Fall through to sound on TTS failure
    end

    local soundName = trigger.sound
    if not soundName or soundName == "" then
        soundName = db.soundName
    end
    if not soundName or soundName == "None" then return end
    if soundName == "Default" then
        PlaySoundTracked(db, db.fallbackSoundKitID or 12867, db.soundChannel or "Master"); return
    end
    local channel = db.soundChannel or "Master"
    -- LSM lookup must happen here, not as an undefined global. PlayPulseSound
    -- uses the same pattern (line ~1820). Without this, every trigger sound
    -- falls through to PlaySound(fallbackSoundKitID) and ignores the user's
    -- LibSharedMedia selection.
    local path
    if LibStub then
        local lsm = LibStub("LibSharedMedia-3.0", true)
        if lsm then path = lsm:Fetch("sound", soundName, true) end
    end
    if path then PlaySoundFileTracked(db, path, channel)
    else PlaySoundTracked(db, db.fallbackSoundKitID or 12867, channel) end
end

-- ─────────────────────────────────────────────────────────────────────
-- ICON-PULSE ROUTER (shared by DoPulse and DoPulseFromTrigger)
-- ─────────────────────────────────────────────────────────────────────
-- Centralises the dedup / queue / stack / replace pipeline so trigger-
-- driven pulses get the same multi-icon behavior as legacy pulses.
-- Sound is the CALLER's responsibility (PlayPulseSound for legacy,
-- PlayTriggerSound for triggers). This function is icon-only.
--
-- requeueDescriptor: the table to put back into pulseQueue if a queue
-- is needed (DoPulse passes its own {spellID,kind,isItem}; trigger
-- callers pass the same plus a trigger ref — but our queue drain only
-- routes through DoPulseNow which doesn't know about triggers, so for
-- now trigger-fired alerts are queued WITHOUT trigger overrides on
-- drain — sound already fired, the icon-on-drain matches the spell).
-- ── REPLACE-MODE HOLD BUFFER ────────────────────────────────────────
-- When replace mode's guard is active and a new pulse arrives, hold
-- the pulse (not drop it) so it fires when the guard expires OR the
-- current pulse finishes — whichever comes first. Latest-wins: if a
-- newer pulse arrives while one is held, the held one is replaced.
-- Cleared on cancel-on-cast, mode change, and successful drain.
local replaceHold = nil           -- { spellID, kind, isItem, trigger, expireTime, token }
local replaceHoldToken = 0

local function _DrainReplaceHold(reason)
    local hold = replaceHold
    if not hold then return end
    replaceHold = nil
    Log:Write("DEBUG", hold.spellID, string.format(
        "replace drain (reason=%s)", tostring(reason)))
    -- The token is captured by the timer; if a NEWER hold replaced this
    -- one, the timer's token won't match — that case is handled via
    -- replaceHold reassignment below before the timer ever fires. By the
    -- time we get here, hold is the latest valid entry.
    local db = GetDB(); if not db then return end
    if pulseFrame and pulseFrame._ag and pulseFrame._ag:IsPlaying() then
        pulseFrame._ag:Stop()
        StopPulseGlow(pulseFrame)
    end
    PlayIconOnFrame(pulseFrame, db, hold.spellID, hold.isItem, hold.trigger)
end
CR._DrainReplaceHold = _DrainReplaceHold

-- Public helper used by CancelPulseForSpell to drop a held pulse for a
-- spell that the user just cast. Doesn't fire — just discards.
local function _ClearReplaceHoldFor(spellID, isItem)
    if not replaceHold then return end
    if replaceHold.spellID == spellID and (replaceHold.isItem or false) == (isItem or false) then
        replaceHold = nil
    end
end
CR._ClearReplaceHoldFor = _ClearReplaceHoldFor

-- Public helper used by FlushPulseState to wipe the held pulse on
-- mode switch / reset.
local function _WipeReplaceHold()
    replaceHold = nil
end
CR._WipeReplaceHold = _WipeReplaceHold

local function RouteIconPulse(db, spellID, kind, isItem, trigger)
    if not pulseFrame then pulseFrame = CreatePulseFrame() end
    ApplyPulseSettings(db)

    -- Resolve incoming priority once. Default 0 = "no priority".
    local incomingPrio = (trigger and tonumber(trigger.priority)) or 0

    -- Same-spell deduplication — restart the existing frame in place.
    -- Same-spell always wins over priority gating (it's a refresh, not a
    -- replacement) so the user's "still relevant" alert keeps re-firing
    -- as the trigger conditions repeat.
    local function sameAlert(f)
        return f._spellID == spellID and (f._isItem or false) == (isItem or false)
    end
    if pulseFrame._ag and pulseFrame._ag:IsPlaying() and sameAlert(pulseFrame) then
        PlayIconOnFrame(pulseFrame, db, spellID, isItem, trigger)
        return
    end
    for _, f in ipairs(activeStackFrames) do
        if f ~= pulseFrame and sameAlert(f) then
            PlayIconOnFrame(f, db, spellID, isItem, trigger)
            return
        end
    end

    -- ── PRIORITY GATE ──────────────────────────────────────────────
    -- Priority overrides mode/guard: a higher-priority pulse interrupts
    -- whatever is currently playing on the primary, ignoring the
    -- replace-mode guard and the queue-mode "wait your turn" rule.
    -- A lower-priority pulse is dropped entirely (no queue, no hold)
    -- so it can't bump out the elevated alert later either.
    -- Equal priority falls through to the normal mode logic below.
    --
    -- Stack mode is exempt: it's additive by nature (everything coexists)
    -- so priority makes no sense as an interrupt rule. Higher-priority
    -- pulses in stack mode just appear alongside lower-priority ones.
    -- See queue/stack overflow eviction below for how stack-full handles it.
    local primaryBusy = pulseFrame._ag and pulseFrame._ag:IsPlaying()
    local effectiveMode = db.queueMode or "queue"
    if primaryBusy and effectiveMode ~= "stack" then
        local activePrio = tonumber(pulseFrame._priority) or 0
        if incomingPrio > activePrio then
            -- Interrupt: stop the active pulse and play immediately on
            -- the primary. Skip the replace-mode guard. Also discards
            -- any held replace pulse since we're forcing through a
            -- higher-priority one. Stack-mode active extras are NOT
            -- ejected here — stack mode is "additive" by nature; a
            -- priority interrupt just takes over the primary slot and
            -- existing extras finish their own animations.
            Log:Write("DEBUG", spellID, string.format(
                "priority interrupt (in=%d active=%d)", incomingPrio, activePrio))
            pulseFrame._ag:Stop()
            StopPulseGlow(pulseFrame)
            replaceHold = nil
            for i, entry in ipairs(activeStackFrames) do
                if entry == pulseFrame then table.remove(activeStackFrames, i); break end
            end
            PlayIconOnFrame(pulseFrame, db, spellID, isItem, trigger)
            return
        elseif incomingPrio < activePrio then
            -- Drop: the active higher-priority pulse owns the primary
            -- slot for its full duration. Don't enqueue, don't hold,
            -- don't stack — just suppress the lower-priority alert.
            Log:Write("DEBUG", spellID, string.format(
                "priority dropped (in=%d active=%d)", incomingPrio, activePrio))
            return
        end
        -- equal priority → fall through to existing mode logic
    end

    -- Queue mode: dedup against pending entries
    if (db.queueMode or "queue") == "queue" then
        for _, entry in ipairs(pulseQueue) do
            if entry.spellID == spellID and (entry.isItem or false) == (isItem or false) then
                return
            end
        end
    end

    local mode = db.queueMode or "queue"
    -- primaryBusy was computed above for the priority gate; reuse it.

    -- ── REPLACE-MODE GUARD: HOLD-AND-RELEASE ────────────────────────
    -- Old behavior: drop the new pulse if guard is still active.
    -- New behavior: HOLD the new pulse in a single-slot buffer. Fire it
    -- when EITHER the current pulse's animation finishes (via the
    -- _onPulseFinished dispatcher's _DrainReplaceHold call) OR the
    -- guard duration expires (whichever is first). Latest-wins: a
    -- newer pulse arriving during the hold replaces the held one.
    -- The user can still cancel-on-cast: CancelPulseForSpell calls
    -- _ClearReplaceHoldFor which drops the hold without firing.
    if mode == "replace" and primaryBusy then
        local guard = tonumber(db.replaceGuard) or 0
        if guard > 0 and pulseFrame._playedAt then
            local elapsed = GetTime() - pulseFrame._playedAt
            if elapsed < guard then
                -- Guard active — hold the new pulse.
                replaceHoldToken = replaceHoldToken + 1
                local token = replaceHoldToken
                replaceHold = {
                    spellID    = spellID,
                    kind       = kind,
                    isItem     = isItem or false,
                    trigger    = trigger,
                    expireTime = pulseFrame._playedAt + guard,
                    token      = token,
                }
                local remaining = guard - elapsed
                Log:Write("DEBUG", spellID, string.format(
                    "replace hold (elapsed=%.2f guard=%.2f remaining=%.2f token=%d)",
                    elapsed, guard, remaining, token))
                C_Timer.After(remaining, function()
                    -- Token check: if a newer hold replaced this one, or
                    -- the hold was already drained / cancelled, bail.
                    if not replaceHold or replaceHold.token ~= token then return end
                    _DrainReplaceHold("guard_expired")
                end)
                return
            end
        end
    end

    if mode == "replace" or not primaryBusy then
        for i, entry in ipairs(activeStackFrames) do
            if entry == pulseFrame then table.remove(activeStackFrames, i); break end
        end
        PlayIconOnFrame(pulseFrame, db, spellID, isItem, trigger)
        if mode == "stack" then
            table.insert(activeStackFrames, 1, pulseFrame)
            RelayoutStack(db)
        end
        return
    end

    if mode == "queue" then
        local queueMax = tonumber(db.queueMaxLen) or PULSE_QUEUE_MAX
        if #pulseQueue >= queueMax then
            -- Pick the lowest-priority entry to drop. Ties go to the
            -- oldest (lowest index). If the new pulse is strictly lower
            -- than the lowest queued, drop the NEW pulse instead.
            local victimIdx, victimPrio
            for i, entry in ipairs(pulseQueue) do
                local p = (entry.trigger and tonumber(entry.trigger.priority)) or 0
                if victimPrio == nil or p < victimPrio then
                    victimIdx, victimPrio = i, p
                end
            end
            if victimPrio ~= nil and incomingPrio < victimPrio then
                Log:Write("DEBUG", spellID, string.format(
                    "queue full — new pulse priority too low (in=%d minQueued=%d)",
                    incomingPrio, victimPrio))
                return
            end
            local dropped = victimIdx and table.remove(pulseQueue, victimIdx) or nil
            if dropped then
                Log:Write("DEBUG", dropped.spellID, "queue full — dropped lowest-priority entry")
            end
        end
        pulseQueue[#pulseQueue + 1] = { spellID = spellID, kind = kind, isItem = isItem, trigger = trigger }
        Log:Write("DEBUG", spellID, string.format(
            "queue enqueued (depth=%d priority=%d)", #pulseQueue, incomingPrio))
        return
    end

    if mode == "stack" then
        if #activeStackFrames >= STACK_MAX then
            -- Choose eviction victim: pick the LOWEST-priority frame.
            -- Ties go to the OLDEST (first inserted, lowest index).
            -- If the new pulse's priority is lower than every existing
            -- frame's, drop the new pulse entirely instead of evicting
            -- a more-important one.
            local victim, victimPrio, victimIdx = nil, nil, nil
            for i, f in ipairs(activeStackFrames) do
                local p = tonumber(f._priority) or 0
                if victimPrio == nil or p < victimPrio then
                    victim, victimPrio, victimIdx = f, p, i
                end
            end
            if victim and victimPrio ~= nil and incomingPrio < victimPrio then
                -- New pulse is lower than the lowest-priority active
                -- frame — drop it rather than make room.
                Log:Write("DEBUG", spellID, string.format(
                    "stack full — new pulse priority too low (in=%d minActive=%d)",
                    incomingPrio, victimPrio))
                return
            end
            if victim then
                if victim == pulseFrame then
                    pulseFrame._ag:Stop()
                    for i, entry in ipairs(activeStackFrames) do
                        if entry == pulseFrame then table.remove(activeStackFrames, i); break end
                    end
                    PlayIconOnFrame(pulseFrame, db, spellID, isItem, trigger)
                    table.insert(activeStackFrames, 1, pulseFrame)
                    RelayoutStack(db)
                    return
                else
                    ReleaseStackFrame(victim)
                end
            end
        end
        local primaryInStack = false
        for _, entry in ipairs(activeStackFrames) do
            if entry == pulseFrame then primaryInStack = true; break end
        end
        if not primaryInStack then
            table.insert(activeStackFrames, 1, pulseFrame)
        end
        local extra = GetExtraFrame(db)
        table.insert(activeStackFrames, extra)
        RelayoutStack(db)
        PlayIconOnFrame(extra, db, spellID, isItem, trigger)
        return
    end
end
CR._RouteIconPulse = RouteIconPulse

-- Fire a pulse using a trigger config's per-trigger overrides. Mirrors
-- DoPulse but routes sound through PlayTriggerSound and consults the
-- trigger's showIcon flag for icon visibility. Used by the multi-trigger
-- system (Engine:_FireTrigger) — DoPulse / DoPulseNow remain unchanged
-- for the legacy single-trigger code path.
function CR.DoPulseFromTrigger(spellID, kind, isItem, trigger)
    local db = GetDB(); if not db then return end
    if not trigger then return end

    -- Icon visibility: trigger.showIcon overrides global iconEnabled and
    -- the per-spell spellIconDisabled flag. nil = use global.
    local shouldShow
    if trigger.showIcon == false then
        shouldShow = false
    elseif trigger.showIcon == true then
        shouldShow = (db.iconEnabled ~= false)
    else
        shouldShow = ShouldShowIconFor(db, spellID, isItem)
    end

    if not shouldShow then
        -- Sound-only path: no icon was requested or iconEnabled is off.
        -- Fire sound/TTS directly here since PlayIconOnFrame won't run.
        -- This is the ONLY path where sound fires without an icon — every
        -- other path goes through PlayIconOnFrame which fires sound and
        -- animation in lock-step.
        PlayTriggerSound(db, spellID, trigger)
        return
    end

    -- Route through the same dedup/queue/stack/replace pipeline as DoPulse
    -- so multi-trigger pulses honor the user's queueMode setting (stack
    -- mode shows side-by-side icons, queue mode chains them, etc.).
    -- Pass the trigger so per-trigger animStyle / glowType / glowColor
    -- propagate through to PlayIconOnFrame. PlayIconOnFrame fires sound
    -- in lock-step with the animation, so we DO NOT play sound here —
    -- otherwise queue/replace/priority paths would play sound for pulses
    -- that get held, dropped, or rerouted.
    RouteIconPulse(db, spellID, kind, isItem, trigger)
end

local function DoPulse(spellID, kind, isItem)
    local db = GetDB(); if not db then return end

    if not ShouldShowIconFor(db, spellID, isItem) then
        -- Sound-only path: no icon for this alert. Fire sound directly
        -- here since PlayIconOnFrame won't run. All other paths (icon
        -- shown) get sound from PlayIconOnFrame so audio and animation
        -- start in the same frame.
        PlayPulseSound(db, spellID)
        return
    end

    -- Sound is fired from PlayIconOnFrame (inside RouteIconPulse →
    -- PlayIconOnFrame) so audio and animation are guaranteed to start
    -- together. If queue/replace/priority logic decides to hold, drop,
    -- or reroute this pulse, sound also waits / drops / reroutes — no
    -- desync where the user hears a sound for a pulse they never see.
    RouteIconPulse(db, spellID, kind, isItem)
end

function CR.ShowAnchor()
    local db = GetDB(); if not db then return end
    if not pulseFrame then pulseFrame = CreatePulseFrame() end
    if not anchorFrame then
        anchorFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        anchorFrame:SetFrameStrata("HIGH")
        anchorFrame:SetBackdrop({
            bgFile = "Interface/Buttons/WHITE8X8",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        anchorFrame:SetBackdropColor(0, 0, 0, 0.15)
        anchorFrame:SetBackdropBorderColor(0.7, 0.7, 0.7, 0.9)
        local label = anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER"); label:SetText("Cooldown Reminder")
    end
    anchorFrame:ClearAllPoints(); anchorFrame:SetAllPoints(pulseFrame)
    anchorFrame:EnableMouse(true)
    anchorFrame:SetScript("OnMouseDown", function()
        if GetDB() and not GetDB().locked then pulseFrame:StartMoving() end
    end)
    anchorFrame:SetScript("OnMouseUp", function()
        local db2 = GetDB()
        if db2 and not db2.locked then
            pulseFrame:StopMovingOrSizing()
            local point, _, relPoint, x, y = pulseFrame:GetPoint(1)
            db2.point = point; db2.relPoint = relPoint
            db2.x = math.floor(x + 0.5); db2.y = math.floor(y + 0.5)
        end
    end)
    anchorFrame:Show()
    ApplyPulseSettings(db)
end

function CR.HideAnchor()
    if anchorFrame then anchorFrame:Hide() end
end

function CR.ApplySettings()
    local db = GetDB(); if not db then return end
    ApplyPulseSettings(db)
    Engine:RebuildTrackedSpells("apply_settings")
end

-- Flush ALL pulse state — visible icons, queue, stack frames, pool — so
-- the next pulse starts from a clean slate. Used when the user switches
-- queueMode mid-runtime; without this, a Stack-mode session can leave
-- extras behind that confuse Replace/Queue routing, and a Queue-mode
-- session can leave pending entries that drain into the new mode.
-- Reload would reset all of this naturally; this helper avoids the reload.
function CR.FlushPulseState()
    -- Hide and clear all stack frames (primary + extras).
    -- Walk a copy because ReleaseStackFrame mutates the list.
    local snapshot = {}
    for i = 1, #activeStackFrames do snapshot[i] = activeStackFrames[i] end
    for _, f in ipairs(snapshot) do
        if f._ag and f._ag:IsPlaying() then f._ag:Stop() end
        f:Hide()
        if f ~= pulseFrame then
            -- Return extras to the pool for reuse; primary stays the primary.
            extraFramePool[#extraFramePool + 1] = f
        end
    end
    wipe(activeStackFrames)

    -- Stop the primary even if it wasn't in activeStackFrames (e.g. replace
    -- mode never adds it to the array but it can still be animating).
    if pulseFrame and pulseFrame._ag and pulseFrame._ag:IsPlaying() then
        pulseFrame._ag:Stop()
        pulseFrame:Hide()
    end

    -- Drop any pending queued pulses.
    wipe(pulseQueue)

    -- Drop any held replace-mode pulse waiting on the guard.
    if CR._WipeReplaceHold then CR._WipeReplaceHold() end
end

function CR.TestPulse(spellID)
    local db = GetDB(); if not db then return false end
    if not spellID then
        local testIsItem = false
        for k, enabled in pairs(db.whitelist or {}) do
            if enabled then
                local itemIDStr = type(k) == "string" and k:match("^i:(%d+)")
                if itemIDStr then
                    spellID = tonumber(itemIDStr); testIsItem = true
                else
                    spellID = tonumber(k); testIsItem = false
                end
                if spellID then break end
            end
        end
        if not spellID then return false end
        DoPulse(spellID, "TEST", testIsItem); return true
    end
    DoPulse(tonumber(spellID) or 0, "TEST"); return true
end

-- Collect up to N distinct enabled reminders and fire staggered test pulses
-- so the user can see queue/stack behavior with real icons. count defaults
-- to 3; stagger defaults to 0.25s. If fewer than `count` reminders exist,
-- fires only as many distinct ones as are available — never loops back to
-- replay the first spell (that would just dedupe into the existing frame
-- and look like a glitch).
function CR.TestPulseMultiple(count, stagger)
    local db = GetDB(); if not db then return false end
    count   = tonumber(count)   or 3
    stagger = tonumber(stagger) or 0.25

    -- Gather up to `count` enabled reminders
    local picks = {}
    for k, enabled in pairs(db.whitelist or {}) do
        if enabled then
            local itemIDStr = type(k) == "string" and k:match("^i:(%d+)")
            if itemIDStr then
                local id = tonumber(itemIDStr)
                if id then picks[#picks + 1] = { spellID = id, isItem = true } end
            else
                local id = tonumber(k)
                if id then picks[#picks + 1] = { spellID = id, isItem = false } end
            end
            if #picks >= count then break end
        end
    end
    if #picks == 0 then return false end

    for i = 1, #picks do
        local pick = picks[i]
        if i == 1 then
            DoPulse(pick.spellID, "TEST_MULTI", pick.isItem)
        else
            C_Timer.After((i - 1) * stagger, function()
                DoPulse(pick.spellID, "TEST_MULTI", pick.isItem)
            end)
        end
    end
    return true
end

-- ===================================================================
-- TOOLTIP SPELL/ITEM ID DISPLAY
-- ===================================================================
local function IsTooltipEnabled()
    local db = GetDB()
    return db and db.showSpellIDsInTooltips == true
end

local function EnsureClearHook(tooltip)
    if tooltip.__arcCRClearHook then return end
    tooltip.__arcCRClearHook = true
    tooltip:HookScript("OnTooltipCleared", function(tip)
        tip.__arcCRLastSpellID = nil
        tip.__arcCRLastItemID  = nil
    end)
end

local function AddSpellIdLine(tooltip, spellID)
    if not tooltip or type(spellID) ~= "number" then return end
    -- Secret spellIDs (e.g. aura tooltips on nameplates in restricted contexts)
    -- can't be compared, formatted, or displayed. Bail silently — the user
    -- wouldn't see a meaningful number anyway.
    if issecretvalue and issecretvalue(spellID) then return end
    if spellID <= 0 then return end
    EnsureClearHook(tooltip)
    if tooltip.__arcCRLastSpellID == spellID then return end
    tooltip.__arcCRLastSpellID = spellID
    tooltip:AddLine(string.format("Spell ID: %d (ArcUI)", spellID),
        CR.TOOLTIP_R, CR.TOOLTIP_G, CR.TOOLTIP_B)
    tooltip:Show()
end

local function AddItemIdLine(tooltip, itemID)
    if not tooltip or type(itemID) ~= "number" then return end
    if issecretvalue and issecretvalue(itemID) then return end
    if itemID <= 0 then return end
    EnsureClearHook(tooltip)
    if tooltip.__arcCRLastItemID == itemID then return end
    tooltip.__arcCRLastItemID = itemID
    tooltip:AddLine(string.format("Item ID: %d (ArcUI)", itemID),
        CR.TOOLTIP_R, CR.TOOLTIP_G, CR.TOOLTIP_B)
    tooltip:Show()
end

local function TryGetSpellIDFromTooltip(tooltip, data)
    if tooltip and tooltip.GetSpell then
        local _, _, sid = tooltip:GetSpell()
        if type(sid) == "number" then return sid end
    end
    if data then
        local spellID = data.spellID or data.id
        if type(spellID) == "number" then return spellID end
        if type(spellID) == "string" then local n = tonumber(spellID); if n then return n end end
        if type(data.hyperlink) == "string" then
            local n = tonumber(string.match(data.hyperlink, "spell:(%d+)")); if n then return n end
        end
    end
    return nil
end

local function TryGetItemIDFromTooltip(tooltip)
    if not tooltip then return nil end
    if tooltip.GetItem then
        local _, itemLink = tooltip:GetItem()
        if type(itemLink) == "string" then
            local id = tonumber(itemLink:match("item:(%d+)"))
            if id and id > 0 then return id end
        end
    end
    return nil
end

local function RegisterTooltipHooks()
    local function OnSpellTooltip(tooltip, data)
        if not IsTooltipEnabled() then return end
        local spellID = TryGetSpellIDFromTooltip(tooltip, data)
        if spellID then AddSpellIdLine(tooltip, spellID) end
    end
    local function OnItemTooltip(tooltip, data)
        if not IsTooltipEnabled() then return end
        local itemID = TryGetItemIDFromTooltip(tooltip)
        if itemID then AddItemIdLine(tooltip, itemID) end  -- AddItemIdLine guards
    end

    local registered = false
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        local function tryReg(typeKey, cb)
            local dt = Enum.TooltipDataType[typeKey]
            if dt ~= nil then TooltipDataProcessor.AddTooltipPostCall(dt, cb); return true end
            return false
        end
        registered = tryReg("Spell",    OnSpellTooltip) or registered
        registered = tryReg("UnitAura", OnSpellTooltip) or registered
        registered = tryReg("Aura",     OnSpellTooltip) or registered
        registered = tryReg("Item",     OnItemTooltip)  or registered
    end
    if not registered and GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetSpell", function(tip)
            if not IsTooltipEnabled() then return end
            local sid = TryGetSpellIDFromTooltip(tip, nil)
            if sid then AddSpellIdLine(tip, sid) end
        end)
        GameTooltip:HookScript("OnTooltipSetItem", function(tip)
            if not IsTooltipEnabled() then return end
            local id = TryGetItemIDFromTooltip(tip)
            if id and id > 0 then AddItemIdLine(tip, id) end
        end)
    end
end

-- ===================================================================
-- EVENT FRAME
-- ===================================================================
local eventFrame = CreateFrame("Frame")

local function InitModule()
    local db = GetDB()
    if not db then return end
    Engine:Init()
    Engine:SetPulseHandler(DoPulse)
    Engine:RebuildTrackedSpells("init")
    ApplyPulseSettings(db)
    RegisterTooltipHooks()
    Log:WriteAlways("INFO", nil, "ArcUI Cooldown Reminder loaded")
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
-- DISABLED with aura-gate system:
-- eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
eventFrame:RegisterEvent("SPELL_UPDATE_USES")             -- charge-like "uses" tracking (mirrors ArcAurasCooldown)
eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
-- Item-path reset/sync events (research confirmed via ArcUI_CDMItemShadowTest)
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")        -- slot re-detection (bag↔slot13↔slot14)
eventFrame:RegisterEvent("ENCOUNTER_END")                   -- boss kill/wipe resets trinkets + combat potions
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")            -- leaving combat unlocks once-per-combat items
eventFrame:RegisterEvent("CHALLENGE_MODE_START")            -- M+ key start
eventFrame:RegisterEvent("CHALLENGE_MODE_RESET")            -- M+ key reset
eventFrame:RegisterEvent("ARENA_OPPONENT_UPDATE")           -- arena start CD reset
eventFrame:RegisterEvent("PLAYER_EQUIPED_SPELLS_CHANGED")   -- item charge changes (Healthstone etc.)
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")          -- late item-data loads (re-resolve use-spell)
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")   -- proc glow ON (action-button overlay; spellID non-secret)
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")   -- proc glow OFF

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        -- Init after ArcUI's DB is ready (ArcUI_Options.lua registers on PLAYER_LOGIN
        -- so we defer to PLAYER_LOGIN via a flag instead of ADDON_LOADED)
        if addonName == ADDON then
            self:UnregisterEvent("ADDON_LOADED")
            -- AceDB isn't ready yet at ADDON_LOADED; init fires after PLAYER_LOGIN
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- AceDB is ready by PLAYER_ENTERING_WORLD (after PLAYER_LOGIN)
        if not Engine._initTime then
            InitModule()
        end
        if Engine and Engine._initTime then Engine._initTime = GetTime() end
        if Engine and Engine._EvaluateZoneEnabled then Engine:_EvaluateZoneEnabled() end
        return
    end

    -- Guard: only handle events after init
    if not Engine._initTime then return end
    local db = GetDB()
    if not db or not db.enabled then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" then Engine:OnPlayerCastSucceeded(spellID) end
        return
    end
    -- DISABLED with aura-gate system:
    -- if event == "UNIT_AURA" then
    --     local unit = ...
    --     if unit == "player" then Engine:OnUnitAura() end
    --     return
    -- end
    if event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" or event == "SPELL_UPDATE_USES" then
        Engine:OnCooldownUpdate(event, ...)
        return
    end
    if event == "BAG_UPDATE_COOLDOWN" then
        Engine:OnItemCooldownUpdate()
        return
    end
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        local slot = ...
        Engine:OnEquipmentChanged(slot)
        return
    end
    if event == "GET_ITEM_INFO_RECEIVED" then
        local itemID = ...
        Engine:OnItemInfoReceived(itemID)
        return
    end
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        local spellID = ...
        Engine:OnSpellActivationOverlayShow(spellID)
        return
    end
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local spellID = ...
        Engine:OnSpellActivationOverlayHide(spellID)
        return
    end
    if event == "ENCOUNTER_END"
        or event == "PLAYER_REGEN_ENABLED"
        or event == "CHALLENGE_MODE_START"
        or event == "CHALLENGE_MODE_RESET"
        or event == "ARENA_OPPONENT_UPDATE"
        or event == "PLAYER_EQUIPED_SPELLS_CHANGED" then
        Engine:OnItemReset(event)
        return
    end
end)

-- ===================================================================
-- SLASH COMMAND  /arcuicr  (convenience, main access via /arcui)
-- ===================================================================
SLASH_ARCUICR1 = "/arcuicr"
SlashCmdList["ARCUICR"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S+)%s*(.-)%s*$")
    cmd = cmd and cmd:lower() or ""
    if cmd == "" then
        ns.API.OpenOptions()
        C_Timer.After(0.1, function()
            local ACD = LibStub and LibStub("AceConfigDialog-3.0", true)
            if ACD then ACD:SelectGroup("ArcUI", "cooldowns", "cooldownReminder") end
        end)
    elseif cmd == "test" then
        CR.TestPulse(tonumber(rest))
    elseif cmd == "add" then
        local ok, err = Engine:AddSpell(tonumber(rest))
        print(ok and "|cff00ccffArcUI|r CR: Added " .. tostring(rest)
                  or "|cff00ccffArcUI|r CR: " .. tostring(err))
    elseif cmd == "remove" then
        local ok, err = Engine:RemoveSpell(tonumber(rest))
        print(ok and "|cff00ccffArcUI|r CR: Removed " .. tostring(rest)
                  or "|cff00ccffArcUI|r CR: " .. tostring(err))
    elseif cmd == "additem" then
        local id = ParseItemID(rest)
        local ok, err = Engine:AddItem(id)
        print(ok and "|cff00ccffArcUI|r CR: Added item " .. tostring(id)
                  or "|cff00ccffArcUI|r CR: " .. tostring(err))
    elseif cmd == "migrate" then
        -- Force-run the legacy → triggers migration RIGHT NOW. Walks
        -- db.whitelist and creates a default trigger array for any spell
        -- that doesn't have one. Also reports a count so the user can
        -- confirm something happened.
        local db = GetDB()
        if not db or not db.whitelist then
            print("|cff00ccffArcUI|r CR: No database loaded yet."); return
        end
        local before = 0
        for _, _ in pairs(db.whitelist) do before = before + 1 end
        local seeded = 0
        if db.spellTriggers then
            for k in pairs(db.whitelist) do
                local sk = tostring(k)
                if not db.spellTriggers[sk] or #db.spellTriggers[sk] == 0 then
                    seeded = seeded + 1
                end
            end
        else
            seeded = before
        end
        Engine:_MigrateLegacyTriggers()
        Engine:RebuildTrackedSpells("manual_migrate")
        print(string.format("|cff00ccffArcUI|r CR: Migration ran. "
            .. "%d spell(s) in whitelist, %d needed triggers, all done.",
            before, seeded))
    elseif cmd == "voices" then
        -- List all available TTS voices (for debugging male/female selection)
        if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then
            print("|cff00ccffArcUI|r CR: TTS voice list API not available"); return
        end
        local voices = C_VoiceChat.GetTtsVoices()
        if type(voices) ~= "table" then
            print("|cff00ccffArcUI|r CR: Could not fetch voice list"); return
        end
        print("|cff00ccffArcUI|r CR: " .. #voices .. " TTS voice(s) available:")
        for i, v in ipairs(voices) do
            local name   = tostring(v and v.name or "?")
            local id     = tostring(v and v.voiceID or "?")
            local gender = (v and v.gender ~= nil) and tostring(v.gender) or "nil"
            local lang   = tostring(v and v.language or "?")
            print(string.format("  [%d] id=%s gender=%s lang=%s name=%s",
                i, id, gender, lang, name))
        end
        -- Report which API path we'd use for speaking
        if C_CombatAudioAlert and C_CombatAudioAlert.SpeakText then
            local catVoice = "?"
            if Enum and Enum.CombatAudioAlertCategory and C_CombatAudioAlert.GetCategoryVoice then
                catVoice = tostring(C_CombatAudioAlert.GetCategoryVoice(Enum.CombatAudioAlertCategory.General))
            end
            local speed = "?"
            if C_CombatAudioAlert.GetSpeakerSpeed then
                speed = tostring(C_CombatAudioAlert.GetSpeakerSpeed())
            end
            print(string.format("  |cff00ff88API: C_CombatAudioAlert (new)|r  General voice=%s speed=%s", catVoice, speed))
        else
            print("  |cffffaa00API: C_VoiceChat.SpeakText (legacy)|r")
        end
    end
end