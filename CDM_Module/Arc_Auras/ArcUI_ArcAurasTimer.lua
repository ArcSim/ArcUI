-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Arc Auras TIMER — Custom cooldown frames driven by a user timer.
--
-- Behaviour:
--   User defines (spellID, duration). On UNIT_SPELLCAST_SUCCEEDED for player
--   matching that spellID, a cooldown of `duration` seconds is started on
--   the frame. Icon and visuals reuse ArcAuras frame creation + ApplySpell-
--   StateVisuals pipeline; the ONLY difference from a normal spell frame is
--   that the cooldown comes from our own timer, not C_Spell cooldown APIs.
--
-- State is plain math: isOnCD = GetTime() < (startTime + duration).
-- No secret values involved, no shadow frames required.
--
-- Frames register with ArcAuras.CreateFrame as type="timer" so they inherit
-- CDMEnhance, Masque, CDMGroups (positioning/movement), Options pipeline.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local ArcAuras = ns.ArcAuras
if not ArcAuras then
    print("|cffFF4444[Arc Auras Timer]|r ERROR: ArcAuras core not loaded")
    return
end

local ArcAurasTimer = {}
ns.ArcAurasTimer = ArcAurasTimer

-- State
ArcAurasTimer.timers      = {}   -- arcID -> timerData (engine state)
ArcAurasTimer.spellsByID  = {}   -- spellID -> { [arcID]=true, ... } (multi)

-- ═══════════════════════════════════════════════════════════════════════════
-- DB
-- ═══════════════════════════════════════════════════════════════════════════

local function GetDB()
    local db = ArcAuras.GetDB and ArcAuras.GetDB() or nil
    if not db then return nil end
    db.customTimers = db.customTimers or {}
    return db
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function safeSpellID(id) local n = tonumber(id); return (n and n > 0) and n or nil end
local function safeDuration(d) local n = tonumber(d); return (n and n > 0) and n or nil end

-- ═══════════════════════════════════════════════════════════════════════════
-- TRIGGER NORMALIZATION
--
-- Timers store start/end triggers as multi-event sets:
--   trigger = {
--     events  = { cast = true, proc = true, ... },  -- OR-set of event names
--     spellID = nil | number,                        -- optional ID override
--     restartOnRefire = bool,                        -- start trigger only
--   }
--
-- Both fields are migrated from all older schemas on every load/edit so
-- SavedVariables keep up with changes automatically. Empty events set is
-- valid (Start: never fires; End: no early termination).
-- ═══════════════════════════════════════════════════════════════════════════

local START_EVENTS = { cast = true, cooldown = true, proc = true }
local END_EVENTS   = { cast = true, proc = true, procEnd = true, death = true }

local function NormalizeEventSet(raw, allowed)
    local out = {}
    if type(raw) == "table" then
        if type(raw.events) == "table" then
            for k, v in pairs(raw.events) do
                if v and allowed[k] then out[k] = true end
            end
        end
        -- Absorb legacy single .event field only if no new-shape set found.
        if next(out) == nil and type(raw.event) == "string"
           and raw.event ~= "none" and allowed[raw.event] then
            out[raw.event] = true
        end
    end
    return out
end

-- Public: normalize a whole timer config table's triggers. Mutates config
-- in place AND returns the normalized start/end trigger descriptors.
local function NormalizeConfigTriggers(config)
    if not config then return nil, nil end

    local startEvents = NormalizeEventSet(config.startTrigger, START_EVENTS)
    if next(startEvents) == nil then
        -- Seed from legacy v1 triggerType, or default to cast.
        local legacy = config.triggerType
        if legacy == "cast" or legacy == "cooldown" then
            startEvents[legacy] = true
        else
            startEvents.cast = true
        end
    end

    local endEvents = NormalizeEventSet(config.endTrigger, END_EVENTS)
    if config.resetOnDeath == true then
        endEvents.death = true
    end

    local restartOnRefire
    if type(config.startTrigger) == "table"
       and type(config.startTrigger.restartOnRefire) == "boolean" then
        restartOnRefire = config.startTrigger.restartOnRefire
    else
        restartOnRefire = (config.resetOnRecast == true)
    end

    -- Stack-tracking fields. trackStacks is an opt-in bool; stackMode
    -- controls whether stacks die with the duration ("refresh"), each
    -- stack has its own independent expiry ("independent"), or the timer
    -- runs on a generator/spender economy ("consume"). Default is
    -- "refresh" which matches the simpler, more common case.
    local trackStacks = type(config.startTrigger) == "table"
                        and config.startTrigger.trackStacks == true
    local stackMode = type(config.startTrigger) == "table"
                      and config.startTrigger.stackMode
    if stackMode ~= "refresh" and stackMode ~= "independent"
       and stackMode ~= "consume" then
        stackMode = "refresh"
    end

    -- Consume-mode fields: max cap, initial seed, on-empty action, and
    -- the generators/spenders arrays. Each entry mirrors the start/end
    -- trigger shape: { events = {cast=true,...}, spellID = N, amount = N }.
    -- Normalize defensively — accept any sane input, drop garbage.
    local function normalizeEntries(raw)
        local out = {}
        if type(raw) ~= "table" then return out end
        for i = 1, #raw do
            local e = raw[i]
            if type(e) == "table" then
                local events = {}
                if type(e.events) == "table" then
                    for k, v in pairs(e.events) do
                        if v and START_EVENTS[k] then events[k] = true end
                    end
                end
                local sid = tonumber(e.spellID)
                local amt = tonumber(e.amount)
                if not amt or amt <= 0 then amt = 1 end
                out[#out + 1] = {
                    events  = events,
                    spellID = (sid and sid > 0) and sid or nil,
                    amount  = amt,
                }
            end
        end
        return out
    end

    local generators, spenders = {}, {}
    local maxStacks, initialStacks, onEmptyAction, noMaxStacks
    if type(config.startTrigger) == "table" then
        generators = normalizeEntries(config.startTrigger.generators)
        spenders   = normalizeEntries(config.startTrigger.spenders)
        maxStacks  = tonumber(config.startTrigger.maxStacks)
        initialStacks = tonumber(config.startTrigger.initialStacks)
        noMaxStacks = config.startTrigger.noMaxStacks == true
        local oea = config.startTrigger.onEmptyAction
        if oea == "stop" or oea == "keep" or oea == "hide" then
            onEmptyAction = oea
        end
    end
    if not maxStacks or maxStacks <= 0 then maxStacks = 5 end
    if not initialStacks or initialStacks < 0 then initialStacks = 0 end
    -- Only clamp initialStacks against maxStacks when there IS a max. With
    -- noMaxStacks=true the user is allowed any seed value.
    if not noMaxStacks and initialStacks > maxStacks then
        initialStacks = maxStacks
    end
    if not onEmptyAction then onEmptyAction = "keep" end

    -- Extra spell IDs — optional list of additional spellIDs that ALSO
    -- count as a match for this trigger. Use case: one icon tracking "any
    -- potion in this list" — different IDs but same duration. Each entry
    -- is just a number; primary spellID stays in the singular field and
    -- still drives the icon, range check, and reverse lookup. The matcher
    -- (TriggerMatches) checks evSpellID against {primary} ∪ extras.
    local function normalizeIDList(raw)
        local out, seen = {}, {}
        if type(raw) ~= "table" then return out end
        for i = 1, #raw do
            local n = tonumber(raw[i])
            if n and n > 0 and not seen[n] then
                seen[n] = true
                out[#out + 1] = n
            end
        end
        return out
    end

    local startExtras, endExtras = {}, {}
    if type(config.startTrigger) == "table" then
        startExtras = normalizeIDList(config.startTrigger.extraSpellIDs)
    end
    if type(config.endTrigger) == "table" then
        endExtras = normalizeIDList(config.endTrigger.extraSpellIDs)
    end

    local startTrig = {
        events          = startEvents,
        spellID         = (type(config.startTrigger) == "table"
                           and tonumber(config.startTrigger.spellID)) or nil,
        extraSpellIDs   = startExtras,
        restartOnRefire = restartOnRefire,
        trackStacks     = trackStacks,
        stackMode       = stackMode,
        -- consume-mode config (always present; only consulted when
        -- stackMode == "consume" so other modes are unaffected)
        maxStacks       = maxStacks,
        noMaxStacks     = noMaxStacks,
        initialStacks   = initialStacks,
        onEmptyAction   = onEmptyAction,
        generators      = generators,
        spenders        = spenders,
    }
    local endTrig = {
        events        = endEvents,
        spellID       = (type(config.endTrigger) == "table"
                         and tonumber(config.endTrigger.spellID)) or nil,
        extraSpellIDs = endExtras,
    }
    config.startTrigger = startTrig
    config.endTrigger   = endTrig
    return startTrig, endTrig
end

-- Expose for Options UI modules that want to write config and re-normalize.
ArcAurasTimer.NormalizeConfigTriggers = NormalizeConfigTriggers

local function GetSpellNameAndIcon(spellID)
    local info = C_Spell.GetSpellInfo(spellID)
    if info then
        return info.name or ("Spell " .. spellID), info.iconID or info.originalIconID
    end
    return "Spell " .. spellID, nil
end

-- Add to reverse lookup. Multiple arcIDs can watch the same spellID.
local function IndexBySpell(spellID, arcID)
    ArcAurasTimer.spellsByID[spellID] = ArcAurasTimer.spellsByID[spellID] or {}
    ArcAurasTimer.spellsByID[spellID][arcID] = true
end
local function UnindexBySpell(spellID, arcID)
    local set = ArcAurasTimer.spellsByID[spellID]
    if not set then return end
    set[arcID] = nil
    if next(set) == nil then ArcAurasTimer.spellsByID[spellID] = nil end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FEED / STATE
-- ═══════════════════════════════════════════════════════════════════════════

local function IsTimerActive(td)
    if not td.active or not td.startTime then return false end
    return GetTime() < (td.startTime + td.duration)
end

-- Public accessor — called by ArcAurasCooldown.GetCooldownState and the
-- timer-branch short-circuit in FeedCooldown. Returns true iff the timer
-- for this arcID is currently running.
function ArcAurasTimer.IsTimerRunning(arcID)
    local td = ArcAurasTimer.timers[arcID]
    if not td then return false end
    return IsTimerActive(td)
end

-- Push the durObj to the VISIBLE cooldown frame. When timer is inactive /
-- expired, clear the cooldown. OnCooldownDone handles the ready transition.
local function FeedVisible(td)
    local frame = td.frame
    if not frame or not frame.Cooldown then return end

    if IsTimerActive(td) then
        if frame._durationObj and C_DurationUtil then
            frame._durationObj:SetTimeFromStart(td.startTime, td.duration)
            frame.Cooldown:SetCooldownFromDurationObject(frame._durationObj, true)
        else
            frame.Cooldown:SetCooldown(td.startTime, td.duration)
        end
    else
        frame.Cooldown:Clear()
    end
end

-- Apply the visual pipeline directly via ApplySpellStateVisuals. We do NOT
-- route through FeedCooldown here — FeedCooldown's timer short-circuit
-- calls back into us (RefreshTimerFrame), which would recurse.
local function ApplyVisuals(td)
    local fd = td.fd
    if not fd then return end
    local isOnCD = IsTimerActive(td)
    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ApplySpellStateVisuals then
        ns.ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD, nil, false)
    end
end

-- Refresh: push durObj, apply visuals. Single source of truth.
local function RefreshTimer(td)
    FeedVisible(td)
    ApplyVisuals(td)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ACTIVE TIMER PERSISTENCE
--
-- When the player reloads mid-timer, we want the timer to pick up where it
-- left off. Runtime state (td.active, td.startTime) is lost on reload, so
-- we persist expiration in wall-clock form (Lua's time(), not GetTime())
-- under ns.db.char.arcAuras.activeTimerState. This survives /reload AND
-- full client quit+restart — critical because GetTime() resets on full
-- restart while time() doesn't.
--
-- Shape:
--   db.activeTimerState[arcID] = { expireAt = <unix seconds> }
--
-- Lifecycle:
--   StartTimer     → write expireAt = time() + duration
--   StopTimer      → clear
--   OnCooldownDone → clear (natural expiration)
--   CreateTimer    → on load, if expireAt > time(), resume from the
--                    computed remaining; if <= time(), clear (already expired)
--
-- Kept in its own sub-table (NOT inside customTimers[arcID]) so it doesn't
-- leak into exports/imports or profile copies.
-- ═══════════════════════════════════════════════════════════════════════════

local function GetActiveState()
    local db = GetDB()
    if not db then return nil end
    if not db.activeTimerState then db.activeTimerState = {} end
    return db.activeTimerState
end

-- Persist the active snapshot: expiration + stack count + per-stack expiries.
-- Callers pass the current td, so the single entry-point handles every mode.
-- For Mode A (refresh) stackExpiries is empty; for Mode B (independent) the
-- list is the source of truth.
local function RecordActive(arcID, td, duration)
    local state = GetActiveState()
    if not state then return end
    local entry = state[arcID] or {}
    entry.expireAt = time() + duration
    if td then
        entry.stacks        = td.stacks or 0
        entry.stackExpiries = td.stackExpiries and { unpack(td.stackExpiries) } or nil
    end
    state[arcID] = entry
end

-- Update persisted stacks + expiries WITHOUT touching expireAt. Used when
-- the timer's duration isn't changing but stack state is — i.e. stack-only
-- ticks in independent mode, or refire bumps without restart.
local function PersistStacks(arcID, td)
    local state = GetActiveState()
    if not state or not state[arcID] then return end
    state[arcID].stacks = td and td.stacks or 0
    state[arcID].stackExpiries =
        td and td.stackExpiries and #td.stackExpiries > 0
        and { unpack(td.stackExpiries) } or nil
end

local function ClearActive(arcID)
    local state = GetActiveState()
    if state then state[arcID] = nil end
end

-- ─────────────────────────────────────────────────────────────────────────
-- STACK HELPERS
--
-- Two modes:
--   "refresh"     — stacks increment on every start-trigger fire; they all
--                   die together when the duration swipe completes. Pure
--                   counter, no per-stack state, no scheduling.
--   "independent" — each stack carries its own expiry timestamp in
--                   td.stackExpiries. A C_Timer.After is scheduled for the
--                   next soonest expiry; when it fires we drop that entry,
--                   decrement stacks, and reschedule for the next. Zero
--                   idle CPU — one pending C_Timer per active timer at a
--                   time, driven purely by wall-clock transitions.
-- ─────────────────────────────────────────────────────────────────────────

local ScheduleNextStackExpiry  -- forward declaration

-- Update the stack count shown on the icon. We drive the same fontstring
-- the ArcAuras chargeText system manages (frame._arcStackText), via the
-- public ApplyStackText hook so per-icon chargeText visibility / styling
-- is respected automatically.
local function RefreshStackDisplay(td)
    if not td or not td.frame then return end
    if ns.ArcAuras and ns.ArcAuras.InvalidateStackCache then
        ns.ArcAuras.InvalidateStackCache(td.arcID)
    end
    if ns.ArcAuras and ns.ArcAuras.ApplyStackText then
        ns.ArcAuras.ApplyStackText(td.frame, td.arcID)
    end
end

-- Drop expired entries from td.stackExpiries. Returns the number removed.
local function PruneExpiredStacks(td)
    if not td.stackExpiries or #td.stackExpiries == 0 then return 0 end
    local now = time()
    local removed = 0
    for i = #td.stackExpiries, 1, -1 do
        if td.stackExpiries[i] <= now then
            table.remove(td.stackExpiries, i)
            removed = removed + 1
        end
    end
    if removed > 0 then
        td.stacks = math.max(0, (td.stacks or 0) - removed)
    end
    return removed
end

-- Schedule the next C_Timer for the soonest upcoming stack expiry. Only
-- ONE timer is in flight at a time; cancellation happens implicitly by
-- bumping a generation counter — the callback checks the generation and
-- no-ops if the list changed since it was scheduled.
ScheduleNextStackExpiry = function(td)
    if not td or not td.stackExpiries or #td.stackExpiries == 0 then
        td._stackTimerGen = (td._stackTimerGen or 0) + 1
        return
    end
    -- Find soonest
    local soonest = td.stackExpiries[1]
    for i = 2, #td.stackExpiries do
        if td.stackExpiries[i] < soonest then soonest = td.stackExpiries[i] end
    end
    local delay = soonest - time()
    if delay <= 0 then delay = 0.05 end   -- fire ASAP if already past

    td._stackTimerGen = (td._stackTimerGen or 0) + 1
    local myGen = td._stackTimerGen
    local arcID = td.arcID

    C_Timer.After(delay, function()
        -- Freshly look up the td — it may have been destroyed in the meantime
        local currentTd = ArcAurasTimer.timers[arcID]
        if not currentTd or currentTd._stackTimerGen ~= myGen then return end
        -- Generation still matches: prune, persist, refresh, reschedule
        local dropped = PruneExpiredStacks(currentTd)
        if dropped > 0 then
            PersistStacks(arcID, currentTd)
            RefreshStackDisplay(currentTd)
        end
        ScheduleNextStackExpiry(currentTd)
    end)
end

-- Increment the stack counter. Called on every start-trigger event fire
-- when startTrigger.trackStacks is true, regardless of restartOnRefire.
-- Writes to the frame's stack text via the shared ApplyStackText pipeline.
local function IncrementStack(td)
    if not td or not td.startTrigger or not td.startTrigger.trackStacks then return end
    td.stacks = (td.stacks or 0) + 1

    if td.startTrigger.stackMode == "independent" then
        -- Append a per-stack expiry and (re)schedule the next tick
        td.stackExpiries = td.stackExpiries or {}
        table.insert(td.stackExpiries, time() + (td.duration or 0))
        ScheduleNextStackExpiry(td)
    end
    -- refresh mode has no per-stack state — the existing duration timer
    -- will clear everything on natural expiry via OnCooldownDone.
    PersistStacks(td.arcID, td)
    RefreshStackDisplay(td)
end

-- ─────────────────────────────────────────────────────────────────────────
-- CONSUME MODE — Generator / Spender economy.
--
-- A third stackMode where the timer behaves like the resource bars in
-- ArcUI_CooldownBars: a list of "generator" entries that ADD stacks (each
-- one is an event match — cast/cooldown/proc on a specific spellID — with
-- an amount), and "spender" entries that SUBTRACT. Stacks clamp to
-- [0, maxStacks]. When stacks reach 0, onEmptyAction decides what happens:
--   "keep" (default) — timer keeps running until duration expires
--   "stop"           — StopTimer immediately (clears swipe + visuals)
--   "hide"           — frame hides until stacks > 0 again or timer ends
--
-- Pattern lifted from ns.CooldownBars.ApplyStackChange + ProcessEventStackTrigger
-- but kept minimal: no aura-based triggers, no suppressors, no
-- requireHostileTarget — just clean event + spellID gain/consume.
-- ─────────────────────────────────────────────────────────────────────────

local function GenSpenderMatches(entry, evEvent, evSpellID)
    if not entry or type(entry.events) ~= "table" then return false end
    if not entry.events[evEvent] then return false end
    if not evSpellID or not entry.spellID then return false end
    return evSpellID == entry.spellID
end

-- Apply onEmptyAction when stacks hit 0. Forward declared so ConsumeStack
-- can reach it; the StopTimer call below targets the public API entry.
local OnStacksEmpty

-- Hide / unhide frame in "hide" onEmptyAction. We track suppression in a
-- flag so re-show on next gain works; CDMGroups layout still controls
-- final visibility via group:Layout().
local function ApplyHideState(td, hidden)
    if not td or not td.frame then return end
    if hidden then
        td.frame._arcConsumeHidden = true
        td.frame:SetAlpha(0)
    else
        td.frame._arcConsumeHidden = nil
        -- Restore the alpha pipeline by re-applying visuals.
        ApplyVisuals(td)
    end
end

-- Gain N stacks. Clamps to maxStacks unless noMaxStacks=true, in which case
-- there is no upper bound. In independent mode, appends N per-stack expiries.
-- In consume mode, no per-stack expiries — stacks live until the main
-- duration expires or a spender consumes them.
local function GainStacks(td, amount)
    if not td or not td.startTrigger or not td.startTrigger.trackStacks then return end
    amount = tonumber(amount) or 1
    if amount <= 0 then return end
    local before = td.stacks or 0
    local newStacks
    if td.startTrigger.noMaxStacks then
        newStacks = before + amount
    else
        local maxS = td.startTrigger.maxStacks or 5
        newStacks = math.min(maxS, before + amount)
    end
    td.stacks = newStacks
    local actual = td.stacks - before
    if actual <= 0 then return end

    -- If the frame was hidden because stacks were 0 with onEmptyAction=hide,
    -- bring it back as soon as we gain a stack again.
    if td.frame and td.frame._arcConsumeHidden then
        ApplyHideState(td, false)
    end

    if td.startTrigger.stackMode == "independent" then
        td.stackExpiries = td.stackExpiries or {}
        for _ = 1, actual do
            table.insert(td.stackExpiries, time() + (td.duration or 0))
        end
        ScheduleNextStackExpiry(td)
    end
    PersistStacks(td.arcID, td)
    RefreshStackDisplay(td)
end

-- Consume N stacks. Clamps to 0. In independent mode, FIFO — pops the
-- soonest-expiring stack first (matches "burning the oldest charge first"
-- intuition; mirrors how MSW etc. behave in practice). Fires onEmptyAction
-- if stacks hit 0.
local function ConsumeStack(td, amount)
    if not td or not td.startTrigger or not td.startTrigger.trackStacks then return end
    amount = tonumber(amount) or 1
    if amount <= 0 then return end
    local before = td.stacks or 0
    if before <= 0 then return end
    td.stacks = math.max(0, before - amount)
    local actual = before - td.stacks

    if td.startTrigger.stackMode == "independent"
       and td.stackExpiries and #td.stackExpiries > 0 then
        -- Pop the soonest-expiring `actual` entries (FIFO by expiry time).
        for _ = 1, actual do
            if #td.stackExpiries == 0 then break end
            local idx, soonest = 1, td.stackExpiries[1]
            for i = 2, #td.stackExpiries do
                if td.stackExpiries[i] < soonest then
                    soonest = td.stackExpiries[i]
                    idx = i
                end
            end
            table.remove(td.stackExpiries, idx)
        end
        ScheduleNextStackExpiry(td)
    end

    PersistStacks(td.arcID, td)
    RefreshStackDisplay(td)

    if td.stacks <= 0 then
        if OnStacksEmpty then OnStacksEmpty(td) end
    end
end

OnStacksEmpty = function(td)
    if not td or not td.startTrigger then return end
    local action = td.startTrigger.onEmptyAction or "keep"
    if action == "stop" then
        ArcAurasTimer.StopTimer(td.arcID)
    elseif action == "hide" then
        ApplyHideState(td, true)
    end
    -- "keep" → no-op; timer keeps running until natural duration end.
end

-- Wipe all stack state on the timer (called when the duration ends or
-- the timer is explicitly stopped).
local function ClearAllStacks(td)
    if not td then return end
    td.stacks = 0
    td.stackExpiries = {}
    td._stackTimerGen = (td._stackTimerGen or 0) + 1   -- cancel any pending C_Timer
    RefreshStackDisplay(td)
end

-- Called when the visible cooldown's OnCooldownDone fires. Our authoritative
-- "ready" transition point — flips state and re-applies visuals. Also the
-- natural point where "refresh"-mode stacks all die at once.
local function OnCooldownDone(td)
    td.active = false
    -- In refresh mode the main duration ending kills all stacks at once.
    -- In independent mode, stacks fall off on their own schedule and may
    -- have already cleared to 0; if any are still alive here, the main
    -- timer ended early (manual stop or end trigger) and we also wipe.
    ClearAllStacks(td)
    ClearActive(td.arcID)
    ApplyVisuals(td)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

-- Public read-access for ComputeStackDisplay in ArcAuras.lua. Returns the
-- current stack count for a timer, or nil if this arcID isn't a timer or
-- has no active stacks. Always returns a non-secret number.
function ArcAurasTimer.GetStackCount(arcID)
    local td = ArcAurasTimer.timers[arcID]
    if not td or not td.stacks or td.stacks <= 0 then return nil end
    return td.stacks
end

-- Start (or restart) the timer. Called internally on cast success, or via
-- /slash commands for testing.

function ArcAurasTimer.StartTimer(arcID)
    local td = ArcAurasTimer.timers[arcID]
    if not td then return end

    local wasActive = td.active
    td.startTime = GetTime()
    td.active    = true

    -- Clear any hide-on-empty suppression from a previous cycle.
    if td.frame and td.frame._arcConsumeHidden then
        ApplyHideState(td, false)
    end

    -- Stack handling on start:
    --   wasActive=false → fresh start
    --     - refresh/independent: stacks = 1 (count this fire)
    --     - consume: stacks = initialStacks (seed the pool, ignore the firing event)
    --   wasActive=true  → this is a refire that's actually causing a restart
    --                     (dispatcher only calls StartTimer again if
    --                     restartOnRefire or inactive). For refresh mode we
    --                     just increment; independent mode also appends a
    --                     new per-stack expiry. Consume mode RE-SEEDS to
    --                     initialStacks (the bar resets on retrigger).
    if td.startTrigger and td.startTrigger.trackStacks then
        if td.startTrigger.stackMode == "consume" then
            -- Seed (or re-seed) the consume pool. We DON'T treat the firing
            -- event as a +1 — start trigger just opens the window during
            -- which generators add and spenders subtract.
            td.stacks = td.startTrigger.initialStacks or 0
            td.stackExpiries = {}
        elseif not wasActive then
            td.stacks = 1
            td.stackExpiries = {}
            if td.startTrigger.stackMode == "independent" then
                table.insert(td.stackExpiries, time() + td.duration)
                ScheduleNextStackExpiry(td)
            end
        else
            IncrementStack(td)
        end
    else
        -- No tracking — make sure no stale display lingers.
        ClearAllStacks(td)
    end

    RecordActive(arcID, td, td.duration)
    RefreshTimer(td)
    RefreshStackDisplay(td)
end

function ArcAurasTimer.StopTimer(arcID)
    local td = ArcAurasTimer.timers[arcID]
    if not td then return end
    td.active = false
    ClearAllStacks(td)
    ClearActive(arcID)
    if td.frame and td.frame.Cooldown then td.frame.Cooldown:Clear() end
    -- Clear hide-on-empty suppression so the frame returns to its normal
    -- ready-state alpha pipeline after the timer ends.
    if td.frame and td.frame._arcConsumeHidden then
        ApplyHideState(td, false)
    end
    ApplyVisuals(td)
end

-- Public: re-push the current timer state to the visible cooldown frame.
-- Called when something external (options preview toggle, settings refresh)
-- cleared the Cooldown frame and we need to restore the running swipe from
-- our stored startTime/duration. Safe to call when timer isn't running —
-- FeedVisible will just clear the frame (no-op on already-clear).
function ArcAurasTimer.RefreshTimerFrame(arcID)
    local td = ArcAurasTimer.timers[arcID]
    if not td then return end
    RefreshTimer(td)
end

-- Build the frame + engine state for a timer. Called from RebuildTrackedTimers
-- during init and whenever a new timer is added via options.
function ArcAurasTimer.CreateTimer(arcID, config)
    if ArcAurasTimer.timers[arcID] then return ArcAurasTimer.timers[arcID] end

    local spellID  = safeSpellID(config.spellID)
    local duration = safeDuration(config.duration)
    if not spellID or not duration then return nil end

    local frameConfig = {
        type    = "timer",
        spellID = spellID,
        name    = GetSpellNameAndIcon(spellID),
    }
    local frame = ArcAuras.CreateFrame(arcID, frameConfig)
    if not frame then return nil end

    -- Mark as a spell-like cooldown frame so ApplySpellStateVisuals / the
    -- Masque + CDMEnhance stack treats it the same way it would a real spell.
    frame._arcIsSpellCooldown = true
    frame._arcIsCustomTimer   = true

    if not frame._durationObj and C_DurationUtil and C_DurationUtil.CreateDuration then
        frame._durationObj = C_DurationUtil.CreateDuration()
    end

    -- OnCooldownDone: flip to ready when our timer's swipe completes.
    frame.Cooldown:SetScript("OnCooldownDone", function()
        local td = ArcAurasTimer.timers[arcID]
        if td then OnCooldownDone(td) end
    end)

    -- Build a full fd that matches what ArcAurasCooldown.InitializeSpellFrame
    -- would produce for a normal spell frame. Register it in spellData so
    -- the entire existing event pipeline — SPELL_UPDATE_USABLE for resource
    -- tints, SPELL_RANGE_CHECK_UPDATE for range glows, RefreshAllSpellVisuals
    -- for settings changes, etc. — iterates over timer frames too.
    --
    -- The critical flag is `isCustomTimer = true`. SPELL_UPDATE_COOLDOWN /
    -- SPELL_UPDATE_CHARGES handlers skip frames with this flag (their CD
    -- source is our timer, not the spell API). FeedCooldown also short-
    -- circuits to just ApplySpellStateVisuals for timer frames.
    local fd = {
        frame            = frame,
        icon             = frame.Icon,
        cooldown         = frame.Cooldown,
        chargeText       = frame._arcStackText,
        spellID          = spellID,
        arcID            = arcID,
        -- Engine state (match normal spell fd shape for compatibility)
        isCustomTimer    = true,
        isChargeSpell    = false,
        desaturate       = true,
        lastIsOnGCD      = nil,
        lastIsOnCD       = false,
        procGlowActive   = false,
        procGlowType     = nil,
        -- Range / usability state
        needsRangeCheck   = false,
        rangeCheckSpellID = nil,
        spellOutOfRange   = false,
        usableGlowActive  = false,
        usableGlowType    = nil,
        readyGlowActive   = false,
        readyGlowType     = nil,
    }

    -- Store back-reference so hooks can find frameData via the Cooldown frame
    if frame.Cooldown then
        frame.Cooldown._arcFrameData = fd
    end

    -- Opt into SPELL_RANGE_CHECK_UPDATE if the watched spell has a range.
    -- This mirrors InitializeSpellFrame so the range tint / out-of-range
    -- glow work identically on timer frames.
    if C_Spell.SpellHasRange and C_Spell.EnableSpellRangeCheck then
        if C_Spell.SpellHasRange(spellID) then
            fd.needsRangeCheck = true
            fd.rangeCheckSpellID = spellID
            C_Spell.EnableSpellRangeCheck(spellID, true)
            local inRange = C_Spell.IsSpellInRange(spellID)
            fd.spellOutOfRange = (inRange == false)
        end
    end

    -- Register in the ArcAurasCooldown tables so the existing event
    -- handlers and the settings-refresh pipeline pick this frame up.
    if ns.ArcAurasCooldown then
        if ns.ArcAurasCooldown.spellFrames then
            ns.ArcAurasCooldown.spellFrames[arcID] = frame
        end
        if ns.ArcAurasCooldown.spellData then
            ns.ArcAurasCooldown.spellData[arcID] = fd
        end
        if ns.ArcAurasCooldown.spellsByID then
            ns.ArcAurasCooldown.spellsByID[spellID] = arcID
        end
    end

    -- Normalize triggers (handles all legacy shapes, returns v3 descriptors).
    local startTriggerCfg, endTriggerCfg = NormalizeConfigTriggers(config)

    local td = {
        arcID          = arcID,
        frame          = frame,
        fd             = fd,
        spellID        = spellID,
        duration       = duration,
        icon           = config.icon,
        startTrigger   = startTriggerCfg,
        endTrigger     = endTriggerCfg,
        active         = false,
        startTime      = nil,
        -- Stack-tracking state. Always present but only populated when
        -- startTrigger.trackStacks is true. `stacks` is the displayed
        -- number; `stackExpiries` is an array of unix epoch timestamps
        -- used only by "independent" stackMode so each stack can fall
        -- off on its own schedule.
        stacks         = 0,
        stackExpiries  = {},
        -- Handle to the current pending C_Timer scheduled for the next
        -- soonest stack expiry (independent mode only). Used to cancel
        -- stale schedules when the list changes.
        _stackTimer    = nil,
    }

    ArcAurasTimer.timers[arcID] = td
    IndexBySpell(spellID, arcID)

    -- ─────────────────────────────────────────────────────────────────────
    -- Resume persisted active state (if any). If the timer was running
    -- when we reloaded and hasn't expired yet, we set td.startTime such
    -- that startTime + duration = the original expiration — so the
    -- cooldown swipe shows exactly the remaining time.
    --
    --   elapsed  = duration - remaining
    --   startTime (in GetTime() space) = GetTime() - elapsed
    --
    -- If the persisted state has already expired, clear it and skip —
    -- the timer just comes up ready as normal.
    -- ─────────────────────────────────────────────────────────────────────
    local state = GetActiveState()
    local entry = state and state[arcID]
    if entry and entry.expireAt then
        local remaining = entry.expireAt - time()
        if remaining > 0 then
            local elapsed = duration - remaining
            if elapsed < 0 then elapsed = 0 end    -- clamp: saved remaining > duration
            td.startTime = GetTime() - elapsed
            td.active    = true
            -- Do NOT call RecordActive again — the existing expireAt is
            -- already correct (we're resuming, not restarting).

            -- Restore stack state. For "independent" mode we walk the
            -- saved expiries list, dropping any that have already elapsed
            -- while we were offline, then schedule the next-soonest.
            if entry.stacks and entry.stacks > 0 then
                td.stacks = entry.stacks
                if entry.stackExpiries then
                    td.stackExpiries = { unpack(entry.stackExpiries) }
                    PruneExpiredStacks(td)   -- remove already-expired stacks
                    if #td.stackExpiries > 0 then
                        ScheduleNextStackExpiry(td)
                    end
                end
                -- Persist the pruned state back so SavedVariables don't
                -- carry stale expiries forward.
                PersistStacks(arcID, td)
                RefreshStackDisplay(td)
            end
        else
            -- Timer already expired while offline / during reload.
            state[arcID] = nil
        end
    end

    -- Apply initial visuals (ready state OR resumed mid-swipe)
    RefreshTimer(td)

    -- Initialize the stack-text fontstring even on idle/fresh timers so
    -- the "0" placeholder renders for trackStacks-enabled icons. Without
    -- this, the fontstring stays empty until the first IncrementStack /
    -- ClearAllStacks call, which means the user can't see / style the
    -- text in the options panel before triggering the timer.
    RefreshStackDisplay(td)

    return td
end

function ArcAurasTimer.DestroyTimer(arcID)
    local td = ArcAurasTimer.timers[arcID]
    if not td then return end

    -- Disable range check on the watched spell (if we turned it on)
    if td.fd and td.fd.needsRangeCheck and td.fd.rangeCheckSpellID
       and C_Spell.EnableSpellRangeCheck then
        C_Spell.EnableSpellRangeCheck(td.fd.rangeCheckSpellID, false)
    end

    -- Unregister from ArcAurasCooldown tables so the event pipeline stops
    -- iterating over this frame.
    if ns.ArcAurasCooldown then
        if ns.ArcAurasCooldown.spellFrames then
            ns.ArcAurasCooldown.spellFrames[arcID] = nil
        end
        if ns.ArcAurasCooldown.spellData then
            ns.ArcAurasCooldown.spellData[arcID] = nil
        end
        if ns.ArcAurasCooldown.spellsByID and td.spellID
           and ns.ArcAurasCooldown.spellsByID[td.spellID] == arcID then
            ns.ArcAurasCooldown.spellsByID[td.spellID] = nil
        end
    end

    UnindexBySpell(td.spellID, arcID)
    ArcAurasTimer.timers[arcID] = nil

    if td.frame and td.frame.Cooldown then
        td.frame.Cooldown:SetScript("OnCooldownDone", nil)
        td.frame.Cooldown:Clear()
    end

    -- CRITICAL: mirror ArcAurasCooldown.HideFrame. ArcAuras.DestroyFrame
    -- internally calls ns.CDMGroups.UnregisterExternalFrame which wipes
    -- savedPositions[arcID]. If we let that happen, the frame loses its
    -- group assignment and comes back as a free icon on next CreateTimer.
    -- Save before destroy, restore after — same pattern HideFrame uses.
    local savedPos = ns.CDMGroups and ns.CDMGroups.savedPositions
        and ns.CDMGroups.savedPositions[arcID]
    ArcAuras.DestroyFrame(arcID)
    if savedPos and ns.CDMGroups and ns.CDMGroups.savedPositions then
        ns.CDMGroups.savedPositions[arcID] = savedPos
    end
end

-- Apply a custom icon override. iconID is a raw FileDataID (texture ID) —
-- the number shown in the tooltip's "IconID" line. SetTexture accepts this
-- directly; no spell/item lookup needed. Pass nil/0 to clear.
function ArcAurasTimer.ApplyIconOverride(arcID, iconID)
    local db = GetDB()
    if not db or not db.customTimers or not db.customTimers[arcID] then return end
    local cfg = db.customTimers[arcID]

    local n = tonumber(iconID)
    if not n or n <= 0 then
        cfg.icon = nil
        cfg.iconID = nil
        -- Restore original (watched spell's icon)
        local _, originalIcon = GetSpellNameAndIcon(cfg.spellID)
        local td = ArcAurasTimer.timers[arcID]
        if td and td.frame and td.frame.Icon then
            td.frame.Icon:SetTexture(originalIcon or 134400)
        end
        print("|cff00CCFF[Arc Auras]|r Timer icon reset to default")
        return
    end

    -- SetTexture accepts a FileDataID (number) directly. WoW resolves it
    -- to the texture file at render time. If the ID is invalid, the icon
    -- will just show as a question mark / missing texture — which is the
    -- expected behaviour and gives clear feedback to the user.
    cfg.icon   = n
    cfg.iconID = n

    local td = ArcAurasTimer.timers[arcID]
    if td and td.frame and td.frame.Icon then
        td.frame.Icon:SetTexture(n)
    end
    print(string.format("|cff00CCFF[Arc Auras]|r Timer icon -> FileID %d", n))
end

-- Refresh engine state after Options UI edits the timer config (duration,
-- spellID, trigger events). Safe to call whether or not the timer is
-- currently running. Handles spellID change by re-indexing spellsByID.
function ArcAurasTimer.UpdateTimerConfig(arcID)
    local db = GetDB()
    if not db or not db.customTimers then return end
    local cfg = db.customTimers[arcID]
    if not cfg then return end
    local td = ArcAurasTimer.timers[arcID]
    if not td then return end

    td.duration = safeDuration(cfg.duration) or td.duration

    -- SpellID edits: re-index reverse lookup, update display data, refresh
    -- icon on the frame. Cooldown/range hooks installed on the frame still
    -- reference the ORIGINAL spellID for API calls — for a full rebuild on
    -- spellID change, the user should Remove + re-Add the timer. This path
    -- handles the common "fixed a typo" case where lookup + icon need to
    -- follow the new ID but the Cooldown backend doesn't.
    local newSpellID = safeSpellID(cfg.spellID)
    if newSpellID and newSpellID ~= td.spellID then
        UnindexBySpell(td.spellID, arcID)
        td.spellID = newSpellID
        if td.fd then td.fd.spellID = newSpellID end
        IndexBySpell(newSpellID, arcID)
        -- Refresh display (name + icon) from the new spellID, unless the
        -- user has an explicit icon override in play.
        local name, icon = GetSpellNameAndIcon(newSpellID)
        if td.fd then
            td.fd.spellName = name
        end
        if td.frame and td.frame.Icon and not cfg.iconID then
            td.frame.Icon:SetTexture(icon)
        end
    end

    -- Re-normalize triggers. Handles legacy shapes and fills defaults.
    ArcAurasTimer.NormalizeConfigTriggers(cfg)
    td.startTrigger = cfg.startTrigger
    td.endTrigger   = cfg.endTrigger

    -- Push the stack text so toggling Track Stacks on/off in options shows
    -- (or hides) the "0" placeholder immediately without needing a refire.
    RefreshStackDisplay(td)

    -- If currently running, re-feed so the swipe matches the new duration.
    if td.active then RefreshTimer(td) end
end

-- Add a new custom timer from user input. Stores in DB + creates frame.
function ArcAurasTimer.AddTimer(spellID, duration, opts)
    spellID  = safeSpellID(spellID)
    duration = safeDuration(duration)
    if not spellID or not duration then return false, "invalid input" end

    local db = GetDB()
    if not db then return false, "no DB" end

    -- Generate a unique arcID. Prefix "arc_timer_" so CDMEnhance Options
    -- (which pattern-matches "^arc_") recognizes these as Arc frames.
    local base = "arc_timer_" .. spellID
    local arcID = base
    local i = 2
    while db.customTimers[arcID] do
        arcID = base .. "_" .. i
        i = i + 1
    end

    -- Build a config table using whatever shape the caller provided. The
    -- normalizer handles legacy (triggerType/resetOnRecast/resetOnDeath)
    -- and new shapes (events sets) uniformly, so we just need to pass the
    -- opts fields through and let the shared normalizer produce the
    -- canonical v3 descriptors.
    local cfg = {
        spellID       = spellID,
        duration      = duration,
        icon          = opts and opts.icon,
        -- legacy fields (absorbed by the normalizer if present)
        triggerType   = opts and opts.triggerType,
        resetOnRecast = opts and opts.resetOnRecast,
        resetOnDeath  = opts and opts.resetOnDeath,
        -- new-shape fields (also absorbed by the normalizer)
        startTrigger  = opts and opts.startTrigger,
        endTrigger    = opts and opts.endTrigger,
    }
    ArcAurasTimer.NormalizeConfigTriggers(cfg)
    -- Strip legacy fields so the DB stores only the canonical shape.
    cfg.triggerType   = nil
    cfg.resetOnRecast = nil
    cfg.resetOnDeath  = nil

    db.customTimers[arcID] = cfg
    ArcAurasTimer.CreateTimer(arcID, cfg)
    return true, arcID
end

function ArcAurasTimer.RemoveTimer(arcID)
    local db = GetDB()
    if not db then return false end
    if not db.customTimers[arcID] then return false end

    ArcAurasTimer.DestroyTimer(arcID)
    db.customTimers[arcID] = nil
    return true
end

function ArcAurasTimer.GetTimers()
    local db = GetDB()
    return db and db.customTimers or {}
end

-- Build all timer frames from saved config. Called on login / enable.
function ArcAurasTimer.RebuildAll()
    local db = GetDB()
    if not db or not db.customTimers then return end

    -- Destroy any stale frames
    for arcID in pairs(ArcAurasTimer.timers) do
        if not db.customTimers[arcID] then
            ArcAurasTimer.DestroyTimer(arcID)
        end
    end

    -- Create new / refresh existing
    for arcID, config in pairs(db.customTimers) do
        if not ArcAurasTimer.timers[arcID] then
            ArcAurasTimer.CreateTimer(arcID, config)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPEC / TALENT VISIBILITY GATING
--
-- Timer frames honor `showOnSpecs`, `talentConditions`, `talentConditionMode`,
-- and `forceShow` — the same field names used by spell-cooldown frames — so
-- saved configs are interchangeable.
--
-- IMPORTANT: custom timers do NOT use a PlayerKnowsSpell check. The user
-- explicitly created the timer for this spellID, so we trust their intent.
-- Many legitimate use cases hit spell IDs that are NOT "player-known":
--   • Trinket on-use / proc spell IDs — tied to items, not learned spells
--   • Passive talent EFFECT IDs (e.g. 31616 Nature's Guardian) that aren't
--     the same as the talent ID the player actually learns
--   • Absorb/damage IDs that fire from gear procs
-- Gating on IsPlayerSpell would make all of these vanish with no user-
-- actionable cause. We leave visibility purely in the hands of forceShow,
-- showOnSpecs, and talentConditions — all of which the user controls
-- through the Spec & Talents section of the editor.
--
-- Priority order (checked in sequence, first failure hides the frame):
--   1. forceShow=true                       → visible, no further checks
--   2. showOnSpecs set → current spec in list?
--   3. talentConditions set → CheckTalentConditions passes?
--   4. (no PlayerKnowsSpell fallback — trust the user)
-- ═══════════════════════════════════════════════════════════════════════════

local function ShouldTimerBeVisible(config, spellID)
    if not config or not spellID then return false end

    -- forceShow = unconditional yes. Bypasses every gate below.
    if config.forceShow then return true end

    -- Spec filter: must match current spec if list is non-empty.
    if config.showOnSpecs and #config.showOnSpecs > 0 then
        local currentSpec = GetSpecialization() or 1
        local specAllowed = false
        for _, spec in ipairs(config.showOnSpecs) do
            if spec == currentSpec then specAllowed = true break end
        end
        if not specAllowed then return false end
    end

    -- Talent conditions: must pass CheckTalentConditions if set.
    if config.talentConditions and #config.talentConditions > 0 then
        if ns.TalentPicker and ns.TalentPicker.CheckTalentConditions then
            if not ns.TalentPicker.CheckTalentConditions(
                   config.talentConditions, config.talentConditionMode or "all") then
                return false
            end
        end
    end

    return true
end

function ArcAurasTimer.RefreshSpecVisibility()
    local db = GetDB()
    if not db or not db.customTimers then return end

    local changed = false
    for arcID, cfg in pairs(db.customTimers) do
        local td = ArcAurasTimer.timers[arcID]
        local shouldShow = ShouldTimerBeVisible(cfg, cfg.spellID)

        if shouldShow and not td then
            -- Config says visible but there's no frame — (re)create it.
            ArcAurasTimer.CreateTimer(arcID, cfg)
            changed = true
        elseif not shouldShow and td then
            -- Config says hidden but a frame exists — destroy it. The saved
            -- config stays in db.customTimers so flipping the spec/talent
            -- state back re-creates the frame via this same function.
            ArcAurasTimer.DestroyTimer(arcID)
            changed = true
        end
    end

    -- If any frames were created/destroyed, ask CDMGroups to re-layout so
    -- the icons reflow around the change.
    if changed and ns.CDMGroups and ns.CDMGroups.groups then
        for _, group in pairs(ns.CDMGroups.groups) do
            if group.Layout then group:Layout() end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENTS
-- ═══════════════════════════════════════════════════════════════════════════

local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
evFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
evFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
evFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
evFrame:RegisterEvent("PLAYER_DEAD")
-- Spec / talent change events — mirror ArcAurasCooldown's set so timer
-- frames gate on the same showOnSpecs / talentConditions fields and
-- react to the same triggers.
evFrame:RegisterEvent("SPELLS_CHANGED")
evFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
evFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
evFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
evFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")

-- ─────────────────────────────────────────────────────────────────────────
-- Trigger matcher. A trigger is a set of enabled events (OR semantics).
-- Returns true iff the incoming event is in that set AND the spellID
-- matches (or is nil for bulk SPELL_UPDATE_COOLDOWN).
--
-- triggerSpell resolution: trigger.spellID if set, else the timer's display
-- spellID (td.spellID).
-- ─────────────────────────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────────────────────────
-- Trigger matcher. A trigger is a set of enabled events (OR semantics).
-- Returns true iff the incoming event is in that set AND the spellID
-- exactly matches the trigger's target spellID.
--
-- triggerSpell resolution: trigger.spellID if set, else the timer's display
-- spellID (td.spellID).
--
-- IMPORTANT: every match requires an exact spellID equality, including the
-- cooldown branch. Earlier versions accepted bulk-nil SPELL_UPDATE_COOLDOWN
-- events ("something somewhere updated") but those fire constantly during
-- combat (every buff gain, talent swap, resource change) — accepting them
-- caused timers to spuriously trigger on unrelated events. The engine's
-- cooldown-state refresh pipeline handles bulk updates independently; the
-- user-facing "cooldown trigger" should only mean "THIS spell's CD changed."
-- ─────────────────────────────────────────────────────────────────────────
local function TriggerMatches(trigger, td, evEvent, evSpellID)
    if not trigger or type(trigger.events) ~= "table" then return false end
    if not trigger.events[evEvent] then return false end
    if not evSpellID then return false end  -- NEVER match bulk fires
    local targetID = trigger.spellID or td.spellID
    if evSpellID == targetID then return true end
    -- Extra spellIDs: optional list of alternate IDs that ALSO count as a
    -- match. Use case is "any potion in this list" — different spellIDs
    -- with the same buff duration, all driving the same icon. Empty / nil
    -- list short-circuits the loop with zero work.
    if trigger.extraSpellIDs then
        for i = 1, #trigger.extraSpellIDs do
            if evSpellID == trigger.extraSpellIDs[i] then return true end
        end
    end
    return false
end

-- Cooldown-event suppression window. SPELL_UPDATE_COOLDOWN fires a burst
-- at PLAYER_ENTERING_WORLD and on zone changes — Blizzard's way of telling
-- addons "refresh your state, everything reloaded." Those fires are NOT
-- real cooldown starts, so timers set to start on cooldown events would
-- spuriously fire on every zone-in. Suppress the `cooldown` event type
-- for a short window after PLAYER_ENTERING_WORLD.
local cooldownSuppressUntil = 0
local COOLDOWN_SUPPRESS_SECONDS = 2

evFrame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- Arm cooldown-event suppression: ignore SPELL_UPDATE_COOLDOWN
        -- triggers for a short window to absorb the burst Blizzard sends
        -- on zone changes / load-in.
        cooldownSuppressUntil = GetTime() + COOLDOWN_SUPPRESS_SECONDS

        -- Immediate pass: rebuild frames from saved config and do a first
        -- visual refresh. This gets icons on screen with SOME state.
        ArcAurasTimer.RebuildAll()
        for _, td in pairs(ArcAurasTimer.timers) do
            RefreshTimer(td)
        end

        -- Deferred pass 1.5s later — mirrors ArcAurasCooldown's pattern.
        -- By this point CDMEnhance has populated its per-icon settings cache,
        -- so readyAlpha / desat / glow settings actually resolve when we
        -- call ApplySpellStateVisuals. Spec/talent info is also reliably
        -- available by this point, so we do the first spec-gating pass here.
        C_Timer.After(1.5, function()
            for arcID, td in pairs(ArcAurasTimer.timers) do
                if td.frame then
                    td.frame._lastAppliedAlpha  = nil
                    td.frame._arcLastSpellState = nil
                end
                RefreshTimer(td)
            end
            ArcAurasTimer.RefreshSpecVisibility()
        end)
        return
    end

    -- Spec / talent change family. Debounced — mirrors the spell cooldown
    -- module's 0.5s delay so the three-way PLAYER_SPECIALIZATION_CHANGED /
    -- ACTIVE_TALENT_GROUP_CHANGED / TRAIT_CONFIG_UPDATED burst collapses
    -- into a single visibility pass instead of three.
    if event == "SPELLS_CHANGED"
       or event == "PLAYER_SPECIALIZATION_CHANGED"
       or event == "ACTIVE_TALENT_GROUP_CHANGED"
       or event == "PLAYER_TALENT_UPDATE"
       or event == "TRAIT_CONFIG_UPDATED" then
        C_Timer.After(0.5, function()
            ArcAurasTimer.RefreshSpecVisibility()
        end)
        return
    end

    if event == "PLAYER_DEAD" then
        -- "death" is a valid End Trigger event. Any timer whose endTrigger
        -- set includes death + is currently active gets stopped.
        for arcID, td in pairs(ArcAurasTimer.timers) do
            if td.endTrigger and td.endTrigger.events
               and td.endTrigger.events.death and td.active then
                ArcAurasTimer.StopTimer(arcID)
            end
        end
        return
    end

    -- ─────────────────────────────────────────────────────────────────────
    -- All remaining events are "spell triggers". Normalize each one into a
    -- (evEvent, evSpellID) pair, then dispatch to every timer asking:
    --   (a) does my endTrigger events include this? → Stop if active
    --   (b) does my startTrigger events include this? → Start (or restart)
    -- End wins ties when the same event matches both sets on one timer.
    -- ─────────────────────────────────────────────────────────────────────
    local evEvent, evSpellID
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 ~= "player" then return end
        evEvent   = "cast"
        evSpellID = safeSpellID(arg3)
        if not evSpellID then return end
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        -- Drop cooldown events during the post-load suppression window so
        -- Cooldown-trigger timers don't spuriously fire on zone-in.
        if GetTime() < cooldownSuppressUntil then return end
        evEvent = "cooldown"
        -- arg1 may be nil (bulk update) or a spellID. arg2 is baseSpellID.
        -- If BOTH are nil (pure bulk broadcast), TriggerMatches will reject
        -- the dispatch — we only want to match this timer's exact spellID.
        evSpellID = safeSpellID(arg1) or safeSpellID(arg2)
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        evEvent   = "proc"
        evSpellID = safeSpellID(arg1)
        if not evSpellID then return end
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        evEvent   = "procEnd"
        evSpellID = safeSpellID(arg1)
        if not evSpellID then return end
    else
        return
    end

    for arcID, td in pairs(ArcAurasTimer.timers) do
        -- Frames gated out by spec/talent have already been destroyed by
        -- RefreshSpecVisibility and won't appear in this loop — so we don't
        -- need a visibility guard here. Any timer we iterate is active and
        -- eligible to receive trigger events.

        -- ─── Consume-mode generator/spender pass ───
        -- Only meaningful when (a) trackStacks is on, (b) stackMode is
        -- "consume", and (c) the timer is currently active. Generators add
        -- stacks; spenders subtract. We check spenders first so an event
        -- that matches BOTH (rare but possible) is treated as a consume —
        -- the user's explicit spender list wins over an accidental match.
        local handledByEconomy = false
        if td.active and td.startTrigger and td.startTrigger.trackStacks
           and td.startTrigger.stackMode == "consume" then
            -- Spenders
            if td.startTrigger.spenders then
                for i = 1, #td.startTrigger.spenders do
                    local sp = td.startTrigger.spenders[i]
                    if GenSpenderMatches(sp, evEvent, evSpellID) then
                        ConsumeStack(td, sp.amount or 1)
                        handledByEconomy = true
                        break
                    end
                end
            end
            -- Generators (only if no spender matched on this event)
            if not handledByEconomy and td.startTrigger.generators then
                for i = 1, #td.startTrigger.generators do
                    local gen = td.startTrigger.generators[i]
                    if GenSpenderMatches(gen, evEvent, evSpellID) then
                        GainStacks(td, gen.amount or 1)
                        handledByEconomy = true
                        break
                    end
                end
            end
        end

        -- END trigger check first — end wins ties.
        if td.endTrigger and TriggerMatches(td.endTrigger, td, evEvent, evSpellID) then
            if td.active then
                ArcAurasTimer.StopTimer(arcID)
            end
        -- START trigger: start if inactive, restart if restartOnRefire,
        -- or (for stack-tracking timers) just bump the stack counter when
        -- the refire wouldn't otherwise restart the duration. Skip if the
        -- generator/spender pass already handled this event (avoids
        -- double-counting when start spell == generator spell).
        elseif not handledByEconomy
               and td.startTrigger and TriggerMatches(td.startTrigger, td, evEvent, evSpellID) then
            if not td.active or td.startTrigger.restartOnRefire then
                ArcAurasTimer.StartTimer(arcID)
            elseif td.startTrigger.trackStacks
                   and td.startTrigger.stackMode ~= "consume" then
                -- Timer is already running AND restartOnRefire is off —
                -- normally we'd skip this event entirely. But when stack
                -- tracking is on (refresh / independent), the user still
                -- wants the count to grow with every proc. Increment-only;
                -- don't touch startTime.
                --
                -- Consume mode is excluded here: in consume mode, gain
                -- only happens via explicit generator entries (handled
                -- above), not from the start-trigger event firing again.
                IncrementStack(td)
            end
        end
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- SLASH COMMAND (for testing)
-- ═══════════════════════════════════════════════════════════════════════════

SLASH_ARCTIMER1 = "/arctimer"
SlashCmdList.ARCTIMER = function(msg)
    msg = msg or ""
    local cmd, arg1, arg2 = msg:match("^(%S+)%s*(%S*)%s*(%S*)$")
    cmd = cmd and cmd:lower()

    if cmd == "add" then
        local sid = safeSpellID(arg1)
        local dur = safeDuration(arg2)
        if not sid or not dur then
            print("|cff00CCFF[ArcTimer]|r Usage: /arctimer add <spellID> <duration>")
            return
        end
        local ok, result = ArcAurasTimer.AddTimer(sid, dur)
        if ok then
            print("|cff00CCFF[ArcTimer]|r Added: " .. result .. " (" .. sid .. ", " .. dur .. "s)")
        else
            print("|cff00CCFF[ArcTimer]|r Failed: " .. tostring(result))
        end
    elseif cmd == "remove" or cmd == "rm" then
        if ArcAurasTimer.RemoveTimer(arg1) then
            print("|cff00CCFF[ArcTimer]|r Removed: " .. arg1)
        else
            print("|cff00CCFF[ArcTimer]|r Not found: " .. tostring(arg1))
        end
    elseif cmd == "list" then
        local n = 0
        for arcID, cfg in pairs(ArcAurasTimer.GetTimers()) do
            local name = GetSpellNameAndIcon(cfg.spellID)
            print(string.format("|cff00CCFF[ArcTimer]|r %s: %s (%d) %gs", arcID, name, cfg.spellID, cfg.duration))
            n = n + 1
        end
        if n == 0 then print("|cff00CCFF[ArcTimer]|r No timers") end
    elseif cmd == "test" then
        ArcAurasTimer.StartTimer(arg1)
    else
        print("|cff00CCFF[ArcTimer]|r Commands: add <spellID> <duration> | remove <arcID> | list | test <arcID>")
    end
end