-- ===================================================================
-- ArcUI_FrameActive.lua
-- Centralized active-state detection for CDM item frames.
--
-- A frame is ACTIVE iff ANY of:
--   - frame.Cooldown:IsShown()
--   - frame.auraInstanceID ~= nil
--   - frame.totemData ~= nil
--
-- IN-COMBAT PERFORMANCE PROFILE:
--   Per-signal hot-path cost (best case, no transition):
--     AII-Set      : 1 table read, 1 bool compare → bail
--     AII-Cleared  : 1 table read, 1 field read, 1 field read, 1 bool → bail
--     Cooldown OnShow  : 1 table read, 1 bool compare → bail
--     Cooldown OnHide  : 1 table read, 1 field read, 1 field read, 1 bool → bail
--     TotemUpdate  : (deferred — handled next frame)
--     UNIT_AURA    : EVENT NOT REGISTERED unless aidIndex has entries
--
--   Per real transition:
--     + 1 table mutation for entry.isActive
--     + N callbacks fired (typically 1 AuraFrames + 1 DynamicLayout per frame)
--
-- DESIGN:
--   - UNIT_AURA only registered when at least one frame has a captured
--     aid. Zero event dispatch when no aura frames are tracked.
--   - Per-signal fast paths: signals that imply a known active value
--     (AII-Set = true, Cooldown:OnShow = true) skip ComputeActive.
--   - Aid bookkeeping only runs for aid-related signals. Cooldown
--     widget and totem signals don't touch aidIndex.
--   - No initial-fire on subscribe. Consumers query IsActive() to read
--     initial state. Eliminates duplicate work when multiple consumers
--     subscribe to the same frame.
--   - No RefreshLayout sweep. Per-frame hooks fire during CDM rebuild.
-- ===================================================================

local ADDON, ns = ...

ns.FrameActive = ns.FrameActive or {}
local FA = ns.FrameActive

local issecretvalue = issecretvalue
local C_Timer_After = C_Timer.After

-- ===================================================================
-- STATE
-- ===================================================================

-- frame → entry { isActive, capturedAID, pendingRecompute, changedCallbacks, aidChangedCallbacks, frame }
local entries = {}

-- aid → entry (reverse lookup for UNIT_AURA backup)
local aidIndex = {}
local aidIndexCount = 0

-- ===================================================================
-- HELPERS
-- ===================================================================

-- INDEX presence: rejects secret. Feeds aidIndex / capturedAID, whose keys and the
-- UNIT_AURA-removed backup only work with non-secret instance ids (a secret can't be a
-- reliable table key, and the removed-id payload is itself secret in restricted content).
local function HasAID(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return false end
    return value ~= 0
end

-- ACTIVE-STATE presence: a SECRET auraInstanceID means the aura IS present (12.1 restricted
-- content) -- we just can't read/compare its value. This MUST agree with
-- ns.API.HasAuraInstanceID, which AuraFrames keys off. If they disagree, FrameActive fires
-- "inactive" when the swipe ends while the aura's id is still secret-present, AuraFrames then
-- re-asserts "active" (SetAlpha 1), and when the id finally clears there is no fa transition to
-- re-run AuraFrames -> the icon sticks at alpha=1. See cdm-debuff-stuck-alpha-secret-env.
local function AuraPresent(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return true end
    return value ~= 0
end

-- ===================================================================
-- UNIT_AURA LISTENER — registered ONLY while aidIndex has entries.
-- Zero event dispatch when no aura frames are tracked.
-- ===================================================================

local unitAuraFrame = CreateFrame("Frame")
local unitAuraRegistered = false

local function StartUnitAuraListener()
    if unitAuraRegistered then return end
    unitAuraFrame:RegisterUnitEvent("UNIT_AURA", "player")
    unitAuraRegistered = true
end

local function StopUnitAuraListener()
    if not unitAuraRegistered then return end
    unitAuraFrame:UnregisterEvent("UNIT_AURA")
    unitAuraRegistered = false
end

-- Forward declaration — body defined below RecomputeForRemoval
local OnUnitAuraEvent

-- ===================================================================
-- DISPATCH PRIMITIVES
-- ===================================================================

local function FireChanged(entry, frame, isActive, wasActive)
    local cbs = entry.changedCallbacks
    if not cbs then return end
    for i = 1, #cbs do
        cbs[i](frame, isActive, wasActive)
    end
end

local function FireAuraInstanceChanged(entry, frame, newAID, oldAID)
    local cbs = entry.aidChangedCallbacks
    if not cbs then return end
    for i = 1, #cbs do
        cbs[i](frame, newAID, oldAID)
    end
end

-- Apply a new active value. No-op if unchanged. Only path that
-- mutates entry.isActive and fires OnChanged callbacks.
local function ApplyActive(entry, frame, newActive)
    local wasActive = entry.isActive
    if newActive == wasActive then return end
    entry.isActive = newActive
    if ns.TraceTap then
        ns.TraceTap("FA", string.format("cd=%s active %s -> %s",
            tostring(frame and (frame.cooldownID or frame._arcAuraID)),
            tostring(wasActive), tostring(newActive)))
    end
    FireChanged(entry, frame, newActive, wasActive)
end

-- ===================================================================
-- AID BOOKKEEPING — called only from aid-related signals
-- (AII Set/Cleared, UNIT_AURA, rebind). NOT called from cooldown
-- widget or totem signals — those don't affect aid.
-- ===================================================================

local function UpdateAID(entry, frame)
    local liveAID = frame.auraInstanceID
    if not HasAID(liveAID) then liveAID = nil end

    local oldAID = entry.capturedAID
    if liveAID == oldAID then return end

    -- Reverse-index maintenance
    if oldAID then
        if aidIndex[oldAID] == entry then
            aidIndex[oldAID] = nil
            aidIndexCount = aidIndexCount - 1
            if aidIndexCount <= 0 then
                aidIndexCount = 0
                StopUnitAuraListener()
            end
        end
    end
    if liveAID then
        if aidIndex[liveAID] == nil then
            aidIndexCount = aidIndexCount + 1
            if aidIndexCount == 1 then
                StartUnitAuraListener()
            end
        end
        aidIndex[liveAID] = entry
    end

    entry.capturedAID = liveAID
    FireAuraInstanceChanged(entry, frame, liveAID, oldAID)
end

-- Drop entry's captured aid without firing OnAuraInstanceChanged.
-- Used by Unregister and rebind (release case).
local function DropAID(entry)
    local oldAID = entry.capturedAID
    if not oldAID then return end
    if aidIndex[oldAID] == entry then
        aidIndex[oldAID] = nil
        aidIndexCount = aidIndexCount - 1
        if aidIndexCount <= 0 then
            aidIndexCount = 0
            StopUnitAuraListener()
        end
    end
    entry.capturedAID = nil
end

-- ===================================================================
-- SIGNAL-SPECIFIC RECOMPUTE PATHS
-- Each signal type has a tailored function that does the MINIMUM
-- work needed for that signal. No generic ComputeActive call.
-- ===================================================================

-- AII-Set: aura just bound. Active is guaranteed true. Update aid.
-- BURST DETECTION: if an AII-Cleared deferred fire is pending for this
-- frame with the SAME aid, cancel it — this is a CDM rebuild burst, not
-- a real state change.
local function OnAII_Set(frame)
    local entry = entries[frame]
    if not entry then return end
    if ns.TraceTap then ns.TraceTap("FAS", "AII-Set cd=" .. tostring(frame.cooldownID or frame._arcAuraID)) end

    -- Pending inactive dispatch from same-tick AII-Cleared? Cancel it.
    if entry.pendingClearDispatch then
        entry.pendingClearDispatch = false
        -- The Clear already dropped capturedAID. Re-capture before
        -- ApplyActive so consumers see consistent state.
        UpdateAID(entry, frame)
        ApplyActive(entry, frame, true)
        return
    end

    UpdateAID(entry, frame)
    ApplyActive(entry, frame, true)
end

-- AII-Cleared: aura just unbound. Defers the OnChanged dispatch to next
-- frame so a same-tick AII-Set with the SAME aid (CDM rebuild burst)
-- can cancel it. Field reads + aid drop happen immediately for
-- correctness; only the dispatch is deferred.
local function OnAII_Cleared(frame)
    local entry = entries[frame]
    if not entry then return end
    if ns.TraceTap then ns.TraceTap("FAS", "AII-Cleared cd=" .. tostring(frame.cooldownID or frame._arcAuraID)) end

    UpdateAID(entry, frame)

    -- Compute what active state would be
    local cd = frame.Cooldown
    local active = (cd and cd:IsShown()) or frame.totemData ~= nil
    local newActive = active and true or false

    -- 50ms coalesce window. CDM's rebuild churn (spell override / refresh /
    -- data swap) can span multiple render frames within a few ms — using
    -- C_Timer.After(0) (= next frame only) was missing some of these and
    -- causing momentary false inactive→active flips that showed as layout
    -- reflows. 50ms is well below human perception (~100ms) and well above
    -- CDM's longest observed rebuild duration. Matches the probe window
    -- which proved reliable in testing.
    -- SCHEDULED ON EVERY CLEAR, including when the immediate compute still
    -- reads active: at Cleared time CDM's refresh has cleared the aura but
    -- often not yet refreshed the Cooldown widget — the old swipe still
    -- shows, we read "still active" and previously bailed with NO follow-up,
    -- latching stuck-active (the target-swap "saturated icon, no timer"
    -- report). The recheck runs after the widget settles and decides from
    -- real state. Secret-safe: the widget's shown flag can be secret in
    -- restricted content — only a NON-secret true counts as proof of active.
    local function ScheduleClearRecheck()
        if entry.pendingClearDispatch then return end  -- already scheduled
        entry.pendingClearDispatch = true
        C_Timer_After(0.05, function()
            if not entries[frame] then return end
            if not entry.pendingClearDispatch then return end  -- cancelled by AII-Set
            entry.pendingClearDispatch = false

            local recheck = AuraPresent(frame.auraInstanceID)
                         or frame.totemData ~= nil
            if not recheck then
                local cd2 = frame.Cooldown
                if cd2 and cd2.IsShown then
                    local shown = cd2:IsShown()
                    if not (issecretvalue and issecretvalue(shown)) and shown then
                        recheck = true
                    end
                end
            end
            local final = recheck and true or false

            if final == entry.isActive then return end
            local was = entry.isActive
            entry.isActive = final
            FireChanged(entry, frame, final, was)
        end)
    end

    if newActive == entry.isActive then
        if newActive then ScheduleClearRecheck() end
        return
    end

    -- If we'd transition to inactive, defer one frame so a same-tick
    -- AII-Set can cancel us. If we'd transition to active (unusual for
    -- a Clear hook but possible if cd widget is shown), fire synchronously.
    if newActive then
        entry.isActive = newActive
        FireChanged(entry, frame, newActive, not newActive)
        return
    end

    -- Defer the inactive dispatch
    ScheduleClearRecheck()
end

-- Cooldown:OnShow: widget just shown. Active is guaranteed true.
-- NO aid bookkeeping (widget event has nothing to do with aura instance).
local function OnCD_Show(frame)
    local entry = entries[frame]
    if not entry then return end
    if ns.TraceTap then ns.TraceTap("FAS", "CD-Show cd=" .. tostring(frame.cooldownID or frame._arcAuraID)) end
    ApplyActive(entry, frame, true)
end

-- Cooldown:OnHide: widget just hidden. Active = aura bound OR totem.
-- NO aid bookkeeping (widget event has nothing to do with aura instance).
local function OnCD_Hide(frame)
    local entry = entries[frame]
    if not entry then return end
    if ns.TraceTap then ns.TraceTap("FAS", "CD-Hide cd=" .. tostring(frame.cooldownID or frame._arcAuraID)) end
    local active = AuraPresent(frame.auraInstanceID) or frame.totemData ~= nil
    ApplyActive(entry, frame, active and true or false)
end

-- TotemUpdate / CooldownDone: state writes happen AFTER hook. Defer
-- one frame so the read sees settled state. No aid bookkeeping.
local function OnTotem_Deferred(frame)
    local entry = entries[frame]
    if not entry then return end
    if entry.pendingTotem then return end
    entry.pendingTotem = true

    C_Timer_After(0, function()
        entry.pendingTotem = false
        if not entries[frame] then return end
        -- Full check: any of cooldown shown, aura bound, totem present
        local cd = frame.Cooldown
        local active = (cd and cd:IsShown())
                    or AuraPresent(frame.auraInstanceID)
                    or frame.totemData ~= nil
        ApplyActive(entry, frame, active and true or false)
    end)
end

-- UNIT_AURA removed: an aid we're tracking just dropped. Active state
-- depends on what's left. We update the aid (which removes it from
-- index) then recompute.
local function OnUnitAuraRemoved(entry, frame)
    -- Aid is gone from UnitAuras state; force capturedAID drop and
    -- reverse-index cleanup. UpdateAID will see auraInstanceID still
    -- non-nil if CDM hasn't dispatched AII-Cleared yet — that's fine,
    -- we just leave the index stale until AII-Cleared comes through.
    -- Most of the time AII-Cleared lands immediately after.
    UpdateAID(entry, frame)
    local cd = frame.Cooldown
    local active = (cd and cd:IsShown())
                or AuraPresent(frame.auraInstanceID)
                or frame.totemData ~= nil
    ApplyActive(entry, frame, active and true or false)
end

OnUnitAuraEvent = function(_, _, unit, info)
    -- 12.1: feed the shared aura-secrecy cache early (this handler is "player"-registered and
    -- often fires around the CDM icon-assignment path, keeping ns.API.AurasSecret fresh there).
    if ns.API and ns.API.NoteUnitAuraSecrecy then ns.API.NoteUnitAuraSecrecy(unit or "player", info) end
    if not info then return end
    local removed = info.removedAuraInstanceIDs
    if not removed then return end
    -- 12.1: the UNIT_AURA payload is secret in restricted content, so #removed throws. The
    -- AII-Cleared hooks are the primary path; this UNIT_AURA backup just bails when secret.
    if issecretvalue and issecretvalue(removed) then return end
    for i = 1, #removed do
        local entry = aidIndex[removed[i]]
        if entry then
            OnUnitAuraRemoved(entry, entry.frame)
        end
    end
end

unitAuraFrame:SetScript("OnEvent", OnUnitAuraEvent)

-- ===================================================================
-- HOOK INSTALLATION (idempotent per frame)
-- ===================================================================

local function InstallHooks(frame)
    if frame._arcFAHooksInstalled then return end
    frame._arcFAHooksInstalled = true

    if frame.Cooldown then
        frame.Cooldown:HookScript("OnShow", function()
            if entries[frame] then OnCD_Show(frame) end
        end)
        frame.Cooldown:HookScript("OnHide", function()
            if entries[frame] then OnCD_Hide(frame) end
        end)
        frame.Cooldown:HookScript("OnCooldownDone", function()
            if entries[frame] then OnTotem_Deferred(frame) end
        end)
    end

    if type(frame.OnAuraInstanceInfoSet) == "function" then
        hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
            if entries[self] then OnAII_Set(self) end
        end)
    end
    if type(frame.OnAuraInstanceInfoCleared) == "function" then
        hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
            if entries[self] then OnAII_Cleared(self) end
        end)
    end

    if type(frame.OnPlayerTotemUpdateEvent) == "function" then
        hooksecurefunc(frame, "OnPlayerTotemUpdateEvent", function(self)
            if entries[self] then OnTotem_Deferred(self) end
        end)
    end
end

-- ===================================================================
-- GLOBAL TOTEM SAFETY NET
-- Every totem signal above rides PER-FRAME hooks (OnPlayerTotemUpdateEvent,
-- Cooldown OnHide/OnCooldownDone). If Blizzard never calls that method on a
-- given frame — reparented-into-group frames are the suspect class — the
-- recompute never runs and the cached state sticks: seen live as an Earthbind
-- icon reading ACTIVE (IsActive=true) while totemData, Cooldown:IsShown and
-- Blizzard's own isActive all said inactive. PLAYER_TOTEM_UPDATE only fires on
-- totem summon/expire/destroy, so deferring a recompute for every registered
-- frame is near-free (OnTotem_Deferred coalesces to one next-frame full check
-- per frame, and the deferral guarantees CDM's own ClearTotemData has already
-- run by the time we read the state). Zero idle cost.
-- ===================================================================
local totemSafetyFrame = CreateFrame("Frame")
totemSafetyFrame:RegisterEvent("PLAYER_TOTEM_UPDATE")
totemSafetyFrame:SetScript("OnEvent", function()
    for frame in pairs(entries) do
        OnTotem_Deferred(frame)
    end
end)

-- ===================================================================
-- PUBLIC API
-- ===================================================================

function FA.Register(frame)
    if not frame then return end
    if entries[frame] then return end

    local entry = {
        frame             = frame,
        isActive          = false,
        capturedAID       = nil,
        pendingTotem      = false,
        changedCallbacks  = nil,
        aidChangedCallbacks = nil,
    }
    entries[frame] = entry

    InstallHooks(frame)

    -- Seed initial state without firing callbacks.
    -- Direct reads, no helpers — we know we're seeding from scratch.
    local liveAID = frame.auraInstanceID
    if liveAID and (not issecretvalue or not issecretvalue(liveAID)) and liveAID ~= 0 then
        entry.capturedAID = liveAID
        if aidIndex[liveAID] == nil then
            aidIndexCount = aidIndexCount + 1
            if aidIndexCount == 1 then
                StartUnitAuraListener()
            end
        end
        aidIndex[liveAID] = entry
    end

    local cd = frame.Cooldown
    entry.isActive = (cd and cd:IsShown())
                  or AuraPresent(frame.auraInstanceID)
                  or frame.totemData ~= nil
    if not entry.isActive then entry.isActive = false end
end

function FA.Unregister(frame)
    if not frame then return end
    local entry = entries[frame]
    if not entry then return end
    DropAID(entry)
    entries[frame] = nil
end

-- O(1) cached read. Use this in consumer code instead of re-reading
-- frame fields directly.
function FA.IsActive(frame)
    local entry = entries[frame]
    if not entry then return false end
    return entry.isActive
end

-- Subscribe to active-state transitions.
-- callback(frame, isActive, wasActive)
-- Does NOT fire immediately. Consumers should call IsActive() after
-- subscribing if they need to seed against initial state.
function FA.OnChanged(frame, callback)
    if not frame or type(callback) ~= "function" then return end
    local entry = entries[frame]
    if not entry then
        FA.Register(frame)
        entry = entries[frame]
        if not entry then return end
    end
    local cbs = entry.changedCallbacks
    if not cbs then
        cbs = {}
        entry.changedCallbacks = cbs
    end
    cbs[#cbs + 1] = callback
end

-- Subscribe to aid changes (first bind, refresh, unbind).
-- callback(frame, newAID, oldAID)
function FA.OnAuraInstanceChanged(frame, callback)
    if not frame or type(callback) ~= "function" then return end
    local entry = entries[frame]
    if not entry then
        FA.Register(frame)
        entry = entries[frame]
        if not entry then return end
    end
    local cbs = entry.aidChangedCallbacks
    if not cbs then
        cbs = {}
        entry.aidChangedCallbacks = cbs
    end
    cbs[#cbs + 1] = callback
end

-- Manual recompute trigger. Used by FrameController rebind only.
-- Cheap full-check, not deferred — caller knows state may have
-- changed and wants the answer immediately.
function FA.RequestRecompute(frame)
    local entry = entries[frame]
    if not entry then return end
    UpdateAID(entry, frame)
    local cd = frame.Cooldown
    local active = (cd and cd:IsShown())
                or AuraPresent(frame.auraInstanceID)
                or frame.totemData ~= nil
    ApplyActive(entry, frame, active and true or false)
end

-- ===================================================================
-- FRAME REBIND HANDLER
-- Deferred to ADDON_LOADED — FrameController loads after this file.
-- ===================================================================

local function InstallRebindHandler()
    if not ns.FrameController or not ns.FrameController.OnFrameRebind then return end

    ns.FrameController.OnFrameRebind(function(frame, oldCdID, newCdID)
        if not frame then return end
        local entry = entries[frame]
        if not entry then return end

        DropAID(entry)

        if newCdID then
            -- New binding: recompute against the new spell's state.
            FA.RequestRecompute(frame)
        else
            -- Released: force inactive.
            ApplyActive(entry, frame, false)
        end
    end)
end

local rebindBoot = CreateFrame("Frame")
rebindBoot:RegisterEvent("ADDON_LOADED")
rebindBoot:SetScript("OnEvent", function(self, event, addon)
    if addon == ADDON then
        InstallRebindHandler()
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
-- ═══════════════════════════════════════════════════════════════════════════
-- PULSE RESYNC (Arc's call, 2026-08-13 — the spec-swap phantom-active bug).
-- FrameActive is EVENT-FED, and a lost deactivation event (an OnHide on a
-- secret-aspected widget during combat, group-container churn during profile
-- load) latches entry.isActive forever — /afi-proven: cd 175622 stuck active
-- with every live signal false. This re-derives every entry from the LIVE
-- signals at settle moments and fires OnChanged for any mismatch, so every
-- downstream consumer (glows, aura visuals, dynamic layout) self-heals.
-- Event-driven with periodic truth reconciliation, never blind event trust.
-- Desk-time only: IsShown on a secret-aspected widget yields a secret
-- boolean (boolean-testing it throws); every trigger below is a settle
-- moment, and the pulse skips itself under aura secrecy.
-- ═══════════════════════════════════════════════════════════════════════════
function FA.ResyncAll(reason)
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        return
    end
    local fixed, total = 0, 0
    for frame, entry in pairs(entries) do
        total = total + 1
        -- refresh aid bookkeeping first (no-op when unchanged)
        UpdateAID(entry, frame)
        local live = false
        local cd = frame.Cooldown
        if cd and cd.IsShown then
            local shown = cd:IsShown()
            if not (issecretvalue and issecretvalue(shown)) and shown then
                live = true
            end
        end
        if not live and AuraPresent(frame.auraInstanceID) then live = true end
        if not live and frame.totemData ~= nil then live = true end
        if entry.isActive ~= live then
            fixed = fixed + 1
            if ns.TraceTap then
                ns.TraceTap("FA", string.format("RESYNC FIX cd=%s %s -> %s (%s)",
                    tostring(frame.cooldownID or frame._arcAuraID),
                    tostring(entry.isActive), tostring(live), tostring(reason)))
            end
            ApplyActive(entry, frame, live)
        end
    end
    if ns.TraceTap then
        ns.TraceTap("FA", string.format("RESYNC done (%s): %d corrected of %d entries",
            tostring(reason), fixed, total))
    end
    return fixed
end

-- Settle triggers — TRAILING debounce: CDM has NO "shuffle done" signal
-- (source-checked: viewers rebuild off CooldownViewerSettings.OnDataChanged
-- + deferred MarkDirty; nothing terminal), so QUIESCENCE is the settle
-- signal. Every churn marker PUSHES the timer back and the pulse fires only
-- after 1.5s of silence — never mid-shuffle. Churn markers: spec/talent/
-- zone/regen events, CDM's own data-changed callback, and every
-- FrameController REBIND (each one is literally CDM moving a frame; FC
-- calls PokeResync directly). Zero idle CPU — one-shot timers only.
local resyncGen = 0
function FA.PokeResync(reason)
    resyncGen = resyncGen + 1
    local myGen = resyncGen
    C_Timer_After(1.5, function()
        if myGen ~= resyncGen then return end   -- superseded: churn continued
        FA.ResyncAll(reason)
    end)
end

local resyncEv = CreateFrame("Frame")
resyncEv:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
resyncEv:RegisterEvent("TRAIT_CONFIG_UPDATED")
resyncEv:RegisterEvent("PLAYER_ENTERING_WORLD")
resyncEv:RegisterEvent("PLAYER_REGEN_ENABLED")
if C_EventUtils and C_EventUtils.IsEventValid
   and C_EventUtils.IsEventValid("COOLDOWN_VIEWER_DATA_LOADED") then
    resyncEv:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
end
resyncEv:SetScript("OnEvent", function(_, event)
    FA.PokeResync(event)
end)
-- CDM's data-provider change callback — the exact signal its own viewers
-- rebuild from (EventRegistry is Blizzard's addon-safe pub-sub)
if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
        FA.PokeResync("CDMDataChanged")
    end, "ArcUIFrameActiveResync")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TARGET-SWAP TRUTH SWEEP (the "debuff icon stays lit after switching to a
-- clean target" reports). Blizzard's deactivation signal for a target-aura
-- item is PLAYER_TARGET_CHANGED (source: CooldownViewerMixin:
-- OnPlayerTargetChanged -> itemFrame:OnNewTarget() [SetIsActive(false)] ->
-- RefreshData) — the aura clear arrives with NO UNIT_AURA removal, because
-- the debuff still exists on the OLD target. Our event hooks can catch it
-- mid-refresh in a still-active-looking intermediate state and latch, and
-- the resync pulse has no churn marker for a plain target swap. So mirror
-- Blizzard's own signal: shortly after every swap (CDM's refresh has run by
-- then), re-derive every entry from live signals through the single writer.
-- SECRET-SAFE, POSITIVE-PROOF-ONLY under restriction (the hook-state rule):
-- a secret Cooldown shown flag proves nothing — the frame is then only
-- flipped ACTIVE on a positive aura/totem signal, never flipped inactive on
-- an unprovable one. At the desk (the reported repro) everything is
-- readable and the sweep fully corrects. Zero idle cost: one timer per
-- human-rate target change, superseded-generation guarded.
-- ═══════════════════════════════════════════════════════════════════════════
local targetSwapEv = CreateFrame("Frame")
targetSwapEv:RegisterEvent("PLAYER_TARGET_CHANGED")
local swapGen = 0
targetSwapEv:SetScript("OnEvent", function()
    swapGen = swapGen + 1
    local myGen = swapGen
    C_Timer_After(0.15, function()
        if myGen ~= swapGen then return end   -- superseded: user is tab-cycling
        for frame, entry in pairs(entries) do
            UpdateAID(entry, frame)
            local live = AuraPresent(frame.auraInstanceID) or frame.totemData ~= nil
            local provable = true
            if not live then
                local cd = frame.Cooldown
                if cd and cd.IsShown then
                    local shown = cd:IsShown()
                    if issecretvalue and issecretvalue(shown) then
                        provable = false   -- cannot prove inactive; leave state alone
                    elseif shown then
                        live = true
                    end
                end
            end
            if live then
                ApplyActive(entry, frame, true)
            elseif provable then
                if entry.isActive and ns.TraceTap then
                    ns.TraceTap("FA", "TARGETSWAP FIX cd="
                        .. tostring(frame.cooldownID or frame._arcAuraID) .. " -> false")
                end
                ApplyActive(entry, frame, false)
            end
        end
    end)
end)
