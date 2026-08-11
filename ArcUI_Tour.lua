-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_Tour: guided "what's new" walkthrough of the options panel.
--
-- The changelog says WHAT changed; this shows WHERE. A tour is pure data (see
-- TOURS below): a list of steps, each naming an options tab and a control label
-- to point at, plus the text to show beside it.
--
-- HOW A STEP FINDS ITS CONTROL: AceConfig builds its widgets on the fly, so
-- there is no stable handle for "the Ping Key keybinding". We open the panel,
-- SelectGroup to the step's tab, then walk the dialog's frame tree for a
-- FontString whose text matches the step's `find` label and anchor to its owner.
--
-- That is inherently fragile -- renaming an option silently orphans its step --
-- so it FAILS SOFT by design: an unfound label still shows its callout, centred
-- on the panel, with the text intact. A tour that is slightly less precise beats
-- one that errors or dead-ends.
--
-- DEV-ONLY CODE sits inside packager debug fences. The BigWigs packager strips
-- them from a release build, so /arctour dev, dump and clear do not exist in the
-- shipped addon at all: not hidden, absent.
--
-- Two rules when touching them. Anything inside a fence must leave valid Lua
-- when it is deleted. And NEVER write the fence tokens in prose, not even in a
-- comment like this one: the packager matches them anywhere, so an explanatory
-- mention opens a fence of its own and takes out everything down to the next
-- close. That exact mistake cost a 399-line strip here.
--
-- Zero IDLE cpu. The one OnUpdate here drives the ~0.35s spotlight glide and
-- clears its own script on the final frame, so nothing runs between steps or
-- while the tour is closed. The ring's breathing is an AnimationGroup. No pcall.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

ns.Tour = ns.Tour or {}
local T = ns.Tour

local ARC   = { 0.247, 0.788, 0.949 }
local PANEL = { 0.043, 0.059, 0.102 }
local LINE  = { 0.114, 0.165, 0.247 }
local INK   = { 0.950, 0.970, 1.000 }
local DIM   = { 0.620, 0.700, 0.800 }
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- ═══════════════════════════════════════════════════════════════════════════
-- TOUR DATA. One entry per version that introduces something worth showing.
-- Keyed by BASE version (matching the changelog's own gate, so hotfix suffixes
-- like .a do not re-trigger a tour the player already took).
--
--   tab   = { "tabKey", "subTabKey" }  -- passed to AceConfigDialog:SelectGroup
--   find  = "Exact Control Label"      -- nil = just describe the tab
--   frame = "GlobalFrameName" | fn()   -- focus a real UI frame instead of a
--                                      -- control, e.g. the Ping Feed window.
--                                      -- fn may return SEVERAL frames; the
--                                      -- highlight covers all of them
--   grow  = true | <levels>            -- with `find`: light the SECTION that
--                                      -- control sits in. A number climbs that
--                                      -- many parents only (1 = its own row)
--   openDropdown = true                -- with `find`: click the control open so
--                                      -- its choices are on screen
--   unionPanel = true                  -- widen the highlight to take in the
--                                      -- whole panel as well as the control
--   place = { x = , y = }              -- hand-placed callout, as an offset from
--                                      -- the panel's bottom-left. Capture one
--                                      -- by dragging in /arctour dev
--   pre   = function() end             -- run before the step draws: use it to
--                                      -- put the panel in the state the step
--                                      -- describes (select a spell, etc)
--   title / text                       -- the callout
--   check = function() return bool end -- optional: skip when it returns false
-- ═══════════════════════════════════════════════════════════════════════════
local TOURS = {
    -- SIX STEPS, HARD CAP. A tour people skip teaches nothing, so this shows the
    -- shape of the feature and gets out of the way.
    --
    -- House style: plain punctuation. No em dashes.
    --
    -- `place` values were set by hand in /arctour dev and are offsets from the
    -- panel's bottom-left. Steps without one use the automatic search.
    ["3.7.10"] = {
        -- WHOLE-TOUR GATE. This release ships ahead of the patch its headline
        -- features need, so on a pre-12.1 client these tabs are inert and the
        -- tour must not exist at all -- not merely fail to find its controls.
        -- Being unavailable also stops the once-per-patch OFFER from firing,
        -- which would otherwise be answered on live and never seen again once
        -- the player actually patches.
        check = function()
            return (ns.Pings and ns.Pings.IsAvailable and ns.Pings.IsAvailable()) and true or false
        end,
        {
            -- the TAB plus everything under it: the tab alone says where to
            -- click, the panel says what you get
            tab   = { "pings", "pingkeys" },
            find  = "Pings",
            unionPanel = true,
            place = { x = 576, y = 509 },
            title = "Ping Keys",
            text  = "Call your cooldowns out to the group without writing a single macro.\n\nEverything for it lives under this tab.",
        },
        {
            tab   = { "pings", "pingkeys" },
            find  = "Enable Ping Keys",
            grow  = 1,   -- its own row only, not the whole tab body
            place = { x = 490, y = 488 },
            title = "One key does it",
            text  = "Turn it on and bind a spare key. An extra mouse button works well.\n\nHold that key and press any spell's normal action bar key: the spell gets called out to your group instead of cast.\n\nIt works on everything you have bound, with nothing else to set up.",
        },
        {
            -- open the editor AND the mode list: the three choices are the whole
            -- point of the step, and they read better on screen than in prose
            tab   = { "pings", "pingkeys" },
            pre   = function()
                return ns.Pings and ns.Pings.TourSelectSpell and ns.Pings.TourSelectSpell()
            end,
            find  = "Pings When",
            openDropdown = true,
            place = { x = 246, y = 178 },
            title = "Or give one spell its own rules",
            text  = "Pick any spell and it can behave differently from the rest.\n\nPing every time you press it, answer a different key from everything else, or get a key of its own that only pings and never casts.",
        },
        {
            tab   = { "pings", "window" },
            -- the title floats ABOVE the window as a separate frame, so the
            -- window's own rect stops short of it and cut the label off
            frame = function()
                local w = _G.ArcUIPingHistory
                if not w then return nil end
                local t = w.titleHolder
                if t and t:IsShown() then return w, t end
                return w
            end,
            title = "The Ping Feed",
            text  = "Everyone's pings land here. It keeps working in combat, even though the game hides who sent what.\n\nA sample line is showing because the options are open, so you can drag the window wherever you like.",
        },
        {
            tab   = { "pings", "window", "entrylayout" },
            find  = "Font Size",
            grow  = 2,   -- the Entry Globals block, not the whole panel
            place = { x = -303, y = 456 },
            title = "Build the line",
            text  = "Every piece of an entry, the sender, the timestamp and the callout itself, can be placed, resized and coloured here.\n\nOr drag them around visually in the Layout Designer.",
        },
        {
            tab   = { "pings", "window" },
            find  = "Changes I Make Apply To",
            openDropdown = true,
            title = "Set it up once",
            text  = "Your settings are shared by every character.\n\nIf one of them wants something different, switch this first. Only what you change afterwards is kept for that character or spec, and everything else keeps following the shared setup.",
        },
        -- runs straight into the aura tour: two features shipped together, so
        -- two short tours instead of one twelve-step slog. Swap which comes
        -- first by moving this key onto the other list.
        chain = "3.7.10-auras",
    },

    -- ═══════════════════════════════════════════════════════════════════════
    -- AURA TRACKING (12.1 engine): icons, groups and bars driven by spell ID.
    -- DRAFT PLACEMENTS: no `place` values yet, so every callout is
    -- auto-positioned. Run "/arctour dev", drag each box where it reads best,
    -- then "/arctour dump" and paste the offsets in.
    -- ═══════════════════════════════════════════════════════════════════════
    ["3.7.10-auras"] = {
        label = "Auras",   -- shown on the previous tour's skip-ahead button
        check = function()
            return (ns.AuraIcons and ns.AuraIcons.IsAvailable and ns.AuraIcons.IsAvailable()) and true or false
        end,
        {
            -- close the popup if a previous run left it open, so step 1 shows
            -- the catalog and the tile, not the window that comes next
            pre   = function()
                local p = _G.ArcUIAddIconPopup
                if p and p:IsShown() then p:Hide() end
                return true
            end,
            tab   = { "icons", "cdmIcons" },
            find  = "Add",
            title = "Everything starts here",
            text  = "The Icon Catalog has absorbed the old Arc Icons and Custom Icons tabs, so every icon you own now lives in one place.\n\nThe green tile at the end of the grid is how you add a new one.",
        },
        {
            pre   = function()
                local p = _G.ArcUIAddIconPopup
                if not (p and p:IsShown()) and ns.ArcAurasOptions
                   and ns.ArcAurasOptions.ShowAddPopup then
                    ns.ArcAurasOptions.ShowAddPopup()
                end
                return true
            end,
            tab   = { "icons", "cdmIcons" },
            frame = "ArcUIAddIconPopup",
            title = "One window for every kind of icon",
            text  = "Items, trinkets, spell cooldowns, custom timers and now auras, all added from here.\n\nYou can also drag a spell or an item straight onto the window instead of typing anything.",
        },
        {
            -- opens the window ON the Aura page: the step is about that
            -- section, so it has to be the one showing
            pre   = function()
                return ns.ArcAurasOptions and ns.ArcAurasOptions.TourOpenAddPopup
                   and ns.ArcAurasOptions.TourOpenAddPopup("aura")
            end,
            tab   = { "icons", "cdmIcons" },
            frame = "ArcUIAddIconPopup",
            title = "Aura: track any buff or debuff",
            text  = "Enter a spell ID here and you get an icon for that aura, whether or not the Cooldown Manager knows about it.",
        },
        {
            -- select an icon so the per-icon panel is actually on screen
            pre   = function()
                local p = _G.ArcUIAddIconPopup
                if p and p:IsShown() then p:Hide() end
                return ns.ArcAurasOptions and ns.ArcAurasOptions.TourSelectAnyIcon
                   and ns.ArcAurasOptions.TourSelectAnyIcon()
            end,
            tab   = { "icons", "cdmIcons" },
            title = "Settings moved in with them",
            text  = "Click any icon in the catalog and its options open below.\n\nThe old Arc Icon settings, load conditions, the timer editor and the new alert sounds all live here now.",
        },
        {
            tab   = { "auras", "auraBars" },
            find  = "Add",
            title = "Bars can do it too",
            text  = "The same green tile is here in Buffs/Debuffs.\n\nEnter a spell ID and it joins the aura catalog, so the buttons you already use will build a duration bar, a stack bar or a texture for auras the Cooldown Manager never sees.",
        },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- state
-- ═══════════════════════════════════════════════════════════════════════════
local steps, index = nil, 0
-- DEV MODE. Auto-placement gets a box out of the way, but only a human can say
-- where it reads BEST. So: drag it, and the position is captured relative to
-- the panel (which is centred during a tour, so the offset survives any
-- resolution). "/arctour dump" prints them ready to paste into the step data.
local devMode = false
-- the last tour actually run. dump/clear default to this, not the build version:
-- you are usually iterating on an UNRELEASED tour, so BaseVersion() is wrong.
local lastRun
local panelRect        -- the centred panel's rect, computed not queried  (hoisted: BuildFrame's drag handler closes over it)
local running          -- which version's tour is on screen (may differ from the
                       -- build when previewing an unreleased tour)
local lastRect         -- where the spotlight is now, so the next step can glide
local frame, spot

local function GetDB()
    local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if not g then return nil end
    g.tour = g.tour or {}
    g.tour.seen = g.tour.seen or {}
    return g.tour
end

local function BaseVersion()
    local v = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version"))
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"
    -- strip a hotfix suffix (3.7.10.a -> 3.7.10) so a tour pops once per release
    return (v:match("^(%d+%.%d+%.%d+)")) or v
end

-- ═══════════════════════════════════════════════════════════════════════════
-- finding a control by its visible label
-- ═══════════════════════════════════════════════════════════════════════════
local function StripColor(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return (s:match("^%s*(.-)%s*$"))
end

-- Depth-first walk of the open options dialog. Returns the FRAME that owns a
-- FontString reading `label` -- that is the widget container, which is what we
-- want to draw around.
local function FindByLabel(label)
    local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
    local dlg = acd and acd.OpenFrames and acd.OpenFrames["ArcUI"]
    local root = dlg and dlg.frame
    if not (root and label) then return nil end

    local found
    local function walk(f, depth)
        if found or depth > 14 or not f.GetRegions then return end
        if f.IsShown and not f:IsShown() then return end
        for _i, r in ipairs({ f:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "FontString" and r.GetText then
                if StripColor(r:GetText()) == label then found = f; return end
            end
        end
        if f.GetChildren then
            for _i, c in ipairs({ f:GetChildren() }) do walk(c, depth + 1) end
        end
    end
    walk(root, 0)
    return found
end

-- ═══════════════════════════════════════════════════════════════════════════
-- THE SPOTLIGHT
--
-- Four dark quads laid around the focused control, leaving a hole over it, so
-- everything else on screen dims and the eye is pulled to one place. The quads
-- glide to the next control when you press Next -- that travel is the whole
-- point: you see WHERE the next thing is, not just what it says.
--
-- Rects are computed in UIParent space so the maths survives a scaled panel.
-- ═══════════════════════════════════════════════════════════════════════════
local DIM_ALPHA = 0.62
local GLIDE     = 0.35

-- callout box: space above the body text, and below it for the button row.
-- Kept as constants because the height is recomputed per step from the text.
local TEXT_TOP    = 38          -- title + the body's own top inset
local TEXT_BOTTOM = 52          -- gap + 22px buttons + bottom padding

local function RectOf(f)
    if not f then return nil end
    local l, b, w, h = f:GetLeft(), f:GetBottom(), f:GetWidth(), f:GetHeight()
    if not (l and b and w and h) or w <= 0 or h <= 0 then return nil end
    local s = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return { l = l * s, b = b * s, w = w * s, h = h * s }
end

local function BuildSpot()
    if spot then return spot end

    -- the dimmer. Mouse is deliberately NOT enabled: the tour explains the
    -- panel, it should never stop you touching it.
    -- TOOLTIP, not FULLSCREEN_DIALOG: the options panel lives in the latter at
    -- level 100 with SetToplevel(true), so it re-raises itself above anything we
    -- put in that strata. A whole strata up is the only way to stay on top.
    local d = CreateFrame("Frame", "ArcUITourDim", UIParent)
    d:SetFrameStrata("TOOLTIP")
    d:SetFrameLevel(1)
    d:SetAllPoints(UIParent)
    d:EnableMouse(false)
    d.quads = {}
    for i = 1, 4 do
        local t = d:CreateTexture(nil, "BACKGROUND")
        t:SetColorTexture(0, 0, 0, DIM_ALPHA)
        d.quads[i] = t
    end

    -- the ring around the hole
    local s = CreateFrame("Frame", "ArcUITourSpot", UIParent, "BackdropTemplate")
    s:SetFrameStrata("TOOLTIP")
    s:SetFrameLevel(10)
    s:EnableMouse(false)
    s:SetBackdrop({ edgeFile = WHITE, edgeSize = 2 })
    s:SetBackdropBorderColor(ARC[1], ARC[2], ARC[3], 1)
    s.glow = s:CreateTexture(nil, "BACKGROUND")
    s.glow:SetAllPoints()
    s.glow:SetColorTexture(ARC[1], ARC[2], ARC[3], 0.10)

    -- breathing edge once it has settled. An AnimationGroup, so it costs
    -- nothing while hidden and needs no per-frame script of ours.
    local ag = s:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(1); a:SetToAlpha(0.45); a:SetDuration(0.85)
    s._pulse = ag

    s.dim = d
    d:Hide(); s:Hide()
    spot = s
    return s
end

-- Lay the quads + ring out for one rect. Pure geometry, no animation.
local function ApplySpot(r, pad)
    local s = BuildSpot()
    pad = pad or 4
    local SW, SH = UIParent:GetWidth(), UIParent:GetHeight()
    local l, b = r.l - pad, r.b - pad
    local w, h = r.w + pad * 2, r.h + pad * 2

    s:ClearAllPoints()
    s:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
    s:SetSize(math.max(w, 1), math.max(h, 1))

    local q = s.dim.quads
    -- left / right run full height; top / bottom only span the hole's width
    q[1]:ClearAllPoints()
    q[1]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    q[1]:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", math.max(l, 0), SH)
    q[2]:ClearAllPoints()
    q[2]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", math.min(l + w, SW), 0)
    q[2]:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", SW, SH)
    q[3]:ClearAllPoints()
    q[3]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", math.max(l, 0), math.min(b + h, SH))
    q[3]:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", math.min(l + w, SW), SH)
    q[4]:ClearAllPoints()
    q[4]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", math.max(l, 0), 0)
    q[4]:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", math.min(l + w, SW), math.max(b, 0))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- the glide. A bounded tween driven by a lone OnUpdate that clears its own
-- script on the final frame, so nothing polls between steps.
-- ═══════════════════════════════════════════════════════════════════════════
local tweener = CreateFrame("Frame")
local function Glide(from, to, pad, onDone)
    tweener:SetScript("OnUpdate", nil)
    if not from then                       -- first step: no travel, just arrive
        ApplySpot(to, pad)
        if onDone then onDone() end
        return
    end
    local t = 0
    tweener:SetScript("OnUpdate", function(_self, elapsed)
        t = t + elapsed
        local x = t / GLIDE
        if x >= 1 then
            tweener:SetScript("OnUpdate", nil)
            ApplySpot(to, pad)
            if onDone then onDone() end
            return
        end
        local e = 1 - (1 - x) ^ 3          -- ease-out: fast away, settles gently
        ApplySpot({
            l = from.l + (to.l - from.l) * e,
            b = from.b + (to.b - from.b) * e,
            w = from.w + (to.w - from.w) * e,
            h = from.h + (to.h - from.h) * e,
        }, pad)
    end)
end

local function BuildFrame()
    if frame then return frame end
    local f = CreateFrame("Frame", "ArcUITourFrame", UIParent, "BackdropTemplate")
    f:SetSize(330, 190)
    -- above the options panel AND our own dimmer, so Next stays clickable no
    -- matter what it happens to be sitting over. See the strata note in BuildSpot.
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(20)
    f:SetToplevel(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
--@debug@
        if not (devMode and panelRect and steps and steps[index]) then return end
        local l, b = self:GetLeft(), self:GetBottom()
        if not (l and b) then return end
        local sc = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
        local x = math.floor(l * sc - panelRect.l + 0.5)
        local y = math.floor(b * sc - panelRect.b + 0.5)
        local db = GetDB()
        if db then
            db.devPlace = db.devPlace or {}
            db.devPlace[running or "?"] = db.devPlace[running or "?"] or {}
            db.devPlace[running or "?"][index] = { x = x, y = y }
        end
        print(("|cff00ccffArcUI Tour|r step %d placed at |cff33ff99place = { x = %d, y = %d }|r"):format(index, x, y))
--@end-debug@
    end)
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(PANEL[1], PANEL[2], PANEL[3], 0.97)
    f:SetBackdropBorderColor(ARC[1], ARC[2], ARC[3], 1)

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont(STANDARD_TEXT_FONT, 15, "")
    f.title:SetPoint("TOPLEFT", 14, -12)
    f.title:SetTextColor(ARC[1], ARC[2], ARC[3])

    f.count = f:CreateFontString(nil, "OVERLAY")
    f.count:SetFont(STANDARD_TEXT_FONT, 11, "")
    f.count:SetPoint("TOPRIGHT", -14, -14)
    f.count:SetTextColor(DIM[1], DIM[2], DIM[3])

    f.body = f:CreateFontString(nil, "OVERLAY")
    f.body:SetFont(STANDARD_TEXT_FONT, 12, "")
    f.body:SetPoint("TOPLEFT", 14, -38)
    -- EXPLICIT width, not a second anchor. Deriving it from TOPLEFT+TOPRIGHT
    -- means GetStringHeight lies until the frame has laid out, so the first
    -- step measured short and the text came out as "...".
    f.body:SetWidth(330 - 28)
    f.body:SetWordWrap(true)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(3)
    f.body:SetTextColor(INK[1], INK[2], INK[3])

    local function MakeBtn(text, w)
        local b = CreateFrame("Button", nil, f, "BackdropTemplate")
        b:SetSize(w or 70, 22)
        b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        b:SetBackdropColor(0.09, 0.13, 0.20, 1)
        b:SetBackdropBorderColor(LINE[1], LINE[2], LINE[3], 1)
        b.fs = b:CreateFontString(nil, "OVERLAY")
        b.fs:SetFont(STANDARD_TEXT_FONT, 12, "")
        b.fs:SetPoint("CENTER")
        b.fs:SetTextColor(INK[1], INK[2], INK[3])
        b.fs:SetText(text)
        b:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(ARC[1], ARC[2], ARC[3], 1) end)
        b:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(LINE[1], LINE[2], LINE[3], 1) end)
        return b
    end

    f.next = MakeBtn("Next", 80)
    f.next:SetPoint("BOTTOMRIGHT", -12, 10)
    f.next:SetScript("OnClick", function() T.Next() end)   -- last step hands off to the chained tour

    f.back = MakeBtn("Back", 70)
    f.back:SetPoint("RIGHT", f.next, "LEFT", -6, 0)
    f.back:SetScript("OnClick", function() T.Back() end)

    f.skip = MakeBtn("Skip", 70)
    f.skip:SetPoint("BOTTOMLEFT", 12, 10)
    f.skip:SetScript("OnClick", function() T.Stop(true) end)

    -- With another tour queued behind this one, Skip must not mean "skip
    -- everything": this leaves the CURRENT feature's tour and starts the next
    -- one, while Skip still exits the whole thing.
    f.skipNext = MakeBtn("Skip to Next", 130)
    f.skipNext:SetPoint("LEFT", f.skip, "RIGHT", 6, 0)
    f.skipNext:SetScript("OnClick", function() T.SkipToChain() end)

    if not tContains(UISpecialFrames, "ArcUITourFrame") then
        tinsert(UISpecialFrames, "ArcUITourFrame")
    end
    f:Hide()
    frame = f
    return f
end

-- ═══════════════════════════════════════════════════════════════════════════
-- the options panel: centre it for the tour, put it back afterwards
--
-- A plain SetPoint does NOT hold. AceGUI's Frame:ApplyStatus does
-- ClearAllPoints() and re-anchors from status.top/status.left on every layout,
-- so the position has to be written into that status table -- which is the same
-- table ArcUI_Options persists as globalDB.optionsPanelPos. We anchor exactly
-- the way AceGUI does (TOP to UIParent BOTTOM, LEFT to UIParent LEFT) so its
-- next ApplyStatus is a harmless re-application of our own numbers.
-- ═══════════════════════════════════════════════════════════════════════════
local savedPanelPos

local function PanelFrame()
    local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
    local dlg = acd and acd.OpenFrames and acd.OpenFrames["ArcUI"]
    return dlg and dlg.frame or nil
end

local function StatusTable()
    local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
    return acd and acd.GetStatusTable and acd:GetStatusTable("ArcUI") or nil
end

local function AnchorPanel(p, top, left)
    p:ClearAllPoints()
    if top and left then
        p:SetPoint("TOP", UIParent, "BOTTOM", 0, top)
        p:SetPoint("LEFT", UIParent, "LEFT", left, 0)
    else
        p:SetPoint("CENTER")
    end
end

local function CentrePanel()
    local p = PanelFrame()
    if not p then panelRect = nil return end
    local w, h = p:GetWidth(), p:GetHeight()
    if not (w and h) or w <= 0 then return end

    local left = (UIParent:GetWidth() - w) * 0.5
    local top  = (UIParent:GetHeight() + h) * 0.5

    if not savedPanelPos then                  -- move once, on the first step
        local st = StatusTable()
        savedPanelPos = { top = st and st.top, left = st and st.left }
        if st then st.top, st.left = top, left end
        AnchorPanel(p, top, left)
    end

    -- Where the panel WILL be this frame, COMPUTED rather than queried.
    -- GetLeft/GetTop still report the pre-move position until the next draw,
    -- so measuring here sent step 1's spotlight to wherever the panel used to
    -- be. Later steps looked fine only because the move had already landed.
    local sc = p:GetEffectiveScale() / UIParent:GetEffectiveScale()
    panelRect = { l = left * sc, b = (top - h) * sc, w = w * sc, h = h * sc }
end

local function RestorePanel()
    if not savedPanelPos then return end
    local st, p = StatusTable(), PanelFrame()
    if st then st.top, st.left = savedPanelPos.top, savedPanelPos.left end
    if p then AnchorPanel(p, savedPanelPos.top, savedPanelPos.left) end

    -- ArcUI_Options persists status.top/left into globalDB when the panel
    -- closes. Closing it mid-tour would therefore save OUR centring as the
    -- player's preferred position, so put the stored value back too.
    local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if g and g.optionsPanelPos and savedPanelPos.top and savedPanelPos.left then
        g.optionsPanelPos.top  = savedPanelPos.top
        g.optionsPanelPos.left = savedPanelPos.left
    end
    savedPanelPos, panelRect = nil, nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- running a step
-- ═══════════════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════════════
-- Focusing a frame that is NOT part of the options panel (the Ping Feed) has a
-- problem: the feed defaults near the middle of the screen, which is exactly
-- where we just put the panel -- so the spotlight hole would reveal the panel
-- sitting on top of it.
--
-- Lifting the feed for one step beats shoving the panel aside: no layout
-- thrash, no window jumping around mid-tour, and it drops straight back to its
-- own strata afterwards. Level 5 puts it above our dimmer (1) but under the
-- ring (10), so the ring still draws around it.
-- ═══════════════════════════════════════════════════════════════════════════
-- a LIST: a step can focus more than one frame (the Ping Feed's title floats
-- above the window as its own frame, so ringing the window alone cut it off)
local raised = {}

local function LowerTarget()
    for i = #raised, 1, -1 do
        local r = raised[i]
        r.f:SetFrameStrata(r.strata)
        r.f:SetFrameLevel(r.level)
        raised[i] = nil
    end
end

local function RaiseTarget(f)
    if not f or not f.SetFrameStrata then return end
    raised[#raised + 1] = { f = f, strata = f:GetFrameStrata(), level = f:GetFrameLevel() }
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(5)
end

-- Click a control's own button so a dropdown shows its choices. Telling someone
-- "you can pick a different scope here" lands far better with the list open in
-- front of them than with a closed box. Best effort by design: if the widget has
-- no button, or is already open, nothing happens and the step still reads fine.
local function OpenDropdown(target)
    if not (target and target.GetChildren) then return end
    for _i, c in ipairs({ target:GetChildren() }) do
        if c.GetObjectType and c:GetObjectType() == "Button"
           and c.IsEnabled and c:IsEnabled() and c.Click and c:IsShown() then
            c:Click()
            return
        end
    end
end

-- Climb from a control to the container it lives in, so a step can light up a
-- whole SECTION (the Ping Keys tab body) instead of one checkbox. Stops before
-- reaching anything panel-sized, which would just be the whole window again.
local function GrowToContainer(f, levels)
    if not (f and panelRect) then return f end
    local panelArea = panelRect.w * panelRect.h
    local best, cur, depth = f, f:GetParent(), 0
    local cap = (type(levels) == "number") and levels or 8
    while cur and cur ~= UIParent and depth < cap do
        local r = RectOf(cur)
        if r then
            -- never grow into something panel-sized: that is not a section any
            -- more, it is "everything", and it tells the player nothing
            if r.w * r.h >= panelArea * 0.85 then break end
            best = cur
        end
        cur, depth = cur:GetParent(), depth + 1
    end
    return best
end

-- Smallest rect containing both.
local function UnionRect(a, b)
    if not a then return b end
    if not b then return a end
    local l = math.min(a.l, b.l)
    local bo = math.min(a.b, b.b)
    local r = math.max(a.l + a.w, b.l + b.w)
    local t = math.max(a.b + a.h, b.b + b.h)
    return { l = l, b = bo, w = r - l, h = t - bo }
end

-- A scroll child can be taller than the visible area; trim to what is on screen
local function ClampToPanel(r)
    if not (r and panelRect) then return r end
    local l  = math.max(r.l, panelRect.l)
    local b  = math.max(r.b, panelRect.b)
    local rr = math.min(r.l + r.w, panelRect.l + panelRect.w)
    local tt = math.min(r.b + r.h, panelRect.b + panelRect.h)
    if rr <= l or tt <= b then return r end
    return { l = l, b = b, w = rr - l, h = tt - b }
end

-- Does box (x,y,w,h) intersect rect r?
local function Overlaps(x, y, w, h, r)
    return not (x + w <= r.l or x >= r.l + r.w or y + h <= r.b or y >= r.b + r.h)
end

-- NEVER COVER THE HIGHLIGHT. That is the whole job: a box sitting on top of the
-- thing it is describing teaches nothing, and it was hiding the very tab the
-- first step points at.
--
-- Order of preference: beside the highlight and still on the panel, then beside
-- the highlight anywhere on screen. The second case is what happens when the
-- highlight IS the panel, and going outside is correct there rather than a
-- compromise: there is no honest room inside.
local function PlaceCallout(rect, hasTarget)
    local f = BuildFrame()
    local fw, fh = f:GetWidth(), f:GetHeight()
    local SW, SH = UIParent:GetWidth(), UIParent:GetHeight()
    local host = panelRect
    f:ClearAllPoints()

    -- A hand-placed position always wins over the automatic search: someone
    -- looked at it. Dev captures override the baked value so you can iterate
    -- without editing the file between attempts.
    local step = steps and steps[index]
    local hand = step and step.place
--@debug@
    local db = GetDB()
    if db and db.devPlace and running and db.devPlace[running] then
        hand = db.devPlace[running][index] or hand
    end
--@end-debug@
    if hand and host then
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", host.l + hand.x, host.b + hand.y)
        return
    end

    if not (rect and hasTarget) then
        if host then
            f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
                host.l + (host.w - fw) * 0.5, host.b + (host.h - fh) * 0.5)
        else
            f:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
        end
        return
    end

    local m, gap = 12, 20
    local function fitsScreen(x, y) return x >= m and y >= m and x + fw <= SW - m and y + fh <= SH - m end
    local function onPanel(x, y)
        return host and x >= host.l and y >= host.b
           and x + fw <= host.l + host.w and y + fh <= host.b + host.h
    end

    local cy = math.max(m, math.min(SH - fh - m, rect.b + rect.h * 0.5 - fh * 0.5))
    local cx = math.max(m, math.min(SW - fw - m, rect.l + rect.w * 0.5 - fw * 0.5))
    local cands = {
        { rect.l + rect.w + gap, cy },              -- right of it
        { rect.l - gap - fw,     cy },              -- left of it
        { cx, rect.b - gap - fh },                  -- below it
        { cx, rect.b + rect.h + gap },              -- above it
    }

    -- pass 1: clear of the highlight AND still on the panel
    for _i, c in ipairs(cands) do
        if fitsScreen(c[1], c[2]) and onPanel(c[1], c[2]) and not Overlaps(c[1], c[2], fw, fh, rect) then
            f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", c[1], c[2]) return
        end
    end
    -- pass 2: clear of the highlight, anywhere on screen (highlight fills the panel)
    for _i, c in ipairs(cands) do
        if fitsScreen(c[1], c[2]) and not Overlaps(c[1], c[2], fw, fh, rect) then
            f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", c[1], c[2]) return
        end
    end
    -- nothing clears it: hug the screen edge furthest from the highlight
    local x = (rect.l + rect.w * 0.5 > SW * 0.5) and m or (SW - fw - m)
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, math.max(m, math.min(SH - fh - m, cy)))
end

local function ShowStep()
    local step = steps and steps[index]
    if not step then T.Stop(true) return end

    -- Open ONLY if it is not already open. OpenOptions restores the player's
    -- saved position into the status table on every call, so calling it each
    -- step dragged the panel straight back out of centre.
    if not PanelFrame() and ns.API and ns.API.OpenOptions then ns.API.OpenOptions() end
    local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
    if acd and step.tab then
        acd:SelectGroup("ArcUI", unpack(step.tab))
    end

    LowerTarget()   -- drop anything the previous step lifted

    -- put the panel into the state this step describes (select a spell, etc)
    -- BEFORE the redraw below, so the controls it talks about actually exist
    if step.pre then step.pre() end

    -- one frame for AceConfig to rebuild the tab before we go looking in it
    C_Timer.After(0.06, function()
        if not steps then return end          -- stopped while we waited
        -- centre BEFORE measuring: every control rect below is relative to it
        CentrePanel()
        local f = BuildFrame()
        local s = BuildSpot()

        -- Three ways to pick a subject, in order of preference:
        --   frame = a real UI frame (the Ping Feed window)
        --   find  = a control inside the options panel
        --   neither, or a label renamed out from under us = the panel itself
        local target, frameRect
        if step.frame then
            local list = {}
            if type(step.frame) == "function" then
                for _i, v in ipairs({ step.frame() }) do list[#list + 1] = v end
            else
                list[1] = step.frame
            end
            for _i, fr in ipairs(list) do
                if type(fr) == "string" then fr = _G[fr] end
                if type(fr) == "table" and fr.GetLeft and fr:IsShown() then
                    target = target or fr
                    RaiseTarget(fr)     -- or the centred panel would cover it
                    frameRect = UnionRect(frameRect, RectOf(fr))
                end
            end
        end
        if not target and step.find then
            target = FindByLabel(step.find)
            -- open BEFORE growing: the button belongs to the control itself,
            -- not to whatever container the highlight ends up hugging
            if target and step.openDropdown then OpenDropdown(target) end
            -- grow: light the section this control sits in, not the control
            if target and step.grow then target = GrowToContainer(target, step.grow) end
        end

        -- panelRect, not RectOf(PanelFrame()) -- see the note in CentrePanel
        local rect = frameRect or RectOf(target)
        if rect and step.grow then rect = ClampToPanel(rect) end
        -- unionPanel: light the control AND everything it governs. Ringing the
        -- Pings TAB alone says where to click but not what you get.
        if rect and step.unionPanel then rect = UnionRect(rect, panelRect) end
        rect = rect or panelRect or RectOf(PanelFrame())
        local pad = target and 4 or 0

        f.title:SetText(step.title or "")
        f.body:SetText(step.text or "")
        -- dev mode has to be obvious, or you drag boxes around wondering why
        -- nothing is being recorded
        f.count:SetText(devMode
            and ("|cff33ff99DEV|r  %d / %d"):format(index, #steps)
            or  ("%d / %d"):format(index, #steps))
        f.back:SetShown(index > 1)
        -- name the destination: "Skip to Auras" reads as a choice, "Skip to
        -- Next" reads as a mystery. On the LAST step it would duplicate the
        -- Next button (which becomes the handoff), so it steps aside there.
        local chained = steps.chain and TOURS[steps.chain]
        local chainName = chained and (chained.label or "Next")
        local showSkipNext = chained ~= nil and index < #steps
        f.skipNext:SetShown(showSkipNext)
        if showSkipNext then f.skipNext.fs:SetText("Skip to " .. chainName) end
        -- FOUR buttons do not fit the standard box: widen it for that one case
        -- (Skip 70 + Skip-to 130 + Back 70 + Next 80 plus gaps needs ~390).
        local boxW = showSkipNext and 400 or 330
        f:SetWidth(boxW)
        f.body:SetWidth(boxW - 28)
        f.next.fs:SetText(index >= #steps
            and (chainName and (chainName .. " Tour") or "Done")
            or "Next")

        -- Grow the box to fit however far the text wrapped. A fixed height let
        -- long steps run underneath the buttons. Must happen before the
        -- placement below, which measures GetHeight().
        f:SetHeight(math.max(150, TEXT_TOP + (f.body:GetStringHeight() or 0) + TEXT_BOTTOM))

        if not rect then                       -- panel not open yet; text only
            s._pulse:Stop(); s:Hide(); s.dim:Hide()
            PlaceCallout(nil, false)
            f:Show(); f:Raise()
            return
        end

        -- Hand the box off first so it does not drag along behind the
        -- spotlight, then let the light travel to the new control.
        local from = lastRect
        s._pulse:Stop()
        s:SetAlpha(1)
        s.dim:Show(); s:Show()
        f:Show(); f:Raise()

        Glide(from, rect, pad, function()
            if not steps then return end
            s._pulse:Play()
        end)
        PlaceCallout(rect, target ~= nil)
        lastRect = rect
    end)
end

function T.Next()
    if not steps then return end
    if index >= #steps then
        -- CHAINED TOUR: when one update ships two separate features, they get
        -- two tours back to back rather than one long one (the six-step cap is
        -- per tour, and a single twelve-step tour is a tour people skip). The
        -- finished tour is marked seen here so it never replays on its own.
        local nextKey = steps.chain
        if nextKey and TOURS[nextKey] then
            local finished = running
            if T.Start(nextKey) then
                local db = GetDB()
                if db and finished then db.seen[finished] = true end
                return
            end
        end
        T.Stop(true)
        return
    end
    index = index + 1
    ShowStep()
end

-- Leave THIS tour and start the one queued behind it (marking only this one
-- seen). Skip still exits everything.
function T.SkipToChain()
    if not steps then return end
    local nextKey, finished = steps.chain, running
    if not (nextKey and TOURS[nextKey]) then T.Stop(true) return end
    if T.Start(nextKey) then
        local db = GetDB()
        if db and finished then db.seen[finished] = true end
    else
        T.Stop(true)
    end
end

function T.Back()
    if not steps or index <= 1 then return end
    index = index - 1
    ShowStep()
end

-- markSeen=false is used by the "replay" path so testing never burns the flag
function T.Stop(markSeen)
    local ver = running
    steps, index, running, lastRect, panelRect = nil, 0, nil, nil, nil
    tweener:SetScript("OnUpdate", nil)     -- kill an in-flight glide
    LowerTarget()
    if frame then frame:Hide() end
    if spot then spot._pulse:Stop(); spot:Hide(); spot.dim:Hide() end
    RestorePanel()
    if markSeen and ver then
        local db = GetDB()
        if db then db.seen[ver] = true end
    end
end

-- Start a tour. version defaults to the current build; returns false when there
-- is nothing to show for it.
-- The steps of `list` that can actually run on THIS client, or nil when the
-- tour has nothing to show (feature absent, or the whole tour is gated off).
local function UsableSteps(list)
    if not list then return nil end
    if list.check and not list.check() then return nil end
    local usable = {}
    for _i, s in ipairs(list) do
        if not s.check or s.check() then usable[#usable + 1] = s end
    end
    if #usable == 0 then return nil end
    usable.chain, usable.label = list.chain, list.label
    return usable
end

-- Walk the chain until a tour with runnable steps turns up: on a client where
-- the first feature is missing, the SECOND tour still gets its chance.
local function FirstRunnable(version)
    local key, list = version, TOURS[version]
    local guard = 0
    while list and guard < 8 do
        local usable = UsableSteps(list)
        if usable then return key, usable end
        key = list.chain
        list = key and TOURS[key] or nil
        guard = guard + 1
    end
    return nil, nil
end

function T.Start(version)
    version = version or BaseVersion()
    local key, usable = FirstRunnable(version)
    if not usable then return false end
    version = key
    lastRect = nil                         -- first step arrives, never glides
    steps, index, running = usable, 1, version
    lastRun = version
    ShowStep()
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- THE OFFER. A tour nobody knows about teaches nobody, so the first time this
-- build's options are opened we ASK once. Once per patch, per character-set:
-- the flag is stored beside the seen flags, and taking or declining both close
-- the question for good. Never interrupts anything: it only appears because
-- the player just opened the options themselves.
-- ═══════════════════════════════════════════════════════════════════════════
local offerFrame

function T.Offered(version)
    local db = GetDB()
    return db and db.offered and db.offered[version or BaseVersion()] == true
end

local function MarkOffered(version)
    local db = GetDB()
    if not db then return end
    db.offered = db.offered or {}
    db.offered[version or BaseVersion()] = true
end

function T.OfferIfNew()
    local ver = BaseVersion()
    if not T.HasTour(ver) then return false end
    if T.Seen(ver) or T.Offered(ver) then return false end
    if running then return false end   -- already touring

    if not offerFrame then
        local f = CreateFrame("Frame", "ArcUITourOffer", UIParent, "BackdropTemplate")
        f:SetSize(360, 132)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
        -- TOOLTIP: the options window is FULLSCREEN_DIALOG, and this asks its
        -- question ON TOP of it (same reason the changelog uses TOOLTIP)
        f:SetFrameStrata("TOOLTIP")
        f:SetToplevel(true)
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.06, 0.08, 0.12, 1)

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.title:SetPoint("TOP", 0, -18)
        f.title:SetTextColor(0.25, 0.79, 0.95)

        f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.body:SetPoint("TOPLEFT", 20, -46)
        f.body:SetPoint("TOPRIGHT", -20, -46)
        f.body:SetJustifyH("CENTER")
        f.body:SetText("Want a quick tour of what is new?")

        local yes = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        yes:SetSize(150, 24)
        yes:SetPoint("BOTTOM", f, "BOTTOM", -80, 16)
        yes:SetText("Show Me Around")
        yes:SetScript("OnClick", function()
            MarkOffered()
            f:Hide()
            T.Start()
        end)

        local no = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        no:SetSize(110, 24)
        no:SetPoint("BOTTOM", f, "BOTTOM", 80, 16)
        no:SetText("Not Now")
        no:SetScript("OnClick", function()
            MarkOffered()
            f:Hide()
        end)

        offerFrame = f
    end

    offerFrame.title:SetText("New in " .. (C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(ADDON, "Version") or ver))
    offerFrame:Show()
    return true
end

-- "has a tour" means "has one that can RUN here": a client missing the
-- features must not be shown the button or the offer at all.
function T.HasTour(version)
    local _key, usable = FirstRunnable(version or BaseVersion())
    return usable ~= nil
end

function T.Seen(version)
    local db = GetDB()
    return db and db.seen[version or BaseVersion()] == true
end

local function Authored()
    local t = {}
    for k in pairs(TOURS) do t[#t + 1] = k end
    table.sort(t)
    return t
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SELF-CHECK. The whole design rests on matching option labels by text, so a
-- rename orphans a step silently. This resolves every step's label against the
-- LIVE panel and reports the misses, which is how you catch drift before a
-- release rather than after one. Run it with the options panel open.
-- ═══════════════════════════════════════════════════════════════════════════
local function SelfCheck(version)
    version = version or BaseVersion()
    local list = TOURS[version]
    if not list then
        print(("|cff00ccffArcUI Tour|r: no tour authored for %s."):format(version))
        return
    end
    if ns.API and ns.API.OpenOptions then ns.API.OpenOptions() end
    local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
    print(("|cff00ccffArcUI Tour|r: checking %d steps for %s..."):format(#list, version))

    -- serialise the checks: each step needs its own tab selected and drawn
    local i = 0
    local bad = 0
    local function step()
        i = i + 1
        local s = list[i]
        if not s then
            print(bad == 0
                and "|cff00ccffArcUI Tour|r: |cff55ff55all steps resolve.|r"
                or ("|cff00ccffArcUI Tour|r: |cffff5555%d step(s) could not find their control|r, they will still show, centred."):format(bad))
            return
        end
        if s.pre then s.pre() end          -- same state the real step would set
        if acd and s.tab then acd:SelectGroup("ArcUI", unpack(s.tab)) end
        C_Timer.After(0.10, function()
            if s.frame then
                local fr = s.frame
                if type(fr) == "function" then fr = fr() end
                if type(fr) == "string" then fr = _G[fr] end
                local ok = type(fr) == "table" and fr.GetLeft and fr:IsShown()
                if not ok then bad = bad + 1 end
                print(("  %d. %s  %s"):format(i, s.title or "?",
                    ok and "|cff55ff55frame shown|r"
                       or "|cffff5555frame MISSING or hidden|r"))
            elseif s.find then
                local ok = FindByLabel(s.find) ~= nil
                if not ok then bad = bad + 1 end
                print(("  %d. %s  %s"):format(i, s.title or "?",
                    ok and "|cff55ff55found '" .. s.find .. "'|r"
                       or "|cffff5555MISSING '" .. s.find .. "'|r"))
            else
                print(("  %d. %s  |cff8298b4(no anchor, tab intro)|r"):format(i, s.title or "?"))
            end
            step()
        end)
    end
    step()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- slash
-- ═══════════════════════════════════════════════════════════════════════════
SLASH_ARCTOUR1 = "/arctour"
SlashCmdList["ARCTOUR"] = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd, arg = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if cmd == "reset" then
        local db = GetDB()
        if db then wipe(db.seen) end
        print("|cff00ccffArcUI|r: tour reset. The What's New window will offer it again.")
        return
    end

    if cmd == "check" then
        SelfCheck((arg ~= "" and arg) or nil)
        return
    end

--@debug@
    if cmd == "dev" then
        devMode = not devMode
        if devMode then
            print("|cff00ccffArcUI Tour|r: dev mode |cff33ff99ON|r. Drag the box on any step and its position is captured.")
            print("  |cff8298b4/arctour dump|r to print them, |cff8298b4/arctour clear|r to throw them away.")
            if not steps then T.Start() end
        else
            print("|cff00ccffArcUI Tour|r: dev mode |cffff5555off|r. Captured positions still apply until cleared.")
        end
        if frame and frame:IsShown() then ShowStep() end
        return
    end

    if cmd == "dump" then
        local db = GetDB()
        local v = (arg ~= "" and arg) or running or lastRun or BaseVersion()
        local t = db and db.devPlace and db.devPlace[v]
        if not t then
            print(("|cff00ccffArcUI Tour|r: nothing captured for %s. Run /arctour dev and drag a box."):format(v))
            return
        end
        -- printed one per line so it can be pasted straight into the step
        print(("|cff00ccffArcUI Tour|r: captured placements for %s"):format(v))
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys)
        for _i, k in ipairs(keys) do
            print(("  step %d:   place = { x = %d, y = %d },"):format(k, t[k].x, t[k].y))
        end
        return
    end

    if cmd == "clear" then
        local db = GetDB()
        local v = (arg ~= "" and arg) or running or lastRun or BaseVersion()
        if db and db.devPlace then db.devPlace[v] = nil end
        print(("|cff00ccffArcUI Tour|r: cleared captured placements for %s."):format(v))
        if frame and frame:IsShown() then ShowStep() end
        return
    end
--@end-debug@

    if cmd == "list" then
        local a = Authored()
        print(("|cff00ccffArcUI|r: tours authored for %s. This build is %s.")
            :format(#a > 0 and table.concat(a, ", ") or "nothing", BaseVersion()))
        print("  |cff8298b4/arctour|r run  |cff8298b4check|r verify anchors  |cff8298b4reset|r re-offer the tour")
--@debug@
        print("  |cff8298b4dev|r place boxes by hand  |cff8298b4dump|r print them  |cff8298b4clear|r discard them")
--@end-debug@
        return
    end

    -- explicit version wins
    if cmd ~= "" and TOURS[cmd] then T.Start(cmd) return end

    if T.Start() then return end

    -- Nothing for this build. Rather than dead-end, run the newest authored
    -- tour -- this is what lets a tour be tested before its version ships.
    local a = Authored()
    local newest = a[#a]
    if newest then
        print(("|cff00ccffArcUI|r: no tour for %s yet, previewing %s."):format(BaseVersion(), newest))
        T.Start(newest)
    else
        print("|cff00ccffArcUI|r: no tours authored.")
        return
    end
end
