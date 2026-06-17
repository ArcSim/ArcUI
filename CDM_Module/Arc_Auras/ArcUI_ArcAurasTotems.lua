-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Arc Auras TOTEMS — Custom frames mirroring the player's totem slots.
--
-- Behaviour:
--   One ArcUI-owned frame per totem slot (1..GetNumTotemSlots()). Each frame
--   shows WHATEVER totem currently occupies that slot — totems are generic
--   containers (totem, ground effect, temporary ability) so the slot, not a
--   specific spell, is what we track.
--
--   State is "active" (a totem is in the slot) vs "not active" (slot empty),
--   reusing the spell/timer visual pipeline (ApplySpellStateVisuals): active
--   maps to the "Active State" (cooldownState) visuals, empty to "Not Active"
--   (readyState). Empty slots default to hidden (readyState.alpha = 0) and
--   surface a placeholder icon only while the options panel is open, so the
--   user can size/border/position/group them before any totem is cast.
--
-- SECRET-SAFE (works in combat AND instances, zero taint):
--   - GetTotemDuration(slot) → LuaDurationObject (NOT flagged secret-when-slot-
--     secret) → frame.Cooldown:SetCooldownFromDurationObject(durObj, true).
--     Drives the swipe AND the active signal (Cooldown:IsShown()).
--   - GetTotemInfo(slot).icon → SetTexture (a secret-safe sink; renders even
--     when the slot is secret in instances).
--   - PLAYER_TOTEM_UPDATE (payload totemSlot, non-secret) is the only trigger.
--   No arithmetic on secret values, no SetCooldown, all ArcUI-owned frames.
--
-- Frames register with ArcAuras.CreateFrame as type="totem" so they inherit
-- CDMEnhance styling, Masque, CDMGroups (positioning/movement/groups), and the
-- per-icon options pipeline exactly like spell/timer frames.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local ArcAuras = ns.ArcAuras
if not ArcAuras then
    print("|cffFF4444[Arc Auras Totems]|r ERROR: ArcAuras core not loaded")
    return
end

local Totems = {}
ns.ArcAurasTotems = Totems

-- arcID scheme: "arc_totem_<slot>"
local ID_PREFIX = "arc_totem_"
local PLACEHOLDER_ICON = 310731  -- totem glyph fileID; generic empty-slot icon

-- State: arcID -> { slot, frame, fd }
Totems.frames = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- DB  (under arcAuras; enable/disable is PER SPEC like the CDM layout)
--   arcAuras.totemSlots.bySpec[specKey] = {
--       enabled = bool,
--       perSlot = { [slot] = false to disable },   -- absent key = enabled
--   }
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Per-spec config ────────────────────────────────────────────────────────
-- Totem tracking enable + per-slot disables are stored PER SPEC, exactly like
-- the CDM layout (positions live in the active spec's profile savedPositions,
-- visuals in its iconSettings). A spec that never enabled totems shows nothing.
-- Stored under  arcAuras.totemSlots.bySpec[specKey] = { enabled, perSlot = {…} }
-- keyed by the same spec key the CDM groups system uses.
local function CurrentSpecKey()
    if ns.CDMShared and ns.CDMShared.GetCurrentSpecKey then
        return ns.CDMShared.GetCurrentSpecKey()
    end
    local specIndex = (GetSpecialization and GetSpecialization()) or 1
    local _, _, classID = UnitClass("player")
    return "class_" .. (classID or 0) .. "_spec_" .. specIndex
end

-- Returns the current spec's totem table. With create=false, returns nil when
-- the spec has no entry (never enabled) — callers treat that as disabled.
local function GetSpecData(create)
    local adb = ArcAuras.GetDB and ArcAuras.GetDB() or nil
    if not adb then return nil end
    adb.totemSlots = adb.totemSlots or {}
    local ts = adb.totemSlots
    ts.bySpec = ts.bySpec or {}

    -- One-time migration from the old character-wide { enabled, perSlot } shape:
    -- fold it into the CURRENT spec so the user's main keeps its setup, while
    -- every other spec starts disabled (kills the cross-spec enable leak).
    if ts.enabled ~= nil and not ts._migratedPerSpec then
        local key = CurrentSpecKey()
        ts.bySpec[key] = ts.bySpec[key] or {}
        ts.bySpec[key].enabled = ts.enabled
        ts.bySpec[key].perSlot = ts.perSlot or {}
        ts.enabled, ts.perSlot = nil, nil
        ts._migratedPerSpec = true
    end

    local key = CurrentSpecKey()
    if not ts.bySpec[key] then
        if not create then return nil end
        ts.bySpec[key] = { perSlot = {} }
    end
    ts.bySpec[key].perSlot = ts.bySpec[key].perSlot or {}
    return ts.bySpec[key]
end

local function MakeID(slot) return ID_PREFIX .. tostring(slot) end

-- Public: parse "arc_totem_N" → slot number (nil if not a totem id).
function Totems.ParseID(arcID)
    if type(arcID) ~= "string" then return nil end
    local s = arcID:match("^arc_totem_(%d+)$")
    return s and tonumber(s) or nil
end

local function NumSlots()
    return (GetNumTotemSlots and GetNumTotemSlots()) or 0
end

local function SlotEnabled(sd, slot)
    -- perSlot stores ONLY explicit disables (false). Absent = enabled.
    return sd.perSlot[slot] ~= false
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FEED / STATE  (called from ArcAurasCooldown.FeedCooldown's isCustomTotem
-- branch, and directly on PLAYER_TOTEM_UPDATE)
-- ═══════════════════════════════════════════════════════════════════════════

-- Feed the visible cooldown + icon from the live totem slot. Returns isActive
-- (a totem currently occupies the slot) as a NON-SECRET bool derived from the
-- cooldown widget's IsShown() after the durObj feed (zero-span → auto-hidden →
-- empty). Never compares or stores a secret value.
function Totems.FeedSlot(arcID)
    local entry = Totems.frames[arcID]
    if not entry or not entry.frame then return false end
    local frame = entry.frame
    local slot  = entry.slot
    local cd    = frame.Cooldown
    if not cd then return false end

    -- Feed the swipe from the secret-safe duration OBJECT. GetTotemDuration
    -- returns NOTHING for an empty slot, and a DurationObject when a totem is
    -- present (its fields are secret, but the reference itself is a normal,
    -- nil-testable userdata). We NEVER read GetTotemInfo's `haveTotem` — it is a
    -- SECRET BOOLEAN and `if haveTotem then` throws under taint. Active state is
    -- taken from the cooldown widget's IsShown() (a non-secret bool), exactly
    -- the custom-icon shadow approach.
    local durObj = GetTotemDuration and GetTotemDuration(slot)
    if durObj then
        cd:SetCooldownFromDurationObject(durObj, true)  -- clearIfZero → empty auto-hides
    else
        cd:Clear()
    end

    local active = cd:IsShown() and true or false

    -- Icon: live totem icon when active, generic placeholder when empty. The
    -- icon from GetTotemInfo is a secret fileID when the slot is secret, but
    -- SetTexture is a safe sink — we pass it WITHOUT truth-testing it (secret
    -- numbers can't be boolean-tested either). `active` gates the call and is a
    -- non-secret bool, so no secret test occurs.
    local iconTex = frame.Icon
    if iconTex and iconTex.SetTexture then
        if active then
            if GetTotemInfo then
                local _, _, _, _, icon = GetTotemInfo(slot)
                iconTex:SetTexture(icon)   -- secret fileID is accepted by SetTexture
            end
        else
            iconTex:SetTexture(PLACEHOLDER_ICON)
        end
    end

    -- "Slot N" label: only on the empty placeholder, hidden once a totem is up.
    if frame._arcTotemSlotLabel then
        if active then frame._arcTotemSlotLabel:Hide() else frame._arcTotemSlotLabel:Show() end
    end

    return active
end

-- Public: is the slot currently active? Reads the cooldown widget's IsShown()
-- (non-secret) — NOT GetTotemInfo's secret haveTotem boolean. Reflects the last
-- FeedSlot, which runs on every PLAYER_TOTEM_UPDATE and refresh pass.
function Totems.IsSlotActive(arcID)
    local entry = Totems.frames[arcID]
    if not entry or not entry.frame or not entry.frame.Cooldown then return false end
    return entry.frame.Cooldown:IsShown() and true or false
end

-- Refresh one slot: feed + run the visual pipeline. Mirrors the timer's
-- ApplyVisuals, including the transition cache-clear so an active/inactive
-- flip is never skipped by the alpha/state dedup memo (the same class of bug
-- we fixed for custom timers).
function Totems.RefreshSlot(arcID)
    local entry = Totems.frames[arcID]
    if not entry then return end
    local fd = entry.fd
    if not fd then return end

    local active = Totems.FeedSlot(arcID)

    if fd._arcLastTotemActive ~= active then
        fd._arcLastTotemActive = active
        if fd.frame then
            fd.frame._arcLastSpellState = nil
            fd.frame._lastAppliedAlpha  = nil
        end
    end

    -- Map totem ACTIVE → the readyState visuals (isOnCD=false), so a live totem
    -- reuses readyState's full glow suite (the only state with glow widgets +
    -- application). Empty → cooldownState (isOnCD=true). The options panel labels
    -- readyState "Active State" and cooldownState "Not Active" for totem icons,
    -- so the user sees the correct names while we reuse the glow plumbing.
    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ApplySpellStateVisuals then
        ns.ArcAurasCooldown.ApplySpellStateVisuals(fd, not active, nil, false)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME LIFECYCLE
-- ═══════════════════════════════════════════════════════════════════════════

-- Seed the "empty = hidden" default ONCE per slot: readyState.alpha = 0 so an
-- empty slot is invisible in play, while the options-panel-open preview path
-- (ApplySpellStateVisuals bumps alpha→0.35 when readyState.alpha<=0 and the
-- panel is open) still surfaces the placeholder for configuration. Idempotent:
-- only seeds when the user has no readyState.alpha set yet.
local function SeedEmptyHiddenDefault(arcID)
    if not (ns.CDMEnhance and ns.CDMEnhance.GetOrCreateIconSettings) then return end
    local s = ns.CDMEnhance.GetOrCreateIconSettings(arcID)
    if not s then return end
    s.cooldownStateVisuals = s.cooldownStateVisuals or {}
    local csv = s.cooldownStateVisuals
    csv.cooldownState = csv.cooldownState or {}
    csv.readyState   = csv.readyState   or {}

    -- Intended default mapping for a totem slot (active→readyState via the flip):
    --   ACTIVE  (readyState)    = visible → alpha 1 (left unset; default is 1)
    --   NOT ACTIVE (cooldownState) = hidden → alpha 0
    local changed = false

    -- UN-REVERSE: a totem whose ACTIVE alpha is 0 (invisible when the totem is up)
    -- is always wrong — a stale pre-flip seed, or an accidental reversal like the
    -- one seen on slot 2 (active=0 / not-active=1), leaves it that way. Restore the
    -- intended defaults: active visible (clear → 1) AND not-active hidden (0). This
    -- is NOT gated on cooldownState.alpha (that gate is exactly why an already-set,
    -- reversed slot never got corrected). Idempotent — once active≠0 it's a no-op.
    if csv.readyState.alpha == 0 then
        csv.readyState.alpha    = nil
        csv.cooldownState.alpha = 0
        changed = true
    end

    -- Fresh slot with no explicit "Not Active" alpha → default hidden (0). The
    -- options-panel preview still bumps it to 0.35 so the placeholder is editable.
    if csv.cooldownState.alpha == nil then
        csv.cooldownState.alpha = 0
        changed = true
    end

    if changed and ns.CDMEnhance.InvalidateCache then
        ns.CDMEnhance.InvalidateCache()
    end
end

function Totems.CreateSlotFrame(slot)
    local arcID = MakeID(slot)
    if Totems.frames[arcID] then return Totems.frames[arcID] end

    local frameConfig = {
        type = "totem",
        slot = slot,
        name = "Totem Slot " .. slot,
    }
    local frame = ArcAuras.CreateFrame(arcID, frameConfig)
    if not frame then return nil end

    frame._arcIsSpellCooldown = true   -- use the spell/cooldown visual path
    frame._arcIsCustomTotem   = true
    frame._arcTotemSlot       = slot

    -- "Slot N" identifier shown on the empty placeholder so the user can tell
    -- which slot is which while configuring. It's a child of the frame (no
    -- IgnoreParentAlpha), so it follows the frame's alpha — visible at the
    -- options-panel preview (0.35), gone when the empty slot is hidden in play,
    -- and hidden entirely once a totem occupies the slot (real icon shows).
    if not frame._arcTotemSlotLabel then
        local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("CENTER", frame, "CENTER", 0, 0)
        lbl:SetText("Slot " .. slot)
        lbl:SetDrawLayer("OVERLAY", 7)
        frame._arcTotemSlotLabel = lbl
    end

    -- Install the shared alpha-enforcement hook (same one InitializeSpellFrame
    -- and the timer module use) so external SetAlpha calls don't desync the
    -- _lastAppliedAlpha memo and strand the frame in the wrong state.
    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.InstallAlphaEnforcementHook then
        ns.ArcAurasCooldown.InstallAlphaEnforcementHook(frame)
    end

    -- OnCooldownDone: when a totem expires (swipe completes) flip to empty.
    if frame.Cooldown then
        frame.Cooldown:SetScript("OnCooldownDone", function()
            Totems.RefreshSlot(arcID)
        end)
    end

    -- Build an fd matching the spell-frame shape so the existing event /
    -- settings-refresh pipeline (RefreshAllSpellVisuals, FeedCooldown) and the
    -- ApplySpellStateVisuals reads all work unchanged. isCustomTotem routes
    -- FeedCooldown + GetCooldownState to our totem branch.
    local fd = {
        frame          = frame,
        icon           = frame.Icon,
        cooldown       = frame.Cooldown,
        chargeText     = frame._arcStackText,
        spellID        = nil,
        arcID          = arcID,
        isCustomTotem  = true,
        isCustomTimer  = false,
        isChargeSpell  = false,
        desaturate     = false,  -- totems are NOT desaturated when active by default
        lastIsOnGCD    = nil,
        lastIsOnCD     = false,
        procGlowActive = false,
        needsRangeCheck   = false,
        rangeCheckSpellID = nil,
        spellOutOfRange   = false,
    }
    if frame.Cooldown then frame.Cooldown._arcFrameData = fd end

    -- DELIBERATELY NOT registered into ArcAurasCooldown.spellData. That table is
    -- iterated by many spell-pipeline loops that call C_Spell.GetSpellCharges /
    -- GetCooldownState(fd.spellID) etc. — all of which assume a non-nil spellID
    -- and would error on a totem (no spellID). The totem module owns its own
    -- refresh and applies visuals by calling ApplySpellStateVisuals(fd, active)
    -- directly (safe with nil spellID — its usability lookup early-returns).

    local entry = { slot = slot, frame = frame, fd = fd, arcID = arcID }
    Totems.frames[arcID] = entry

    SeedEmptyHiddenDefault(arcID)

    -- Initial feed + visuals (resume current slot state on login/enable).
    Totems.RefreshSlot(arcID)
    return entry
end

function Totems.DestroySlotFrame(slot)
    local arcID = MakeID(slot)
    local entry = Totems.frames[arcID]
    if not entry then return end

    if entry.frame and entry.frame.Cooldown then
        entry.frame.Cooldown:SetScript("OnCooldownDone", nil)
        entry.frame.Cooldown:Clear()
    end

    -- Preserve the saved group/free position across destroy (mirrors the timer
    -- and HideFrame pattern — DestroyFrame wipes savedPositions otherwise).
    local savedPos = ns.CDMGroups and ns.CDMGroups.savedPositions
        and ns.CDMGroups.savedPositions[arcID]
    ArcAuras.DestroyFrame(arcID)
    if savedPos and ns.CDMGroups and ns.CDMGroups.savedPositions then
        ns.CDMGroups.savedPositions[arcID] = savedPos
    end

    Totems.frames[arcID] = nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ENABLE / PER-SLOT
--
-- On enable we auto-create a "Totems" group centered on screen and drop every
-- slot into it — the "one group with all totems" default. Slots stay fully
-- independent (each its own arcID / saved position), so the user can drag any
-- of them into another group afterward (mix-and-match, exactly like trinkets).
-- Re-assignment only happens for BRAND-NEW slots (no saved position yet), so a
-- user's later drags are never yanked back.
-- ═══════════════════════════════════════════════════════════════════════════

local GROUP_NAME = "Totems"

-- Ensure the Totems group exists; center it on first creation only (never stomp
-- a group the user has since moved). Returns the group or nil if CDMGroups is
-- unavailable/disabled (in which case slots fall back to free-icon placement).
local function EnsureTotemGroup()
    if not (ns.CDMGroups and ns.CDMGroups.CreateGroup) then return nil end
    local existed = ns.CDMGroups.groups and ns.CDMGroups.groups[GROUP_NAME] ~= nil
    local g = existed and ns.CDMGroups.groups[GROUP_NAME] or ns.CDMGroups.CreateGroup(GROUP_NAME)
    if g and not existed then
        g.position = { x = 0, y = 0 }   -- screen center (relative to UIParent CENTER)
        if ns.CDMGroups.SnapContainerPositionToPixel then
            ns.CDMGroups.SnapContainerPositionToPixel(g)
        end
    end
    return g
end

-- Create a slot's frame and drop it into the Totems group at a distinct grid
-- cell. Eligible for auto-placement unless the slot is ALREADY assigned to a
-- group — so leftover "free" positions (e.g. from earlier /arctotem tests) get
-- pulled into the Totems group, while an intentional group placement the user
-- dragged elsewhere is respected and left alone. Each slot maps to a stable
-- cell: slot N → (row floor((N-1)/cols), col (N-1)%cols).
local function CreateAndPlaceSlot(slot, group, cols)
    local arcID = MakeID(slot)
    local sp = ns.CDMGroups and ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID]
    local alreadyGrouped = (sp ~= nil) and (sp.type == "group")
    local entry = Totems.CreateSlotFrame(slot)
    if not alreadyGrouped and group and entry and entry.frame
       and ns.CDMGroups.Integration and ns.CDMGroups.Integration.AssignToGroup then
        cols = cols or 4
        local idx = slot - 1
        local row = math.floor(idx / cols)
        local col = idx % cols
        ns.CDMGroups.Integration.AssignToGroup(arcID, entry.frame, GROUP_NAME, row, col, "cooldown")
    end
    return entry
end

function Totems.RebuildAll()
    local sd = GetSpecData(false)
    if not sd or not sd.enabled then
        for arcID, entry in pairs(Totems.frames) do
            Totems.DestroySlotFrame(entry.slot)
        end
        return
    end

    local n = NumSlots()
    local group = EnsureTotemGroup()
    local cols = (group and group.gridCols) or 4

    -- Destroy frames for slots that no longer exist or were toggled off.
    for arcID, entry in pairs(Totems.frames) do
        if entry.slot > n or not SlotEnabled(sd, entry.slot) then
            Totems.DestroySlotFrame(entry.slot)
        end
    end

    -- Create + place enabled slots.
    for slot = 1, n do
        if SlotEnabled(sd, slot) and not Totems.frames[MakeID(slot)] then
            CreateAndPlaceSlot(slot, group, cols)
        end
    end
end

-- Destroy every totem frame. Used on spec change so the new spec rebuilds its
-- OWN placement from scratch — a frame kept across a switch keeps the previous
-- spec's position, and a slot with no saved position on the new spec then never
-- gets placed (the bug the per-slot toggle worked around). DestroySlotFrame
-- preserves each slot's CURRENT-spec saved position, and ClearPositionFromSpec
-- only touches the current spec, so other specs' saved layouts are untouched.
function Totems.TeardownAll()
    for arcID, entry in pairs(Totems.frames) do
        Totems.DestroySlotFrame(entry.slot)
    end
end

function Totems.SetEnabled(enabled)
    local sd = GetSpecData(true); if not sd then return end
    sd.enabled = enabled and true or false
    Totems.RebuildAll()
end

function Totems.IsEnabled()
    local sd = GetSpecData(false)
    return sd and sd.enabled == true or false
end

function Totems.SetSlotEnabled(slot, enabled)
    local sd = GetSpecData(true); if not sd then return end
    -- perSlot stores ONLY explicit disables (false); absent = enabled. Do NOT use
    -- the `(enabled==false) and false or nil` idiom — `and false` is falsy, so the
    -- `or nil` branch always wins and the disable never persists (perSlot stays {}).
    if enabled == false then
        sd.perSlot[slot] = false
    else
        sd.perSlot[slot] = nil
    end
    if sd.enabled then
        if enabled == false then
            Totems.DestroySlotFrame(slot)
        elseif not Totems.frames[MakeID(slot)] then
            local group = EnsureTotemGroup()
            CreateAndPlaceSlot(slot, group, (group and group.gridCols) or 4)
        end
    end
end

-- Public: number of totem slots the current class has (0 = feature N/A).
function Totems.GetNumSlots() return NumSlots() end

-- Public: is a given slot enabled? (default true; perSlot stores only disables)
function Totems.IsSlotEnabled(slot)
    local sd = GetSpecData(false)
    return sd and SlotEnabled(sd, slot) or false
end

-- Refresh every active slot's visuals (settings change / panel open-close).
function Totems.RefreshAll()
    for arcID in pairs(Totems.frames) do
        Totems.RefreshSlot(arcID)
    end
end

-- Like RefreshAll but first clears the per-frame visual/alpha dedup caches, so
-- a settings change or a FrameController SetAlpha(1) settle can't leave a frame
-- stranded at the wrong alpha. Used by the deferred login passes and the
-- options-panel callback (totems are NOT in the spell-refresh sweep).
function Totems.ForceRefreshAll()
    for arcID, entry in pairs(Totems.frames) do
        if entry.frame then
            entry.frame._lastAppliedAlpha  = nil
            entry.frame._arcLastSpellState = nil
        end
        Totems.RefreshSlot(arcID)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENTS
-- ═══════════════════════════════════════════════════════════════════════════

local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:RegisterEvent("PLAYER_TOTEM_UPDATE")
evFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

evFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        Totems.RebuildAll()
        -- Deferred passes: 1.5s so CDMEnhance per-icon settings are populated
        -- before we resolve readyAlpha/desat/glow; 4.5s to re-assert after
        -- FrameController repositions free icons and calls SetAlpha(1) on the
        -- ~1-2s settle (mirrors ArcAurasCooldown's 4.5s RefreshAllSpellVisuals).
        C_Timer.After(1.5, Totems.ForceRefreshAll)
        C_Timer.After(4.5, Totems.ForceRefreshAll)
        return
    end

    if event == "PLAYER_TOTEM_UPDATE" then
        local slot = tonumber(arg1)
        if slot then
            Totems.RefreshSlot(MakeID(slot))
        else
            Totems.RefreshAll()
        end
        return
    end

    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Totem enable + positions are PER SPEC. Two stages:
        --   0.6s — if the NEW spec has totems OFF, tear the old spec's frames down
        --          promptly so they don't linger through the settle.
        --   2.8s — AFTER CDMGroups.OnSpecChange clears its restoration/protection
        --          windows (~2.5s) and repoints savedPositions to the new spec:
        --          FULL teardown + rebuild so every enabled slot is re-placed for
        --          THIS spec. A frame kept across the switch otherwise keeps the
        --          previous spec's position, so a slot that has no saved position
        --          on this spec never shows until toggled — mirrors the
        --          destroy+recreate the per-slot toggle does. ForceRefreshAll then
        --          settles alpha so empty slots hide on their own.
        C_Timer.After(0.6, function()
            if not Totems.IsEnabled() then Totems.TeardownAll() end
        end)
        C_Timer.After(2.8, function()
            Totems.TeardownAll()
            Totems.RebuildAll()
            Totems.ForceRefreshAll()
        end)
        C_Timer.After(3.5, Totems.ForceRefreshAll)
        return
    end
end)

-- Options-panel open/close refresh. Totems are not in the spell-refresh sweep,
-- so this is how a per-icon settings change gets re-applied to totem frames.
if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
    ns.CDMShared.RegisterPanelCallback("ArcAurasTotems", {
        onOpen  = function() Totems.ForceRefreshAll() end,
        onClose = function() Totems.ForceRefreshAll() end,
    })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SLASH COMMAND (testing until the options UI lands)
-- ═══════════════════════════════════════════════════════════════════════════

SLASH_ARCTOTEM1 = "/arctotem"
SlashCmdList.ARCTOTEM = function(msg)
    msg = (msg or ""):lower():match("^%s*(%S*)")
    if msg == "on" or msg == "enable" then
        Totems.SetEnabled(true)
        print(string.format("|cff00CCFF[ArcTotem]|r enabled (%d slots)", NumSlots()))
    elseif msg == "off" or msg == "disable" then
        Totems.SetEnabled(false)
        print("|cff00CCFF[ArcTotem]|r disabled")
    elseif msg == "list" then
        print(string.format("|cff00CCFF[ArcTotem]|r slots=%d enabled=%s", NumSlots(), tostring(Totems.IsEnabled())))
        for arcID, entry in pairs(Totems.frames) do
            print(string.format("  %s  active=%s", arcID, tostring(Totems.IsSlotActive(arcID))))
        end
    else
        print("|cff00CCFF[ArcTotem]|r commands: on | off | list   (slots: " .. NumSlots() .. ")")
    end
end
