-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Duration Override — Container source  (12.1 ONLY, EXPERIMENTAL)
--
-- Secret-safe replacement for the "Aura" duration-override source. Instead of
-- reading a source aura's duration through the C_UnitAuras instance-id API
-- (secret / throws on 12.1), we OVERLAY a Blizzard AuraButton — filtered to the
-- aura's SPELL ID via the 12.1 AuraContainer system — on top of the cooldown
-- icon. The AuraButton's own Cooldown (SetDurationCooldown) draws the aura's
-- remaining-time swipe on the icon while the aura is up, and hides when it drops,
-- letting the real cooldown show through. Blizzard drives the (secret) duration;
-- we never read an aura value.
--
-- Works for native CDM cooldown icons AND Arc cooldown icons (any Frame target).
-- 12.1 only: the AuraContainer/AuraButton intrinsics don't exist on live 12.0.x,
-- and creating a container in combat is a Lua error (deferred). Inert on live.
--
-- Verified API (build 12.1.0.68629): CreateFrame("AuraContainer", ...,
-- "CustomAuraContainerTemplate"); container:SetUnit / :AddAuraSlot(key, filter,
-- {candidateFilters.includeSpellIDs, templateNames, initializeFrame}) -> returns
-- the AuraButton frame (excluded from container flow layout, so SetPoint sticks).
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local DOC = {}
ns.DurationOverrideContainer = DOC

-- ── log (chat; quiet unless DOC.debug, so the engine path isn't spammy) ──────
local PREFIX = "|cff33ff99[ArcDurOvC]|r "
DOC.debug = false
local function Log(fmt, ...)
    if not DOC.debug then return end
    local msg = (select("#", ...) > 0) and fmt:format(...) or fmt
    print(PREFIX .. msg)
end

-- ── availability: 12.1 client only ──────────────────────────────────────────
local IS_121 = (ns.API and ns.API.IS_121) or false
function DOC.IsAvailable() return IS_121 end

if not IS_121 then
    -- Live 12.0.x: no-op stubs so the DO engine + options can call unconditionally.
    function DOC.Attach() end
    function DOC.Detach() end
    function DOC.DetachAll() end
    return
end

-- ── state ────────────────────────────────────────────────────────────────────
local containers = {}   -- [unit] -> AuraContainer frame
local attached   = {}   -- [targetFrame] -> { slot, unit, spellID, key, container }
local pending    = {}   -- [targetFrame] -> { spellID, unit } (combat-deferred, flushed on regen)
local slotSeq    = 0

-- Resolve the live frame for a cdID (native cooldownID) or arcID — same lookup the
-- DO engine uses, replicated here so this module has no hard dependency on it.
local function ResolveFrameForCdID(cdID)
    if cdID == nil then return nil end
    if ns.ArcAuras and ns.ArcAuras.frames and ns.ArcAuras.frames[cdID] then
        return ns.ArcAuras.frames[cdID]
    end
    if ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrameData then
        local d = ns.CDMEnhance.GetEnhancedFrameData(cdID)
        if d then return d.frame end
    end
    return nil
end

-- The target icon's actual Icon TEXTURE (native CDM: frame.Icon.Icon; Arc: frame.Icon).
local function ResolveIconTexture(frame)
    local t = frame and frame.Icon
    if t and not t.SetTexCoord and t.Icon then t = t.Icon end   -- native CDM wraps Icon in a frame
    return t
end

-- Make the overlay's cover texture pixel-match the target icon: same texture, same zoom (texcoord),
-- same bounds. Called at attach + kept current on each RefreshAll re-attach. SetTexture accepts a
-- secret file id (safe sink); GetTexture/GetTexCoord on a cooldown icon are non-secret.
local function MatchCover(slot, targetFrame)
    local cover = slot and slot.ArcIcon
    local tIcon = ResolveIconTexture(targetFrame)
    if not (cover and tIcon) then return end
    if tIcon.GetTexture then cover:SetTexture(tIcon:GetTexture()) end
    if tIcon.GetTexCoord then cover:SetTexCoord(tIcon:GetTexCoord()) end
    cover:ClearAllPoints()
    cover:SetAllPoints(tIcon)   -- match the icon's exact position/size (inside any border inset)
end

-- One AuraContainer per unit (player buffs vs target debuffs live separately).
-- Created out of combat only (in-combat creation is a Lua error, intended).
local function GetContainer(unit)
    local c = containers[unit]
    if c then return c end
    if InCombatLockdown() then
        Log("cannot create a container in combat — try again out of combat.")
        return nil
    end
    c = CreateFrame("AuraContainer", "ArcDurOvContainer_" .. unit, UIParent, "CustomAuraContainerTemplate")
    if c.SetUnit then c:SetUnit(unit) end
    if c.SetEnabled then c:SetEnabled(true) end
    c:Show()
    containers[unit] = c
    Log("created AuraContainer for unit=%s", unit)
    return c
end

-- Overlay an aura-duration AuraButton (filtered to auraSpellID) on targetFrame.
-- Returns the slot frame, or nil on failure (logged).
function DOC.Attach(targetFrame, auraSpellID, unit)
    if not (targetFrame and auraSpellID) then return nil end
    unit = unit or "player"
    if attached[targetFrame] then DOC.Detach(targetFrame) end

    local c = GetContainer(unit)
    if not c or not c.AddAuraSlot then
        -- Reload mid-combat lands here: container CREATION is hard combat-
        -- locked by Blizzard, so showing the overlay DURING that combat is
        -- impossible. Queue it -- the regen flush below re-attaches the moment
        -- combat drops (and eager creation at login covers every later fight).
        pending[targetFrame] = { spellID = auraSpellID, unit = unit }
        Log("no container yet (combat?) -> queued for regen (spellID=%s).", tostring(auraSpellID))
        return nil
    end
    pending[targetFrame] = nil

    -- spellID filtering is only valid for HELPFUL on assistable units, HARMFUL on non-assistable.
    local assist = (unit == "player") or (UnitCanAssist and UnitCanAssist("player", unit))
    local filter = assist and "HELPFUL" or "HARMFUL"

    slotSeq = slotSeq + 1
    local key = "arcdo" .. slotSeq

    local slot = c:AddAuraSlot(key, filter, {
        candidateFilters = { includeSpellIDs = { [auraSpellID] = true } },
        templateNames    = { "ArcDurOvOverlayButtonTemplate" },
        initializeFrame  = function(button)
            -- Aura swipe + timer. The opaque cover (ArcIcon) is set to COPY the target cooldown
            -- icon's own texture/zoom/bounds in Attach (below), so the overlay is seamless -- we do
            -- NOT call SetIcon (that would fill it with the buff's icon at full size / default border).
            -- The ArcCD Cooldown draws the aura's remaining-time swipe AND its own countdown number
            -- (OmniCC / Blizzard style it like every other cooldown), so we do NOT also SetDurationText
            -- -- that produced a second, redundant number stacked on the first.
            if button.ArcCD and button.SetDurationCooldown then
                button:SetDurationCooldown(button.ArcCD)
            end
            -- No mouse: the overlay must not intercept hover (else it shows the buff tooltip instead
            -- of the icon's). Disable it on the button + its cooldown at creation.
            if button.EnableMouse then button:EnableMouse(false) end
            if button.ArcCD and button.ArcCD.EnableMouse then button.ArcCD:EnableMouse(false) end
            -- Anchor + seamless cover INSIDE the init window. PTR5: the button
            -- and every region we templated into it are FORBIDDEN post-init
            -- whenever auras are secret -- combat re-attaches (CDM frame
            -- rebinds) land here, the only moment they are guaranteed legal.
            -- Slot frames are excluded from the container's flow layout, so
            -- this anchoring sticks.
            button:ClearAllPoints()
            button:SetAllPoints(targetFrame)
            button:SetFrameStrata(targetFrame:GetFrameStrata())
            -- LAYERING: sit just above the target's NATIVE SWIPE, not +5 over
            -- the whole frame -- charge/stack text, glows and labels are all
            -- designed to draw above the swipe, so slotting in at swipe+1
            -- keeps them on top of our aura swipe too (the +5 overlay was
            -- burying stacks and glows).
            local swipe = targetFrame.Cooldown
            local lvl = (swipe and swipe.GetFrameLevel and swipe:GetFrameLevel())
                or targetFrame:GetFrameLevel()
            button:SetFrameLevel(lvl + 1)
            MatchCover(button, targetFrame)
        end,
    })

    if not slot then
        Log("AddAuraSlot returned nil (spellID=%s, filter=%s).", tostring(auraSpellID), filter)
        return nil
    end
    -- NO slot touches past this point (see the init-window note above).

    attached[targetFrame] = { slot = slot, unit = unit, spellID = auraSpellID, key = key, container = c }
    Log("attached: spellID=%s filter=%s key=%s over target (level +5).", tostring(auraSpellID), filter, key)
    return slot
end

function DOC.Detach(targetFrame)
    pending[targetFrame] = nil
    local a = attached[targetFrame]
    if not a then return end
    attached[targetFrame] = nil
    -- NEVER touch the slot button here: post-init it is FORBIDDEN whenever
    -- auras are secret (PTR5). Parking the include set on a never-matching id
    -- makes the ENGINE release + hide the button itself (always legal);
    -- anchors are kept. Container methods stay callable in combat.
    if a.container and a.container.SetAuraSlotCandidateFilters then
        a.container:SetAuraSlotCandidateFilters(a.key, { includeSpellIDs = { [0] = true } })
        if a.container.UpdateAllAuras then a.container:UpdateAllAuras() end
    end
    Log("detached: key=%s", a.key)
end

function DOC.DetachAll()
    local targets = {}
    for t in pairs(attached) do targets[#targets + 1] = t end
    for _, t in ipairs(targets) do DOC.Detach(t) end
    wipe(pending)
end

-- ── combat deferral: eager container creation + pending flush ────────────────
-- A reload MID-COMBAT cannot show the overlay during that combat (container
-- creation is hard combat-locked by Blizzard -- no workaround exists). This
-- makes it self-heal at the first regen, and pre-creates both containers out
-- of combat so every LATER fight attaches instantly, reload or not.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function()
    if InCombatLockdown() then return end
    GetContainer("player")
    GetContainer("target")
    if next(pending) then
        local q = pending
        pending = {}
        for targetFrame, req in pairs(q) do
            DOC.Attach(targetFrame, req.spellID, req.unit)
        end
    end
end)

-- ── test slash: /arcdurovc <cdID|arcID> <auraSpellID> [unit] ─────────────────
SLASH_ARCDUROVC1 = "/arcdurovc"
SlashCmdList["ARCDUROVC"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "quiet" then DOC.debug = false; print(PREFIX .. "logging off.") return end
    DOC.debug = true   -- any test/command turns logging on so you can see what happens
    if msg == "" or msg == "help" then
        Log("usage: /arcdurovc <cooldownID or arcID> <auraSpellID> [unit]")
        Log("  overlays an aura-duration AuraButton on that cooldown icon, filtered to the buff spell id.")
        Log("  /arcdurovc off <cooldownID>  -> remove the overlay from that icon.")
        return
    end
    local a, b = msg:match("^(%S+)%s+(%S+)")
    if a == "off" then
        local frame = ResolveFrameForCdID(tonumber(b) or b)
        if frame then DOC.Detach(frame) else Log("no frame for %s", tostring(b)) end
        return
    end
    local rest = msg:match("^%S+%s+%S+%s+(%S+)")
    local cdKey = tonumber(a) or a
    local spellID = tonumber(b)
    if not spellID then Log("need a numeric aura spell id as the 2nd arg.") return end
    local frame = ResolveFrameForCdID(cdKey)
    if not frame then Log("no live frame for cdID/arcID '%s' (is the icon shown?).", tostring(cdKey)) return end
    local sName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    Log("attaching aura %s (%s) onto icon %s ...", tostring(spellID), tostring(sName or "?"), tostring(cdKey))
    DOC.Attach(frame, spellID, rest or "player")
end
