--[[===========================================================================
  ARC UI THEME -- canonical primitives for a hand-built (no-Ace) options panel.

  THIS FILE IS THE SOURCE OF TRUTH. Copy it into a new Arc addon, rename AT if
  you like, and build the panel from it. Do NOT re-derive the look from an
  existing addon's file: those drift. Fix bugs and add features HERE first, then
  carry them into the addons.

  Everything hangs off ONE table (AT). That is deliberate: a big single-file
  addon sits at Lua's 200-file-level-local ceiling, and thirty loose locals for
  the theme is enough to tip it into a hard load failure that luac -p reports as
  "too many local variables".

  A MENU, NOT A FRAMEWORK. Take only what the addon needs; nothing here is a stub.
  Minimum viable panel: CreateWindow -> NewPage -> Section -> Row* -> LayoutPage.

  FOUNDATION (always)
    AT.COL                     the palette. Never hardcode a hex.
    AT.Skin(f, bg, border)     flat fill + 1px edge, every surface
    AT.CloseDropdown()         wire to the window OnMouseDown/OnHide

  CHROME (as the addon's shape needs)
    AT.CreateWindow(name,opts) solid navy window, title bar, close, drag, resize grip
    AT.AddTabs(p,names,pages)  chip tabs on a cyan line. Skip for a single-page addon.
    AT.AddDiscordFooter(p,nm)  Discord button + copy popup. Reserve 34px at the bottom.

  CONTROLS (raw widgets, when a row builder does not fit)
    AT.MakeCheckbox(parent)    THE toggle. :SetOn(bool) :SetHover(bool)
    AT.MakeSmallButton(p,l,w)  raised navy/steel button, cyan border on hover only
    AT.MakeSwatch(p,w,h)       colour swatch, :SetColor{r,g,b}
    AT.MakeDropdown(...)       windowed-scroll select; itemsFn re-read on every open

  ROW ENGINE (this is what makes it look Arc)
    AT.NewPage(parent)         a page with its own rows and sections
    AT.Section(pg,text,opts)   titled bordered box. opts: visibleFn, side "L"/"R",
                               ctrlX, collapsible=true (header bar), store (remembers)
    AT.LayoutPage(pg)          flow, size boxes to VISIBLE rows, measure the control
                               column. Call after anything that shows/hides a row.
    AT.AddRow / AT.RowLabel    bare row + standard label, for custom controls
    AT.Tooltip(region,t,body)  hover tooltip. Descriptions NEVER get their own row.

  ROW BUILDERS (one line each, fully wired)
    AT.RowToggle   label + checkbox, whole row clickable, flip sound
    AT.RowInput    sunken field; `hint` shows what is in effect WITHOUT pre-filling
    AT.RowDropdown label + select
    AT.RowSlider   fill slider + [-] typed box [+]; grows with the box
    AT.RowColor    label + swatch + ColorPickerFrame
    AT.RowButton   left-aligned action button (an action, not a setting)
    AT.RowDesc     dim paragraph. Prefer a `desc` tooltip; use this only when the
                   text must always be visible.

  TWO MECHANISMS TO UNDERSTAND FIRST
    visibleFn   on any row/section: return false and it hides AND its box shrinks on
                the next LayoutPage. This is how dependent options collapse away.
    row._sync   set by the builders, called by LayoutPage every pass to re-read the DB
                into the widget. Set it on custom rows too or they go stale.

  House rules baked in: solid background, one cyan accent, boxed sections,
  raised buttons vs sunken fields, square checkbox toggles, descriptions as
  hover tooltips, no em-dashes or emoji in user-facing strings.
=============================================================================]]

local ADDON, NS = ...
-- ArcUI-bundled copy (loaded for the Bonus Roll module; exported as ns.AT so
-- future ArcUI modules can share it). Canonical source: the arc-ui-theme skill.
local AT = {}
NS.AT = AT

AT.WHITE = "Interface\\Buttons\\WHITE8X8"
AT.DISCORD = "https://discord.gg/yMZmnFjUTd"

AT.COL = {
    bg       = { 0.043, 0.059, 0.102 },  -- window body (SOLID, never translucent)
    panel    = { 0.063, 0.094, 0.153 },  -- title bar, dropdown pullout, header bars
    well     = { 0.039, 0.067, 0.125 },  -- SUNKEN input fields and dropdowns
    line     = { 0.114, 0.165, 0.247 },  -- 1px borders and hairlines
    line2    = { 0.165, 0.231, 0.341 },  -- brighter outer window border, checkbox edge
    box      = { 0.055, 0.078, 0.130 },  -- section container fill, a step above bg
    ink      = { 0.950, 0.970, 1.000 },  -- near-white primary text
    dim      = { 0.700, 0.780, 0.880 },  -- secondary text, hints, unselected tabs
    faint    = { 0.550, 0.650, 0.780 },  -- placeholder text, off-state knob
    arc      = { 0.247, 0.788, 0.949 },  -- ARC CYAN, the one accent (#3FC9F2)
    arcDeep  = { 0.078, 0.353, 0.451 },  -- deep teal, hover borders
    btn      = { 0.110, 0.161, 0.243 },  -- raised navy button fill
    btnHover = { 0.150, 0.205, 0.295 },  -- button fill on hover
    steel    = { 0.298, 0.400, 0.549 },  -- steel button border (cyan only on hover)
    blurple  = { 0.345, 0.396, 0.949 },  -- Discord #5865F2
}

-- Layout constants. Row heights are deliberately tight: the locked template lets
-- the row height do the breathing, not padding.
AT.LAY = {
    rowH = 24, descH = 20, hdr = 22,
    ctrl = 230,          -- fallback control column when a section does not measure
    gap  = 12,           -- between section blocks
    fieldW = 180,
}

local COL, WHITE, LAY = AT.COL, AT.WHITE, AT.LAY

-- The single most reused primitive: flat fill + 1px edge. No border art, ever.
function AT.Skin(f, bg, borderCol)
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    local b = borderCol or COL.line
    f:SetBackdropBorderColor(b[1], b[2], b[3], 1)
end
local Skin = AT.Skin

-- one dropdown pullout open at a time, panel-wide
AT.openDropdown = nil
function AT.CloseDropdown()
    if AT.openDropdown then AT.openDropdown:Hide(); AT.openDropdown = nil end
end

--[[ CONTROLS ================================================================]]

-- THE canonical toggle: a WoW-style square checkbox. The box is CONSTANT (it
-- never recolours); only the mark toggles. checkmark-minimal renders GREEN, so
-- desaturate BEFORE tinting or it stays green. The 20px mark in an 18px box
-- overhangs slightly, exactly like Blizzard's.
function AT.MakeCheckbox(parent)
    local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
    c:SetSize(18, 18); Skin(c, COL.well, COL.line2)
    c.check = c:CreateTexture(nil, "OVERLAY")
    c.check:SetAtlas("checkmark-minimal")
    c.check:SetDesaturated(true)
    c.check:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    c.check:SetSize(20, 20); c.check:SetPoint("CENTER"); c.check:Hide()
    c.glow = c:CreateTexture(nil, "ARTWORK")
    c.glow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    c.glow:SetBlendMode("ADD")
    c.glow:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.55)
    c.glow:SetPoint("TOPLEFT", -3, 3); c.glow:SetPoint("BOTTOMRIGHT", 3, -3)
    c.glow:Hide()
    function c:SetHover(on) self.glow:SetShown(on and true or false) end
    function c:SetOn(on) self.check:SetShown(on and true or false) end
    return c
end

-- Raised action button: navy fill + STEEL border (never a cyan resting border),
-- cyan only on hover. Reads as raised against the sunken well fields.
function AT.MakeSmallButton(parent, label, w)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 92, 22); Skin(b, COL.btn, COL.steel)
    local bevel = b:CreateTexture(nil, "ARTWORK")
    bevel:SetTexture(WHITE); bevel:SetVertexColor(1, 1, 1, 0.06)
    bevel:SetPoint("TOPLEFT", 1, -1); bevel:SetPoint("TOPRIGHT", -1, -1); bevel:SetHeight(1)
    b.fs = b:CreateFontString(nil, "OVERLAY")
    b.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    b.fs:SetPoint("CENTER")
    b.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    b.fs:SetText(label or "")
    b:SetScript("OnEnter", function()
        b:SetBackdropColor(COL.btnHover[1], COL.btnHover[2], COL.btnHover[3], 1)
        b:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropColor(COL.btn[1], COL.btn[2], COL.btn[3], 1)
        b:SetBackdropBorderColor(COL.steel[1], COL.steel[2], COL.steel[3], 1)
    end)
    return b
end

function AT.MakeSwatch(parent, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 24, h or 14); Skin(b, COL.well)
    b.tex = b:CreateTexture(nil, "OVERLAY")
    b.tex:SetTexture(WHITE)
    b.tex:SetPoint("TOPLEFT", 1, -1); b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    function b:SetColor(c) self.tex:SetVertexColor(c[1], c[2], c[3], 1) end
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    return b
end

-- Windowed-scroll dropdown. itemsFn() -> { {value=,text=}, ... }, re-read on every
-- open so live lists stay current. Opens scrolled to the current value.
function AT.MakeDropdown(owner, parent, w, itemsFn, get, set, onSelect)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or LAY.fieldW, 20); Skin(b, COL.well)
    local vf = b:CreateFontString(nil, "OVERLAY")
    vf:SetFont(STANDARD_TEXT_FONT, 11, "")
    vf:SetPoint("LEFT", 8, 0); vf:SetPoint("RIGHT", -18, 0); vf:SetJustifyH("LEFT")
    vf:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    -- drawn chevron (two rotated bars, same as ArcSkin) - never a text "v" glyph
    local arrow = CreateFrame("Frame", nil, b)
    arrow:SetSize(12, 12); arrow:SetPoint("RIGHT", -5, 0)
    local a1 = arrow:CreateTexture(nil, "OVERLAY")
    a1:SetTexture(WHITE); a1:SetSize(7, 1.5); a1:SetPoint("CENTER", -2, 0.5)
    a1:SetRotation(math.rad(-50)); a1:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    local a2 = arrow:CreateTexture(nil, "OVERLAY")
    a2:SetTexture(WHITE); a2:SetSize(7, 1.5); a2:SetPoint("CENTER", 2, 0.5)
    a2:SetRotation(math.rad(50)); a2:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)

    function b.Refresh()
        local cur = get()
        for _, it in ipairs(itemsFn() or {}) do
            if it.value == cur then vf:SetText(it.text) return end
        end
        vf:SetText(cur ~= nil and tostring(cur) or "")
    end
    b.Refresh()

    -- Auto width (w == nil): the field is exactly as long as the LONGEST
    -- option name plus insets (8 text + 18 chevron), floored at 80 and
    -- capped at 300 so a runaway name cannot eat the row. The pullout below
    -- always copies the field width, so the two stay edge to edge. An
    -- explicit w is honored untouched (hand-tuned call sites).
    local function SizeToItems(items)
        if w then return end
        local fs = AT._measureFS
        if not fs then
            fs = UIParent:CreateFontString(nil, "ARTWORK")
            fs:SetFont(STANDARD_TEXT_FONT, 11, ""); fs:Hide()
            AT._measureFS = fs
        end
        local widest = 0
        for _, it in ipairs(items or itemsFn() or {}) do
            fs:SetText(it.text or "")
            local tw = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
                or fs:GetStringWidth() or 0
            if tw > widest then widest = tw end
        end
        local want = math.floor(widest + 26 + 0.5)
        if want < 80 then want = 80 end
        if want > 300 then want = 300 end
        b:SetWidth(want)
    end
    SizeToItems()

    b:SetScript("OnClick", function()
        if AT.openDropdown and AT.openDropdown._owner == b then AT.CloseDropdown() return end
        AT.CloseDropdown()
        local items = itemsFn() or {}
        SizeToItems(items)
        local vis = math.min(#items, 12)
        local list = CreateFrame("Frame", nil, owner, "BackdropTemplate")
        list:SetFrameLevel(owner:GetFrameLevel() + 30)
        list:SetWidth(b:GetWidth()); list:SetHeight(vis * 20 + 2)
        Skin(list, COL.panel, COL.arcDeep)
        list:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -1)
        list._owner = b
        list:EnableMouse(true); list:EnableMouseWheel(true)
        local off, maxOff = 0, math.max(0, #items - vis)
        for i, it in ipairs(items) do
            if it.value == get() then off = math.min(maxOff, math.max(0, i - 1)) end
        end
        local rows = {}
        for i = 1, vis do
            local ib = CreateFrame("Button", nil, list)
            ib:SetHeight(20)
            ib:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 20)
            ib:SetPoint("TOPRIGHT", -1, -1 - (i - 1) * 20)
            ib:SetHighlightTexture(WHITE)
            ib:GetHighlightTexture():SetVertexColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 0.5)
            ib.t = ib:CreateFontString(nil, "OVERLAY")
            ib.t:SetFont(STANDARD_TEXT_FONT, 11, "")
            ib.t:SetPoint("LEFT", 8, 0); ib.t:SetPoint("RIGHT", -6, 0); ib.t:SetJustifyH("LEFT")
            rows[i] = ib
        end
        local function draw()
            for i = 1, vis do
                local it, ib = items[i + off], rows[i]
                if it then
                    ib.t:SetText(it.text)
                    if it.value == get() then ib.t:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
                    else ib.t:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]) end
                    ib:SetScript("OnClick", function()
                        set(it.value); b.Refresh(); AT.CloseDropdown()
                        if onSelect then onSelect(it.value) end
                    end)
                    ib:Show()
                else ib:Hide() end
            end
        end
        list:SetScript("OnMouseWheel", function(_, d)
            off = math.min(maxOff, math.max(0, off - d * 3)); draw()
        end)
        draw()
        AT.openDropdown = list
    end)
    return b
end

--[[ WINDOW CHROME ===========================================================]]

-- Solid navy window, panel title bar ("Word1" cyan + rest light), boxed close,
-- draggable, resizable. minW/minH matter: these pages do not scroll, they CLIP.
-- Arc scroll region (canonized from Arc Pings): plain ScrollFrame, slim
-- 4px well-colored track on the right edge, proportional CYAN thumb that
-- only shows when there is overflow, mouse-wheel driven. Never use
-- UIPanelScrollFrameTemplate (stone buttons) in an Arc panel.
-- Returns host, content. Size the CONTENT's height after laying out its
-- children, then call host:UpdateScroll(). Pass an existing region (e.g.
-- a multiline EditBox) as `child` to scroll it instead of a new frame.
function AT.MakeScroll(parent, child)
    local host = CreateFrame("ScrollFrame", nil, parent)
    local content = child or CreateFrame("Frame", nil, host)
    if not child then content:SetSize(1, 1) end
    host:SetScrollChild(content)
    local track = CreateFrame("Frame", nil, host, "BackdropTemplate")
    track:SetWidth(4)
    track:SetPoint("TOPRIGHT", host, "TOPRIGHT", 2, 0)
    track:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 2, 0)
    Skin(track, COL.well, COL.well)
    local thumb = track:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(WHITE)
    thumb:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.85)
    thumb:SetPoint("TOPLEFT", 0, 0)
    thumb:SetPoint("TOPRIGHT", 0, 0)
    track:Hide()
    function host:UpdateScroll()
        local viewH = host:GetHeight() or 0
        local contentH = content:GetHeight() or 0
        local over = contentH - viewH
        if over <= 1 or viewH <= 0 then
            host:SetVerticalScroll(0)
            track:Hide()
            return
        end
        track:Show()
        local cur = math.min(host:GetVerticalScroll() or 0, over)
        if cur < 0 then cur = 0 end
        host:SetVerticalScroll(cur)
        local thumbH = math.max(20, viewH * (viewH / contentH))
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", 0, -(viewH - thumbH) * (cur / over))
        thumb:SetPoint("TOPRIGHT", 0, -(viewH - thumbH) * (cur / over))
    end
    host:EnableMouseWheel(true)
    host:SetScript("OnMouseWheel", function(_, delta)
        local viewH = host:GetHeight() or 0
        local over = ((content:GetHeight() or 0)) - viewH
        if over <= 0 then return end
        local cur = (host:GetVerticalScroll() or 0) - delta * 40
        if cur < 0 then cur = 0 elseif cur > over then cur = over end
        host:SetVerticalScroll(cur)
        host:UpdateScroll()
        AT.CloseDropdown()
    end)
    host:SetScript("OnSizeChanged", function() host:UpdateScroll() end)
    return host, content
end

function AT.CreateWindow(globalName, opts)
    opts = opts or {}
    local minW, minH = opts.minW or 400, opts.minH or 480
    local p = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    p:SetSize(math.max(minW, opts.w or 460), math.max(minH, opts.h or 540))
    p:SetPoint("CENTER", 0, 40)
    p:SetFrameStrata("DIALOG"); p:SetToplevel(true); p:SetClampedToScreen(true)
    p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", p.StopMovingOrSizing)
    p:SetScript("OnMouseDown", AT.CloseDropdown)
    p:SetScript("OnHide", AT.CloseDropdown)
    Skin(p, COL.bg, COL.line2)
    if globalName then tinsert(UISpecialFrames, globalName) end

    local bar = CreateFrame("Frame", nil, p, "BackdropTemplate")
    bar:SetPoint("TOPLEFT", 1, -1); bar:SetPoint("TOPRIGHT", -1, -1); bar:SetHeight(30)
    Skin(bar, COL.panel)
    local t1 = bar:CreateFontString(nil, "OVERLAY")
    t1:SetFont(STANDARD_TEXT_FONT, 14, ""); t1:SetPoint("LEFT", 12, 0)
    t1:SetText(opts.title or "|cff3fc9f2Arc|r|cffd5e2f2 Addon|r")
    if opts.version then
        local ver = bar:CreateFontString(nil, "OVERLAY")
        ver:SetFont(STANDARD_TEXT_FONT, 10, "")
        ver:SetPoint("LEFT", t1, "RIGHT", 8, -1)
        ver:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        ver:SetText(opts.version)
    end
    local close = CreateFrame("Button", nil, bar, "BackdropTemplate")
    close:SetSize(18, 18); close:SetPoint("RIGHT", -6, 0); Skin(close, COL.well, COL.line2)
    local cx = close:CreateFontString(nil, "OVERLAY")
    cx:SetFont(STANDARD_TEXT_FONT, 12, ""); cx:SetPoint("CENTER", 0, 0); cx:SetText("x")
    cx:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    close:SetScript("OnEnter", function()
        cx:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
        close:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    end)
    close:SetScript("OnLeave", function()
        cx:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        close:SetBackdropBorderColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
    end)
    close:SetScript("OnClick", function() p:Hide() end)
    p.titleBar, p.titleText = bar, t1

    if opts.resizable ~= false then
        p:SetResizable(true)
        if p.SetResizeBounds then p:SetResizeBounds(minW, minH, opts.maxW or 900, opts.maxH or 1000) end
        local grip = CreateFrame("Button", nil, p)
        grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -2, 2); grip:EnableMouse(true)
        local gt = grip:CreateTexture(nil, "OVERLAY")
        gt:SetAllPoints(); gt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        gt:SetVertexColor(COL.faint[1], COL.faint[2], COL.faint[3], 0.8)
        grip:SetScript("OnEnter", function() gt:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1) end)
        grip:SetScript("OnLeave", function() gt:SetVertexColor(COL.faint[1], COL.faint[2], COL.faint[3], 0.8) end)
        grip:SetScript("OnMouseDown", function()
            AT.CloseDropdown()
            -- PIN THE TOP-LEFT FIRST. A CENTER-anchored frame grows symmetrically,
            -- so sizing from the corner lurches the whole window.
            local l, t = p:GetLeft(), p:GetTop()
            if l and t then
                p:ClearAllPoints()
                p:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
            end
            p:StartSizing("BOTTOMRIGHT")
        end)
        grip:SetScript("OnMouseUp", function()
            p:StopMovingOrSizing()
            if opts.onResize then opts.onResize(p:GetWidth(), p:GetHeight()) end
            if p.RefreshActive then p:RefreshActive() end
        end)
    end
    -- windows spawn hidden: a toggle-style opener would otherwise close a
    -- brand-new window on its first use (ported from the canonical theme)
    p:Hide()
    return p
end

-- Chip tabs sitting on a CONTINUOUS cyan line. tabs = { "General", "Alerts" }.
-- Returns a select(name) function; pages are created by the caller via NewPage.
function AT.AddTabs(p, tabs, pages, y)
    y = y or -34
    p._tabs = {}
    local x = 10
    local function repaint(active)
        for name, d in pairs(p._tabs) do
            local sel = (name == active)
            pages[name]:SetShown(sel)
            if sel then
                Skin(d.chip, COL.panel, COL.arc)
                d.fs:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
                if pages[name].Refresh then pages[name]:Refresh() end
            else
                Skin(d.chip, COL.well, COL.line)
                d.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end
        p._activeTab = active
    end
    local function select(name) repaint(name) end
    for _, name in ipairs(tabs) do
        local tb = CreateFrame("Button", nil, p, "BackdropTemplate")
        tb:SetHeight(24)
        local fs = tb:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 12, ""); fs:SetPoint("CENTER"); fs:SetText(name)
        tb:SetWidth(math.max(70, (fs:GetStringWidth() or 40) + 22))
        tb:SetPoint("TOPLEFT", x, y); x = x + tb:GetWidth() + 3
        tb:SetScript("OnClick", function() AT.CloseDropdown(); select(name) end)
        tb:SetScript("OnEnter", function()
            if p._activeTab ~= name then
                tb:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1)
                fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
            end
        end)
        tb:SetScript("OnLeave", function()
            if p._activeTab ~= name then
                tb:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
                fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end)
        p._tabs[name] = { chip = tb, fs = fs }
    end
    local line = p:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    line:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    line:SetPoint("TOPLEFT", 10, y - 25); line:SetPoint("TOPRIGHT", -10, y - 25)
    line:SetHeight(1)
    p.SelectTab = select
    function p:RefreshActive()
        if self._activeTab and pages[self._activeTab] and pages[self._activeTab].Refresh then
            pages[self._activeTab]:Refresh()
        end
    end
    return select
end

--[[ ROW ENGINE ==============================================================]]

function AT.NewPage(parent)
    local pg = CreateFrame("Frame", nil, parent)
    pg._rows, pg._sections, pg._curSection = {}, {}, nil
    function pg:Refresh() AT.LayoutPage(self) end
    pg:Hide()
    return pg
end

function AT.AddRow(pg, h, visibleFn)
    local sec = pg._curSection
    local row = CreateFrame("Frame", nil, (sec and sec.box) or pg)
    h = h or LAY.rowH
    row:SetHeight(h); row._h = h; row._visibleFn = visibleFn
    row._ctrlX = (sec and sec.ctrlX) or LAY.ctrl
    if sec then sec.rows[#sec.rows + 1] = row else pg._rows[#pg._rows + 1] = row end
    return row
end

function AT.RowLabel(row, text)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 12, ""); fs:SetPoint("LEFT", 10, 0)
    fs:SetWordWrap(false); fs:SetJustifyH("LEFT")
    fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); fs:SetText(text)
    return fs
end

function AT.Tooltip(region, title, body)
    region:HookScript("OnEnter", function(self)
        local b = (type(body) == "function") and body() or body
        if not b or b == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine((type(title) == "function") and title() or title, 1, 1, 1)
        GameTooltip:AddLine(b, 0.75, 0.82, 0.92, true)
        GameTooltip:Show()
    end)
    region:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- COLLAPSIBLE SECTION. A 22px header bar the width of the box: title left,
-- Blizzard's own expand arrow pinned RIGHT (their CollapseButtonTemplate anchors
-- it RIGHT,-6 -- never beside the label), whole bar clickable. Collapsed, the bar
-- keeps a cyan underline so a shut section still reads as Arc.
--   opts = { visibleFn, side = "L"/"R", ctrlX, collapsible = false, store = table }
-- `store` is any table you own; the open/shut state is saved under the title.
function AT.Section(pg, text, opts)
    opts = opts or {}
    local titled = (text ~= nil and text ~= "")
    local box = CreateFrame("Frame", nil, pg, "BackdropTemplate")
    Skin(box, COL.box, COL.line)
    box:SetClipsChildren(true)
    local sec = {
        box = box, rows = {}, visibleFn = opts.visibleFn, side = opts.side,
        ctrlX = opts.ctrlX or LAY.ctrl, collapsed = false, f = 1, store = opts.store,
    }
    if titled and opts.collapsible then
        local bar = CreateFrame("Button", nil, pg, "BackdropTemplate")
        bar:SetHeight(LAY.hdr); Skin(bar, COL.panel, COL.line)
        local title = bar:CreateFontString(nil, "OVERLAY")
        title:SetFont(STANDARD_TEXT_FONT, 11, ""); title:SetPoint("LEFT", 9, 0)
        title:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3]); title:SetText(text)
        local arrow = bar:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(11, 11); arrow:SetPoint("RIGHT", -7, 0)
        local rule = bar:CreateTexture(nil, "OVERLAY")
        rule:SetTexture(WHITE)
        rule:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
        rule:SetPoint("BOTTOMLEFT", 1, 1); rule:SetPoint("BOTTOMRIGHT", -1, 1)
        rule:SetHeight(1); rule:Hide()
        sec.hit, sec.title, sec.arrow, sec.rule = bar, title, arrow, rule
        local function paint(hot)
            local c = hot and COL.ink or COL.arc
            title:SetTextColor(c[1], c[2], c[3])
            arrow:SetVertexColor(c[1], c[2], c[3], 1)
            local f = hot and COL.btnHover or COL.panel
            bar:SetBackdropColor(f[1], f[2], f[3], 1)
        end
        bar:SetScript("OnEnter", function() paint(true) end)
        bar:SetScript("OnLeave", function() paint(false) end)
        bar:SetScript("OnClick", function()
            AT.CloseDropdown()
            sec.collapsed = not sec.collapsed
            if sec.store then
                sec.store.secCollapsed = sec.store.secCollapsed or {}
                sec.store.secCollapsed[text] = sec.collapsed or nil
            end
            PlaySound(sec.collapsed and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF
                                     or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON, "Master")
            sec.page = pg
            AT.anims = AT.anims or {}
            AT.anims[sec] = true
            if not AT.animDriver then
                AT.animDriver = CreateFrame("Frame")
                AT.animDriver:SetScript("OnUpdate", function(drv, elapsed)
                    local pages, any = {}, false
                    for s in pairs(AT.anims) do
                        local target = s.collapsed and 0 or 1
                        local f = s.f or (1 - target)
                        local step = elapsed / 0.16
                        if f < target then f = math.min(target, f + step)
                        else f = math.max(target, f - step) end
                        s.f = f
                        if f == target then AT.anims[s] = nil else any = true end
                        if s.page then pages[s.page] = true end
                    end
                    for p2 in pairs(pages) do AT.LayoutPage(p2) end
                    -- ZERO IDLE COST: the driver dies the moment nothing moves
                    if not any then drv:SetScript("OnUpdate", nil); AT.animDriver = nil end
                end)
            end
        end)
        if sec.store and (sec.store.secCollapsed or {})[text] then
            sec.collapsed, sec.f = true, 0
        end
    elseif titled then
        local t = pg:CreateFontString(nil, "OVERLAY")
        t:SetFont(STANDARD_TEXT_FONT, 11, "")
        t:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3]); t:SetText(text)
        sec.title = t
    end
    pg._sections[#pg._sections + 1] = sec
    pg._curSection = sec
    return box
end

-- Flow rows, size each box to its VISIBLE rows, and place every single-control
-- row's control on ONE column measured per section.
function AT.LayoutPage(pg)
    if not (pg and pg._sections) then return end
    local y = pg._startY or -4
    for _, row in ipairs(pg._rows) do
        if row._sync then row._sync() end
        if (not row._visibleFn) or row._visibleFn() then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 2, y); row:SetPoint("TOPRIGHT", -2, y)
            row:Show(); y = y - row._h
        else row:Hide() end
    end
    local pairTopY, pairBottomY
    for _, sec in ipairs(pg._sections) do
        local side = sec.side
        if sec.visibleFn and not sec.visibleFn() then
            if sec.hit then sec.hit:Hide() end
            if sec.title then sec.title:Hide() end
            sec.box:Hide()
            if side == "L" then pairTopY, pairBottomY = y, y
            elseif side == "R" then pairTopY, pairBottomY = nil, nil end
        else
            local topY = (side == "R" and pairTopY) or y
            local hdrH = 0
            local function span(f, top)
                f:ClearAllPoints()
                if side == "L" then
                    f:SetPoint("TOPLEFT", 0, top); f:SetPoint("TOPRIGHT", pg, "TOP", -6, top)
                elseif side == "R" then
                    f:SetPoint("TOPLEFT", pg, "TOP", 6, top); f:SetPoint("TOPRIGHT", 0, top)
                else
                    f:SetPoint("TOPLEFT", 0, top); f:SetPoint("TOPRIGHT", 0, top)
                end
            end
            if sec.hit then
                span(sec.hit, topY); sec.hit:Show(); hdrH = LAY.hdr
                sec.arrow:SetAtlas(sec.collapsed and "Options_ListExpand_Right"
                                                  or "Options_ListExpand_Right_Expanded")
                sec.arrow:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
                sec.rule:SetShown(sec.collapsed)
            elseif sec.title then
                sec.title:ClearAllPoints()
                if side == "R" then sec.title:SetPoint("TOPLEFT", pg, "TOP", 10, topY - 2)
                else sec.title:SetPoint("TOPLEFT", 4, topY - 2) end
                sec.title:Show(); hdrH = 13
            end
            local boxTop = topY - hdrH
            span(sec.box, boxTop)

            -- CONTROL COLUMN, measured. Use the UNBOUNDED width: GetStringWidth
            -- reports the already-truncated width, so a truncated label would feed
            -- a smaller column back in on the next pass and ratchet down.
            local col
            for _, r in ipairs(sec.rows) do
                if r._colLabel and ((not r._visibleFn) or r._visibleFn()) then
                    local fs = r._colLabel
                    local w = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
                           or fs:GetStringWidth() or 0
                    w = 10 + w + 16
                    if not col or w > col then col = w end
                end
            end
            local by = -2
            for _, row in ipairs(sec.rows) do
                if row._sync then row._sync() end
                if (not row._visibleFn) or row._visibleFn() then
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", sec.box, "TOPLEFT", 6, by)
                    row:SetPoint("TOPRIGHT", sec.box, "TOPRIGHT", -6, by)
                    row:Show(); by = by - row._h
                else row:Hide() end
            end
            if col then
                local cap = (sec.box:GetWidth() or 400) - 34
                if col > cap then col = math.max(12, cap) end
                for _, r in ipairs(sec.rows) do
                    if r._colCtrl then
                        r._colCtrl:ClearAllPoints()
                        r._colCtrl:SetPoint("LEFT", r, "LEFT", col, 0)
                        -- _colFill = true: fill to the ROW's right edge
                        -- (inputs); a frame: stop at that frame (sliders)
                        if r._colFill == true then
                            r._colCtrl:SetPoint("RIGHT", r, "RIGHT", -12, 0)
                        elseif r._colFill then
                            r._colCtrl:SetPoint("RIGHT", r._colFill, "LEFT", -8, 0)
                        end
                        if r._colLabel then r._colLabel:SetPoint("RIGHT", r, "LEFT", col - 6, 0) end
                    end
                end
            end
            local fullH = math.max(10, -by + 3)
            local f = sec.f or 1
            local shownH = (f >= 1) and fullH or math.max(2, math.floor(fullH * f + 0.5))
            sec.box:SetShown(not (sec.collapsed and f <= 0))
            sec.box:SetHeight(shownH)
            local bottom = boxTop - (sec.box:IsShown() and shownH or 0) - LAY.gap
            if side == "L" then pairTopY, pairBottomY, y = topY, bottom, bottom
            elseif side == "R" then y = math.min(pairBottomY or bottom, bottom); pairTopY, pairBottomY = nil, nil
            else y = bottom end
        end
    end
    pg._contentH = -y + 8
end

--[[ ROW BUILDERS ============================================================]]

-- Checkbox sits NEXT TO its label (LayoutPage then column-aligns it), whole row
-- clickable, description as a hover TOOLTIP and never an inline row.
function AT.RowToggle(pg, label, get, set, visibleFn, desc)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local cb = AT.MakeCheckbox(row)
    cb:SetPoint("LEFT", lbl, "RIGHT", 14, 0)
    cb:SetOn(get())
    local function flip()
        AT.CloseDropdown()
        set(not get()); cb:SetOn(get())
        PlaySound(get() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                         or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
        AT.LayoutPage(pg)
    end
    cb:SetScript("OnClick", flip)
    row:EnableMouse(true); row:SetScript("OnMouseUp", flip)
    row:HookScript("OnEnter", function() cb:SetHover(true) end)
    row:HookScript("OnLeave", function() cb:SetHover(false) end)
    -- the checkbox is a child Button that EATS mouse events: hover glow and
    -- tooltip must be hooked on it too, or the toggle itself is a dead zone
    cb:HookScript("OnEnter", function() cb:SetHover(true) end)
    cb:HookScript("OnLeave", function() cb:SetHover(false) end)
    if desc then AT.Tooltip(row, label, desc); AT.Tooltip(cb, label, desc) end
    row._colLabel, row._colCtrl = lbl, cb
    row._sync = function() cb:SetOn(get()) end
    return row
end

-- desc and hint may each be a string OR a function (live text). hint draws dim
-- placeholder text INSIDE the box while empty: use it to show what is in effect
-- without PRE-FILLING, which would turn "I left it alone" into a saved value.
-- live = true commits on every USER keystroke/paste (not just focus lost), for
-- fields that feed a derived row (e.g. a link the next row transforms).
function AT.RowInput(pg, label, get, set, visibleFn, desc, hint, live)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local box = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    box:SetSize(LAY.fieldW, 18); box:SetPoint("RIGHT", -12, 0); Skin(box, COL.well)
    box:SetFont(STANDARD_TEXT_FONT, 11, ""); box:SetTextInsets(6, 6, 0, 0)
    box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); box:SetAutoFocus(false)
    box:SetText(get() or "")
    local hintFS
    if hint then
        hintFS = box:CreateFontString(nil, "OVERLAY")
        hintFS:SetFont(STANDARD_TEXT_FONT, 11, "")
        hintFS:SetPoint("LEFT", 6, 0); hintFS:SetPoint("RIGHT", -6, 0)
        hintFS:SetJustifyH("LEFT")
        hintFS:SetTextColor(COL.faint[1], COL.faint[2], COL.faint[3])
    end
    local function syncHint()
        if not hintFS then return end
        hintFS:SetText(((type(hint) == "function") and hint()) or hint or "")
        hintFS:SetShown((box:GetText() or "") == "")
    end
    syncHint()
    box:SetScript("OnTextChanged", function(self, userInput)
        syncHint()
        if live and userInput then set(self:GetText() or "") end
    end)
    -- the tooltip must be hooked on the BOX too: it is a child that eats mouse
    -- events, so a row-only hook shows nothing when you hover the field
    if desc then AT.Tooltip(row, label, desc); AT.Tooltip(box, label, desc) end
    local function commit() set(box:GetText() or ""); box:SetText(get() or ""); syncHint() end
    box:SetScript("OnEnterPressed", function() box:ClearFocus() end)
    box:SetScript("OnEscapePressed", function() box:SetText(get() or ""); box:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    box:SetScript("OnEditFocusLost", function() commit(); box:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    -- inputs sit on the measured control column like every other control,
    -- and FILL from the column to the row's right edge (true = row fill)
    row._colLabel, row._colCtrl, row._colFill = lbl, box, true
    row._sync = function()
        if not box:HasFocus() then box:SetText(get() or "") end
        syncHint()
    end
    return row
end

function AT.RowDropdown(pg, owner, label, get, set, itemsFn, visibleFn, onSelect)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local dd = AT.MakeDropdown(owner, row, nil, itemsFn, get, set, onSelect)
    dd:SetPoint("LEFT", row._ctrlX, 0)
    row._colLabel, row._colCtrl = lbl, dd
    row._sync = dd.Refresh
    return row
end

function AT.RowColor(pg, label, get, set, visibleFn)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local sw = AT.MakeSwatch(row)
    sw:SetPoint("LEFT", row._ctrlX, 0)
    local function refresh() sw:SetColor(get()) end
    refresh()
    sw:SetScript("OnClick", function()
        AT.CloseDropdown()
        local c = get()
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = c[1], g = c[2], b = c[3], hasOpacity = false,
                swatchFunc = function()
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    set({ r, g, b }); refresh()
                end,
                cancelFunc = function() set({ c[1], c[2], c[3] }); refresh() end,
            })
        end
    end)
    row._colLabel, row._colCtrl = lbl, sw
    row._sync = refresh
    return row
end

-- Slider FILLS the space between the column and the stepper, so it grows with
-- the box and never leaves dead air or clips in a narrow one.
function AT.RowSlider(pg, label, get, set, minV, maxV, step, isPct, visibleFn)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local s = CreateFrame("Slider", nil, row, "BackdropTemplate")
    local box = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    local settingUp = true
    local function fmt(v)
        v = tonumber(v) or 0
        if isPct then return ("%.0f"):format(v * 100)
        elseif step < 1 then return ("%.1f"):format(v)
        else return ("%d"):format(math.floor(v + 0.5)) end
    end
    local function clamp(v)
        if v < minV then v = minV elseif v > maxV then v = maxV end
        if step >= 1 then v = math.floor(v + 0.5) end
        return v
    end
    local function refresh()
        settingUp = true
        s:SetValue(math.max(minV, math.min(maxV, get() or 0)))
        if not box:HasFocus() then box:SetText(fmt(get() or 0)) end
        settingUp = false
    end
    local function setVal(v) set(clamp(v)); refresh() end
    local function arrow(glyph, delta)
        local b = CreateFrame("Button", nil, row, "BackdropTemplate")
        b:SetSize(14, 14); Skin(b, COL.well)
        local g = b:CreateFontString(nil, "OVERLAY")
        g:SetFont(STANDARD_TEXT_FONT, 11, ""); g:SetPoint("CENTER")
        g:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3]); g:SetText(glyph)
        b:SetScript("OnClick", function() AT.CloseDropdown(); setVal((get() or minV) + delta) end)
        b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
        b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
        return b
    end
    local plus = arrow("+", step)
    local minus = arrow("-", -step)
    box:SetSize(38, 16); Skin(box, COL.well)
    box:SetFont(STANDARD_TEXT_FONT, 11, "")
    box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    box:SetJustifyH("CENTER"); box:SetAutoFocus(false)
    local function commitTyped(self)
        local n = tonumber(self:GetText())
        if n then if isPct then n = n / 100 end setVal(n) else refresh() end
    end
    box:SetScript("OnEnterPressed", function(self) commitTyped(self); self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", commitTyped)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    plus:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    box:SetPoint("RIGHT", plus, "LEFT", -2, 0)
    minus:SetPoint("RIGHT", box, "LEFT", -2, 0)
    s:SetOrientation("HORIZONTAL"); s:SetHeight(10)
    s:SetPoint("LEFT", row._ctrlX, 0)
    s:SetPoint("RIGHT", minus, "LEFT", -8, 0)
    Skin(s, COL.well)
    s:SetThumbTexture(WHITE)
    local th = s:GetThumbTexture()
    th:SetSize(8, 10); th:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    s:SetMinMaxValues(minV, maxV); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
    s:SetScript("OnValueChanged", function(_, v)
        if settingUp then return end
        if step >= 1 then v = math.floor(v + 0.5) end
        if not box:HasFocus() then box:SetText(fmt(v)) end
        set(v)
    end)
    refresh()
    row._colLabel, row._colCtrl, row._colFill = lbl, s, minus
    row._sync = refresh
    return row
end

function AT.RowButton(pg, label, onClick, visibleFn, w)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local b = AT.MakeSmallButton(row, label, w or 150)
    b:SetPoint("LEFT", 12, 0)
    b:SetScript("OnClick", function() AT.CloseDropdown(); onClick() end)
    row.button = b
    return row
end

function AT.RowDesc(pg, text, h, visibleFn)
    local row = AT.AddRow(pg, h or LAY.descH, visibleFn)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 10, "")
    fs:SetPoint("LEFT", 10, 1); fs:SetPoint("RIGHT", -10, 1)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3]); fs:SetText(text)
    return row
end

--[[ DISCORD FOOTER ==========================================================]]

-- Addons cannot open URLs, so the button shows a copy popup with the invite
-- selected for Ctrl+C. Reserve ~34px at the window bottom for the footer band.
function AT.AddDiscordFooter(p, globalName)
    local line = p:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    line:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 1)
    line:SetPoint("BOTTOMLEFT", 10, 32); line:SetPoint("BOTTOMRIGHT", -10, 32)
    line:SetHeight(1)
    local b = CreateFrame("Button", nil, p, "BackdropTemplate")
    b:SetSize(84, 20); b:SetPoint("BOTTOMLEFT", 10, 9); Skin(b, COL.well)
    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 11, ""); fs:SetPoint("CENTER")
    fs:SetText("|cff7289DADiscord|r")
    local hint = p:CreateFontString(nil, "OVERLAY")
    hint:SetFont(STANDARD_TEXT_FONT, 11, "")
    hint:SetPoint("LEFT", b, "RIGHT", 10, 0)
    hint:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    hint:SetText("Questions or help? Join the Arc UI Discord")
    b:SetScript("OnEnter", function()
        b:SetBackdropBorderColor(COL.blurple[1], COL.blurple[2], COL.blurple[3], 1)
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
    end)
    b:SetScript("OnClick", function()
        if not AT.copyPopup then
            local d = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
            d:SetSize(300, 70); d:SetFrameStrata("FULLSCREEN_DIALOG"); d:SetToplevel(true)
            Skin(d, COL.panel, COL.arc)
            local t = d:CreateFontString(nil, "OVERLAY")
            t:SetFont(STANDARD_TEXT_FONT, 12, ""); t:SetPoint("TOP", 0, -10)
            t:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
            t:SetText("Press Ctrl+C to copy, then open it in your browser")
            local eb = CreateFrame("EditBox", nil, d, "BackdropTemplate")
            eb:SetSize(272, 22); eb:SetPoint("TOP", 0, -32); Skin(eb, COL.well)
            eb:SetFont(STANDARD_TEXT_FONT, 12, ""); eb:SetTextInsets(6, 6, 0, 0)
            eb:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); eb:SetAutoFocus(false)
            eb:SetScript("OnEscapePressed", function() d:Hide() end)
            eb:SetScript("OnEnterPressed", function() d:Hide() end)
            eb:SetScript("OnEditFocusLost", function() d:Hide() end)
            if globalName then tinsert(UISpecialFrames, globalName) end
            d.box = eb; AT.copyPopup = d
        end
        AT.copyPopup:ClearAllPoints()
        AT.copyPopup:SetPoint("CENTER", p, "CENTER", 0, 0)
        AT.copyPopup:Show(); AT.copyPopup:Raise()
        AT.copyPopup.box:SetText(AT.DISCORD)
        AT.copyPopup.box:SetFocus(); AT.copyPopup.box:HighlightText()
    end)
    return b
end

-- exported via NS.AT (WoW discards file return values)
