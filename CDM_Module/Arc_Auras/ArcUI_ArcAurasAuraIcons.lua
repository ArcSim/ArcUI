-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Arc Auras AURA ICONS — buff/debuff icons driven by the 12.1
-- engine-owned AuraContainer system.
--
-- Architecture (lab-proven in ArcUI_AuraLab, see the backend spec at
-- E:\WoWDev\reference\ArcUI_AuraIcons_backend_spec.md):
--   * One ArcUI HOLDER frame per icon (ArcAuras.CreateFrame type="aura") —
--     inherits drag, CDM groups, per-icon settings, Masque, tooltips. The
--     holder's own Icon texture is the desaturated GHOST (the "aura missing"
--     look); its Cooldown stays idle.
--   * One engine CustomAuraButton per tracked unit, created via
--     container:AddAuraSlot and ANCHORED over the holder (never reparented).
--     The engine owns all aura data (secret in combat) and drives the
--     button's show/hide, icon, swipe, stacks and duration text.
--   * Buttons carry NO XML template: regions are built in Lua inside
--     initializeFrame (statically-configured children keep rendering while
--     the button is forbidden in combat). This also keeps the file inert on
--     live 12.0 clients — an <AuraButton> XML template would error there.
--
-- SECRECY RULES (hard-won): never read ANYTHING off an engine button
-- (IsShown/GetWidth are secret; the button is FORBIDDEN in combat). All
-- writes are create-time. Sizes come from OUR settings, never button reads.
--
-- Visibility conditions (Show on Specs / Talent Conditions) mirror the
-- cooldown-icon system, WITHOUT the spell-known check — aura spellIDs are
-- often uncastable aura-only IDs.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local ArcAuras = ns.ArcAuras
if not ArcAuras then
    print("|cffFF4444[Arc Aura Icons]|r ERROR: ArcAuras core not loaded")
    return
end

local AuraIcons = {}
ns.AuraIcons = AuraIcons

-- 12.1 gate: the whole module is inert on older clients.
local IS_121 = (select(4, GetBuildInfo()) or 0) >= 120100

local ID_PREFIX = "arc_aura_"

-- State
local allContainers = {}     -- list of { unit=, frame= } (one per icon+unit)
local entries = {}           -- arcID -> { def, holder, subs = { {unit, key, container, frame} } }
local pendingRefresh = false -- combat-deferred visibility refresh
local loadWindowOver = false -- true once PLAYER_LOGIN fires (see EnsureSlots)

-- RC 69189+: slot-button creation reparents (CreateFrameOutbound+SetParent
-- inside the provider) and that is BLOCKED from addon stacks while auras are
-- secret. Secrecy is INSTANCE-based (24/7 in raids/M+), not just combat.
local function AurasSecretNow()
    return (C_Secrets and C_Secrets.ShouldAurasBeSecret
        and C_Secrets.ShouldAurasBeSecret()) and true or false
end

function AuraIcons.IsAvailable()
    return IS_121
end

local function GetDB()
    local db = ArcAuras.GetDB and ArcAuras.GetDB() or nil
    if not db then return nil end
    db.auraIcons = db.auraIcons or {}
    return db
end

function AuraIcons.MakeID(spellID) return ID_PREFIX .. tostring(spellID) end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTAINERS — ONE PER ICON PER UNIT, never shared.
--
-- WHY (in-game error, 2026-08-09): the engine's frame provider REUSES pooled
-- buttons via SetParent, and reparenting a released (forbidden-aspected)
-- frame from an addon stack is BLOCKED ("Reparenting disallowed as child
-- object would inherit forbidden aspects"). A shared container's pool warms
-- up over the session (parking, engine churn releases buttons), so any later
-- AddAuraSlot into it can die inside Blizzard's provider. A dedicated
-- container receives EXACTLY ONE AddAuraSlot, at creation, when its pool is
-- guaranteed empty — the provider always creates a FRESH frame (legal from
-- any context; this is also what keeps the mid-combat login path working).
-- The engine's own secure-stack recreations during the aura's life are
-- unaffected.
-- ═══════════════════════════════════════════════════════════════════════════

-- Containers only self-refresh on UNIT_AURA of their unit — target containers
-- go STALE on target swap (in-game confirmed), and pet containers when the
-- pet is summoned/dismissed/replaced. UpdateAllAuras on our own
-- PLAYER_TARGET_CHANGED / UNIT_PET closes both gaps.
local targetSwapWatcher
local function ArmTargetSwapRefresh()
    if targetSwapWatcher then return end
    targetSwapWatcher = CreateFrame("Frame")
    targetSwapWatcher:RegisterEvent("PLAYER_TARGET_CHANGED")
    targetSwapWatcher:RegisterEvent("UNIT_PET")
    targetSwapWatcher:SetScript("OnEvent", function(_, event, evUnit)
        if event == "UNIT_PET" and evUnit ~= "player" then return end
        local wantUnit = (event == "UNIT_PET") and "pet" or nil
        for _, rec in ipairs(allContainers) do
            if rec.unit ~= "player" and (not wantUnit or rec.unit == wantUnit)
               and type(rec.frame.UpdateAllAuras) == "function" then
                rec.frame:UpdateAllAuras()
            end
        end
    end)
end

local function CreateIconContainer(unit)
    if not IS_121 then return nil end

    if C_AddOns and C_AddOns.IsAddOnLoaded and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
        C_AddOns.LoadAddOn("Blizzard_AuraContainer")
    end

    local c = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if not c or type(c.AddAuraSlot) ~= "function" then
        print("|cffFF4444[Arc Aura Icons]|r AuraContainer API missing — feature unavailable this build")
        return nil
    end
    c:SetSize(1, 1)
    c:SetPoint("TOP", UIParent, "TOP", 0, -80)
    c:SetUnit(unit)
    c:SetEnabled(true)
    c:Show()
    table.insert(allContainers, { unit = unit, frame = c })
    if unit ~= "player" then ArmTargetSwapRefresh() end
    return c
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BUTTON WIRING (create-time only; regions are statically configured)
-- ═══════════════════════════════════════════════════════════════════════════

-- ── STACK-TEXT FORMATTER (12.1) — LIVE REGISTRY ─────────────────────────────
-- The engine's default application-count formatter hides the number at 0/1
-- stacks (CDM parity). A NumericRuleFormatter replaces it WHOLESALE and its
-- breakpoints run on the REAL (secret) count C-side — which restores both
-- options the 12.1 wall took away from stack text: "Show at 1 Stack"
-- (breakpoint at 1) and stack threshold COLORS (color escapes baked per band).
--
-- LIFECYCLE (the post-3.7.10.c lesson, Blizzard source verified): each slot's
-- button is created EXACTLY ONCE at AddAuraSlot (per-slot provider, batch
-- size 1) and initializeFrame never re-runs — anything read at wire time is
-- frozen into the binding until an explicit re-bind. The .c build derived the
-- formatter from settings at wire time, and the ADDON_LOADED prebuild runs
-- BEFORE the AceDB exists (GetIconSettings returned nil), so EVERY login
-- reverted to the engine-default formatter ("settings not being restored").
--
-- The fix is ONE PERSISTENT formatter object per icon key:
--   * the engine stores the OBJECT and calls FormatNumber on it on every
--     aura update (ApplyApplicationCount, source-verified) — so refreshing
--     the object's breakpoints re-derives the display with NO slot or button
--     work: plain userdata calls, legal in ANY context including mid-key;
--   * belt-and-suspenders (in case the engine copies the formatter at bind
--     time), ApplySettings re-binds SetApplicationCount on ACCESSIBLE
--     buttons whenever the registry version moves — SetApplicationCount
--     re-processes options and refreshes the display immediately;
--   * settings resolve through GetIconSettings, with a READ-ONLY raw
--     ArcUIDB fallback for the ADDON_LOADED window (per-icon chargeText
--     lives in raw spec storage that IS loaded before the AceDB exists).
-- Per-icon slots only — the dynamic Aura Group slots serve changing
-- occupants and get no per-icon formatter (GetLiveFormatter(nil) = nil).
local function StackColorEscape(c)
    return string.format("|c%02x%02x%02x%02x", 255,
        math.floor((c.r or 1) * 255 + 0.5),
        math.floor((c.g or 1) * 255 + 0.5),
        math.floor((c.b or 1) * 255 + 0.5))
end

-- Read-only raw fallback for the load window. Never creates tables: a bad
-- early spec key must not fabricate spec entries (the 3.7.9 phantom-spec
-- lesson), so this only follows keys that already exist.
local function RawChargeTextFallback(key)
    local charName = UnitName and UnitName("player")
    if not charName or charName == "Unknown" then return nil end
    local realm = GetRealmName and GetRealmName()
    if not realm then return nil end
    local charDB = ArcUIDB and ArcUIDB.char and ArcUIDB.char[charName .. " - " .. realm]
    local cdm = charDB and charDB.cdmGroups
    if not cdm or not cdm.specData then return nil end
    local specKey = (ns.CDMGroups and ns.CDMGroups.currentSpec) or cdm.lastActiveSpec
    if not specKey then
        local specIndex = GetSpecialization and GetSpecialization()
        local _, _, classID = UnitClass("player")
        if not specIndex or not classID then return nil end
        specKey = "class_" .. classID .. "_spec_" .. specIndex
    end
    local specData = cdm.specData[specKey]
    local profiles = specData and specData.layoutProfiles
    local profile = profiles and (profiles[specData.activeProfile or "Default"] or profiles["Default"])
    local iconSettings = profile and profile.iconSettings
    local s = iconSettings and iconSettings[tostring(key)]
    return s and s.chargeText or nil
end

-- Current breakpoint list for an icon's settings. ALWAYS returns a list —
-- when the features are off it mimics the engine default (hidden at 0/1,
-- plain number at 2+) so the live formatter can stay bound permanently.
local function ComputeStackBreakpoints(key)
    local cfg = ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(key)
    local cht = cfg and cfg.chargeText
    if not cht then cht = RawChargeTextFallback(key) end
    local showAtOne = cht and cht.enabled ~= false and cht.showSingleStack == true
    local bands
    if cht and cht.enabled ~= false and cht.thresholdColorEnabled
       and type(cht.thresholdBands) == "table" then
        bands = {}
        for i = 1, 6 do
            local b = cht.thresholdBands[i]
            local t = b and b.enabled and tonumber(b.threshold)
            if t and t >= 1 and b.color then bands[#bands + 1] = { t = t, c = b.color } end
        end
        table.sort(bands, function(a, b2) return a.t < b2.t end)
        if #bands == 0 then bands = nil end
    end

    -- Edges: 0 (always hidden), 1 (shown iff Show at 1), 2 (always shown),
    -- plus every band minimum. Highest band whose minimum is reached colors
    -- the segment; below the lowest band the fontstring's own color shows.
    local edgeSet = { [0] = true, [1] = true, [2] = true }
    if bands then for _, b in ipairs(bands) do edgeSet[b.t] = true end end
    local edges = {}
    for v in pairs(edgeSet) do edges[#edges + 1] = v end
    table.sort(edges)

    local bps = {}
    for _, lo in ipairs(edges) do
        local fmtStr
        if lo == 0 or (lo == 1 and not showAtOne) then
            fmtStr = ""
        else
            local esc
            if bands then
                for _, b in ipairs(bands) do
                    if b.t <= lo then esc = StackColorEscape(b.c) end
                end
            end
            fmtStr = esc and (esc .. "%d|r") or "%d"
        end
        bps[#bps + 1] = { threshold = lo, format = fmtStr }
    end
    return bps
end

-- exported: the CDM count overlay owns PER-FRAME formatter objects and
-- rewrites their rules on occupant/settings changes (frames shuffle
-- cooldownIDs mid-key; a shared per-cdID object couldn't be swapped there)
AuraIcons.ComputeStackBreakpoints = ComputeStackBreakpoints

local liveFormatters = {}          -- key (arcID string / CDM cooldownID number) -> formatter
local liveFormatterVersion = 0     -- bumped on refresh; buttons re-bind when stale

local function GetLiveFormatter(key)
    if not key then return nil end   -- dynamic group buttons: engine default
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then return nil end
    local f = liveFormatters[key]
    if not f then
        f = C_StringUtil.CreateNumericRuleFormatter()
        if not f then return nil end
        liveFormatters[key] = f
    end
    f:SetBreakpoints(ComputeStackBreakpoints(key))
    return f
end
AuraIcons.GetLiveFormatter = GetLiveFormatter
-- legacy export name (the CDM count overlay binds through this)
AuraIcons.BuildStackFormatter = GetLiveFormatter

-- Re-derive every registered formatter's breakpoints from CURRENT settings.
-- Plain userdata + saved-variable reads — legal anywhere, including mid-key.
function AuraIcons.RefreshLiveFormatters()
    liveFormatterVersion = liveFormatterVersion + 1
    for key, f in pairs(liveFormatters) do
        f:SetBreakpoints(ComputeStackBreakpoints(key))
    end
end

local function WireAuraButton(btn, arcID)
    -- The engine can re-run initializeFrame on the same frame — wire once
    if btn._arcWired then return end
    btn._arcWired = true
    -- Opaque backdrop UNDER the icon art: the holder's ghost renders BEHIND
    -- the button, so a translucent active icon (Active Alpha < 1) would
    -- composite over the ghost and read as "not dimmed at all". The plate
    -- ignores the button's alpha (stays opaque under the dimmed art) and
    -- lives/dies with the button's engine-driven visibility, so the ghost
    -- shows through exactly when the aura is down.
    local plate = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    plate:SetAllPoints()
    plate:SetColorTexture(0, 0, 0, 1)
    plate:SetIgnoreParentAlpha(true)
    btn._arcPlate = plate

    -- Icon art (engine-fed; texcoord matches Arc icon zoom look)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn._arcIcon = icon

    -- Aura swipe: REVERSED (fresh buff bright, dark grows as it runs out).
    -- Duration display = the swipe's OWN countdown numbers (CDM parity:
    -- bare "8", not the engine default-formatter's "8 s" — EQOL does the
    -- same). The Duration/Cooldown Text settings style and toggle it.
    local swipe = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    swipe:SetAllPoints()
    swipe:SetReverse(true)
    swipe:SetHideCountdownNumbers(false)
    swipe:SetDrawEdge(false)
    swipe:SetDrawBling(false)
    -- Swipe recipe = ArcUI's factory pattern EXACTLY (the proven one), with
    -- a full-bleed texture instead of CDM's margin-bearing one:
    --   * a texture FILE with EXPLICIT white color args is REQUIRED — the
    --     template's color-only swipe does not render on Lua-created
    --     cooldowns, and SetSwipeTexture without color args also fails
    --     (the factory passes 1,1,1,1 for this exact reason)
    --   * WHITE8X8 = edge-to-edge, no texcoord compensation
    --   * NO SetUseAuraDisplayTime — unverified on our setup; neither the
    --     lab's working swipe nor the factory uses it
    swipe:SetSwipeTexture("Interface\\Buttons\\WHITE8X8", 1, 1, 1, 1)
    swipe:SetSwipeColor(0, 0, 0, 0.8)
    -- CooldownFrameTemplate ships hidden="true"; show explicitly at create
    -- time (we can never check later — the sink carries a secret Shown aspect)
    swipe:Show()
    btn._arcSwipe = swipe

    -- Text overlay ABOVE the swipe (a child Cooldown renders over button
    -- textures otherwise). Named TextOverlay: the pandemic/glow port targets
    -- this frame so future visuals also land above the swipe.
    local overlay = CreateFrame("Frame", nil, btn)
    overlay:SetAllPoints()
    overlay:SetFrameLevel(swipe:GetFrameLevel() + 1)
    btn.TextOverlay = overlay

    local stacks = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    -- OVERLAY sublevel 7: the active border edges live on this SAME overlay at
    -- sublevel 6 (ApplyBorderEdges) — texts must sit one notch above or the
    -- border strips draw over them (the "stack text behind the border" report)
    stacks:SetDrawLayer("OVERLAY", 7)
    stacks:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    btn._arcStacks = stacks

    -- countdown fontstring reference for styling (the swipe owns the text).
    -- REHOME it onto TextOverlay: the FS is born on the swipe frame, a full
    -- frame level BELOW the overlay hosting the border edges — frame level
    -- beats draw layer, so SetDrawLayer(7) on the swipe frame still rendered
    -- the countdown UNDER the border. Same object, the Cooldown keeps
    -- driving its text; only the render context moves.
    if swipe.GetCountdownFontString then
        local cfs = swipe:GetCountdownFontString()
        btn._arcDurText = cfs
        if cfs then
            cfs:SetParent(overlay)
            cfs:SetDrawLayer("OVERLAY", 7)
        end
    end

    -- Hand the engine our widgets (inbound setters; engine drives from here)
    btn:SetIcon(icon)
    btn:SetApplicationCount(stacks, { formatter = GetLiveFormatter(arcID) })
    btn._arcFmtKey = arcID
    btn._arcFmtBoundV = liveFormatterVersion
    btn:SetDurationCooldown(swipe)

    -- The holder owns all mouse interaction (drag/tooltip/context menu)
    btn:EnableMouse(false)
end
-- exported: the dynamic Aura Groups module wires its engine-group buttons
-- through the SAME create-time recipe
AuraIcons.WireAuraButton = WireAuraButton

-- ═══════════════════════════════════════════════════════════════════════════
-- DEF HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function UnitsFor(def)
    if def.unitMode == "debuff" then return { "target" } end
    if def.unitMode == "both" then return { "player", "target" } end
    if def.unitMode == "pet" then return { "pet" } end   -- buffs the PET carries
    return { "player" }   -- "buff"
end

local function FilterFor(def, unit)
    -- friendly units carry HELPFUL auras; only the target lane hunts debuffs
    if unit == "player" or unit == "pet" then return "HELPFUL" end
    return def.ownOnly and "HARMFUL|PLAYER" or "HARMFUL"
end

local function IncludeMap(def)
    -- full candidate set when present (CDM imports carry base + override +
    -- linked IDs -- the buff often lives on a linked ID, not the cast spell)
    if def.spellIDs and next(def.spellIDs) then return def.spellIDs end
    return { [def.spellID] = true }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- VISIBILITY (Show on Specs / Talent Conditions — NO spell-known check)
-- ═══════════════════════════════════════════════════════════════════════════

function AuraIcons.ShouldBeVisible(def)
    if not def then return false end
    if def.showOnSpecs and #def.showOnSpecs > 0 then
        local currentSpec = GetSpecialization() or 1
        local ok = false
        for _, spec in ipairs(def.showOnSpecs) do
            if spec == currentSpec then ok = true break end
        end
        if not ok then return false end
    end
    if def.talentConditions and #def.talentConditions > 0 then
        if ns.TalentPicker and ns.TalentPicker.CheckTalentConditions then
            if not ns.TalentPicker.CheckTalentConditions(
                def.talentConditions, def.talentConditionMode or "all") then
                return false
            end
        end
    end
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT PARK / UNPARK (slots cannot be removed — an empty include set is the
-- lab-proven "off" state). Filter edits are queued out of combat as
-- belt-and-suspenders.
-- ═══════════════════════════════════════════════════════════════════════════

local function ApplySlotFilters(entry, parked)
    local def = entry.def
    for _, sub in ipairs(entry.subs) do
        -- PARK = the never-matching id, NEVER the empty table (ONE convention,
        -- the BD pattern the rewire already uses): an empty set is the
        -- permissive fallback if the engine ever reverts toward creation-time
        -- filters — a filterless HELPFUL slot displays an ARBITRARY buff (the
        -- Bonegrinder icon showing a permanent rep bonus).
        local filters = parked and { includeSpellIDs = { [0] = true } }
            or { includeSpellIDs = IncludeMap(def) }
        sub.container:SetAuraSlotCandidateFilters(sub.key, filters)
    end
    entry.parked = parked and true or false
end

local combatQueue = {}
local function SetSlotsParked(entry, parked)
    if InCombatLockdown() then
        combatQueue[entry] = parked
        return
    end
    ApplySlotFilters(entry, parked)
end

-- FILTER TRUTH RE-ASSERTION (the Bonegrinder wrong-aura report): a slot that
-- loses its candidate filter shows an ARBITRARY buff — a permanently-active
-- rep bonus always wins a filterless HELPFUL slot. Our writers only fire on
-- STATE TRANSITIONS, so a filter dropped engine-side (mid-session container
-- churn) was never re-pushed. SetAuraSlotCandidateFilters is a data-only
-- write (legal in any context, engine rescans internally): re-push every
-- entry's correct set at the settle edges. A handful of table writes per
-- event, zero idle cost.
function AuraIcons.ReassertFilters()
    if not IS_121 then return end
    for _, entry in pairs(entries) do
        if entry.subs and #entry.subs > 0 and combatQueue[entry] == nil then
            ApplySlotFilters(entry, entry.parked)
        end
    end
end

local regenWatcher = CreateFrame("Frame")
regenWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
regenWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
regenWatcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
regenWatcher:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        for entry, parked in pairs(combatQueue) do
            ApplySlotFilters(entry, parked)
        end
        wipe(combatQueue)
        if pendingRefresh then
            pendingRefresh = false
            AuraIcons.RefreshVisibility()
        end
    end
    -- every settle edge (regen included): re-assert believed-correct filters
    AuraIcons.ReassertFilters()
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- ICON BUILD / TEARDOWN
-- ═══════════════════════════════════════════════════════════════════════════

-- Create the entry's containers + engine slots (NO holder). This is the ONLY
-- place AddAuraSlot is called — and slot creation must happen in an
-- ACCESSIBLE context or during the load window (pre-PLAYER_LOGIN, the
-- sanctioned reload-mid-combat window): on RC 69189+ the provider creates
-- the slot's button via CreateFrameOutbound + SetParent, and that reparent
-- is BLOCKED from addon stacks while auras are secret (2x/7x in-game
-- errors). Pool REUSE (park/unpark, engine churn) never reparents and stays
-- safe — so every def's slots are pre-created PARKED at ADDON_LOADED and any
-- later creation defers until accessible. maxFrameCount pre-creates the
-- button at AddAuraSlot time, so the whole lifetime after this call is
-- reuse-only.
local function EnsureSlots(arcID, def, startParked)
    local entry = entries[arcID]
    if entry and #entry.subs > 0 then return true end
    if not IS_121 then return false end
    if loadWindowOver and AurasSecretNow() then return false end

    entry = entry or { def = def, subs = {} }
    entry.def = def
    entry.parked = startParked and true or false
    entries[arcID] = entry

    for _, unit in ipairs(UnitsFor(def)) do
        local c = CreateIconContainer(unit)
        if c then
            -- generation suffix: slots can never be unregistered, so a REWIRE
            -- (settings that live in create-time bindings, e.g. the stack
            -- formatter) parks the old keys and adds fresh ones
            local key = arcID .. "_" .. unit .. "_g" .. (entry.gen or 0)
            local sub = { unit = unit, key = key, container = c }
            table.insert(entry.subs, sub)
            -- ALL button setup lives in initializeFrame: the engine
            -- RE-CREATES slot buttons over the aura's life and re-runs this
            -- (MSUF-verified) — a one-time anchor after AddAuraSlot returns
            -- strands later buttons at the container's corner.
            local btn = c:AddAuraSlot(key, FilterFor(def, unit), {
                maxFrameCount = 1,
                initializeFrame = function(b)
                    WireAuraButton(b, arcID)
                    sub.frame = b
                    -- bake the icon's CONFIGURED zoom into art + swipe here:
                    -- initializeFrame is always a legal context and re-runs
                    -- on every engine button recreation, while ApplySettings
                    -- is blocked whenever the button is forbidden (= while
                    -- the aura is up, exactly when the swipe is visible)
                    local s2 = ArcAuras.GetCachedSettings and ArcAuras.GetCachedSettings(arcID)
                    local z = (s2 and s2.zoom) or 0.08
                    if b._arcIcon then
                        b._arcIcon:SetTexCoord(z, 1 - z, z, 1 - z)
                    end
                    local e = entries[arcID]
                    local h = e and e.holder
                    if h then
                        -- ANCHOR (never reparent): two-point anchor follows
                        -- every holder resize from the per-icon settings
                        b:ClearAllPoints()
                        b:SetPoint("TOPLEFT", h, "TOPLEFT", 0, 0)
                        b:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", 0, 0)
                        -- DRAW ORDER: the button is parented to OUR container,
                        -- not the holder — without a strata/level sync it
                        -- renders UNDER the CDMGroups-raised holder (ghost
                        -- covers the live aura = "buff didn't show").
                        -- FULL LADDER (holder = h): ghost regions h, missing
                        -- glow host h+1 (a DECISIVE level above the ghost —
                        -- equal-level ties are family-dependent: pixel won,
                        -- ants/proc lost), GHOST BORDER overlay h+2 — BELOW
                        -- the button: the live button OCCLUDES the ghost
                        -- chrome while the aura is up (we can never READ the
                        -- button's secret shown state, so stacking order IS
                        -- the state logic; the old h+6 put this chrome above
                        -- the texts = the "text behind the border" bug) —
                        -- button h+3, swipe h+4, text overlay h+5 (active
                        -- border sublevel 6, texts sublevel 7), glow anchor
                        -- h+8, count container h+10. CHILDREN DO NOT FOLLOW
                        -- a parent SetFrameLevel — re-level the swipe/text
                        -- overlay explicitly or they keep container-high
                        -- levels. Swipe ABOVE the button (equal level loses
                        -- the draw order against the icon region = invisible
                        -- swipe).
                        local lvl = h:GetFrameLevel() + 3
                        b:SetFrameStrata(h:GetFrameStrata())
                        b:SetFrameLevel(lvl)
                        if b._arcSwipe then b._arcSwipe:SetFrameLevel(lvl + 1) end
                        if b.TextOverlay then b.TextOverlay:SetFrameLevel(lvl + 2) end
                    end
                    b:EnableMouse(false)
                    -- fresh button needs the active-state visuals re-applied.
                    -- SYNCHRONOUS first: initializeFrame is the always-legal
                    -- write window, so a button created MID-COMBAT (login
                    -- during a pull, engine recreation during a fight) gets
                    -- its full styling here instead of sitting unstyled
                    -- until regen. The deferred pass settles the cascade
                    -- out of combat as before.
                    AuraIcons.ApplySettings(arcID, b)
                    C_Timer.After(0, function() AuraIcons.ApplySettings(arcID) end)
                end,
                -- parked creation uses the never-matching id too — never bake
                -- the permissive empty set into the slot's creation state
                candidateFilters = { includeSpellIDs = startParked and { [0] = true } or IncludeMap(def) },
            })
            if btn and not sub.frame then sub.frame = btn end
        end
    end
    return true
end

-- Pre-create every def's slots (parked) inside the load window — legal even
-- when logging/reloading into combat or an instance. Guarded against the
-- early-login "Unknown" character key (spec-key fabrication lesson).
local function PreBuildAllSlots()
    if not IS_121 then return end
    local pn = UnitName and UnitName("player")
    if not pn or pn == "Unknown" then return end
    local db = GetDB()
    if not db then return end
    for arcID, def in pairs(db.auraIcons) do
        EnsureSlots(arcID, def, true)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SETTINGS APPLICATION (the Icon Catalog "Aura" option set)
--
-- The aura panel writes the SAME keys the native CDM aura icons use:
--   Aura ACTIVE  -> cooldownStateVisuals.readyState    (alpha/desaturate/...)
--   Aura MISSING -> cooldownStateVisuals.cooldownState (alpha/desaturate/...)
-- Mapping here: readyState -> the ENGINE BUTTON (static create-time-style
-- writes; it only renders while the aura is active), cooldownState -> the
-- HOLDER ghost (visible whenever the button hides). Zero state reads.
-- Buttons are FORBIDDEN in combat: button writes queue to combat end.
-- ═══════════════════════════════════════════════════════════════════════════

local pendingApply = {}

-- Shared border-edge painter (ONE geometry for ghost and active borders):
-- four WHITE8X8 edges created on `host`, anchored around `anchor`, styled
-- from the standard border settings keys, alpha-multiplied for the ghost.
local BORDER_EDGE_KEYS = { "top", "bottom", "left", "right" }
local function ApplyBorderEdges(host, anchor, storeKey, bcfg, alphaMul)
    local edges = host[storeKey]
    if not (bcfg and bcfg.enabled) then
        if edges then
            for _, t in pairs(edges) do t:Hide() end
        end
        return
    end
    if not edges then
        edges = {}
        for _, k in ipairs(BORDER_EDGE_KEYS) do
            local t = host:CreateTexture(nil, "OVERLAY", nil, 6)
            t:SetTexture("Interface\\Buttons\\WHITE8X8")
            edges[k] = t
        end
        host[storeKey] = edges
    end
    local color
    if bcfg.useClassColor then
        local _, classTag = UnitClass("player")
        local cc = classTag and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classTag]
        color = cc and { cc.r, cc.g, cc.b, 1 } or bcfg.color or { 1, 1, 1, 1 }
    else
        color = bcfg.color or { 1, 1, 1, 1 }
    end
    local r = color[1] or 1
    local g = color[2] or 1
    local b = color[3] or 1
    local a = color[4] or 1
    local th = bcfg.thickness or 2
    local inset = bcfg.inset or -3
    edges.top:ClearAllPoints()
    edges.top:SetPoint("TOPLEFT", anchor, "TOPLEFT", inset, -inset)
    edges.top:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -inset, -inset)
    edges.top:SetHeight(th)
    edges.bottom:ClearAllPoints()
    edges.bottom:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", inset, inset)
    edges.bottom:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -inset, inset)
    edges.bottom:SetHeight(th)
    edges.left:ClearAllPoints()
    edges.left:SetPoint("TOPLEFT", anchor, "TOPLEFT", inset, -inset)
    edges.left:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", inset, inset)
    edges.left:SetWidth(th)
    edges.right:ClearAllPoints()
    edges.right:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -inset, -inset)
    edges.right:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -inset, inset)
    edges.right:SetWidth(th)
    for _, k in ipairs(BORDER_EDGE_KEYS) do
        edges[k]:SetVertexColor(r, g, b, a)
        edges[k]:SetAlpha(alphaMul or 1)
        edges[k]:Show()
    end
end

-- exported: the Aura Groups module paints the SAME border on its engine
-- group buttons (pixel-identical geometry, one painter)
AuraIcons.ApplyBorderEdges = ApplyBorderEdges

-- Shared custom-label painter (ONE styling path for the live button labels
-- and the panel-open holder previews). Mirrors ns.CustomLabel's keys and
-- defaults: size 12, anchor CENTER, white, OVERLAY 7, shared font/outline.
local function PaintLabel(fs, cl, sfx, anchorFrame)
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local fpath = (cl.font and lsm and lsm:Fetch("font", cl.font, true))
        or "Fonts\\FRIZQT__.TTF"
    local outl = cl.outline or "OUTLINE"
    if outl == "NONE" then outl = "" end
    fs:SetFont(fpath, cl["size" .. sfx] or 12, outl)
    fs:SetDrawLayer("OVERLAY", 7)
    local col = cl["color" .. sfx]
    if col then
        fs:SetTextColor(col.r or 1, col.g or 1, col.b or 1, col.a or 1)
    else
        fs:SetTextColor(1, 1, 1, 1)
    end
    fs:SetText(cl["text" .. sfx])
    fs:ClearAllPoints()
    local anch = cl["anchor" .. sfx] or "CENTER"
    fs:SetPoint(anch, anchorFrame, anch,
        cl["xOffset" .. sfx] or 0, cl["yOffset" .. sfx] or 0)
    fs:Show()
end

-- Should label li render at all (text present, within count, active-mode on)?
local function LabelWanted(cl, li)
    if not cl then return false end
    if li > ((cl.labelCount) or 1) then return false end
    local sfx = (li == 1) and "" or tostring(li)
    local text = cl["text" .. sfx]
    if not text or text == "" then return false end
    return cl["showWhenActive" .. sfx] ~= false
end

-- Formatter for the Color-by-Duration bound text. The engine's default aura
-- formatter renders "4 s" spaced acronyms; a SecondsFormatter can at best do
-- "4s" (a unit is always printed). A NumericRuleFormatter with breakpoint
-- rules is the only way to reproduce the native countdown-numbers look
-- (bare "4" under a minute) AND honor the Decimals / Abbreviate-M:SS
-- options, whose semantics mirror ns.CooldownFormatter:
--   decimals == 1  -> one decimal below decimalThreshold (<=0 = everywhere)
--   abbrevThreshold > 0 -> M:SS below that threshold (legacy strings mapped)
-- CN-client crash shield: a CN 12.1 build ships a native INTEGER division in
-- the aura countdown-text engine that hard-crashes the whole client
-- (INT_DIVIDE_BY_ZERO in Wow.exe) when bound countdown text refreshes. The
-- ONE fractional value ArcUI ever hands that engine is the decimals band's
-- 0.1 step below — integer-truncated that is 0. Until Blizzard fixes the CN
-- client, CN renders aura-icon decimals as whole seconds instead of risking
-- the crash. No effect on any other region.
local IS_CN_CLIENT = (GetCurrentRegion and GetCurrentRegion() == 5)
    or (GetCVar and GetCVar("portal") == "CN")

local function BuildBoundTextFormatter(ct)
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
            and Enum.NumericRuleFormatRounding) then
        return nil
    end
    local fmt = C_StringUtil.CreateNumericRuleFormatter()
    if not fmt then return nil end
    local UP, DOWN = Enum.NumericRuleFormatRounding.Up, Enum.NumericRuleFormatRounding.Down
    local bps = {}
    -- seconds band (0-60): countdown parity = ceil to whole seconds
    local decT = 0
    if ct.decimals == 1 and not IS_CN_CLIENT then
        local v = ct.decimalThreshold
        decT = (type(v) == "number" and v > 0) and math.min(v, 60) or 60
    end
    if decT > 0 then
        bps[#bps + 1] = { threshold = 0, step = 0.1, rounding = UP, format = "%.1f" }
    end
    if decT < 60 then
        bps[#bps + 1] = { threshold = decT, step = 1, rounding = UP, format = "%d" }
    end
    -- minutes band: M:SS below abbrevThreshold when configured, else "Nm"
    local abbrev = ct.abbrevThreshold
    if type(abbrev) == "string" then
        abbrev = (abbrev == "1m" and 60) or (abbrev == "5m" and 300)
            or (abbrev == "1h" and 3600) or nil
    end
    if type(abbrev) ~= "number" or abbrev <= 0 then abbrev = nil end
    if abbrev and abbrev > 60 then
        bps[#bps + 1] = { threshold = 60, format = "%d:%02d",
            components = { { div = 60, rounding = DOWN }, { mod = 60, step = 1, rounding = DOWN } } }
        if abbrev < 3600 then
            bps[#bps + 1] = { threshold = abbrev, format = "%dm",
                components = { { div = 60, step = 1, rounding = DOWN } } }
        end
    else
        bps[#bps + 1] = { threshold = 60, format = "%dm",
            components = { { div = 60, step = 1, rounding = DOWN } } }
    end
    bps[#bps + 1] = { threshold = 3600, format = "%dh",
        components = { { div = 3600, step = 1, rounding = DOWN } } }
    fmt:SetBreakpoints(bps)
    return fmt
end

-- legalBtn: a button currently inside ITS OWN initializeFrame call — writes
-- to it are create-time legal even when the accessibility probe says no
-- (the probe reports the general context, not the init-window grant).
-- ═══════════════════════════════════════════════════════════════════════════
-- ONE ACTIVE-BUTTON STYLING PATH: every per-icon option that dresses the
-- engine button lives HERE — alpha/desat/zoom, swipe, duration text (plain
-- countdown numbers or Color-by-Duration binding, full font/shadow/position),
-- the drawn border, stack text (font/shadow/anchor/free position), custom
-- labels and the glow packs. The SLOT path (ApplySettings) and the AURA
-- GROUP engine buttons both run through this exact function, so the two
-- presentations can never drift. sizeRef = the holder (slots) or any object
-- with :GetSize() (group buttons) — only the glow packs read it.
-- ═══════════════════════════════════════════════════════════════════════════
function AuraIcons.StyleActiveButton(btn, settings, sizeRef)
    local csv = settings and settings.cooldownStateVisuals or {}
    local rs = csv.readyState or {}
    local sv = settings and ns.CDMEnhance and ns.CDMEnhance.GetEffectiveStateVisuals
        and ns.CDMEnhance.GetEffectiveStateVisuals(settings) or nil

    local activeAlpha = rs.alpha
    if activeAlpha == nil then activeAlpha = sv and sv.readyAlpha end
    if activeAlpha == nil then activeAlpha = 1 end
    local activeDesat = rs.desaturate
    if activeDesat == nil then activeDesat = sv and sv.readyDesaturate end

    -- Show Icon off (forceHideIcon): CDM parity — art/swipe/border/glows all
    -- hide, ONLY duration + stack text survive (at full alpha).
    -- Preserve Duration Text: the icon/swipe dim to Active Alpha while the
    -- texts float at full opacity (SetIgnoreParentAlpha, same mechanism as
    -- CooldownState's PreserveDurationText on CDM icons).
    local forceHide = settings and settings.forceHideIcon == true
    local floatTexts = forceHide or rs.preserveDurationText == true

    btn:SetAlpha(forceHide and 1 or activeAlpha)
    if btn._arcPlate then btn._arcPlate:SetShown(not forceHide) end
    if btn._arcIcon then
        btn._arcIcon:SetShown(not forceHide)
        btn._arcIcon:SetDesaturated(activeDesat and true or false)
        -- icon zoom parity with the Arc pipeline
        local z = (settings and settings.zoom) or 0.08
        btn._arcIcon:SetTexCoord(z, 1 - z, z, 1 - z)
    end

    -- ── the "cooldown frame solution" (Arc's call): the button's
    -- swipe / duration text / stacks are ORDINARY widgets WE own
    -- — dress them from the SAME settings keys the Arc icon
    -- pipeline uses. The engine only feeds the data into them.
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)

    local sw = btn._arcSwipe
    if sw then
        local swipe = (settings and settings.cooldownSwipe) or {}
        sw:SetDrawSwipe(not forceHide and swipe.showSwipe ~= false)
        sw:SetDrawEdge(not forceHide and swipe.showEdge == true)  -- aura default: no edge
        sw:SetReverse(swipe.reverse ~= false)       -- aura default: reversed
        local sc = swipe.swipeColor
        if sc then
            sw:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
        else
            sw:SetSwipeColor(0, 0, 0, 0.7)
        end
        -- SWIPE INSETS (mirrors the Arc holder pipeline's branch exactly:
        -- separateInsets OFF must ignore stale X/Y values)
        local ix, iy
        if swipe.separateInsets then
            ix, iy = swipe.swipeInsetX or 0, swipe.swipeInsetY or 0
        else
            ix = swipe.swipeInset or 0
            iy = ix
        end
        sw:ClearAllPoints()
        sw:SetPoint("TOPLEFT", btn, "TOPLEFT", ix, -iy)
        sw:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -ix, iy)
        -- EDGE scale + color (plain widget methods, plain saved numbers)
        if sw.SetEdgeScale then sw:SetEdgeScale(swipe.edgeScale or 1) end
        if sw.SetEdgeColor then
            local ec = swipe.edgeColor
            if ec then
                sw:SetEdgeColor(ec.r or 1, ec.g or 1, ec.b or 1, ec.a or 1)
            else
                sw:SetEdgeColor(1, 1, 1, 1)
            end
        end
    end

    -- DURATION DISPLAY, two paths sharing one style block:
    --   plain    -> the swipe's countdown numbers (CDM parity)
    --   colored  -> Color-by-Duration via the ENGINE's text
    --               binding: our fontstring + the user's
    --               threshold curve (CDMTextColor's builder) +
    --               a NumericRuleFormatter reproducing the bare
    --               countdown-numbers look (see the builder above).
    -- Percent mode binds RemainingPercent (enum confirmed in the
    -- 69111 docs); GetCurveForConfig already builds percent-scaled
    -- curves when durationColorUsePercent is set.
    local ct = (settings and settings.cooldownText) or {}
    local curve = nil
    if ct.enabled ~= false and ct.durationColor
       and ns.CDMTextColor and ns.CDMTextColor.GetCurveForConfig then
        if not ct.durationColorUsePercent
           or (Enum.DurationTextBindingProperty
               and Enum.DurationTextBindingProperty.RemainingPercent) then
            curve = ns.CDMTextColor.GetCurveForConfig(settings)
        end
    end
    if sw then
        sw:SetHideCountdownNumbers(ct.enabled == false or curve ~= nil)
        -- Decimals + Abbreviate (M:SS) via the shared formatter
        if ns.CooldownFormatter and ns.CooldownFormatter.Apply then
            ns.CooldownFormatter.Apply(sw, ct)
        end
    end
    local dt
    if curve then
        local bdt = btn._arcBoundDurText
        if not bdt then
            bdt = btn.TextOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
            -- above the border edges (sublevel 6) — see _arcStacks
            bdt:SetDrawLayer("OVERLAY", 7)
            btn._arcBoundDurText = bdt
        end
        -- CustomAuraButtonDurationTextOptions (69111, doc-verified)
        -- consumes EXACTLY: binding / textFormatter / textFormat /
        -- textColor = { curve, property }. The earlier flat
        -- `textColorCurve` + `formatter` keys were silently
        -- stripped by ProcessCustomAuraButtonDurationTextOptions
        -- (the "4 s + no color" bug), and the button's own binding
        -- is NOT reachable from addons (GetDurationTextBinding
        -- lives on the PrivateMixin) — the options table is the
        -- only wiring path.
        local dopts = {}
        local prop = Enum.DurationTextBindingProperty
            and (ct.durationColorUsePercent
                and Enum.DurationTextBindingProperty.RemainingPercent
                or Enum.DurationTextBindingProperty.RemainingDuration)
        if prop then
            dopts.textColor = { curve = curve, property = prop }
        end
        local fmt = BuildBoundTextFormatter(ct)
        if not fmt and C_StringUtil and C_StringUtil.CreateSecondsFormatter then
            -- fallback: compact "4s" beats the default "4 s"
            fmt = C_StringUtil.CreateSecondsFormatter()
            if fmt then
                if fmt.SetDefaultAbbreviation and Enum.SecondsFormatterAbbreviation then
                    fmt:SetDefaultAbbreviation(Enum.SecondsFormatterAbbreviation.OneLetter)
                end
                if fmt.SetConvertToLower then fmt:SetConvertToLower(true) end
            end
        end
        dopts.textFormatter = fmt
        btn:SetDurationText(bdt, dopts)
        bdt:Show()
        dt = bdt
    else
        -- unbind a previously-colored icon back to countdown numbers
        if btn._arcBoundDurText then
            if btn.ClearDurationText then btn:ClearDurationText() end
            btn._arcBoundDurText:SetText("")
            btn._arcBoundDurText:Hide()
        end
        dt = btn._arcDurText
    end
    if dt then
        local fontPath = (ct.font and lsm and lsm:Fetch("font", ct.font, true))
            or select(1, dt:GetFont())
        local outline = ct.outline or "OUTLINE"
        if outline == "NONE" then outline = "" end
        dt:SetFont(fontPath, ct.size or 14, outline)
        dt:SetDrawLayer("OVERLAY", 7)
        if not curve then
            -- static color only in the plain path — the engine's
            -- curve owns the color when Color-by-Duration is on
            local c = ct.color or { r = 1, g = 1, b = 1, a = 1 }
            dt:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
        end
        if ct.shadow then
            dt:SetShadowOffset(ct.shadowOffsetX or 1, ct.shadowOffsetY or -1)
            local scol = ct.shadowColor
            if scol then
                dt:SetShadowColor(scol.r or 0, scol.g or 0, scol.b or 0, scol.a or 0.8)
            else
                dt:SetShadowColor(0, 0, 0, 0.8)
            end
        else
            dt:SetShadowOffset(0, 0)
        end
        dt:ClearAllPoints()
        if ct.mode == "free" then
            dt:SetPoint("CENTER", btn, "CENTER", ct.freeX or 0, ct.freeY or 0)
        else
            local a = ct.anchor or "CENTER"
            dt:SetPoint(a, btn, a, ct.offsetX or 0, ct.offsetY or 0)
        end
        -- Preserve Duration Text / Show Icon off: the text ignores the
        -- button's dimmed alpha and renders at full strength
        if dt.SetIgnoreParentAlpha then
            dt:SetIgnoreParentAlpha(floatTexts)
            if floatTexts then dt:SetAlpha(1) end
        end
    end

    -- BORDER ON THE BUTTON ITSELF (EQOL pattern): edges live on
    -- the button's TextOverlay — they show/hide WITH the aura
    -- and always draw above the swipe. Same shared painter as
    -- the ghost border = pixel-identical geometry. Hidden with
    -- the rest of the art when Show Icon is off.
    ApplyBorderEdges(btn.TextOverlay or btn, btn, "_arcBtnBorder",
        (not forceHide) and settings and settings.border or nil, 1)

    local cht = (settings and settings.chargeText) or {}
    local st = btn._arcStacks
    if st then
        local fontPath = (cht.font and lsm and lsm:Fetch("font", cht.font, true))
            or select(1, st:GetFont())
        local outline = cht.outline or "OUTLINE"
        if outline == "NONE" then outline = "" end
        st:SetFont(fontPath, cht.size or 14, outline)
        st:SetDrawLayer("OVERLAY", 7)
        local c = cht.color
        if c then st:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1) end
        if cht.shadow then
            st:SetShadowOffset(cht.shadowOffsetX or 1, cht.shadowOffsetY or -1)
            local scol = cht.shadowColor
            if scol then
                st:SetShadowColor(scol.r or 0, scol.g or 0, scol.b or 0, scol.a or 0.8)
            else
                st:SetShadowColor(0, 0, 0, 0.8)
            end
        else
            st:SetShadowOffset(0, 0)
        end
        st:ClearAllPoints()
        if cht.mode == "free" then
            st:SetPoint("CENTER", btn, "CENTER", cht.freeX or 0, cht.freeY or 0)
        else
            local a = cht.anchor or cht.position or "BOTTOMRIGHT"
            st:SetPoint(a, btn, a, cht.offsetX or -2, cht.offsetY or 2)
        end
        -- CDM parity: preserve floats the stack text alongside the duration
        if st.SetIgnoreParentAlpha then
            st:SetIgnoreParentAlpha(floatTexts)
            if floatTexts then st:SetAlpha(1) end
        end
        if cht.enabled == false then st:Hide() else st:Show() end
    end

    -- CUSTOM LABELS (ACTIVE-state only): up to 3 text overlays on
    -- the button's TextOverlay — the engine showing/hiding the
    -- button IS the visibility engine, so labels render exactly
    -- while the aura is active. There is no missing-state signal
    -- on container icons (aspect-walled); the When Inactive
    -- toggle is hidden in the panel for these icons. Same keys +
    -- defaults as ns.CustomLabel (size 12, CENTER, white,
    -- OVERLAY 7, shared font/outline).
    local cl = settings and settings.customLabel
    local overlayF = btn.TextOverlay
    if overlayF then
        for li = 1, 3 do
            local fsKey = "_arcCL" .. li
            local fs = overlayF[fsKey]
            if LabelWanted(cl, li) and not forceHide then
                if not fs then
                    fs = overlayF:CreateFontString(nil, "OVERLAY")
                    overlayF[fsKey] = fs
                end
                PaintLabel(fs, cl, (li == 1) and "" or tostring(li), btn)
            elseif fs then
                fs:SetText("")
                fs:Hide()
            end
        end
    end

    -- BUTTON GLOWS — active ("always"), pandemic-timed, swap and
    -- the red pandemic border ALL run through the pack engine in
    -- ArcUI_ArcAurasAuraGlows. ns.Glows/LCG must NEVER target a
    -- button descendant: everything anchored into the button
    -- partition has fully SECRET rect reads (even with an
    -- explicit SetSize — in-game proven), and LCG does
    -- arithmetic on the target's dimensions. Packs take W/H as
    -- PARAMETERS from sizeRef instead — the "special cook".
    if ns.AuraIconGlows and ns.AuraIconGlows.ApplyPandemic and sizeRef then
        ns.AuraIconGlows.ApplyPandemic(btn, sizeRef, settings)
    end
end
local StyleActiveButton = AuraIcons.StyleActiveButton

function AuraIcons.ApplySettings(arcID, legalBtn)
    local entry = entries[arcID]
    if not (entry and entry.holder) then return end

    local settings = ArcAuras.GetCachedSettings and ArcAuras.GetCachedSettings(arcID)
    local csv = settings and settings.cooldownStateVisuals or {}
    local rs = csv.readyState or {}
    local cs = csv.cooldownState or {}
    local sv = settings and ns.CDMEnhance and ns.CDMEnhance.GetEffectiveStateVisuals
        and ns.CDMEnhance.GetEffectiveStateVisuals(settings) or nil

    -- ── AURA MISSING -> holder ghost ────────────────────────────────────
    local holder = entry.holder
    -- Show Icon off: the AURA-ICON force-hide is owned HERE, not by
    -- CDMEnhance's whole-frame alpha-0 path (that would also kill the
    -- engine-button texts this option promises to keep) — ghost art, ghost
    -- border and the missing glow all hide; StyleActiveButton hides the
    -- active art and keeps the texts.
    local forceHide = settings and settings.forceHideIcon == true
    local missAlpha = cs.alpha
    if missAlpha == nil then missAlpha = sv and sv.cooldownAlpha end
    if missAlpha == nil then missAlpha = 0.55 end   -- ghost default
    -- options-panel preview: surface an alpha-0 ghost for editing
    if missAlpha <= 0 and ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen
       and ns.CDMEnhance.IsOptionsPanelOpen() then
        missAlpha = 0.35
    end
    -- Show Icon off: hidden in real play, but while the OPTIONS PANEL is
    -- open (and out of combat) the ghost surfaces at the preview opacity so
    -- the icon stays findable/editable — same look as the Inactive Alpha 0
    -- preview. Combat edges re-run this (SweepForceHideCombat below).
    if forceHide then
        missAlpha = 0
        if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen
           and ns.CDMEnhance.IsOptionsPanelOpen()
           and not InCombatLockdown() then
            missAlpha = 0.35
        end
    end
    -- NORMALIZE the holder FRAME alpha to full: earlier builds wrote the
    -- missing alpha here and it STICKS (nothing else resets it), leaving the
    -- border/chrome dimmed over the live icon. Chrome renders at full
    -- strength in BOTH states; only the ghost TEXTURE dims.
    holder._arcBypassFrameAlphaHook = true
    holder:SetAlpha(1)
    holder._arcBypassFrameAlphaHook = false
    holder._lastAppliedAlpha = 1
    holder.Icon:SetAlpha(missAlpha)
    -- GHOST BORDER: our own edges (same painter as the active border, so the
    -- geometry matches pixel-for-pixel), following the missing-state alpha
    -- (Inactive Alpha 0 = fully hidden, no floating empty frame). CDMEnhance's
    -- holder edges are muted on aura holders — their bottom edge misplaces
    -- on these frames.
    local bcfg = settings and settings.border
    local ghostHost = holder._arcBorderOverlay or holder
    ApplyBorderEdges(ghostHost, holder, "_arcAuraGhostBorder", bcfg, missAlpha)
    if holder._arcBorderEdges then
        for _, edgeTex in pairs(holder._arcBorderEdges) do
            if edgeTex.SetAlpha then edgeTex:SetAlpha(0) end
        end
    end

    -- Re-assert the holder's overlay level ladder from its CURRENT level:
    -- those children got their levels at factory time (base level 10) and
    -- do NOT follow when CDMGroups later raises the holder. GHOST BORDER
    -- overlay goes at h+2, BELOW the button (h+3): the live button OCCLUDES
    -- the ghost chrome while the aura is up — the active border on the
    -- button's TextOverlay is the visible border then — and when the button
    -- hides (aura missing) the ghost chrome surfaces. The old h+6 drew this
    -- chrome over the button's texts at every state ("text behind the
    -- border"). Occlusion IS the state logic: the button's shown state is a
    -- secret we can never read.
    local hl = holder:GetFrameLevel()
    if holder._arcBorderOverlay then holder._arcBorderOverlay:SetFrameLevel(hl + 2) end
    if holder._arcGlowAnchor then holder._arcGlowAnchor:SetFrameLevel(hl + 8) end
    if holder._arcCountContainer then holder._arcCountContainer:SetFrameLevel(hl + 10) end

    local missDesat = cs.desaturate
    if missDesat == nil then missDesat = sv and sv.cooldownDesaturate end
    if missDesat == nil then missDesat = true end   -- ghost default: desaturated
    holder.Icon:SetDesaturated(missDesat and true or false)

    -- CUSTOM LABEL PREVIEW (panel open): the real labels ride the engine
    -- button and only render while the aura is up — while the options panel
    -- is open, mirror them on the holder chrome (always visible, identical
    -- rect) so the user can position them. If the aura happens to be active
    -- the button label overlaps this preview pixel-identically.
    do
        local cl = settings and settings.customLabel
        local panelOpen = ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen
            and ns.CDMEnhance.IsOptionsPanelOpen()
        local prevHost = holder._arcCountContainer or holder
        for li = 1, 3 do
            local fsKey = "_arcCLPrev" .. li
            local fs = holder[fsKey]
            if panelOpen and LabelWanted(cl, li) then
                if not fs then
                    fs = prevHost:CreateFontString(nil, "OVERLAY")
                    holder[fsKey] = fs
                end
                PaintLabel(fs, cl, (li == 1) and "" or tostring(li), holder)
            elseif fs then
                fs:SetText("")
                fs:Hide()
            end
        end
    end

    -- GLOW WHEN MISSING (occlusion mode): the glow renders on a host frame
    -- pinned at holder+1 — a DECISIVE full level above the holder's ghost
    -- regions (equal-level ties are glow-family-dependent: pixel won them,
    -- ants/proc lost and rendered BEHIND the ghost) and below the button at
    -- holder+2, so the live aura icon COVERS the glow while the aura is up.
    -- Zero state reads, works in combat/instances. Styles that overflow the
    -- icon rect peek out around the live icon. A 1px inset keeps
    -- border-hugging styles fully under the icon art. The Frame Strata /
    -- Frame Level options pass through: raising them lifts the glow above
    -- the button (occlusion off — user's explicit choice).
    do
        local aa = settings and settings.auraActiveState or {}
        local host = holder._arcMissGlowHost
        if aa.glowWhenMissing == true and not forceHide and ns.Glows then
            if not host then
                host = CreateFrame("Frame", nil, holder)
                host:SetAllPoints(holder)
                holder._arcMissGlowHost = host
            end
            host:SetFrameLevel(holder:GetFrameLevel() + 1)
            -- default pixel (proven occluder); every style is selectable for
            -- experimentation
            local gtype = aa.glowType or "pixel"
            local gc = aa.glowColor
            local r = gc and gc.r or 1
            local g = gc and gc.g or 0.85
            local b = gc and gc.b or 0.1
            local strata = aa.glowFrameStrata
            if strata == "inherit" or strata == "" then strata = nil end
            local lvlOff = aa.glowFrameLevel or 0
            -- restart only when the recipe actually changed (a Glows restart
            -- resets the animation — avoid the pop on unrelated re-applies)
            local sig = table.concat({ gtype, r, g, b,
                aa.glowIntensity or 1, aa.glowScale or 1, aa.glowSpeed or 0.25,
                aa.glowLines or 8, aa.glowThickness or 2, aa.glowParticles or 4,
                aa.glowLength or 0,
                aa.glowXOffset or 0, aa.glowYOffset or 0,
                strata or "-", lvlOff,
                holder:GetFrameLevel() }, ":")
            if host._arcMissGlowSig ~= sig then
                host._arcMissGlowSig = sig
                ns.Glows.Stop(host, "ArcUI_AuraMissGlow")
                ns.Glows.Start(host, "ArcUI_AuraMissGlow", gtype, {
                    color      = { r, g, b, aa.glowIntensity or 1 },
                    intensity  = aa.glowIntensity or 1,
                    scale      = aa.glowScale or 1,
                    frequency  = aa.glowSpeed or 0.25,
                    lines      = aa.glowLines or 8,
                    thickness  = aa.glowThickness or 2,
                    length     = aa.glowLength,   -- nil/0 = LCG auto
                    particles  = aa.glowParticles or 4,
                    xOffset    = (aa.glowXOffset or 0) - 1,
                    yOffset    = (aa.glowYOffset or 0) - 1,
                    strata     = strata,
                    frameLevel = lvlOff,   -- offset from the host (holder+1)
                })
            end
            holder._arcMissGlowCombatOnly = aa.glowCombatOnly and true or false
            host:SetShown(not holder._arcMissGlowCombatOnly
                or InCombatLockdown()
                or (UnitAffectingCombat and UnitAffectingCombat("player")) or false)
        elseif host then
            ns.Glows.Stop(host, "ArcUI_AuraMissGlow")
            host._arcMissGlowSig = nil
            host:Hide()
        end
    end

    -- ACTIVE-GLOW PREVIEW (options panel): the real Glow When Active lives on
    -- the ENGINE BUTTON and only renders while the aura is up — for tuning,
    -- the Preview toggle renders the same recipe on the holder ghost via
    -- ns.Glows (the button packs are LCG ports, so the preview matches the
    -- live look). Stops with the toggle, the panel, or the glow setting.
    do
        local host = holder._arcActGlowPrevHost
        local previewOn = rs.glow == true and not forceHide
            and ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsGlowPreviewActive
            and ns.CDMEnhanceOptions.IsGlowPreviewActive(arcID)
            and ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen
            and ns.CDMEnhance.IsOptionsPanelOpen()
        if previewOn and ns.Glows then
            if not host then
                host = CreateFrame("Frame", nil, holder)
                host:SetAllPoints(holder)
                holder._arcActGlowPrevHost = host
            end
            host:SetFrameLevel(holder:GetFrameLevel() + 7)
            local gtype = rs.glowType or "pixel"
            local gc = rs.glowColor
            local r = gc and gc.r or 1
            local g = gc and gc.g or 0.85
            local b = gc and gc.b or 0.1
            local strata = rs.glowFrameStrata
            if strata == "inherit" or strata == "" then strata = nil end
            local sig = table.concat({ gtype, r, g, b,
                rs.glowIntensity or 1, rs.glowScale or 1, rs.glowSpeed or 0.25,
                rs.glowLines or 8, rs.glowThickness or 3,
                rs.glowLength or 0,
                rs.glowXOffset or 0, rs.glowYOffset or 0,
                strata or "-", rs.glowFrameLevel or 0,
                holder:GetFrameLevel() }, ":")
            if host._arcActGlowPrevSig ~= sig then
                host._arcActGlowPrevSig = sig
                ns.Glows.Stop(host, "ArcUI_AuraActGlowPreview")
                ns.Glows.Start(host, "ArcUI_AuraActGlowPreview", gtype, {
                    color      = { r, g, b, rs.glowIntensity or 1 },
                    intensity  = rs.glowIntensity or 1,
                    scale      = rs.glowScale or 1,
                    frequency  = rs.glowSpeed or 0.25,
                    lines      = rs.glowLines or 8,
                    thickness  = rs.glowThickness or 3,
                    length     = rs.glowLength,   -- nil/0 = LCG auto
                    xOffset    = rs.glowXOffset or 0,
                    yOffset    = rs.glowYOffset or 0,
                    strata     = strata,
                    frameLevel = rs.glowFrameLevel or 0,
                })
            end
            host:Show()
        elseif host then
            ns.Glows.Stop(host, "ArcUI_AuraActGlowPreview")
            host._arcActGlowPrevSig = nil
            host:Hide()
        end
    end

    -- ── AURA ACTIVE -> engine buttons ───────────────────────────────────
    -- Buttons are FORBIDDEN whenever auras are secret — a WIDER state than
    -- combat (lab finding: aura-data secrecy and button-forbidden are
    -- different signals; the only accurate gate is asking the button
    -- itself). PTR6+ ships the sanctioned probe: CanBeAccessedInContext.
    for _, sub in ipairs(entry.subs) do
        local btn = sub.frame
        if btn then
            local forbidden
            if btn == legalBtn then
                forbidden = false   -- init-window call: writes are legal
            elseif btn.CanBeAccessedInContext then
                forbidden = not btn:CanBeAccessedInContext()
            else
                forbidden = btn.IsForbidden and btn:IsForbidden() or false
            end
            if forbidden then
                pendingApply[arcID] = true
            else
                -- re-assert the holder anchor: a button revived or recreated
                -- during combat can miss its init-time anchor — idempotent
                -- two-point anchor, follows every holder resize
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
                btn:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
                -- re-sync draw order (holder levels move with group ops):
                -- ghost h, miss-glow host h+1, ghost border overlay h+2
                -- (occluded by the button while the aura is up), button h+3,
                -- swipe h+4 (ABOVE the button — equal level buries it under
                -- the icon region), text overlay h+5, then glow anchor h+8 /
                -- count container h+10 — mirror of the creation ladder
                local lvl = holder:GetFrameLevel() + 3
                btn:SetFrameStrata(holder:GetFrameStrata())
                btn:SetFrameLevel(lvl)
                if btn._arcSwipe then btn._arcSwipe:SetFrameLevel(lvl + 1) end
                if btn.TextOverlay then btn.TextOverlay:SetFrameLevel(lvl + 2) end

                -- every button visual (swipe/duration/border/stacks/labels/glows)
                -- now lives in StyleActiveButton — ONE path shared with the
                -- Aura Group engine buttons, so the presentations cannot drift
                StyleActiveButton(btn, settings, holder)

                -- STACK FORMATTER re-bind: belt-and-suspenders against the
                -- engine copying the formatter object at bind time (the live
                -- registry's breakpoint refresh covers the reference case).
                -- Version-gated so it costs nothing when nothing changed.
                if btn._arcStacks and btn._arcFmtBoundV ~= liveFormatterVersion then
                    btn._arcFmtBoundV = liveFormatterVersion
                    btn:SetApplicationCount(btn._arcStacks, { formatter = GetLiveFormatter(arcID) })
                end
            end
        end
    end
end

-- combat-only missing glows: toggle the occlusion hosts at the combat edges
local function SweepMissGlowCombat(inCombat)
    for _, entry in pairs(entries) do
        local h = entry.holder
        local host = h and h._arcMissGlowHost
        if host and h._arcMissGlowCombatOnly then
            host:SetShown(inCombat)
        end
    end
end

-- Show Icon off + options panel open: the editing preview must never show in
-- combat — drop the ghost at combat start, restore the preview at combat end.
-- Holder-side writes only (always legal); button work inside ApplySettings
-- self-gates on accessibility.
local function SweepForceHideCombat(inCombat)
    if not (ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen
        and ns.CDMEnhance.IsOptionsPanelOpen()) then return end
    for arcID, entry in pairs(entries) do
        local holder = entry.holder
        if holder and holder.Icon then
            local s = ArcAuras.GetCachedSettings and ArcAuras.GetCachedSettings(arcID)
            if s and s.forceHideIcon == true then
                if inCombat then
                    holder.Icon:SetAlpha(0)
                else
                    AuraIcons.ApplySettings(arcID)
                end
            end
        end
    end
end

-- deferred button writes: retry at combat end (snapshot first — a still-
-- forbidden button re-queues itself during the retry)
local applyRegen = CreateFrame("Frame")
applyRegen:RegisterEvent("PLAYER_REGEN_ENABLED")
applyRegen:RegisterEvent("PLAYER_REGEN_DISABLED")
applyRegen:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        SweepMissGlowCombat(true)
        SweepForceHideCombat(true)
        return
    end
    SweepMissGlowCombat(false)
    SweepForceHideCombat(false)
    local q = {}
    for arcID in pairs(pendingApply) do q[#q + 1] = arcID end
    wipe(pendingApply)
    for _, arcID in ipairs(q) do
        AuraIcons.ApplySettings(arcID)
    end
end)

-- Tear the holder down but KEEP the slots parked and positions saved — the
-- spec/talent-hidden state and the re-show path both reuse this.
local function TeardownIcon(arcID, preservePosition)
    local entry = entries[arcID]
    if not entry then return end
    SetSlotsParked(entry, true)
    local savedPos = preservePosition and ns.CDMGroups and ns.CDMGroups.savedPositions
        and ns.CDMGroups.savedPositions[arcID]
    ArcAuras.DestroyFrame(arcID)
    if savedPos and ns.CDMGroups and ns.CDMGroups.savedPositions then
        ns.CDMGroups.savedPositions[arcID] = savedPos
    end
    -- Keep the sub records: slots persist for this session and get re-linked
    -- (re-anchored to the new holder) on rebuild.
    entry.holder = nil
    entries[arcID] = entry
end

-- Rebuild the holder for an entry whose slots already exist (post spec-hide).
local function ReviveIcon(arcID)
    local entry = entries[arcID]
    if not entry or entry.holder then return end
    local def = entry.def
    local holder = ArcAuras.CreateFrame(arcID, {
        type = "aura",
        spellID = def.spellID,
        name = def.name,
        icon = def.iconOverride or def.icon,
        enabled = true,
    })
    if not holder then return end
    holder._arcIsAuraIcon = true
    holder.Cooldown:Clear()
    entry.holder = holder
    for _, sub in ipairs(entry.subs) do
        local b = sub.frame
        if b then
            -- forbidden-safe: buttons are inaccessible while auras are
            -- secret — a revive during combat queues the anchor to regen
            -- (ApplySettings re-asserts it in its accessible branch)
            local ok
            if b.CanBeAccessedInContext then
                ok = b:CanBeAccessedInContext()
            else
                ok = not (b.IsForbidden and b:IsForbidden())
            end
            if ok then
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
                b:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
            else
                pendingApply[arcID] = true
            end
        end
    end
    SetSlotsParked(entry, false)
    AuraIcons.ApplySettings(arcID)
end

-- Full build for a def with no live entry: slots first (deferred while auras
-- are secret — see EnsureSlots), then the holder via the same revive path
-- the pre-built entries use.
local function BuildIcon(arcID, def)
    local entry = entries[arcID]
    if entry and entry.holder then return entry end
    if not IS_121 then return nil end
    if not EnsureSlots(arcID, def, true) then
        -- secret context: def is saved; retried at regen / zone change
        pendingRefresh = true
        return nil
    end
    ReviveIcon(arcID)
    return entries[arcID]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

-- Create and track a new aura icon. def fields: spellID (required),
-- unitMode = "buff"|"debuff"|"both" (default "buff"), ownOnly (debuffs).
function AuraIcons.Create(defIn)
    if not IS_121 then return nil end
    local spellID = tonumber(defIn and defIn.spellID)
    if not spellID or spellID <= 0 then return nil end
    local db = GetDB()
    if not db then return nil end

    local arcID = AuraIcons.MakeID(spellID)
    if db.auraIcons[arcID] then return arcID end   -- already tracked

    local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    local def = {
        spellID  = spellID,
        spellIDs = defIn.spellIDs,   -- optional full candidate map (CDM imports)
        -- name override: multi-ID presets (e.g. every Bloodlust variant on one
        -- icon) read better as "Bloodlust / Heroism" than as the primary ID's name
        name     = defIn.name or (info and info.name) or ("Aura " .. spellID),
        icon     = (info and (info.iconID or info.originalIconID)) or 134400,
        unitMode = defIn.unitMode or "buff",
        ownOnly  = defIn.ownOnly and true or false,
    }
    db.auraIcons[arcID] = def

    -- NEW-ICON DEFAULT (Arc's call): the aura-missing ghost starts
    -- DESATURATED — seed the per-icon setting explicitly so the panel shows
    -- it checked and the look is deterministic (the runtime fallback already
    -- desaturated when unset, but the panel read as off).
    if ns.CDMEnhance and ns.CDMEnhance.GetOrCreateIconSettings then
        local s = ns.CDMEnhance.GetOrCreateIconSettings(arcID)
        if s then
            s.cooldownStateVisuals = s.cooldownStateVisuals or {}
            s.cooldownStateVisuals.cooldownState = s.cooldownStateVisuals.cooldownState or {}
            if s.cooldownStateVisuals.cooldownState.desaturate == nil then
                s.cooldownStateVisuals.cooldownState.desaturate = true
            end
            if ns.CDMEnhance.InvalidateCache then ns.CDMEnhance.InvalidateCache() end
        end
    end

    if AuraIcons.ShouldBeVisible(def) then
        BuildIcon(arcID, def)
    end
    return arcID
end

function AuraIcons.Get(arcID)
    local db = GetDB()
    return db and db.auraIcons[arcID] or nil
end

function AuraIcons.All()
    local db = GetDB()
    return db and db.auraIcons or {}
end

-- Full removal: park slots, destroy holder, purge def + settings + positions.
function AuraIcons.Delete(arcID)
    local db = GetDB()
    if not db or not db.auraIcons[arcID] then return end
    local name = db.auraIcons[arcID].name or arcID
    if entries[arcID] then
        SetSlotsParked(entries[arcID], true)
        -- per-icon containers: retire this icon's containers outright.
        -- Hiding is enough (buttons are container children); a re-create
        -- builds FRESH containers — never re-slot a warm one (its pool may
        -- hold released frames the provider can't reparent from our stack).
        for _, sub in ipairs(entries[arcID].subs) do
            if sub.container then sub.container:Hide() end
        end
        if entries[arcID].holder then
            ArcAuras.DestroyFrame(arcID)
        end
        entries[arcID] = nil
    end
    db.auraIcons[arcID] = nil
    if ns.CDMGroups then
        if ns.CDMGroups.savedPositions then ns.CDMGroups.savedPositions[arcID] = nil end
        if ns.CDMGroups.ClearPositionFromSpec then ns.CDMGroups.ClearPositionFromSpec(arcID) end
    end
    if ns.db and ns.db.profile and ns.db.profile.cdmEnhance then
        local iconSettings = ns.db.profile.cdmEnhance.iconSettings
        if iconSettings and iconSettings[arcID] then iconSettings[arcID] = nil end
    end
    print("|cff00CCFF[Arc Auras]|r Removed aura icon: " .. name)
end

-- Icon override: same contract as the cooldown-icon version (spell OR item
-- source ID; 0/nil resets).
function AuraIcons.ApplyIconOverride(arcID, overrideID)
    local db = GetDB()
    local def = db and db.auraIcons[arcID]
    if not def then return end

    if not overrideID or overrideID <= 0 then
        def.iconOverride, def.iconOverrideID = nil, nil
        local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(def.spellID)
        def.icon = (info and (info.iconID or info.originalIconID)) or def.icon
        local entry = entries[arcID]
        if entry and entry.holder and entry.holder.Icon then
            entry.holder.Icon:SetTexture(def.icon or 134400)
        end
        print("|cff00CCFF[Arc Auras]|r Icon reset to default for " .. (def.name or arcID))
        return
    end

    local newIcon, sourceName
    local spellInfo = C_Spell.GetSpellInfo(overrideID)
    if spellInfo and (spellInfo.iconID or spellInfo.originalIconID) then
        newIcon = spellInfo.iconID or spellInfo.originalIconID
        sourceName = spellInfo.name
    end
    if not newIcon and C_Item and C_Item.GetItemIconByID then
        local itemIcon = C_Item.GetItemIconByID(overrideID)
        if itemIcon then
            newIcon = itemIcon
            sourceName = (C_Item.GetItemNameByID and C_Item.GetItemNameByID(overrideID)) or ("Item " .. overrideID)
        end
    end
    if not newIcon then
        print("|cff00CCFF[Arc Auras]|r Could not find icon for ID " .. overrideID)
        return
    end

    def.iconOverride = newIcon
    def.iconOverrideID = overrideID
    local entry = entries[arcID]
    if entry and entry.holder and entry.holder.Icon then
        entry.holder.Icon:SetTexture(newIcon)
    end
    print(string.format("|cff00CCFF[Arc Auras]|r Icon changed to %s (%d) for %s",
        sourceName or "?", overrideID, def.name or arcID))
end

-- Re-evaluate spec/talent visibility for every tracked aura icon. The direct
-- analogue of ArcAurasCooldown.RefreshSpecVisibility.
function AuraIcons.RefreshVisibility()
    if not IS_121 then return end
    -- Mid-combat is a FIRST-CLASS path (DC -> log back in during the pull).
    -- The old blanket bail-out here meant NO aura icons at all until combat
    -- ended. Building in combat is legal since PTR7: container creation was
    -- fixed, AddAuraSlot wires inside its own init window, and every
    -- post-init button write self-gates on CanBeAccessedInContext / queues
    -- to regen. Keep a settle pass at combat end for anything deferred.
    if InCombatLockdown() then
        pendingRefresh = true
    end
    local db = GetDB()
    if not db then return end
    local masterOn = ArcAuras.IsEnabled and ArcAuras.IsEnabled()
    for arcID, def in pairs(db.auraIcons) do
        local visible = masterOn and AuraIcons.ShouldBeVisible(def)
        -- THE FLIP: while an Aura Group's engine rows render this member
        -- (panel closed, drag off), the standalone presentation tears down —
        -- TeardownIcon preserves savedPositions, so the member re-lands in
        -- its grid slot when the panel reopens (spec-hide machinery reused)
        if visible and ns.AuraIconGroups and ns.AuraIconGroups.IsEngineOwned
           and ns.AuraIconGroups.IsEngineOwned(arcID) then
            visible = false
        end
        local entry = entries[arcID]
        if visible then
            if not entry then
                BuildIcon(arcID, def)
            elseif not entry.holder then
                ReviveIcon(arcID)
            elseif entry.parked then
                SetSlotsParked(entry, false)
            end
        else
            if entry and entry.holder then
                TeardownIcon(arcID, true)
            elseif entry and not entry.parked then
                SetSlotsParked(entry, true)
            end
        end
    end
end

-- Login/profile-load sweep.
function AuraIcons.RefreshAll()
    AuraIcons.RefreshVisibility()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REWIRE: recreate every icon's slots so CREATE-TIME bindings pick up changed
-- settings NOW. The engine pre-creates each slot's button once and reuses it
-- forever (maxFrameCount contract) — so the stack formatter, baked in
-- initializeFrame, would otherwise only refresh on a reload. Old slots can't
-- be unregistered: park them on a never-matching filter (the BD pattern) and
-- add fresh generation-suffixed slots. Desk-time only — slot creation is
-- blocked under aura secrecy; callers are options setters, so that is always
-- satisfied outside combat/instances.
-- ═══════════════════════════════════════════════════════════════════════════
local rewirePending = false
local rewireFlush = CreateFrame("Frame")
rewireFlush:RegisterEvent("PLAYER_REGEN_ENABLED")
rewireFlush:RegisterEvent("PLAYER_ENTERING_WORLD")
rewireFlush:SetScript("OnEvent", function()
    if rewirePending and not AurasSecretNow() then
        rewirePending = false
        AuraIcons.RewireAll()
    end
end)

function AuraIcons.RewireAll()
    if not IS_121 then return end
    if AurasSecretNow() then
        -- Slot creation is illegal under aura secrecy (combat/instances). A
        -- silent skip left toggles flipped MID-COMBAT dead until a reload (the
        -- Maelstrom show-at-1 report) — queue instead and flush on regen/zone.
        rewirePending = true
        return
    end
    local touched = {}
    for arcID, entry in pairs(entries) do
        if entry.subs and #entry.subs > 0 then
            for _, sub in ipairs(entry.subs) do
                if sub.container and sub.key and sub.container.SetAuraSlotCandidateFilters then
                    sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = { [0] = true } })
                    touched[sub.container] = true
                end
            end
            wipe(entry.subs)
            entry.gen = (entry.gen or 0) + 1
            EnsureSlots(arcID, entry.def, entry.parked)
            for _, sub in ipairs(entry.subs) do
                if sub.container then touched[sub.container] = true end
            end
        end
    end
    for c in pairs(touched) do
        if c.UpdateAllAuras then c:UpdateAllAuras() end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AUTHORITATIVE STACK SETTLE: re-derive the live formatters from CURRENT
-- settings and re-bind accessible buttons. Called debounced from
-- ns.CDMEnhance.RequestStackSettle — the InvalidateCache chokepoint every
-- settings-restore path funnels through (options setters, profile loads,
-- spec changes, imports, shared-profile sync) — and directly at login/zone.
--
-- STACK TEXT ONLY — deliberately NOT the full ApplySettings: this runs at
-- PLAYER_ENTERING_WORLD, when ArcAuras.GetCachedSettings can transiently
-- serve nil (loading-screen read cached for the TTL window), and a full
-- re-style painted DEFAULT visuals over per-icon customizations (zone-switch
-- ghost-desaturate regression). Buttons still forbidden here (in-instance)
-- pick the binding up at the next accessible settle; the live formatter's
-- breakpoint refresh already covers rule changes on the existing binding.
-- ═══════════════════════════════════════════════════════════════════════════
function AuraIcons.StackSettle()
    if not IS_121 then return end
    AuraIcons.RefreshLiveFormatters()
    for arcID, entry in pairs(entries) do
        for _, sub in ipairs(entry.subs or {}) do
            local btn = sub.frame
            if btn and btn._arcStacks and btn._arcFmtBoundV ~= liveFormatterVersion then
                local ok
                if btn.CanBeAccessedInContext then
                    ok = btn:CanBeAccessedInContext()
                else
                    ok = not (btn.IsForbidden and btn:IsForbidden())
                end
                if ok then
                    btn._arcFmtBoundV = liveFormatterVersion
                    btn:SetApplicationCount(btn._arcStacks, { formatter = GetLiveFormatter(arcID) })
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CDM IMPORT (the lab's "Import CDM buffs" button): one Arc aura icon per
-- Tracked Buff enabled in the Cooldown Manager. Uses the C_CooldownViewer
-- DATA PROVIDER only (no viewer object methods = no taint surface).
-- ═══════════════════════════════════════════════════════════════════════════

-- The user's DISPLAYED tracked buffs only (the lab's displayed-filter):
-- Blizzard's settings data provider caches every cooldown's EFFECTIVE
-- category after the user's show/hide overrides -- entries the user hid are
-- re-categorized (HiddenPassive), so filtering on category IS the "showing
-- in CDM" check. Plain field reads, zero method calls, zero taint.
local function GetDisplayedTrackedBuffIDs()
    local cat = Enum.CooldownViewerCategory
    if not (cat and cat.TrackedBuff) then return nil end
    local dp = CooldownViewerSettings and CooldownViewerSettings.dataProvider
    local dd = dp and dp.displayData
    local byID = dd and dd.cooldownInfoByID
    if type(byID) ~= "table" then return nil end
    local wanted = { [cat.TrackedBuff] = true }
    if cat.TrackedBar then wanted[cat.TrackedBar] = true end
    local set, count = {}, 0
    for cooldownID, info in pairs(byID) do
        if info and wanted[info.category]
           and type(cooldownID) == "number"
           and not (issecretvalue and issecretvalue(cooldownID)) then
            set[cooldownID] = true
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return set
end

function AuraIcons.ImportFromCDM()
    if not IS_121 then return 0 end
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
            and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        print("|cff00CCFF[Arc Auras]|r CDM data provider unavailable on this client")
        return 0
    end
    local cat = Enum.CooldownViewerCategory
    if not (cat and cat.TrackedBuff) then return 0 end

    local displayedSet = GetDisplayedTrackedBuffIDs()
    if not displayedSet then
        print("|cff00CCFF[Arc Auras]|r Could not read the CDM display list -- importing the full set")
    end

    local db = GetDB()
    if not db then return 0 end

    -- dedupe against every spellID any existing aura icon already covers
    local seen = {}
    for _, def in pairs(db.auraIcons) do
        seen[def.spellID] = true
        for id in pairs(def.spellIDs or {}) do seen[id] = true end
    end

    local added, skipped = 0, 0
    local categories = { cat.TrackedBuff }
    if cat.TrackedBar then table.insert(categories, cat.TrackedBar) end
    for _, catID in ipairs(categories) do
        local ids = C_CooldownViewer.GetCooldownViewerCategorySet(catID)
        for _, cooldownID in ipairs(ids or {}) do
            local skipThis = false
            if issecretvalue and issecretvalue(cooldownID) then skipThis = true end
            if not skipThis and displayedSet and not displayedSet[cooldownID] then
                skipped = skipped + 1
                skipThis = true
            end
            if not skipThis then
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
                local spellID = info and info.spellID
                if not spellID or (issecretvalue and issecretvalue(spellID))
                   or info.isKnown == false then
                    skipped = skipped + 1
                else
                    -- include map: base + overrides + full linked set (the
                    -- BUFF often lives on a linked/override id, not the cast)
                    local includeMap = { [spellID] = true }
                    for _, extraID in ipairs({ info.overrideSpellID, info.overrideTooltipSpellID }) do
                        if type(extraID) == "number" then includeMap[extraID] = true end
                    end
                    if type(info.linkedSpellIDs) == "table" then
                        for _, linked in ipairs(info.linkedSpellIDs) do
                            if type(linked) == "number" then includeMap[linked] = true end
                        end
                    end
                    -- DISPLAY identity per Blizzard's precedence:
                    -- overrideTooltipSpellID > overrideSpellID > base
                    local primary = (type(info.overrideTooltipSpellID) == "number" and info.overrideTooltipSpellID)
                        or (type(info.overrideSpellID) == "number" and info.overrideSpellID)
                        or spellID

                    local dupe = false
                    for id in pairs(includeMap) do
                        if seen[id] then dupe = true break end
                    end
                    if dupe or db.auraIcons[AuraIcons.MakeID(primary)] then
                        skipped = skipped + 1
                    else
                        -- BOTH units, like Blizzard's own CDM (buff-on-me OR
                        -- my-debuff-on-target lights the same icon)
                        if AuraIcons.Create({ spellID = primary, spellIDs = includeMap, unitMode = "both" }) then
                            added = added + 1
                            for id in pairs(includeMap) do seen[id] = true end
                        else
                            skipped = skipped + 1
                        end
                    end
                end
            end
        end
    end
    print(string.format("|cff00CCFF[Arc Auras]|r CDM import: %d aura icon(s) created, %d skipped (hidden/dupe/unknown)", added, skipped))
    return added
end

function AuraIcons.GetEntry(arcID) return entries[arcID] end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENTS
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- DEBUG SLASH (/arcaura): state dump + direct add for diagnosis
-- ═══════════════════════════════════════════════════════════════════════════

SLASH_ARCAURAICONS1 = "/arcaura"
SlashCmdList.ARCAURAICONS = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    if cmd == "add" then
        local id, mode = rest:match("^(%d+)%s*(%S*)")
        local arcID = AuraIcons.Create({ spellID = tonumber(id), unitMode = (mode ~= "" and mode) or "buff" })
        print("|cff00CCFF[ArcAura]|r add -> " .. tostring(arcID))
        return
    elseif cmd == "import" then
        AuraIcons.ImportFromCDM()
        return
    elseif cmd == "cat" then
        -- classification truth: which catalog map does each aura icon land in?
        local auras = ns.CDMEnhance and ns.CDMEnhance.GetAuraIcons and ns.CDMEnhance.GetAuraIcons() or {}
        local cds = ns.CDMEnhance and ns.CDMEnhance.GetCooldownIcons and ns.CDMEnhance.GetCooldownIcons() or {}
        local db2 = GetDB()
        for arcID in pairs(db2 and db2.auraIcons or {}) do
            local side = auras[arcID] and "AURAS" or cds[arcID] and "COOLDOWNS (WRONG)" or "NEITHER (missing)"
            local fi = ns.CDMGroups and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID]
            print(string.format("  %s -> %s  freeIcon=%s frameSet=%s vt=%s", arcID, side,
                tostring(fi ~= nil), tostring(fi and fi.frame ~= nil),
                tostring(fi and fi.viewerType)))
        end
        return
    end
    local nP, nT = 0, 0
    for _, rec in ipairs(allContainers) do
        if rec.unit == "player" then nP = nP + 1 else nT = nT + 1 end
    end
    print(string.format("|cff00CCFF[ArcAura]|r 12.1=%s  ArcAurasEnabled=%s  containers: player=%d target=%d",
        tostring(IS_121),
        tostring(ArcAuras.IsEnabled and ArcAuras.IsEnabled()), nP, nT))
    local db = GetDB()
    local n = 0
    if db then
        for arcID, def in pairs(db.auraIcons) do
            n = n + 1
            local e = entries[arcID]
            local subInfo = ""
            if e then
                for _, sub in ipairs(e.subs) do
                    subInfo = subInfo .. " " .. sub.unit .. "/" .. FilterFor(def, sub.unit)
                        .. (sub.frame and "=btn" or "=NOBTN")
                end
            end
            -- ACCEPTED SPELL IDS. The engine only ever shows an aura whose spellId
            -- is a key in here (Blizzard's DoesAuraPassCandidateFilters), so a
            -- "wrong aura is showing" report is answered by this line alone: either
            -- the stray id is listed (bad def.spellIDs, usually from a CDM import
            -- pulling a wide linked set) or it is not, and the cause is elsewhere.
            local ids, nIDs = {}, 0
            for id in pairs(IncludeMap(def)) do
                nIDs = nIDs + 1
                if nIDs <= 8 then
                    local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
                    ids[#ids + 1] = tostring(id) .. (nm and ("=" .. nm) or "")
                end
            end
            print(string.format("  %s mode=%s visible=%s holder=%s parked=%s%s",
                arcID, def.unitMode or "?", tostring(AuraIcons.ShouldBeVisible(def)),
                tostring(e and e.holder ~= nil), tostring(e and e.parked or false), subInfo))
            print(string.format("      accepts %d id(s): %s%s", nIDs,
                table.concat(ids, ", "), (nIDs > 8) and " ..." or ""))
        end
    end
    print("  defs=" .. n .. "   (/arcaura add <spellID> [buff|debuff|both]  |  /arcaura import)")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STACK-TEXT DIAGNOSTIC (/arcstacks): settings-as-read, formatter registry
-- state, button bind versions, CDM count-overlay state. "/arcstacks watch"
-- toggles caller attribution on the native count's SetAlpha (catches any
-- writer fighting the overlay's hide).
-- ═══════════════════════════════════════════════════════════════════════════

local function ChtSummary(key)
    local cfg = ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(key)
    local cht = cfg and cfg.chargeText
    if not cht then cht = RawChargeTextFallback(key) end
    if not cht then return "cht=nil" end
    local bandStr = ""
    if type(cht.thresholdBands) == "table" then
        for i = 1, 6 do
            local b = cht.thresholdBands[i]
            if b and b.enabled and b.threshold then
                bandStr = bandStr .. " b" .. i .. "@" .. tostring(b.threshold)
            end
        end
    end
    return string.format("en=%s show1=%s bands=%s%s",
        tostring(cht.enabled ~= false), tostring(cht.showSingleStack == true),
        tostring(cht.thresholdColorEnabled == true), bandStr)
end

SLASH_ARCSTACKS1 = "/arcstacks"
SlashCmdList.ARCSTACKS = function(msg)
    local cmd = (msg or ""):match("^%s*(%S*)")
    if cmd == "watch" then
        if ns.StackColor and ns.StackColor.ToggleAlphaWatch then
            ns.StackColor.ToggleAlphaWatch()
        else
            print("|cff00CCFF[ArcStacks]|r overlay module has no watch on this client")
        end
        return
    end
    if cmd == "settle" then
        AuraIcons.StackSettle()
        if ns.StackColor and ns.StackColor.RefreshOverlays then ns.StackColor.RefreshOverlays() end
        print("|cff00CCFF[ArcStacks]|r manual settle requested")
        return
    end
    print(string.format("|cff00CCFF[ArcStacks]|r 12.1=%s  db=%s  spec=%s  fmtV=%d  aurasSecret=%s",
        tostring(IS_121), tostring(ns.db ~= nil),
        tostring(ns.CDMShared and ns.CDMShared.GetCurrentSpecKey and ns.CDMShared.GetCurrentSpecKey()),
        liveFormatterVersion, tostring(AurasSecretNow())))
    print("|cffFFD100-- aura icons --|r")
    local shown = 0
    for arcID, entry in pairs(entries) do
        shown = shown + 1
        local f = liveFormatters[arcID]
        local nbp = 0
        if f and f.GetBreakpoints then
            local bps = f:GetBreakpoints()
            nbp = type(bps) == "table" and #bps or 0
        end
        local subInfo = ""
        for _, sub in ipairs(entry.subs or {}) do
            local b = sub.frame
            local acc = "-"
            if b then
                if b.CanBeAccessedInContext then
                    acc = tostring(b:CanBeAccessedInContext())
                else
                    acc = tostring(not (b.IsForbidden and b:IsForbidden()))
                end
            end
            subInfo = subInfo .. string.format(" %s[btn=%s acc=%s boundV=%s]",
                sub.unit, tostring(b ~= nil), acc, tostring(b and b._arcFmtBoundV))
        end
        print(string.format("  %s  fmt=%s bp=%d  %s  |%s",
            arcID, tostring(f ~= nil), nbp, ChtSummary(arcID), subInfo))
    end
    if shown == 0 then print("  (no aura icon entries)") end
    if ns.StackColor and ns.StackColor.DebugDump then
        ns.StackColor.DebugDump(ChtSummary)
    end
    print("  (/arcstacks watch = alpha attribution  |  /arcstacks settle = force refresh)")
end

if IS_121 then
    -- follow the master toggle from ANY caller (options, slash, api)
    hooksecurefunc(ArcAuras, "Enable", function()
        C_Timer.After(0.5, AuraIcons.RefreshVisibility)
    end)
    hooksecurefunc(ArcAuras, "Disable", function()
        AuraIcons.RefreshVisibility()
    end)

    local evFrame = CreateFrame("Frame")
    evFrame:RegisterEvent("ADDON_LOADED")
    evFrame:RegisterEvent("PLAYER_LOGIN")
    evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    evFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    evFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    evFrame:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" then
            if arg1 == ADDON then
                evFrame:UnregisterEvent("ADDON_LOADED")
                -- pre-create every def's slots INSIDE the load window: legal
                -- even when reloading/logging in mid-combat or mid-instance
                PreBuildAllSlots()
            end
            return
        end
        if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
            if event == "PLAYER_LOGIN" then
                -- window closes here: mark first so the retry below defers
                -- instead of erroring if the ADDON_LOADED pass was skipped
                -- (early "Unknown" character key) and auras are secret
                loadWindowOver = true
                PreBuildAllSlots()
            end
            -- The AceDB exists from here (ArcUI_Options' PLAYER_LOGIN handler
            -- runs first — event registration follows toc load order): settle
            -- the live formatters the ADDON_LOADED prebuild derived from the
            -- raw fallback, and re-bind accessible buttons.
            AuraIcons.StackSettle()
            -- STAGGERED passes (totem-module pattern): a single early pass
            -- raced ArcAuras.Enable — the master-enable gate was still false
            -- at +1s, every def skipped, and NO icons built for the session.
            C_Timer.After(1.5, AuraIcons.RefreshVisibility)
            C_Timer.After(4.5, AuraIcons.RefreshVisibility)
        else
            -- spec/talent change: debounced re-evaluation; formatters must
            -- re-derive too — per-icon settings are per-spec
            C_Timer.After(1.0, AuraIcons.RefreshVisibility)
            C_Timer.After(3.0, AuraIcons.RefreshVisibility)
            C_Timer.After(1.2, AuraIcons.StackSettle)
        end
    end)
end
