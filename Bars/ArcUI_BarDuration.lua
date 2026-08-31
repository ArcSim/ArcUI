-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Bar Duration Driver  (12.1 ONLY)
--
-- On 12.1 an addon cannot read an aura's remaining duration (the C_UnitAuras
-- durObj APIs throw while tainted+secret), so a duration bar can't be driven the
-- way stack bars are (SetValue of a static secret count). The ONLY object that
-- can legally hold an aura durObj is a Blizzard AuraButton. So we borrow one as an
-- INVISIBLE ENGINE: for each aura duration bar we add an AuraSlot filtered to the
-- CDM entry's candidate spell IDs, whose AuraButton drives our EXISTING bar's
-- StatusBar (SetDurationBar) and, if enabled, our countdown FontString
-- (SetDurationText). The button draws nothing; the container is invisible. So the
-- bar and every appearance option stay ours; only the fill VALUE is driven.
--
-- SPELL-ID RESOLUTION (critical): the buff can land on ANY of base spellID +
-- overrideSpellID + overrideTooltipSpellID + linkedSpellIDs -- info.spellID alone is
-- the CAST spell, not the buff. We resolve the WHOLE candidate set from the CDM
-- cooldownID via C_CooldownViewer.GetCooldownViewerCooldownInfo (C API, taint-safe).
--
-- LANES (multi-unit): every attach carries a list of (unit, filter) lanes --
-- resolved by ns.Display.ResolveAuraLanes from the bar's Type + On settings,
-- or synthesized as the single legacy lane (buff -> player/HELPFUL, debuff ->
-- target/HARMFUL|PLAYER) when the caller passes none. Each lane gets its own
-- slot composition in that unit's container, all driving the same bar;
-- whichever unit actually holds the aura populates and drives it, the others
-- stay empty (hidden by the engine) -- the set reads as an OR, the aura
-- icons' proven model. The CDM frame's auraDataUnit is never trusted for
-- routing (selfAura is not a routing flag; Flame Shock reports "player" yet
-- lives on the target).
--
-- Inert on live: the AuraContainer/AuraButton intrinsics don't exist on 12.0.x.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local BD = {}
ns.BarDuration = BD

local IS_121 = (ns.API and ns.API.IS_121) or false
function BD.IsAvailable() return IS_121 end

-- Per-bar trace of what Display saw (populated on live + 12.1 so /arcbardur is always useful).
BD.lastTrace = {}
function BD.Trace(barNumber, info) BD.lastTrace[barNumber] = info end

-- Resolve the FULL candidate spell-ID set a CDM entry's buff can land on. Taint-safe (C API +
-- plain field reads). base + overrideSpellID + overrideTooltipSpellID + linkedSpellIDs + any
-- explicit trackedSpellID. Usable on live too (C_CooldownViewer exists); only ever CALLED on 12.1.
function BD.ResolveCandidateSpellIDs(cooldownID, trackedSpellID)
  local set = {}
  if trackedSpellID and trackedSpellID > 0 then set[trackedSpellID] = true end
  if cooldownID and cooldownID > 0 and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
    if info then
      if info.spellID and info.spellID > 0 then set[info.spellID] = true end
      if info.overrideSpellID and info.overrideSpellID > 0 then set[info.overrideSpellID] = true end
      if info.overrideTooltipSpellID and info.overrideTooltipSpellID > 0 then set[info.overrideTooltipSpellID] = true end
      if info.linkedSpellIDs then
        for _, id in ipairs(info.linkedSpellIDs) do
          if id and id > 0 then set[id] = true end
        end
      end
    end
  end
  return set
end

local function SetKeys(set)
  local t = {}
  for id in pairs(set) do t[#t + 1] = id end
  return table.concat(t, ",")
end

local function SameSet(a, b)
  if not (a and b) then return false end
  local n = 0
  for k in pairs(a) do
    if not b[k] then return false end
    n = n + 1
  end
  for _ in pairs(b) do n = n - 1 end
  return n == 0
end

if not IS_121 then
  function BD.Attach() end
  function BD.Detach() end
  function BD.DetachAll() end
  function BD.ApplyStyle() end
  SLASH_ARCBARDUR1 = "/arcbardur"
  SlashCmdList["ARCBARDUR"] = function()
    print("|cff33ff99[ArcBarDur]|r not a 12.1 client -- driver inert (stack bars unaffected).")
    for bn, t in pairs(BD.lastTrace) do
      print(("  bar %s: active=%s hasAuraInfo=%s cooldownID=%s trackedSpellID=%s secret=%s"):format(
        tostring(bn), tostring(t.active), tostring(t.hasAuraInfo), tostring(t.cooldownID), tostring(t.trackedSpellID), tostring(t.secret)))
    end
  end
  return
end

-- ── debug logging ─────────────────────────────────────────────────────────
-- OFF COSTS NOTHING. Attach runs on every refresh of every bar, so formatting
-- a string and a timestamp per call was real garbage in normal play -- the
-- whole function early-outs unless the user turned debug on (persisted, so a
-- login-window capture is still possible). The log window is a copyable
-- EditBox (probe-GUI rule: debug output must be copy-paste-able).
BD.debug = false
BD.logBuf = {}                      -- exposed so the (unshipped) debug tool can read it
local logBuf, LOG_MAX = BD.logBuf, 300
local logWin, logEdit
local function Log(fmt, ...)
  local tap = ns.TraceTap
  if not BD.debug and not tap then return end
  local msg = (select("#", ...) > 0) and fmt:format(...) or fmt
  if tap then tap("BD", msg) end
  if not BD.debug then return end
  logBuf[#logBuf + 1] = date("%H:%M:%S ") .. msg
  if #logBuf > LOG_MAX then table.remove(logBuf, 1) end
  -- NEVER to chat by default: this logs on every refresh of every bar, which
  -- buries the chat window and hides the very lines worth reading. The buffer
  -- above always records; "/arcbardur log" shows it, and chat echo is opt-in
  -- with "/arcbardur chat".
  if BD.debugChat then print("|cff33ff99[ArcBarDur]|r " .. msg) end
  if logEdit and logWin and logWin:IsShown() then
    logEdit:SetText(table.concat(logBuf, "\n"))
  end
end

local function ToggleLogWindow()
  if not logWin then
    logWin = CreateFrame("Frame", "ArcBarDurLog", UIParent, "BackdropTemplate")
    logWin:SetSize(560, 340)
    logWin:SetPoint("CENTER")
    logWin:SetFrameStrata("DIALOG")
    logWin:SetMovable(true); logWin:EnableMouse(true); logWin:RegisterForDrag("LeftButton")
    logWin:SetScript("OnDragStart", logWin.StartMoving)
    logWin:SetScript("OnDragStop", logWin.StopMovingOrSizing)
    logWin:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    logWin:SetBackdropColor(0, 0, 0, 0.9)
    local title = logWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -8)
    title:SetText("ArcBarDur log (Ctrl+C after Select All)")
    local close = CreateFrame("Button", nil, logWin, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    local sf = CreateFrame("ScrollFrame", "ArcBarDurLogScroll", logWin, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 10, -28)
    sf:SetPoint("BOTTOMRIGHT", -30, 38)
    logEdit = CreateFrame("EditBox", nil, sf)
    logEdit:SetMultiLine(true)
    logEdit:SetAutoFocus(false)
    logEdit:SetFontObject("ChatFontNormal")
    logEdit:SetWidth(500)
    logEdit:EnableMouse(true)
    logEdit:SetScript("OnEscapePressed", logEdit.ClearFocus)
    sf:SetScrollChild(logEdit)
    local sel = CreateFrame("Button", nil, logWin, "UIPanelButtonTemplate")
    sel:SetSize(180, 22)
    sel:SetPoint("BOTTOMLEFT", 10, 10)
    sel:SetText("Select all (then Ctrl+C)")
    sel:SetScript("OnClick", function() logEdit:SetFocus(); logEdit:HighlightText() end)
    local clr = CreateFrame("Button", nil, logWin, "UIPanelButtonTemplate")
    clr:SetSize(90, 22)
    clr:SetPoint("LEFT", sel, "RIGHT", 6, 0)
    clr:SetText("Clear")
    clr:SetScript("OnClick", function() wipe(logBuf); logEdit:SetText("") end)
  end
  logWin:SetShown(not logWin:IsShown())
  if logWin:IsShown() then
    logEdit:SetText(table.concat(logBuf, "\n"))
  end
end

local diag = { attachCall = 0, containerNew = 0, slotNew = 0, slotRetarget = 0, initFired = 0, combatDefer = 0, badArgs = 0,
               prebuild = 0, emptySet = 0 }
BD.diag = diag

-- Cached plain-decimal formatters so the engine countdown honours the bar's "Decimals" option
-- (e.g. "10.0" / "10") instead of the engine default ("10 s").
local durFormatters = {}
local function GetDurFormatter(decimals)
  decimals = decimals or 1
  local f = durFormatters[decimals]
  if not f and C_StringUtil and C_StringUtil.CreateNumericRuleFormatter then
    f = C_StringUtil.CreateNumericRuleFormatter()
    f:AddBreakpoint({ threshold = 0, format = "%." .. decimals .. "f" })
    durFormatters[decimals] = f
  end
  return f
end

-- ── state ─────────────────────────────────────────────────────────────────
local containers    = {}   -- [ownerFrame] -> { [unit] -> AuraContainer }
local attached      = {}   -- [barFrame] -> { idKey, cooldownID, spellIDs, subs = {...}, decimals, ... }
local pending       = {}   -- [barFrame] -> { fs, cooldownID, trackedSpellID, unit, opts }
local styleDeferred = {}   -- [barFrame] -> packed ApplyStyle args (buttons forbidden -> re-run on regen)
local seq           = 0

-- PTR7+ (build > 68675): aura containers can be created IN COMBAT -- the
-- reload-mid-combat gap is closed. Pre-PTR7 creation throws, so the combat
-- defer stays as the fallback gate for older 12.1 builds.
local COMBAT_CREATE_OK = (tonumber((select(2, GetBuildInfo()))) or 0) > 68675

-- One AuraContainer per OWNER FRAME per unit, PARENTED to the owner: the
-- engine buttons (container children) then inherit EVERY visibility path the
-- owner has -- Hide When conditions, spec hides, hideWhenInactive, alpha
-- fades, enable toggles -- with zero button touches. That is the only
-- combat-safe way to hide the overlay: the buttons themselves are FORBIDDEN
-- while auras are secret, but hiding OUR bar frame is always legal. A hidden
-- container stops processing and refreshes itself on OnShow (documented
-- refresh trigger). Pre-PTR7: created out of combat only (in-combat creation
-- is a Lua error); guarded, so no pcall. 12.1-only (IS_121 above).
local function EnsureContainer(unit, owner)
  owner = owner or UIParent
  local perOwner = containers[owner]
  if not perOwner then perOwner = {}; containers[owner] = perOwner end
  local c = perOwner[unit]
  if c then return c end
  if InCombatLockdown() and not COMBAT_CREATE_OK then Log("EnsureContainer(%s): in combat, deferred", unit); return nil end
  c = CreateFrame("AuraContainer", nil, owner, "CustomAuraContainerTemplate")
  if not c then Log("EnsureContainer(%s): CreateFrame returned nil", unit); return nil end
  if c.SetUnit then c:SetUnit(unit) end
  if c.SetEnabled then c:SetEnabled(true) end
  c:ClearAllPoints()
  c:SetPoint("CENTER", owner, "CENTER", 0, 0)
  c:SetSize(1, 1)
  c:Show()   -- must be shown+enabled to self-register UNIT_AURA
  perOwner[unit] = c
  diag.containerNew = diag.containerNew + 1
  Log("EnsureContainer(%s): CREATED (per-owner, parent-inherits visibility)", unit)
  return c
end

-- THRESHOLD BAND overlays (stack bars): a band sub's ArcBar is anchored to a
-- FRACTION of the bar (widthFrac = T/maxStacks) with maxApplications = T, so
-- its fill edge tracks the base fill exactly (W*T/max * count/T = W*count/max)
-- and SATURATES at the band boundary -- painting the fill region below T in
-- the band's color with ZERO count reads. Geometry re-asserted on refresh
-- (bar resizes) while not secret.
local function ReassertBandWidth(sub, barFrame)
  local ab = sub.arcBar
  if not (ab and sub.widthFrac and barFrame.bar) then return end
  local vertical = barFrame.bar.GetOrientation and barFrame.bar:GetOrientation() == "VERTICAL"
  local rev = barFrame.bar.GetReverseFill and barFrame.bar:GetReverseFill()
  ab:ClearAllPoints()
  if vertical then
    local p1 = rev and "TOPLEFT" or "BOTTOMLEFT"
    local p2 = rev and "TOPRIGHT" or "BOTTOMRIGHT"
    ab:SetPoint(p1, barFrame.bar, p1, 0, 0)
    ab:SetPoint(p2, barFrame.bar, p2, 0, 0)
    ab:SetHeight(math.max(1, (barFrame.bar:GetHeight() or 1) * sub.widthFrac))
  else
    local p1 = rev and "TOPRIGHT" or "TOPLEFT"
    local p2 = rev and "BOTTOMRIGHT" or "BOTTOMLEFT"
    ab:SetPoint(p1, barFrame.bar, p1, 0, 0)
    ab:SetPoint(p2, barFrame.bar, p2, 0, 0)
    ab:SetWidth(math.max(1, (barFrame.bar:GetWidth() or 1) * sub.widthFrac))
  end
end

-- CONTINUOUS STEP overlays (stack bars, whole-fill color switch): TWO slots
-- per threshold T in the bar's shared container. Adversarially verified math
-- (X = snapped threshold coordinate, ONE formula for both so the seam is
-- exact):
--   P ("upper", maxApplications = maxStacks): plain full-bar fill, masked to
--     [X..end] -> paints [T..count]. Inherits the bar's interpolation so its
--     edge tracks the base fill.
--   Q ("lower", maxApplications = T): ArcBar (T+1)*X long, fill-direction END
--     at X, overhanging backwards past the bar origin, masked to [0..X].
--     Coverage is empty through T-1 (one-window margin) and full at T.
--     Immediate interpolation (a smoothed sweep would transiently paint the
--     wrong region; the flip pops while P's edge animates). Q fills in the
--     SAME direction as the bar (anchoring is positional only).
-- Union = the whole fill [0..count] recolored iff count >= T.
--
-- IN-HIERARCHY MASK is the clip mechanism. Ancestor clipping is PROVEN DEAD:
-- an engine aura button renders NOTHING when any ancestor has
-- SetClipsChildren(true) (v3 -- and the base container, parented to our bar
-- frame WITHOUT clipping, renders fine, so parenting is not the issue).
-- Anchoring a clip window to the engine fill TEXTURE rect was equally dead
-- (v1). What DOES work in the button partition: objects CREATED ON THE
-- BUTTON (the ownChrome frames prove it). So each step overlay masks its own
-- ArcBar fill with a MaskTexture created on its button and anchored to that
-- button -- the button is SetAllPoints(barFrame.bar), so button coordinates
-- ARE bar coordinates and the mask rect is exact.
local function EnsureStepMask(button)
  local m = button._arcStepMask
  if not m then
    m = button:CreateMaskTexture(nil, "BACKGROUND")
    -- CLAMPTOBLACKADDITIVE = everything outside the mask rect is masked out.
    -- "NEAREST" is MANDATORY: the default bilinear filter fades the outer
    -- HALF TEXEL of this 8x8 texture, which stretched over a ~200px bar is
    -- ~12px of soft edge -- the overlay faded out near its boundaries and
    -- the base colour bled through (the green-tinted-yellow report).
    m:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "NEAREST")
    m:SetSnapToPixelGrid(false)
    m:SetTexelSnappingBias(0)
    button._arcStepMask = m
  end
  return m
end

-- Mask rect + (Q only) the overhanging ArcBar geometry. Both derived from
-- OUR bar's readable size; X is the single snapped seam coordinate.
local function ReassertStepGeometry(sub, barFrame)
  if not (sub.stepKind and barFrame.bar and sub.button) then return end
  local bar, btn = barFrame.bar, sub.button
  local vertical = bar.GetOrientation and bar:GetOrientation() == "VERTICAL"
  local rev = (bar.GetReverseFill and bar:GetReverseFill()) or false
  local size = vertical and (bar:GetHeight() or 0) or (bar:GetWidth() or 0)
  -- see ReassertDurGeometry: an unanchored mask hides the whole fill
  if size <= 1 then
    -- Geometry unresolvable (bar not sized yet). Do NOT hide the layer: the
    -- repair pass is gated on auras being non-secret, which on 12.1 never
    -- happens, so a hidden layer stays hidden for the session. Leave the mask
    -- covering everything instead -- an unmasked overlay is wrong-looking,
    -- a permanently invisible one is a dead bar.
    local m = sub.stepMask
    if m and sub.button then
      m:ClearAllPoints()
      m:SetPoint("TOPLEFT", sub.button, "TOPLEFT", -400, 400)
      m:SetPoint("BOTTOMRIGHT", sub.button, "BOTTOMRIGHT", 400, -400)
      m:Show()
    end
    sub.geomPending = true
    return
  end
  sub.geomPending = nil
  local scale = barFrame:GetEffectiveScale()
  local _, ph = GetPhysicalScreenSize()
  local onePx = (ph and ph > 0 and scale and scale > 0) and (768 / ph) / scale or 1
  local X = math.floor((size * sub.stepFrac) / onePx + 0.5) * onePx
  local upper = sub.stepKind == "upper"

  -- MASK: [X..end] for P, [0..X] for Q -- measured from the FILL ORIGIN.
  -- PAD every edge that must NOT cut anything far outside the bar, so the
  -- only real boundary is the threshold seam; the two masks OVERLAP by 1px
  -- there (both paint the same colour, so overlap is free -- a gap is not).
  -- Q's origin-side edge is the one exception: it must cut hard at the bar
  -- origin or the overhang leaks outside the bar.
  local m = sub.stepMask
  if m then
    local PAD, OVER = 400, onePx
    m:ClearAllPoints()
    if vertical then
      if rev then   -- origin TOP, grows down
        if upper then
          m:SetPoint("TOPLEFT", btn, "TOPLEFT", -PAD, -(X - OVER)); m:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", PAD, -PAD)
        else
          m:SetPoint("TOPLEFT", btn, "TOPLEFT", -PAD, 0);           m:SetPoint("BOTTOMRIGHT", btn, "TOPRIGHT", PAD, -(X + OVER))
        end
      else          -- origin BOTTOM, grows up
        if upper then
          m:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -PAD, X - OVER); m:SetPoint("TOPRIGHT", btn, "TOPRIGHT", PAD, PAD)
        else
          m:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -PAD, 0);        m:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", PAD, X + OVER)
        end
      end
    else
      if rev then   -- origin RIGHT, grows left
        if upper then
          m:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -(X - OVER), PAD); m:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -PAD, -PAD)
        else
          m:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, PAD);           m:SetPoint("BOTTOMLEFT", btn, "BOTTOMRIGHT", -(X + OVER), -PAD)
        end
      else          -- origin LEFT, grows right
        if upper then
          m:SetPoint("TOPLEFT", btn, "TOPLEFT", X - OVER, PAD); m:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", PAD, -PAD)
        else
          m:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, PAD);        m:SetPoint("BOTTOMRIGHT", btn, "BOTTOMLEFT", X + OVER, -PAD)
        end
      end
    end
    m:Show()
  end

  if upper then return end   -- P keeps the plain full-bar rect

  -- Q: fill-direction END at X + E, overhanging (T+1)*X backwards past the
  -- bar origin (the masked-away part). Coverage of [0..X] is empty through
  -- T-1 and full at T.
  --
  -- E = OVERSHOOT past the threshold, masked away. Bar textures bake darker
  -- pixels into their END caps, and the fill's texture terminates at the
  -- fill edge -- with E = 0 that dark cap landed exactly on the threshold
  -- stack (the "darker at the changing stack" report). Overshooting puts the
  -- cap outside the mask so only clean interior texture shows.
  -- Emptiness at T-1 requires E <= X/(T-1); half that keeps the margin.
  local ab = sub.arcBar
  if not ab then return end
  local T = sub.stepT
  local E = X / (2 * math.max(T - 1, 1))
  local L = math.max(1, (T + 1) * X + E)
  ab:ClearAllPoints()
  if vertical then
    if rev then
      ab:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, -(X + E))
      ab:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, -(X + E))
    else
      ab:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, X + E)
      ab:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, X + E)
    end
    ab:SetHeight(L)
  else
    if rev then
      ab:SetPoint("TOPLEFT", bar, "TOPRIGHT", -(X + E), 0)
      ab:SetPoint("BOTTOMLEFT", bar, "BOTTOMRIGHT", -(X + E), 0)
    else
      ab:SetPoint("TOPRIGHT", bar, "TOPLEFT", X + E, 0)
      ab:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT", X + E, 0)
    end
    ab:SetWidth(L)
  end
end

-- BUTTON-OWNED CHROME (Hide When Inactive, ownership model): the bar's
-- background + border are built as CHILDREN OF THE BUTTON (the aura icons'
-- proven pattern -- CreateFrame on the button), so the ENTIRE visible bar --
-- fill, texts, chrome -- shows and hides with the aura NATIVELY. Zero
-- presence reads, zero hooks: the engine's visibility boolean is SECRET
-- (ApplyVisibility does SetShown(secretwrap(...)); Show is never called) and
-- must never be observed. Our barFrame stays SHOWN as the invisible
-- container host. Callers gate on aura secrecy (buttons are forbidden then);
-- wiring-time application is always legal.
local function ApplyOwnChromeToButton(button, oc)
  local ch = button._arcChrome
  if not oc then
    if ch then
      ch.bgHost:Hide(); ch.borderHost:Hide()
      if ch.nameHost then ch.nameHost:Hide() end
    end
    return
  end
  if not ch then
    ch = {}
    button._arcChrome = ch
    ch.bgHost = CreateFrame("Frame", nil, button)
    ch.bgHost:SetAllPoints(button)
    ch.bg = ch.bgHost:CreateTexture(nil, "BACKGROUND")
    ch.bg:SetAllPoints()
    ch.bg:SetSnapToPixelGrid(false); ch.bg:SetTexelSnappingBias(0)
    ch.borderHost = CreateFrame("Frame", nil, button)
    ch.borderHost:SetAllPoints(button)
    for _, k in ipairs({ "top", "bottom", "left", "right" }) do
      local t = ch.borderHost:CreateTexture(nil, "OVERLAY")
      t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0)
      ch[k] = t
    end
  end
  ch.bgHost:SetFrameLevel(button:GetFrameLevel())           -- below the ArcBar child frame
  -- +10: must clear EVERY overlay fill (band/step buttons sit at bar+1+boost,
  -- boost up to 5, their ArcBars one higher -- +3 tied at 2 thresholds and
  -- was overdrawn beyond that; level-audit finding)
  ch.borderHost:SetFrameLevel(button:GetFrameLevel() + 10)
  if oc.bgShown then
    local c = oc.bgColor
    if oc.bgTexture then
      ch.bg:SetTexture(oc.bgTexture); ch.bg:SetVertexColor(c.r, c.g, c.b, c.a or 1)
    else
      ch.bg:SetColorTexture(c.r, c.g, c.b, c.a or 1)
    end
    ch.bgHost:Show()
  else
    ch.bgHost:Hide()
  end
  if oc.borderShown then
    local bc, px = oc.borderColor, oc.borderPx or 1
    ch.top:ClearAllPoints()
    ch.top:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0); ch.top:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    ch.top:SetHeight(px)
    ch.bottom:ClearAllPoints()
    ch.bottom:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0); ch.bottom:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    ch.bottom:SetHeight(px)
    ch.left:ClearAllPoints()
    ch.left:SetPoint("TOPLEFT", button, "TOPLEFT", 0, -px); ch.left:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, px)
    ch.left:SetWidth(px)
    ch.right:ClearAllPoints()
    ch.right:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, -px); ch.right:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, px)
    ch.right:SetWidth(px)
    for _, k in ipairs({ "top", "bottom", "left", "right" }) do
      ch[k]:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1); ch[k]:Show()
    end
  else
    ch.top:Hide(); ch.bottom:Hide(); ch.left:Hide(); ch.right:Hide()
  end

  -- TICK MARKS (chrome copy of UpdateTickMarks' simple-mode math; positions
  -- are precomputed, snapped px offsets from the fill origin -- Display owns
  -- the config math). Drawn under the border strips (OVERLAY sublevel 5 vs 7).
  local ticks = oc.ticks
  local pool = ch.ticks
  if not pool then pool = {}; ch.ticks = pool end
  local n = (ticks and ticks.positions and #ticks.positions) or 0
  for i = 1, n do
    local t = pool[i]
    if not t then
      t = ch.borderHost:CreateTexture(nil, "OVERLAY")
      t:SetDrawLayer("OVERLAY", 5)
      t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0)
      pool[i] = t
    end
    local tc = ticks.color
    t:SetColorTexture(tc.r or 0, tc.g or 0, tc.b or 0, tc.a or 1)
    t:ClearAllPoints()
    if ticks.vertical then
      t:SetSize(ticks.spanPx, ticks.thicknessPx)
      if ticks.reverse then
        t:SetPoint("TOP", button, "TOP", 0, -ticks.positions[i])
      else
        t:SetPoint("BOTTOM", button, "BOTTOM", 0, ticks.positions[i])
      end
    else
      t:SetSize(ticks.thicknessPx, ticks.spanPx)
      if ticks.reverse then
        t:SetPoint("RIGHT", button, "RIGHT", -ticks.positions[i], 0)
      else
        t:SetPoint("LEFT", button, "LEFT", ticks.positions[i], 0)
      end
    end
    t:Show()
  end
  for i = n + 1, #pool do pool[i]:Hide() end

  ch.borderHost:SetShown(oc.borderShown or n > 0)

  -- NAME TEXT (chrome copy of the native nameFrame -- recipe built by
  -- Display's BuildOwnChromeName). Hosted on a button child so it shows and
  -- hides with the aura natively; anchored by the recipe's offset from the
  -- button center (button coordinates ARE fill coordinates). Without this the
  -- engine-owned bar rendered NAMELESS: the native nameFrame is suppressed
  -- while the engine owns the chrome, and nothing carried the name over.
  local nm = oc.name
  if nm then
    local host = ch.nameHost
    if not host then
      host = CreateFrame("Frame", nil, button)
      host:SetAllPoints(button)
      ch.nameHost = host
      ch.name = host:CreateFontString(nil, "OVERLAY")
      ch.name:SetDrawLayer("OVERLAY", 6)
    end
    -- +11: one decisive level above the border strips' host (+10) so the
    -- name clears the border and every overlay fill
    host:SetFrameLevel(button:GetFrameLevel() + 11)
    local fs = ch.name
    -- SetFont returns false on a bad path (it does not raise) -- fall back
    if not fs:SetFont(nm.fontPath, nm.fontSize or 14, nm.fontFlags or "OUTLINE") then
      fs:SetFont("Fonts\\FRIZQT__.TTF", nm.fontSize or 14, "OUTLINE")
    end
    fs:SetShadowOffset(nm.shadowX or 1, nm.shadowY or -1)
    local sc = nm.shadowColor or { r = 0, g = 0, b = 0, a = 1 }
    fs:SetShadowColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 1)
    local c = nm.color or { r = 1, g = 1, b = 1, a = 1 }
    fs:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
    fs:SetText(nm.text)
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", button, "CENTER", nm.dx or 0, nm.dy or 0)
    host:Show()
  elseif ch.nameHost then
    ch.nameHost:Hide()
  end
end

-- Live chrome sync for an already-attached bar (Hide When Inactive toggled,
-- appearance edits, options panel open/close). Desk-time only: buttons are
-- forbidden while auras are secret.
function BD.SetOwnChrome(barFrame, oc)
  local a = attached[barFrame]
  if not a then return end
  if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then return end
  -- every LANE's base sub carries the chrome (multi-unit bars: whichever
  -- lane's aura is active shows the bar's background/border)
  for _, sub in ipairs(a.subs or {}) do
    if sub.isBase and sub.initFired and sub.button then
      ApplyOwnChromeToButton(sub.button, oc)
    end
  end
end

-- DURATION THRESHOLD layers (colour by remaining time). The engine drives a
-- duration bar NORMALISED (SetTimerDuration, value v in 0..1) and -- unlike
-- SetApplicationBar -- never touches min/max, so every layer maps v the same
-- way. Two layers per threshold fraction f, both masked to a STATIC window
-- (the fill is entirely inside [0..f] exactly when the threshold is live):
--   TRACK (durStep = false): plain full-bar rect, so it paints [0..v] like
--     the base; the mask limits it to its side of the threshold.
--   STEP  (durStep = true): rect of length L anchored so the fill origin sits
--     at -L*f, giving edge(v) = L*(v - f): off-bar below f, sweeping over the
--     whole window within DELTA of it. L = X/DELTA, so DELTA is the fraction
--     of the aura's life the wipe takes (0.5% = imperceptible).
-- Drain bars pair TRACK(low) + STEP(low); fill bars pair TRACK(high) +
-- STEP(low). See ns.Display for the layer/colour ordering.
-- The STEP layer's transition is a WIPE across its window: the fill edge has
-- to travel the window's width, taking (window / L) of the aura's life. With
-- geometry alone that is ~0.5% of the duration -- fast, but VISIBLE as the
-- old colour sliding away (in-game report). Two levers, applied together:
--   1. RANGE (the real fix): `ApplyDurationBar` only calls SetTimerDuration
--      and never touches min/max (PTR-source-verified, unlike
--      SetApplicationBar which force-sets 0..max). So pinning a step layer to
--      SetMinMaxValues(f, f + MINMAX_DELTA) makes its fill cross the whole
--      window within MINMAX_DELTA of the threshold = visually instant.
--   2. LENGTH (the fallback): if the engine ever normalises min/max away, the
--      overhang geometry below still produces the correct picture, just with
--      the slower wipe. Both are correct; only the speed differs.
local DUR_STEP_DELTA = 0.0005       -- fallback wipe (fraction of the aura's life)
local DUR_STEP_MAXLEN = 120000
local DUR_STEP_MINMAX_DELTA = 0.0002

local function ReassertDurGeometry(sub, barFrame)
  if not (sub.durSide and barFrame.bar and sub.button) then return end
  local bar, btn = barFrame.bar, sub.button
  local vertical = bar.GetOrientation and bar:GetOrientation() == "VERTICAL"
  local rev = (bar.GetReverseFill and bar:GetReverseFill()) or false
  local size = vertical and (bar:GetHeight() or 0) or (bar:GetWidth() or 0)
  -- Unresolvable geometry (bar not sized yet -- e.g. wired while the frame is
  -- hidden by Hide When Inactive): a mask with no anchors masks EVERYTHING,
  -- which showed up as an active bar with no fill at all. Park the layer
  -- instead and let the next refresh bring it back.
  if size <= 1 then
    -- Geometry unresolvable (bar not sized yet). Do NOT hide the layer: the
    -- repair pass is gated on auras being non-secret, which on 12.1 never
    -- happens, so a hidden layer stays hidden for the session. Leave the mask
    -- covering everything instead -- an unmasked overlay is wrong-looking,
    -- a permanently invisible one is a dead bar.
    local m = sub.stepMask
    if m and sub.button then
      m:ClearAllPoints()
      m:SetPoint("TOPLEFT", sub.button, "TOPLEFT", -400, 400)
      m:SetPoint("BOTTOMRIGHT", sub.button, "BOTTOMRIGHT", 400, -400)
      m:Show()
    end
    sub.geomPending = true
    return
  end
  sub.geomPending = nil
  local scale = barFrame:GetEffectiveScale()
  local _, ph = GetPhysicalScreenSize()
  local onePx = (ph and ph > 0 and scale and scale > 0) and (768 / ph) / scale or 1
  local X = math.floor((size * sub.durFrac) / onePx + 0.5) * onePx
  local upper = sub.durSide == "high"

  local m = sub.stepMask
  if m then
    local PAD, OVER = 400, onePx
    m:ClearAllPoints()
    if vertical then
      if rev then
        if upper then
          m:SetPoint("TOPLEFT", btn, "TOPLEFT", -PAD, -(X - OVER)); m:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", PAD, -PAD)
        else
          m:SetPoint("TOPLEFT", btn, "TOPLEFT", -PAD, 0);           m:SetPoint("BOTTOMRIGHT", btn, "TOPRIGHT", PAD, -(X + OVER))
        end
      else
        if upper then
          m:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -PAD, X - OVER); m:SetPoint("TOPRIGHT", btn, "TOPRIGHT", PAD, PAD)
        else
          m:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -PAD, 0);        m:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", PAD, X + OVER)
        end
      end
    else
      if rev then
        if upper then
          m:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -(X - OVER), PAD); m:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -PAD, -PAD)
        else
          m:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, PAD);           m:SetPoint("BOTTOMLEFT", btn, "BOTTOMRIGHT", -(X + OVER), -PAD)
        end
      else
        if upper then
          m:SetPoint("TOPLEFT", btn, "TOPLEFT", X - OVER, PAD); m:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", PAD, -PAD)
        else
          m:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, PAD);        m:SetPoint("BOTTOMRIGHT", btn, "BOTTOMLEFT", X + OVER, -PAD)
        end
      end
    end
    m:Show()
  end

  local ab = sub.arcBar
  if not ab then return end
  if not sub.durStep then
    ab:ClearAllPoints()
    ab:SetAllPoints(btn)   -- tracks the base fill; the mask does the rest
    if ab.SetMinMaxValues then ab:SetMinMaxValues(0, 1) end
    return
  end

  -- RANGE lever: cross the whole window within MINMAX_DELTA of the threshold
  if ab.SetMinMaxValues then
    local mn = math.min(sub.durFrac, 1 - DUR_STEP_MINMAX_DELTA)
    ab:SetMinMaxValues(mn, mn + DUR_STEP_MINMAX_DELTA)
  end

  local L = math.min(DUR_STEP_MAXLEN, math.max(size, X / DUR_STEP_DELTA))
  local back = L * sub.durFrac    -- fill origin sits this far BEFORE the bar origin
  ab:ClearAllPoints()
  if vertical then
    if rev then   -- origin TOP, grows down
      ab:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, back)
      ab:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, back)
    else          -- origin BOTTOM, grows up
      ab:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, -back)
      ab:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, -back)
    end
    ab:SetHeight(L)
  else
    if rev then   -- origin RIGHT, grows left
      ab:SetPoint("TOPRIGHT", bar, "TOPRIGHT", back, 0)
      ab:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", back, 0)
    else          -- origin LEFT, grows right
      ab:SetPoint("TOPLEFT", bar, "TOPLEFT", -back, 0)
      ab:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", -back, 0)
    end
    ab:SetWidth(L)
  end
end

-- Wire ONE AuraButton's own ArcBar/ArcTimer regions to overlay barFrame.bar / fs. Called from each
-- slot's initializeFrame; stores the regions on the sub. Multiple subs (player + target) overlay the
-- SAME bar -- only the populated one shows, so the aura is found on whichever unit actually holds it.
-- BAR STACK FORMATTER (2026-08-30 — the rule: bars count from 1). The
-- engine's default application-count formatter hides the number at 0 AND 1
-- stack (CDM icon parity) — right for icons, wrong for stack BARS: a
-- 1-stack Freezing bar showed no number until 2+ ("stack text missing at
-- 0/1 stacks" report; pre-3.8 CDM-scanned bars never went through this
-- binding). ONE persistent NumericRuleFormatter shared by every bar stack
-- binding: hidden at 0, plain number from 1 up. The engine stores the
-- object and calls FormatNumber on it C-side on every aura update, so the
-- (secret) count never touches Lua. nil (pre-formatter clients) falls back
-- to the engine default exactly as before.
local barStackFormatter
local function GetBarStackFormatter()
  if barStackFormatter ~= nil then return barStackFormatter or nil end
  local f = C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
    and C_StringUtil.CreateNumericRuleFormatter()
  if f then
    f:SetBreakpoints({ { threshold = 0, format = "" }, { threshold = 1, format = "%d" } })
    barStackFormatter = f
  else
    barStackFormatter = false
  end
  return barStackFormatter or nil
end

local function WireSub(button, barFrame, fs, opts, sub)
  sub.initFired = true
  diag.initFired = diag.initFired + 1
  local ab = button.ArcBar
  local holder = button.ArcTextHolder
  local at = holder and holder.ArcTimer   -- own frame so its LEVEL can go above the border
  sub.button, sub.arcBar, sub.arcTimer, sub.holder = button, ab, at, holder
  local direction     = opts.direction or Enum.StatusBarTimerDirection.RemainingTime
  local interpolation = opts.interpolation or Enum.StatusBarInterpolation.ExponentialEaseOut
  Log("initFrame FIRED key=%s (%s): ArcBar? %s ArcTimer? %s", sub.key, sub.filter, tostring(ab ~= nil), tostring(at ~= nil))

  -- Shared fill styling: mirror our bar's texture/orientation/direction onto
  -- the engine ArcBar, plus the fill-texture hygiene the native bar gets
  -- (Display 856-860): a grid-snapped fill on a sub-pixel-aligned bar
  -- stretches past the widget rect.
  local function StyleEngineFill()
    local srcTex = barFrame.bar.GetStatusBarTexture and barFrame.bar:GetStatusBarTexture()
    if srcTex and srcTex.GetTexture and ab.SetStatusBarTexture then ab:SetStatusBarTexture(srcTex:GetTexture()) end
    if barFrame.bar.GetOrientation and ab.SetOrientation then ab:SetOrientation(barFrame.bar:GetOrientation()) end
    if barFrame.bar.GetReverseFill and ab.SetReverseFill then ab:SetReverseFill(barFrame.bar:GetReverseFill()) end
    if barFrame.bar.GetRotatesTexture and ab.SetRotatesTexture then ab:SetRotatesTexture(barFrame.bar:GetRotatesTexture()) end
    if opts.baseColor and ab.SetStatusBarColor then ab:SetStatusBarColor(opts.baseColor.r, opts.baseColor.g, opts.baseColor.b, opts.baseColor.a or 1) end
    local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
    if ft then
      if ft.SetSnapToPixelGrid then ft:SetSnapToPixelGrid(false) end
      if ft.SetTexelSnappingBias then ft:SetTexelSnappingBias(0) end
    end
  end

  -- Fill: drive the button's OWN bar (a forbidden region), styled to match our bar's fill.
  -- Skipped in text-only mode (no barFrame.bar): only ArcTimer drives.
  -- STACK-BAR mode (opts.applicationMax): the engine ApplicationBar binding
  -- sets min/max 0..maxApplications and value = the (secret) application
  -- count C-side (PTR source-verified: ApplyApplicationBar). maxApplications
  -- is REQUIRED -- nil feeds math.max(nil, 1) inside Blizzard's apply.
  if ab and barFrame.bar and opts.applicationMax and button.SetApplicationBar then
    button:SetApplicationBar(ab, { maxApplications = opts.applicationMax, interpolation = interpolation })
    StyleEngineFill()
    -- reset pooled-reuse leftovers: a recycled button may carry a former
    -- band/Q sub's custom ArcBar anchoring
    ab:ClearAllPoints()
    ab:SetAllPoints(button)
    -- threshold band sub: fractional-width geometry + locked band color
    if opts.fillWidthFrac then
      sub.widthFrac = opts.fillWidthFrac
      ReassertBandWidth(sub, barFrame)
    end
    -- continuous step sub: mask the fill to this overlay's region (P keeps
    -- the plain full-bar rect; Q gets the overhanging sweep geometry). The
    -- mask attaches to the CURRENT fill texture, so it must come after
    -- StyleEngineFill's SetStatusBarTexture.
    -- COLOUR/TEXTURE SPLIT (threshold bars). A StatusBar maps its texture
    -- across the FILL, and the colour layers have structurally different
    -- fill lengths (the sweep's rect is ~T x the threshold offset), so each
    -- shows a different SLICE of the texture's gradient -- two shades
    -- meeting at the threshold, unalignable by any offset (the "darker at
    -- the changing stack" reports). So the colour layers go FLAT and ONE
    -- shade slot carries the user's texture in white with MOD blending over
    -- them: texture RGB x flat colour is exactly how WoW tints a native
    -- statusbar, so the result is the user's texture in the active colour,
    -- identical either side of the threshold. The shade's fill spans
    -- [0..count] like the base, so the EMPTY part of the bar is untouched.
    if opts.shade then
      sub.shade = true
      ab:SetStatusBarColor(1, 1, 1, 1)
      local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
      if ft and ft.SetBlendMode then ft:SetBlendMode("MOD") end
    elseif opts.flatFill or opts.stepKind then
      sub.flat = true
      -- set BEFORE the mask: SetStatusBarTexture can swap the texture object
      ab:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
      if opts.baseColor then
        ab:SetStatusBarColor(opts.baseColor.r, opts.baseColor.g, opts.baseColor.b, opts.baseColor.a or 1)
      end
      local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
      if ft then
        if ft.SetSnapToPixelGrid then ft:SetSnapToPixelGrid(false) end
        if ft.SetTexelSnappingBias then ft:SetTexelSnappingBias(0) end
      end
    end
    if opts.stepKind then
      sub.stepKind, sub.stepFrac, sub.stepT = opts.stepKind, opts.stepFrac, opts.stepT
      sub.stepMask = EnsureStepMask(button)
      local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
      if ft and ft.AddMaskTexture then ft:AddMaskTexture(sub.stepMask) end
      ReassertStepGeometry(sub, barFrame)
    end
    if opts.lockColor then sub.bandColor = opts.baseColor end
    sub.levelBoost = opts.fillLevelBoost
    -- geomPending = the geometry pass could not resolve the bar's size and
    -- PARKED this layer; showing it here would expose the broken (unanchored
    -- mask) state the park exists to prevent
    if not sub.geomPending then ab:Show() end
  elseif ab and barFrame.bar and button.SetDurationBar then
    button:SetDurationBar(ab, { interpolation = interpolation, direction = direction })
    StyleEngineFill()
    -- the engine drives the value NORMALISED (SetTimerDuration) -- pin the
    -- range so every layer maps identically
    if ab.SetMinMaxValues then ab:SetMinMaxValues(0, 1) end
    ab:ClearAllPoints()
    ab:SetAllPoints(button)
    -- DURATION THRESHOLD layers share the colour/texture split with stack
    -- bars (see the block above).
    if opts.shade then
      sub.shade = true
      ab:SetStatusBarColor(1, 1, 1, 1)
      local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
      if ft and ft.SetBlendMode then ft:SetBlendMode("MOD") end
    elseif opts.flatFill or opts.durSide then
      sub.flat = true
      ab:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
      if opts.baseColor then
        ab:SetStatusBarColor(opts.baseColor.r, opts.baseColor.g, opts.baseColor.b, opts.baseColor.a or 1)
      end
      local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
      if ft then
        if ft.SetSnapToPixelGrid then ft:SetSnapToPixelGrid(false) end
        if ft.SetTexelSnappingBias then ft:SetTexelSnappingBias(0) end
      end
    end
    if opts.durSide then
      sub.durSide, sub.durFrac, sub.durStep = opts.durSide, opts.durFrac, opts.durStep
      sub.stepMask = EnsureStepMask(button)
      local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
      if ft and ft.AddMaskTexture then ft:AddMaskTexture(sub.stepMask) end
      ReassertDurGeometry(sub, barFrame)
    end
    if opts.lockColor then sub.bandColor = opts.baseColor end
    sub.levelBoost = opts.fillLevelBoost
    if not sub.geomPending then ab:Show() end
  end

  -- DRAIN-ENGINE mode (Aura Textures, 12.1): the ArcBar carries the user's art
  -- AS ITS FILL TEXTURE -- a StatusBar natively crops its fill as the engine
  -- sweeps the value, so the art drains directionally with ZERO masks. (The
  -- first design anchored the texture module's reveal mask to this fill; the
  -- aspect system rejects that -- "dependent object would inherit forbidden
  -- aspects: UntrustedLayoutScriptExecution" -- masks may not depend on
  -- engine-driven geometry. Frames can; masks cannot.)
  if ab and (not barFrame.bar) and opts.driveArcBar and button.SetDurationBar then
    -- drainElapsed: the COVER inversion for reversed drain directions.
    -- StandardNoRangeFill has no reverse variant (reversed fill = the art
    -- slides -- the "goes up" bug), so reversed directions instead keep the
    -- bright art static underneath and grow a dim cover from the consumed
    -- side: ElapsedTime + NON-reversed fill. No reverse anywhere.
    local drainDir = direction
    if opts.drainElapsed and Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime then
      drainDir = Enum.StatusBarTimerDirection.ElapsedTime
    end
    button:SetDurationBar(ab, { interpolation = interpolation, direction = drainDir })
    if ab.SetOrientation and opts.drainOrient then ab:SetOrientation(opts.drainOrient) end
    if ab.SetReverseFill then ab:SetReverseFill(opts.drainReverse == true) end
    if ab.SetRotatesTexture then ab:SetRotatesTexture(false) end
    -- PIN the art: the default fill style re-maps the texture onto the
    -- shrinking filled region (the art visibly slides as it drains).
    -- StandardNoRangeFill keeps the texture mapped to the FULL bar and crops
    -- the filled portion in place -- the static-art drain. (Its Reverse twin
    -- does not exist yet -- Elkano's open wishlist ask -- so reversed
    -- directions may still slide; report which do.)
    if opts.drainTexture and not opts.drainClip then
      ab:SetStatusBarTexture(opts.drainTexture)
      -- PIN the art AFTER the texture is set (a SetStatusBarTexture can reset
      -- fill state) and RE-ASSERT orientation/reverse after everything -- the
      -- in-game report was "style/reverse not taking effect" with the enum
      -- confirmed present, so ordering is the suspect. Drain Lab (in the
      -- AuraLab) exists to settle the combination empirically.
      if ab.SetFillStyle and Enum and Enum.StatusBarFillStyle
         and Enum.StatusBarFillStyle.StandardNoRangeFill then
        ab:SetFillStyle(Enum.StatusBarFillStyle.StandardNoRangeFill)
      end
      if ab.SetOrientation and opts.drainOrient then ab:SetOrientation(opts.drainOrient) end
      if ab.SetReverseFill then ab:SetReverseFill(opts.drainReverse == true) end
      local c = opts.drainColor
      if c then
        ab:SetStatusBarColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
      else
        ab:SetStatusBarColor(1, 1, 1, 1)
      end
      local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
      if ft and opts.drainBlend and ft.SetBlendMode then ft:SetBlendMode(opts.drainBlend) end
      -- kill texel snapping on the fill: subpixel fill sweep + grid-snapped
      -- texture = periodic micro-stretch of the remaining art (in-game find;
      -- the live drain masks always disabled snapping for the same reason)
      if ft then
        if ft.SetSnapToPixelGrid then ft:SetSnapToPixelGrid(false) end
        if ft.SetTexelSnappingBias then ft:SetTexelSnappingBias(0) end
      end
      Log("driveArcBar wired: orient=%s reverse=%s pin=%s",
        tostring(opts.drainOrient), tostring(opts.drainReverse),
        tostring(ab.SetFillStyle ~= nil and Enum and Enum.StatusBarFillStyle and Enum.StatusBarFillStyle.StandardNoRangeFill ~= nil))
    else
      -- invisible timing/GEOMETRY driver: drainClip mode (the consumer clips
      -- its own art to this fill's moving edge via onWired) or no consumer yet
      ab:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
      ab:SetStatusBarColor(1, 1, 1, 0)
      local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
      if ft then
        if ft.SetSnapToPixelGrid then ft:SetSnapToPixelGrid(false) end
        if ft.SetTexelSnappingBias then ft:SetTexelSnappingBias(0) end
      end
    end
    ab:Show()
  end

  -- Anchor + level the BUTTON itself over the bar HERE, inside
  -- initializeFrame -- the one window PTR5 guarantees the button is not
  -- forbidden. Post-init, ANY API call on it Lua-errors whenever auras are
  -- secret, so the old post-AddAuraSlot anchor block cannot exist. Anchors
  -- persist through the engine's own hide/show. MUST run BEFORE the holder
  -- leveling below: SetFrameLevel on a parent shifts children by the delta,
  -- which would drag holder levels off their targets (level-audit finding).
  button:ClearAllPoints()
  button:SetAllPoints(barFrame.bar or barFrame)
  button:SetFrameStrata(barFrame:GetFrameStrata())
  button:SetFrameLevel((((barFrame.bar and barFrame.bar:GetFrameLevel()) or barFrame:GetFrameLevel()) or 1) + 1 + (opts.fillLevelBoost or 0))

  -- Countdown text on the button's OWN fontstring, overlaid where our duration text sits.
  if opts.showDuration and fs and at and button.SetDurationText then
    -- CustomAuraButtonDurationTextOptions (69111, doc-verified in the
    -- aura-icons port) consumes EXACTLY: binding / textFormatter /
    -- textFormat / textColor = { curve, property }. The old flat
    -- `formatter` / `textColorCurve` / zeroDurationText keys were SILENTLY
    -- STRIPPED by ProcessCustomAuraButtonDurationTextOptions -- the
    -- "10 s despite Decimals + no color-by-time" bar bug.
    local topts = {}
    local fmt = opts.durFormatter or GetDurFormatter(opts.durDecimals)   -- colored (seconds bands) OR plain decimals
    if fmt then topts.textFormatter = fmt end
    if opts.textColorCurve and Enum.DurationTextBindingProperty
       and Enum.DurationTextBindingProperty.RemainingDuration then
      topts.textColor = { curve = opts.textColorCurve, property = Enum.DurationTextBindingProperty.RemainingDuration }
    end
    button:SetDurationText(at, topts)
    if at.SetDrawLayer then at:SetDrawLayer("OVERLAY", 7) end
    if opts.durFontPath and at.SetFont then at:SetFont(opts.durFontPath, opts.durFontSize or 18, opts.durOutline) end
    if opts.durationColor and at.SetTextColor then at:SetTextColor(opts.durationColor.r, opts.durationColor.g, opts.durationColor.b, opts.durationColor.a or 1) end
    at:ClearAllPoints(); at:SetPoint("CENTER", fs, "CENTER", 0, 0)
    -- Raise the timer holder to the user's duration-frame level so it draws ABOVE the bar border.
    local dframe = fs.GetParent and fs:GetParent()
    if holder and dframe and holder.SetFrameLevel then
      holder:SetFrameStrata(dframe:GetFrameStrata())
      holder:SetFrameLevel(dframe:GetFrameLevel())
    end
    at:Show()
  end

  -- Stack count on the button's OWN fontstring, overlaid on the bar's stack text.
  -- SetApplicationCount is the engine binding the aura icons use: the (secret in
  -- restricted content) applications count is written C-side. Bound with the
  -- bar formatter (number from 1 up) — the engine DEFAULT hides 0/1, which is
  -- CDM icon parity but wrong for bars (see GetBarStackFormatter above).
  local sh = button.ArcStackHolder
  local as = sh and sh.ArcStacks
  sub.arcStacks, sub.stackHolder = as, sh
  if opts.stacksText and as and button.SetApplicationCount then
    button:SetApplicationCount(as, { formatter = GetBarStackFormatter() })
    if as.SetDrawLayer then as:SetDrawLayer("OVERLAY", 7) end
    -- plain assignment, NOT `x and f()`: the `and` expression truncates
    -- GetFont's multiple returns to one (nil height -> SetFont usage error
    -- inside the init window)
    local sf, ss, sfl
    if opts.stacksText.GetFont then sf, ss, sfl = opts.stacksText:GetFont() end
    if sf and ss and as.SetFont then as:SetFont(sf, ss, sfl) end
    if opts.stackColor and as.SetTextColor then
      as:SetTextColor(opts.stackColor.r, opts.stackColor.g, opts.stackColor.b, opts.stackColor.a or 1)
    end
    as:ClearAllPoints(); as:SetPoint("CENTER", opts.stacksText, "CENTER", 0, 0)
    local sframe = opts.stacksText.GetParent and opts.stacksText:GetParent()
    if sh and sframe and sh.SetFrameLevel then
      sh:SetFrameStrata(sframe:GetFrameStrata())
      sh:SetFrameLevel(sframe:GetFrameLevel())
    end
    as:Show()
  elseif as then
    as:Hide()
  end
  if button.EnableMouse then button:EnableMouse(false) end

  -- BUTTON-OWNED CHROME (Hide When Inactive ownership model): applied at
  -- wiring; see ApplyOwnChromeToButton above. (After the button leveling --
  -- the chrome hosts derive their levels from the button's.)
  ApplyOwnChromeToButton(button, opts.ownChrome)

  -- Custom init-window composition hook: the ONLY legal moment for a consumer
  -- to capture the button's owned regions (e.g. the ArcBar fill texture that
  -- drain masks anchor to). Anything stored here may be used as an ANCHOR
  -- TARGET later, but never called into post-init.
  if opts.onWired then
    opts.onWired(button, ab, at, sub)
  end
end

-- Create one spell-ID-filtered slot on `c` (unit `filter`) that drives barFrame.bar / fs, anchored
-- over the bar. Returns the sub record (or nil if the slot didn't come back).
local function CreateSub(c, filter, spellIDs, barFrame, fs, opts)
  seq = seq + 1
  local key = "arcbardur" .. seq
  local sub = { container = c, filter = filter, key = key, initFired = false }
  local slot = c:AddAuraSlot(key, filter, {
    candidateFilters = { includeSpellIDs = spellIDs },
    templateNames    = { "ArcBarDurButtonTemplate" },
    initializeFrame  = function(button) WireSub(button, barFrame, fs, opts, sub) end,
  })
  if c.UpdateAllAuras then c:UpdateAllAuras() end   -- parse ALREADY-active auras now, not next UNIT_AURA
  -- NO button touches past this point: anchoring/strata/mouse all happen in
  -- WireSub (the initializeFrame window). The returned slot IS forbidden right
  -- now if auras are secret -- storing the reference is fine, calling is not.
  sub.slot = slot
  diag.slotNew = diag.slotNew + 1
  return sub
end

-- Per-layer LOCKED colours in sub-creation order (base, bands, step pairs,
-- duration layers; the shade slot takes none). Colours are pushed LIVE on the
-- retarget path instead of being part of the rewire key, so recolouring a
-- threshold never recreates slots -- slot churn was leaving the previous
-- composition's colour painted on the bar (in-game report).
local function BuildLayerColors(opts)
  local t = { opts.baseColor }
  for _, b in ipairs(opts.applicationBands or {}) do t[#t + 1] = b.color end
  for _, st in ipairs(opts.applicationSteps or {}) do
    t[#t + 1] = st.color
    t[#t + 1] = st.color
  end
  for _, d in ipairs(opts.durationSteps or {}) do t[#t + 1] = d.color end
  return t
end

-- BD.Attach(barFrame, fs, cooldownID, trackedSpellID, unit, opts)
-- opts.lanes / opts.lanesKey (from ns.Display.ResolveAuraLanes) select the
-- unit lanes; without them `unit` synthesizes the single legacy lane.
function BD.Attach(barFrame, fs, cooldownID, trackedSpellID, unit, opts)
  diag.attachCall = diag.attachCall + 1
  -- exclusive with the CDM mirror mode (Display routes a bar to ONE lane)
  if BD.DetachMirror then BD.DetachMirror(barFrame) end
  -- barFrame.bar is OPTIONAL (text-only mode, e.g. Aura Textures). barFrame itself is required.
  if not barFrame then diag.badArgs = diag.badArgs + 1; Log("Attach: no barFrame"); return end
  opts = opts or {}
  local idKey = (cooldownID and cooldownID > 0) and cooldownID or trackedSpellID
  if not idKey then diag.badArgs = diag.badArgs + 1; Log("Attach: no cooldownID or trackedSpellID"); return end

  if BD.loadWindow then diag.prebuild = diag.prebuild + 1 end

  -- LANES (multi-unit aura bars, the aura icons' model): each lane is a
  -- (unit token, aura filter) pair and gets its OWN slot composition in that
  -- unit's container, all driving the same bar -- the set reads as an OR.
  -- Callers that pass no opts.lanes (textures, older sites) get the single
  -- legacy lane synthesized from `unit`, which is byte-identical to the old
  -- behavior (target = own debuffs only, everything else HELPFUL).
  local lanes = opts.lanes
  if not lanes or #lanes == 0 then
    local u = unit or "player"
    lanes = { { unit = u, filter = (u == "target") and "HARMFUL|PLAYER" or "HELPFUL" } }
  end
  local lanesKey = opts.lanesKey
  if not lanesKey then
    local kparts = {}
    for i, l in ipairs(lanes) do kparts[i] = l.unit .. ":" .. l.filter end
    lanesKey = table.concat(kparts, ",")
  end

  local spellIDs = BD.ResolveCandidateSpellIDs(cooldownID, trackedSpellID)
  if not next(spellIDs) then
    diag.badArgs = diag.badArgs + 1
    diag.emptySet = diag.emptySet + 1
    Log("Attach: EMPTY candidate set (cd=%s tracked=%s) loadWindow=%s",
      tostring(cooldownID), tostring(trackedSpellID), tostring(BD.loadWindow))
    return
  end

  local prev = attached[barFrame]

  -- Rewire-needed cases the retarget path can't serve: a buff<->debuff flip
  -- (the slot lives on the WRONG unit's container; filters can't move it) or
  -- the Stack Text toggle (the applications binding is init-only). Recreate.
  -- Under secrecy the old wiring keeps driving and the flush re-runs this.
  local wantStacks = opts.stacksText ~= nil
  if prev and prev.idKey == idKey
     and ((prev.lanesKey or "") ~= lanesKey or (prev.stacksWired == true) ~= wantStacks
          or (prev.applicationMax or 0) ~= (opts.applicationMax or 0)
          or (prev.bandsKey or "") ~= (opts.bandsKey or "")) then
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
      diag.combatDefer = diag.combatDefer + 1
      pending[barFrame] = { fs = fs, cooldownID = cooldownID, trackedSpellID = trackedSpellID, unit = unit, opts = opts }
      Log("Attach: rewire needed (lanes %s->%s, stacks %s->%s) under secrecy -> deferred",
        tostring(prev.lanesKey), tostring(lanesKey), tostring(prev.stacksWired), tostring(wantStacks))
    else
      Log("Attach: rewire (lanes %s->%s, stacks %s->%s) -> recreating slot",
        tostring(prev.lanesKey), tostring(lanesKey), tostring(prev.stacksWired), tostring(wantStacks))
      BD.Detach(barFrame)
      prev = nil
    end
  end

  if prev and prev.idKey == idKey then
    -- same entry: re-target every sub's filter to the (possibly refreshed) candidate set.
    -- Layering upkeep: the button's strata/level were captured once in WireSub
    -- (the init window). Bar frames are BORN at level 250 and ApplyAppearance
    -- later settles them near barLevel 10 with the border at +23, so a button
    -- wired before (or re-leveled after) that block goes stale-high and its
    -- ArcBar fill draws OVER the bar border. Post-init button calls are only
    -- legal while auras are NOT secret; levels only change from desk-time
    -- config work, so re-asserting on this path catches every real case.
    local aurasSecret = C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()

    -- LIVE colour push: the composition's structure is unchanged, only the
    -- colours may have moved. Also REFRESH the stored request -- ApplyStyle's
    -- re-attach path replays req.opts, and a stale req reinstated the previous
    -- colours/steps over the current ones (the "old colour stayed" bug).
    local newColors = BuildLayerColors(opts)
    for _, sub in ipairs(prev.subs or {}) do
      -- layerIdx, not the subs index: multi-lane repeats the layer sequence
      -- per lane, so the flat index no longer maps onto the color list
      local c = sub.layerIdx and newColors[sub.layerIdx]
      if c and not sub.shade then
        sub.bandColor = c
        if not aurasSecret and sub.arcBar then
          sub.arcBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
      end
    end
    prev.req = { fs = fs, cooldownID = cooldownID, trackedSpellID = trackedSpellID, unit = unit, opts = opts }

    -- PERF: only touch the engine when the candidate set actually moved.
    -- Refreshes re-attach constantly (visibility conditions, appearance
    -- applies), and UpdateAllAuras is a FULL container re-parse + re-bind +
    -- re-layout -- doing it per sub meant up to 10 re-parses per refresh per
    -- bar for a threshold composition. Now: skip entirely when unchanged, and
    -- otherwise refresh each distinct container ONCE.
    local filtersMoved = not SameSet(prev.spellIDs, spellIDs)
    local refreshed
    -- PERF: the layer geometry only depends on the bar's rect / orientation /
    -- level, so re-lay it when THAT moved, not on every refresh (a threshold
    -- composition is up to 10 subs x ~6 anchor calls each).
    local gb = barFrame.bar
    local geomSig = string.format("%.1f|%.1f|%d|%s|%d",
      (gb and gb:GetWidth()) or 0, (gb and gb:GetHeight()) or 0,
      ((gb and gb:GetFrameLevel()) or barFrame:GetFrameLevel() or 0),
      (gb and gb.GetOrientation and gb:GetOrientation()) or "",
      ((gb and gb.GetReverseFill and gb:GetReverseFill()) and 1) or 0)
    local geomChanged = prev.geomSig ~= geomSig
    prev.geomSig = geomSig
    for _, sub in ipairs(prev.subs or {}) do
      if filtersMoved and sub.container and sub.key and sub.container.SetAuraSlotCandidateFilters then
        sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = spellIDs })
        refreshed = refreshed or {}
        refreshed[sub.container] = true
      end
      if not aurasSecret and sub.initFired and sub.button then
        -- chrome lives on every LANE's base sub (isBase), so whichever lane's
        -- aura is active carries the bar's background/border with it
        ApplyOwnChromeToButton(sub.button, sub.isBase and opts.ownChrome or nil)
        sub.button:SetFrameStrata(barFrame:GetFrameStrata())
        sub.button:SetFrameLevel((((barFrame.bar and barFrame.bar:GetFrameLevel()) or barFrame:GetFrameLevel()) or 1) + 1 + (sub.levelBoost or 0))
        if geomChanged or sub.geomPending then
          ReassertBandWidth(sub, barFrame)
          ReassertStepGeometry(sub, barFrame)
          ReassertDurGeometry(sub, barFrame)
        end
        local dframe = fs and fs.GetParent and fs:GetParent()
        if sub.holder and dframe then
          sub.holder:SetFrameStrata(dframe:GetFrameStrata())
          sub.holder:SetFrameLevel(dframe:GetFrameLevel())
        end
        local sframe = opts.stacksText and opts.stacksText.GetParent and opts.stacksText:GetParent()
        if sub.stackHolder and sframe then
          sub.stackHolder:SetFrameStrata(sframe:GetFrameStrata())
          sub.stackHolder:SetFrameLevel(sframe:GetFrameLevel())
        end
        -- stack overlay restyle (skins/appearance changes): font + color are
        -- direct property sets, legal while not secret
        if sub.arcStacks and opts.stacksText then
          local sf, ss, sfl
          if opts.stacksText.GetFont then sf, ss, sfl = opts.stacksText:GetFont() end
          if sf and ss and sub.arcStacks.SetFont then sub.arcStacks:SetFont(sf, ss, sfl) end
          local sc = opts.stackColor
          if sc and sub.arcStacks.SetTextColor then
            sub.arcStacks:SetTextColor(sc.r, sc.g, sc.b, sc.a or 1)
          end
        end
      end
    end
    if refreshed then
      for cont in pairs(refreshed) do
        if cont.UpdateAllAuras then cont:UpdateAllAuras() end
      end
    end
    prev.spellIDs = spellIDs
    diag.slotRetarget = diag.slotRetarget + 1
    -- NOTE: this path only refreshes the candidate spell set. NEW opts (a
    -- drainTexture, changed bindings) DO NOT apply here -- callers needing
    -- different wiring must Detach first (the log line below is the tell).
    Log("Attach: retarget-only (idKey=%s already attached) -- opts changes NOT applied on this path", tostring(idKey))
    return
  end

  -- ID CHANGED while attached (custom bar spell edited / bar reconfigured to
  -- a different aura): reaching here with a prev record means prev.idKey ~=
  -- idKey — the old slots would keep DRIVING this bar's widgets from the OLD
  -- aura (ghost fill/text) while the new attach builds beside them. Detach
  -- first; Detach parks filters + retires containers and is legal in any
  -- context, so it runs even when the create below defers under secrecy.
  if prev then
    Log("Attach: idKey changed (%s -> %s) -> detaching old wiring first",
      tostring(prev.idKey), tostring(idKey))
    BD.Detach(barFrame)
    prev = nil
  end

  -- RC 69189+: AddAuraSlot's frame provider reparents (CreateFrameOutbound +
  -- SetParent), and that reparent is BLOCKED from addon stacks while auras
  -- are SECRET (instances 24/7, combat) — creating a slot would die inside
  -- Blizzard's provider. Defer new slot creation to the flush (regen /
  -- world-enter); the retarget path above stays live (filter edits never
  -- reparent).
  -- BD.loadWindow: inside ADDON_LOADED -> PLAYER_LOGIN creation is legal even
  -- under secrecy, and that is the ONLY chance a bar gets when the session
  -- starts inside an instance. Without this the prebuild deferred exactly like
  -- any other pass and achieved nothing there.
  if not BD.loadWindow
     and C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
    diag.combatDefer = diag.combatDefer + 1
    pending[barFrame] = { fs = fs, cooldownID = cooldownID, trackedSpellID = trackedSpellID, unit = unit, opts = opts }
    Log("Attach: auras SECRET -> slot creation deferred (cd=%s tracked=%s)", tostring(cooldownID), tostring(trackedSpellID))
    return
  end

  -- Route by the caller's PICKER (the lanes list; single legacy lane when no
  -- opts.lanes). That is the reliable signal; the CDM frame's auraDataUnit is
  -- NOT (selfAura entries like Flame Shock report "player" even though the
  -- aura lives on the target).
  --
  -- Filter by LANE SEMANTICS, never live unit state: UnitCanAssist("player",
  -- "pet") is FALSE while the pet does not exist — which is exactly the case
  -- during the login prebuild — so the pet slot got baked with a HARMFUL
  -- filter for the whole session and the pet's buff could never match (the
  -- "empty pet bar after every reload" bug). Each lane's filter is fixed by
  -- design at resolve time (Display.ResolveAuraLanes / the legacy synth
  -- above): harmful lanes default to the player's OWN debuffs (|PLAYER —
  -- plain HARMFUL lit bars up for ANY ally's copy of the debuff, e.g. a
  -- second Arms warrior's Colossus Smash) unless the user opted into other
  -- players' copies; helpful lanes are HELPFUL (any source — external buffs
  -- must match) unless own-only is on.
  unit = unit or "player"

  -- Pre-create EVERY lane's container first: if any is unavailable (combat on
  -- a pre-PTR7 client), defer the whole attach rather than building a partial
  -- lane set.
  local laneContainers = {}
  for i, lane in ipairs(lanes) do
    local c = EnsureContainer(lane.unit, barFrame)
    if not c or not c.AddAuraSlot then
      diag.combatDefer = diag.combatDefer + 1
      pending[barFrame] = { fs = fs, cooldownID = cooldownID, trackedSpellID = trackedSpellID, unit = unit, opts = opts }
      Log("Attach: container(%s) not ready -> pending (cd=%s)", lane.unit, tostring(cooldownID))
      return
    end
    laneContainers[i] = c
  end

  -- threshold overlays present -> colour/texture split: the base goes FLAT
  -- too (the shade slot below carries the texture for every layer at once)
  local nSteps = opts.applicationSteps and #opts.applicationSteps or 0
  local nDur   = opts.durationSteps and #opts.durationSteps or 0
  local nBands = opts.applicationBands and #opts.applicationBands or 0
  opts.flatFill = (nSteps > 0 or nDur > 0 or nBands > 0) or nil

  -- ONE full layer composition PER LANE, every lane's stack in its own
  -- unit's container, all driving the same bar. sub.layerIdx records the
  -- position in the per-lane layer sequence (base=1, bands, step pairs,
  -- duration layers) so colour pushes stay correct across lanes.
  local subs = {}
  for li, lane in ipairs(lanes) do
    local c, filter = laneContainers[li], lane.filter
    local layerIdx = 0
    local function AddLaneSub(fsArg, subOpts)
      layerIdx = layerIdx + 1
      local sub = CreateSub(c, filter, spellIDs, barFrame, fsArg, subOpts)
      sub.layerIdx = layerIdx
      subs[#subs + 1] = sub
      return sub
    end

    local base = AddLaneSub(fs, opts)
    base.isBase = true

    -- Threshold band overlays (stack bars): one extra slot per band, fill-only
    -- (no text opts), saturating maxApplications + fractional width + locked
    -- color. Smaller thresholds get higher levels (drawn on top).
    for _, band in ipairs(opts.applicationBands or {}) do
      AddLaneSub(nil, {
        applicationMax = band.max,
        interpolation  = opts.interpolation,
        baseColor      = band.color,
        fillWidthFrac  = band.widthFrac,
        fillLevelBoost = band.boost,
        lockColor      = true,
      })
    end

    -- Continuous step overlays (whole-fill color switch): TWO slots per
    -- threshold in this lane's container, each masked to its region (see the
    -- step block above). P paints [T..count] (max=maxStacks, bar
    -- interpolation -- edge tracks the base fill); Q covers [0..T] once count
    -- reaches T (max=T, Immediate). Higher thresholds draw on top.
    for _, st in ipairs(opts.applicationSteps or {}) do
      local frac = st.threshold / math.max(opts.applicationMax or 1, 1)
      AddLaneSub(nil, {
        applicationMax = opts.applicationMax,
        interpolation  = opts.interpolation,
        baseColor      = st.color,
        stepKind       = "upper",
        stepFrac       = frac,
        stepT          = st.threshold,
        fillLevelBoost = st.boost,
        lockColor      = true,
      })
      AddLaneSub(nil, {
        applicationMax = st.threshold,
        interpolation  = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate or nil,
        baseColor      = st.color,
        stepKind       = "lower",
        stepFrac       = frac,
        stepT          = st.threshold,
        fillLevelBoost = st.boost,
        lockColor      = true,
      })
    end

    -- DURATION threshold layers (colour by remaining time). Each entry is one
    -- layer with an explicit level boost, built by ns.Display in the order the
    -- composition needs; TRACK layers follow the fill, STEP layers gate on the
    -- threshold. All flat-filled; the shade slot below re-applies the texture.
    for _, d in ipairs(opts.durationSteps or {}) do
      AddLaneSub(nil, {
        direction      = opts.direction,
        interpolation  = d.step and (Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate) or opts.interpolation,
        baseColor      = d.color,
        durSide        = d.side,
        durFrac        = d.frac,
        durStep        = d.step,
        fillLevelBoost = d.boost,
        lockColor      = true,
      })
    end

    -- SHADE slot (only with threshold overlays): the user's texture in white,
    -- MOD blended, spanning the same fill on TOP of every flat colour layer --
    -- gives all of them the same texture shading with one correctly-mapped fill.
    if nSteps > 0 or nDur > 0 or nBands > 0 then
      -- above EVERY colour layer, whatever composition built them
      local shadeBoost = 1
      for _, b in ipairs(opts.applicationBands or {}) do shadeBoost = math.max(shadeBoost, (b.boost or 0) + 1) end
      for _, st in ipairs(opts.applicationSteps or {}) do shadeBoost = math.max(shadeBoost, (st.boost or 0) + 1) end
      for _, d in ipairs(opts.durationSteps or {}) do shadeBoost = math.max(shadeBoost, (d.boost or 0) + 1) end
      AddLaneSub(nil, {
        applicationMax = opts.applicationMax,
        direction      = opts.direction,
        interpolation  = opts.interpolation,
        shade          = true,
        fillLevelBoost = shadeBoost,
      })
    end
  end

  -- lock each layer's colour so restyles cannot reset a composed layer to the
  -- plain bar colour (the base carries the composition's own base, which for
  -- band mode is the TOP band's colour, not cfg.barColor)
  local layerColors = BuildLayerColors(opts)
  for _, sub in ipairs(subs) do
    local col = layerColors[sub.layerIdx]
    if col and not sub.shade then sub.bandColor = col end
  end

  attached[barFrame] = {
    idKey = idKey, cooldownID = cooldownID, spellIDs = spellIDs, subs = subs, unit = unit,
    lanesKey = lanesKey,
    decimals = opts.durDecimals, textColorEnabled = opts.textColorEnabled,
    colorKey = opts.colorKey, stacksWired = wantStacks,
    applicationMax = opts.applicationMax, bandsKey = opts.bandsKey,
    direction = opts.direction, interpolation = opts.interpolation,
    -- full re-attach request: PTR6 forbids re-passing button-child regions to
    -- the binding APIs post-init ("must not be an access-constrained object"),
    -- so binding changes are served by recreating the slot from this request
    req = { fs = fs, cooldownID = cooldownID, trackedSpellID = trackedSpellID, unit = unit, opts = opts },
  }
  Log("Attach: [%s] {%s} (cd=%s)", lanesKey, SetKeys(spellIDs), tostring(cooldownID))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CDM TIMER MIRROR (per-bar "CDM Timer Mirror" option, 12.1)
-- Some timers the CDM displays come from HIDDEN/internal auras that never
-- match AuraContainer candidate filters (e.g. Crusading Strikes' swing aura
-- 1226662, linked to 404542) -- the container lane can never drive those.
-- But the CDM's own tracked-BAR item IS fed: its RefreshCooldownInfo calls
-- barFrame:SetMinMaxValues(0, duration) + SetValue(remaining) + the timer
-- fontstring's SetText, with SECRET values, every OnUpdate. All three are
-- secret-accepting sinks on OUR widgets too (AllowedWhenTainted), so the
-- mirror hooksecurefunc's the CDM item's Bar/Duration widgets and re-pushes
-- the SAME values into our bar. Zero reads, zero CDM method calls, combat-
-- safe. Requires the CDM entry to be displayed AS A BAR and actively
-- updating (a hidden/removed CDM entry stops pushing -> mirror bar empties).
-- Fill is always DRAIN (remaining/duration -- deriving "fill" would need
-- arithmetic on secrets).
-- ═══════════════════════════════════════════════════════════════════════════
local mirrorByBar = {}   -- ourBarFrame -> { cooldownID, frame, srcBar, fs }
local mirrorHooked = {}  -- blizzard widget -> true (hooksecurefunc is permanent)
local mirDiag = { value = 0, fbText = 0 }  -- /arcbardur mirror counters

-- a mirror push is only forwarded while the source frame still owns OUR
-- cooldownID (CDM recycles/reassigns item frames; cooldownID is non-secret)
local function MirrorSourceValid(rec)
  local f = rec.frame
  if not f then return false end
  local cd = f.cooldownID or (f.cooldownInfo and f.cooldownInfo.cooldownID)
  return cd == rec.cooldownID
end

local function MirrorHookBar(srcBar)
  if not srcBar or mirrorHooked[srcBar] then return end
  mirrorHooked[srcBar] = true
  hooksecurefunc(srcBar, "SetValue", function(self, v)
    for ourFrame, rec in pairs(mirrorByBar) do
      if rec.srcBar == self and ourFrame.bar and MirrorSourceValid(rec) then
        -- SMOOTHING: SetValue's second argument is the interpolation enum, and it
        -- is NeverSecret -- we supply it, so a secret value animates fine. The
        -- mirror simply never passed one, so every push was Immediate and the bar
        -- stepped. rec.interp is nil when the user has Smooth Fill off, which is
        -- the documented default (Immediate).
        ourFrame.bar:SetValue(v, rec.interp)
        mirDiag.value = mirDiag.value + 1
        -- DURATION TEXT (Arc's call: value-derived ONLY -- the normal text
        -- sources are cut out entirely in mirror mode): whole seconds from
        -- the (secret) value push via FloorToNearestString (secret-accepting,
        -- AllowedWhenTainted). The mirror OWNS the fontstring while active:
        -- keep it and its parent shown so no other lane can blank it.
        if rec.fs then
          rec.fs:SetText(C_StringUtil and C_StringUtil.FloorToNearestString
            and C_StringUtil.FloorToNearestString(v) or "")
          if not rec.fs:IsShown() then rec.fs:Show() end
          local par = rec.fs:GetParent()
          if par and not par:IsShown() then par:Show() end
          mirDiag.fbText = mirDiag.fbText + 1
        end
      end
    end
  end)
  hooksecurefunc(srcBar, "SetMinMaxValues", function(self, mn, mx)
    for ourFrame, rec in pairs(mirrorByBar) do
      if rec.srcBar == self and ourFrame.bar and MirrorSourceValid(rec) then
        ourFrame.bar:SetMinMaxValues(mn, mx)
        -- the INACTIVE push is literal SetMinMaxValues(0, 0) -- non-secret
        -- constants, so this compare is safe -- clear the mirrored text so no
        -- stale number lingers after the timer ends
        local inactive = not (issecretvalue and issecretvalue(mx)) and mx == 0
        if rec.fs and inactive then
          rec.fs:SetText("")
        end
        -- FILL-MODE LAYER (Display's ApplyMirrorFillLayer): it paints the gap the
        -- drain texture leaves behind, so an inactive entry -- zero-width drain --
        -- would leave the whole bar looking FULL. The active push carries a SECRET
        -- duration, so "mx is secret" is itself the active signal.
        -- gate on the MODE FLAG, not on the texture existing: the texture is
        -- pooled and merely hidden when the user switches back to drain
        local fillTex = ourFrame._mirrorFillActive and ourFrame._mirrorFillTex
        if fillTex then
          fillTex:SetShown(not inactive)
          -- re-assert the drain's alpha-0 at the timer edge: ApplyAppearance can
          -- run between bar updates and restore it, which would put the mirrored
          -- drain back on top of the fill layer. (Keep Texture Still also
          -- keeps the drain INVISIBLE -- its texture only supplies the mask's
          -- boundary anchors, which track on an alpha-0 StatusBar.)
          if not inactive then ourFrame.bar:SetAlpha(0) end
        end
      end
    end
  end)
end

-- (the CDM's own timer-text SetText is deliberately NOT mirrored -- Arc's
-- call: mirror text is value-derived only, one source, no fighting)

-- Attach the mirror for a bar. Re-callable (Display re-runs on every bar
-- update): re-resolves the CDM item frame each time, so CDM frame
-- reassignment self-heals on the next update. Returns true when a bar-kind
-- CDM item was found and hooked.
function BD.AttachMirror(barFrame, fs, cooldownID, interp)
  if not (barFrame and cooldownID and cooldownID > 0) then return false end
  local rec = mirrorByBar[barFrame] or {}
  rec.cooldownID = cooldownID
  rec.fs = fs
  rec.interp = interp   -- StatusBarInterpolation for the mirrored SetValue (nil = Immediate)
  mirrorByBar[barFrame] = rec
  -- registry lookups are COLON methods (self = the registry)
  local f = ns.FrameRegistry and ns.FrameRegistry.GetValidFrameForCooldownID
    and ns.FrameRegistry:GetValidFrameForCooldownID(cooldownID)
  -- the registry may return the ICON-viewer frame for this entry; the mirror
  -- needs the BAR item -- fall back to scanning the BuffBar viewer directly
  -- (plain field reads + widget GetChildren: taint-safe, no CDM Lua methods)
  if not (f and f.Bar) and _G.BuffBarCooldownViewer then
    local kids = { _G.BuffBarCooldownViewer:GetChildren() }
    for _i, k in ipairs(kids) do
      local cd = k.cooldownID or (k.cooldownInfo and k.cooldownInfo.cooldownID)
      if cd == cooldownID and k.Bar then f = k break end
    end
  end
  rec.frame = f
  if f and f.Bar and f.Bar.SetValue then
    -- CooldownViewerBuffBarItemMixin: .Bar StatusBar + .Bar.Duration fontstring
    rec.srcBar = f.Bar
    MirrorHookBar(rec.srcBar)
    Log("AttachMirror cd=%d: hooked CDM bar item (text = value-derived)", cooldownID)
    return true
  end
  rec.srcBar = nil
  Log("AttachMirror cd=%d: no CDM BAR item found (entry hidden, or displayed as an icon -- set it to Bar in the Cooldown Manager)", cooldownID)
  return false
end

function BD.DetachMirror(barFrame)
  mirrorByBar[barFrame] = nil
end

function BD.Detach(barFrame)
  pending[barFrame] = nil
  styleDeferred[barFrame] = nil
  BD.DetachMirror(barFrame)
  local a = attached[barFrame]
  if not a then return end
  attached[barFrame] = nil
  for _, sub in ipairs(a.subs or {}) do
    -- NEVER touch the slot button here: post-init it is FORBIDDEN whenever
    -- auras are secret (PTR5). Parking the include set on a never-matching id
    -- makes the ENGINE release and hide the button itself (engine-side Hide is
    -- always legal, anchors are kept). Container methods stay callable.
    if sub.container and sub.key and sub.container.SetAuraSlotCandidateFilters then
      sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = { [0] = true } })
      if sub.container.UpdateAllAuras then sub.container:UpdateAllAuras() end
    end
  end
  -- RETIRE the owner's containers outright (hide + evict) so the NEXT Attach
  -- builds FRESH ones. THE AURA-ICONS LAW, now enforced here too: a container
  -- that has lived through combat carries forbidden aspects from displaying
  -- secret data, and a later AddAuraSlot into it dies inside Blizzard's frame
  -- provider ("child would inherit forbidden aspects"). Re-slotting the
  -- cached container is why EVERY post-combat rewire — threshold band edits
  -- (ApplyStyle's recreate), the options panel's texture detach/re-attach —
  -- left the binding dead until a reload. One container, ONE AddAuraSlot,
  -- ever. Hiding retires it (buttons are its children); the leaked invisible
  -- 1x1 frame per rewire is the same accepted cost as the aura icons module.
  local perOwner = containers[barFrame]
  if perOwner then
    for _, c in pairs(perOwner) do
      if c.Hide then c:Hide() end
    end
    containers[barFrame] = nil
  end
end

function BD.DetachAll()
  local list = {}
  for bf in pairs(attached) do list[#list + 1] = bf end
  for _, bf in ipairs(list) do BD.Detach(bf) end
end

-- Re-push the CURRENT fill + text style onto BOTH engine subs so bar options take effect LIVE
-- (called from ApplyAppearance after it styles the real frames), not only after a reload.
function BD.ApplyStyle(barFrame, durationFrame, showDuration, decimals, durationColor, baseColor, fillDirection, durFormatter, textColorEnabled, colorKey)
  local a = barFrame and attached[barFrame]
  if not a then return end
  -- PTR5+: the engine button AND everything we templated into it (ArcBar/
  -- ArcTimer/holder are its CHILDREN) are FORBIDDEN while auras are secret.
  -- PTR6 ships the sanctioned per-object probe, CanBeAccessedInContext()
  -- (IsForbidden proved a FALSE NEGATIVE for this state in-game; data-secrecy
  -- probes over/under-gate). Pre-PTR6 fallback: the ENVIRONMENTAL gate --
  -- aura secrecy tracks combat/encounter (thread-confirmed). Either way the
  -- deferred push re-applies on the regen flush.
  local blocked
  for _, sub in ipairs(a.subs or {}) do
    local h = sub.holder or sub.button
    if h and h.CanBeAccessedInContext then
      blocked = not h:CanBeAccessedInContext()
      break
    end
  end
  if blocked == nil then
    blocked = InCombatLockdown() or (IsEncounterInProgress and IsEncounterInProgress())
  end
  if blocked then
    styleDeferred[barFrame] = { durationFrame, showDuration, decimals, durationColor, baseColor, fillDirection, durFormatter, textColorEnabled, colorKey }
    Log("ApplyStyle: BLOCKED (buttons forbidden) -> deferred (cd=%s key %s->%s)",
      tostring(a.cooldownID), tostring(a.colorKey), tostring(colorKey))
    return
  end
  styleDeferred[barFrame] = nil
  local dtext = durationFrame and durationFrame.text
  -- TRUE change detection only: re-attach recreates a slot (no UnregisterAuraSlot
  -- exists), so steady-state refreshes (RefreshAllBars fires on every dynamic
  -- reflow) must never trigger it. The old "or textColorEnabled" steady term
  -- would have churned a slot per reflow. colorKey covers band edits (threshold
  -- values/colors changed while the toggle stays on) -- stable string per config.
  local formatterChanged = (a.decimals ~= decimals) or (a.textColorEnabled ~= textColorEnabled)
    or ((a.colorKey or "") ~= (colorKey or ""))
  local directionChanged = fillDirection and a.direction ~= fillDirection

  -- PTR6 (in-game confirmed): the binding APIs VALIDATE their region args and
  -- permanently reject access-constrained objects -- our ArcBar/ArcTimer carry
  -- that constraint from the moment initializeFrame returns, so re-calling
  -- SetDurationText/SetDurationBar with them post-init errors even out of
  -- combat ("must not be an access-constrained object"). Binding changes are
  -- therefore served by RECREATING the slot: a fresh AddAuraSlot wires the new
  -- formatter/direction inside its own init window (legal even in combat).
  if (formatterChanged or directionChanged) and a.req then
    Log("ApplyStyle: RECREATE (cd=%s, fmtChanged=%s dirChanged=%s, key %s -> %s, dec %s -> %s)",
      tostring(a.cooldownID), tostring(formatterChanged), tostring(directionChanged),
      tostring(a.colorKey), tostring(colorKey), tostring(a.decimals), tostring(decimals))
    local req = a.req
    req.opts.durDecimals      = decimals
    req.opts.durFormatter     = durFormatter
    req.opts.textColorEnabled = textColorEnabled
    req.opts.colorKey         = colorKey
    req.opts.durationColor    = durationColor or req.opts.durationColor
    req.opts.baseColor        = baseColor or req.opts.baseColor
    req.opts.showDuration     = showDuration
    if fillDirection then req.opts.direction = fillDirection end
    if dtext and dtext.GetFont then
      local f, s, fl = dtext:GetFont()
      if f then req.opts.durFontPath, req.opts.durFontSize, req.opts.durOutline = f, s, fl end
    end
    BD.Detach(barFrame)
    BD.Attach(barFrame, req.fs, req.cooldownID, req.trackedSpellID, req.unit, req.opts)
    return
  end

  -- Plain restyles: direct property sets on our (accessible right now) regions
  -- remain legal -- only the validated binding calls are init-only.
  for _, sub in ipairs(a.subs or {}) do
    local ab, at = sub.arcBar, sub.arcTimer
    -- Fill: mirror the freshly-styled real bar's texture/orientation/direction + CONFIGURED base
    -- colour (never barFrame.bar:GetStatusBarColor() -- that's a secret on 12.1 + the dimmed tint).
    -- Band subs keep their LOCKED threshold color and fractional geometry.
    if ab and barFrame.bar then
      -- three layer kinds (see WireSub's colour/texture split): flat colour
      -- layers keep WHITE8X8, the shade layer keeps the bar texture in white
      -- with MOD, everything else mirrors the bar
      if sub.flat then
        ab:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
      else
        local srcTex = barFrame.bar.GetStatusBarTexture and barFrame.bar:GetStatusBarTexture()
        if srcTex and srcTex.GetTexture and ab.SetStatusBarTexture then ab:SetStatusBarTexture(srcTex:GetTexture()) end
      end
      if barFrame.bar.GetOrientation and ab.SetOrientation then ab:SetOrientation(barFrame.bar:GetOrientation()) end
      if barFrame.bar.GetReverseFill and ab.SetReverseFill then ab:SetReverseFill(barFrame.bar:GetReverseFill()) end
      local col = sub.bandColor or baseColor
      if sub.shade then col = { r = 1, g = 1, b = 1, a = 1 } end
      if col and ab.SetStatusBarColor then ab:SetStatusBarColor(col.r, col.g, col.b, col.a or 1) end
      if sub.shade then
        local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
        if ft and ft.SetBlendMode then ft:SetBlendMode("MOD") end
      end
      -- re-assert the mask link: SetStatusBarTexture may hand back a
      -- different texture object, which would drop it (unmasked overlay =
      -- the whole bar recoloured at every count)
      if sub.stepMask then
        local ft = ab.GetStatusBarTexture and ab:GetStatusBarTexture()
        if ft and ft.AddMaskTexture then
          if ft.RemoveMaskTexture then ft:RemoveMaskTexture(sub.stepMask) end
          ft:AddMaskTexture(sub.stepMask)
          if ft.SetSnapToPixelGrid then ft:SetSnapToPixelGrid(false) end
          if ft.SetTexelSnappingBias then ft:SetTexelSnappingBias(0) end
        end
      end
      ReassertBandWidth(sub, barFrame)
      ReassertStepGeometry(sub, barFrame)
      ReassertDurGeometry(sub, barFrame)
    end
    if at then
      -- THE TOGGLE IS THE DEADLINE: Show Duration OFF must hide the engine's
      -- ArcTimer holder NOW — the timer is engine-driven and keeps counting
      -- otherwise ("disabled duration text but it still shows on the bar").
      -- Holder writes are legal here: the blocked path above already
      -- deferred us when the button partition is forbidden. ON re-shows it.
      if sub.holder and sub.holder.SetShown then
        sub.holder:SetShown(showDuration and true or false)
      end
    end
    if at and showDuration then
      if sub.holder and durationFrame and sub.holder.SetFrameLevel then
        sub.holder:SetFrameStrata(durationFrame:GetFrameStrata())
        sub.holder:SetFrameLevel(durationFrame:GetFrameLevel())
      end
      if dtext and at.SetFont then local f, s, fl = dtext:GetFont(); if f then at:SetFont(f, s, fl) end end
      -- static color only when color-by-time is OFF (a direct set would fight
      -- the curve binding the slot was wired with)
      if durationColor and not textColorEnabled and at.SetTextColor then
        at:SetTextColor(durationColor.r, durationColor.g, durationColor.b, durationColor.a or 1)
      end
    end
  end
  if fillDirection then a.direction = fillDirection end
  a.decimals = decimals
  a.textColorEnabled = textColorEnabled
  a.colorKey = colorKey
  a.showDuration = showDuration and true or false
  Log("ApplyStyle: plain restyle done (cd=%s key=%s tce=%s)",
    tostring(a.cooldownID), tostring(colorKey), tostring(textColorEnabled))
end


-- ═══════════════════════════════════════════════════════════════════════════
-- CONTAINER REPAIR (12.1 engine bug -- full write-up in ns.CDMShared)
-- Candidate filters fail OPEN whenever UnitCanAssist fails (vehicles,
-- cinematics, faction change, range, encounter end), so a bar can start lighting
-- on an ARBITRARY aura. Bars previously had NO re-assertion at all: filters were
-- written at attach/retarget/detach and never re-pushed, so a bar that lost its
-- filter mid-fight stayed wrong until the next attach.
-- Cycle the container (SetEnabled is guarded on change, so only false->true
-- re-registers events and refreshes), then re-push each sub's believed-correct
-- filter. Data-only, so it is legal in combat.
-- ═══════════════════════════════════════════════════════════════════════════
function BD.RepairContainers()
  local Sh = ns.CDMShared
  if Sh and Sh.RepairAuraContainer then
    for _, perOwner in pairs(containers) do
      for _, c in pairs(perOwner) do
        Sh.RepairAuraContainer(c)
      end
    end
  end
  -- Re-push what each live sub should be filtering on. Everything still in
  -- attached[] IS live: Detach parks the filters and then clears the entry
  -- (attached[barFrame] = nil, ~line 1429), so there is no parked state to
  -- preserve here and no need to branch on one.
  for _, a in pairs(attached) do
    local subs = a and a.subs
    if subs and a.spellIDs then
      for _, sub in pairs(subs) do
        if sub.container and sub.key and sub.container.SetAuraSlotCandidateFilters then
          sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = a.spellIDs })
        end
      end
    end
  end
end
-- ── combat deferral + eager container creation + target-swap refresh ─────────
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")   -- zone-out ends instance secrecy without a regen
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("PLAYER_FOCUS_CHANGED")  -- focus lanes (multi-unit bars): focus identity changed
ev:RegisterEvent("GROUP_ROSTER_UPDATE")   -- party lanes: party1..4 identities changed
ev:RegisterEvent("UNIT_PET")            -- pet summoned/dismissed/replaced: pet containers go stale
ev:SetScript("OnEvent", function(_, event, evUnit)
  -- LAZY REPAIR REGISTRATION. This file loads BEFORE ArcUI_CDM_Shared.lua (toc
  -- line 42 vs 93), so ns.CDMShared does not exist at our file scope. Register
  -- on the first event we receive instead, by which point every file is loaded.
  -- Idempotent on the CDMShared side, so repeating it costs nothing.
  if ns.CDMShared and ns.CDMShared.RegisterAuraContainerRepair then
    ns.CDMShared.RegisterAuraContainerRepair(BD.RepairContainers)
  end
  if event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED"
     or event == "GROUP_ROSTER_UPDATE" or (event == "UNIT_PET" and evUnit == "player") then
    -- Non-player containers do NOT self-refresh when their unit's IDENTITY changes (they only
    -- react to their own unit's UNIT_AURA), so a target debuff bar goes stale on target swap and
    -- a pet bar on summon/dismiss — same for focus swaps and party roster changes. Force a full
    -- re-parse of the affected containers.
    -- (The exact debuff bug the AuraLab found; pet lane added with the Dark Transformation fix.)
    local wantUnit = (event == "UNIT_PET") and "pet"
      or (event == "PLAYER_FOCUS_CHANGED") and "focus"
      or (event == "GROUP_ROSTER_UPDATE") and "party"
      or nil   -- nil = every non-player unit
    for _, perOwner in pairs(containers) do
      for unit, c in pairs(perOwner) do
        if unit ~= "player"
           and (not wantUnit or unit == wantUnit
                or (wantUnit == "party" and unit:sub(1, 5) == "party"))
           and c.UpdateAllAuras then
          c:UpdateAllAuras()
        end
      end
    end
    return
  end
  if InCombatLockdown() then return end
  -- still secret (in-instance out-of-combat): slot creation stays deferred;
  -- retry on the next flush event
  if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then return end
  -- (containers are now per-owner-frame and created on Attach; the old global
  -- player/target pre-create no longer applies -- PTR7+ allows in-combat
  -- creation anyway, and pre-PTR7 the pending flush covers it)
  if next(pending) then
    local q = pending
    pending = {}
    for bf, req in pairs(q) do
      BD.Attach(bf, req.fs, req.cooldownID, req.trackedSpellID, req.unit, req.opts)
    end
  end
  -- Style pushes that arrived while the buttons were forbidden (secret auras):
  -- re-run now; ApplyStyle re-defers itself if secrecy somehow still holds.
  if next(styleDeferred) then
    local q = styleDeferred
    styleDeferred = {}
    for bf, s in pairs(q) do
      BD.ApplyStyle(bf, s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9])
    end
  end
end)

-- ── diagnostics dump / debug toggle ─────────────────────────────────────────
SLASH_ARCBARDUR1 = "/arcbardur"
SlashCmdList["ARCBARDUR"] = function(msg)
  msg = (msg or ""):gsub("%s+", ""):lower()
  -- The saved flag is written for a future load-window capture but nothing reads
  -- it back at load, so debug is ALWAYS off after a reload (BD.debug = false at
  -- file scope). That is deliberate for now: the trace builds a table per
  -- duration-bar refresh, so a diagnostic that silently survives reloads would
  -- cost every user who ever ran it once. Do not advertise persistence until a
  -- restore is actually wired.
  if msg == "debug" or msg == "on" then
    BD.debug = true
    local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if g then g.barDurDebug = true end
    print("|cff33ff99[ArcBarDur]|r debug ON for THIS session (a /reload clears it). '/arcbardur log' opens the copyable window.")
    return
  end
  if msg == "off" then
    BD.debug = false
    local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if g then g.barDurDebug = nil end
    print("|cff33ff99[ArcBarDur]|r debug OFF")
    return
  end
  if msg == "log"                 then ToggleLogWindow(); return end
  if msg == "chat" then
    BD.debugChat = not BD.debugChat
    print("|cff33ff99[ArcBarDur]|r chat echo " .. (BD.debugChat and "ON" or "OFF"))
    return
  end

  print("|cff33ff99[ArcBarDur]|r ===== 12.1 duration driver status =====")
  print(("  IS_121=%s  AurasSecret(player)=%s"):format(
    tostring(IS_121), tostring(ns.API and ns.API.AurasSecret and ns.API.AurasSecret("player"))))
  print(("  counters: attachCalls=%d newSlots=%d retargets=%d initFired=%d newContainers=%d combatDefer=%d badArgs=%d"):format(
    diag.attachCall, diag.slotNew, diag.slotRetarget, diag.initFired, diag.containerNew, diag.combatDefer, diag.badArgs))
  print(("  loadWindow: attachesDuringPrebuild=%d emptyCandidateSets=%d  (empty = the CDM lookup gave nothing)"):format(
    diag.prebuild, diag.emptySet))
  local nCont = 0
  for _, perOwner in pairs(containers) do
    for u, c in pairs(perOwner) do
      nCont = nCont + 1
      print(("  container[%s] #%d: shown=%s alpha=%.1f"):format(u, nCont, tostring(c:IsShown()), c:GetAlpha() or -1))
    end
  end
  local nAtt = 0
  for bf, a in pairs(attached) do
    nAtt = nAtt + 1
    local parts = {}
    for _, sub in ipairs(a.subs or {}) do
      local kind = sub.stepKind and ("step:" .. sub.stepKind .. "@" .. tostring(sub.stepT))
        or (sub.widthFrac and "band") or "base"
      parts[#parts + 1] = ("%s/%s/init=%s%s%s"):format(sub.filter, kind, tostring(sub.initFired),
        sub.stepMask and "/mask" or "", sub.geomPending and "/PARKED" or "")
    end
    print(("  driving: cooldownID=%s spellIDs={%s} subs=[%s]"):format(
      tostring(a.cooldownID), SetKeys(a.spellIDs), table.concat(parts, "  ")))
    print(("    appMax=%s bandsKey=%s"):format(tostring(a.applicationMax), tostring(a.bandsKey)))
  end
  if nAtt == 0 then print("  driving: (none)") end

  -- WAITING: everything that asked for a slot and could not get one. On 12.1
  -- auras are secret even out of combat, so anything landing here outside the
  -- load window is stuck for the session -- this is the list that matters.
  local nPend = 0
  for _bf, req in pairs(pending) do
    nPend = nPend + 1
    print(("  WAITING: cd=%s tracked=%s unit=%s steps=%s"):format(
      tostring(req.cooldownID), tostring(req.trackedSpellID), tostring(req.unit),
      tostring(req.opts and ((req.opts.durationSteps and #req.opts.durationSteps)
        or (req.opts.applicationSteps and #req.opts.applicationSteps) or 0))))
  end
  if nPend == 0 then print("  WAITING: (none)") end

  -- Geometry dump ('/arcbardur geo'): rect + level of every layer in the fill
  -- stack, to pin down any fill-over-border bleed. Button-descendant reads are
  -- SECRET/forbidden while auras are secret -> desk-only.
  if msg == "geo" then
    local secretNow = C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
    if secretNow then print("  geo: auras SECRET -- button rects unreadable, zone out first"); return end
    local function R(region, label)
      if not region then return label .. "=nil" end
      local x, y, w, h = region:GetRect()
      local lvl = region.GetFrameLevel and region:GetFrameLevel()
      if not x then return ("%s=noRect lvl=%s"):format(label, tostring(lvl)) end
      return ("%s=(%.1f,%.1f %.1fx%.1f)%s"):format(label, x, y, w, h, lvl and (" lvl=" .. lvl) or "")
    end
    for bf, a in pairs(attached) do
      print(("  geo bar cd=%s:"):format(tostring(a.cooldownID or a.idKey)))
      print("    " .. R(bf, "frame") .. "  " .. R(bf.bar, "frame.bar"))
      local bd = bf.barBorderFrame
      print(("    border shown=%s lvl=%s  %s"):format(
        tostring(bd and bd:IsShown()), tostring(bd and bd:GetFrameLevel()),
        bd and R(bd.bottom, "bottomStrip") or ""))
      for _, sub in ipairs(a.subs or {}) do
        if sub.initFired and sub.button then
          print("    " .. R(sub.button, "button") .. "  " .. R(sub.arcBar, "ArcBar"))
          local ft = sub.arcBar and sub.arcBar.GetStatusBarTexture and sub.arcBar:GetStatusBarTexture()
          print("    " .. R(ft, "fillTex"))
        end
      end
    end
    return
  end
  local nMir = 0
  for _bf, rec in pairs(mirrorByBar) do
    nMir = nMir + 1
    print(("  mirror: cd=%s frame=%s srcBar=%s fs=%s fsShown=%s"):format(
      tostring(rec.cooldownID), tostring(rec.frame ~= nil), tostring(rec.srcBar ~= nil),
      tostring(rec.fs ~= nil),
      tostring(rec.fs and rec.fs.IsShown and rec.fs:IsShown())))
    if rec.fs then
      local par = rec.fs:GetParent()
      local pShown = par and par:IsShown()
      local pw = par and par:GetWidth() or -1
      local ph = par and par:GetHeight() or -1
      local pt, rel, relPt, px, py
      if par and par.GetPoint then pt, rel, relPt, px, py = par:GetPoint(1) end
      local a = rec.fs.GetAlpha and rec.fs:GetAlpha() or -1
      local fw = rec.fs.GetStringWidth and rec.fs:GetStringWidth()
      if fw and issecretvalue and issecretvalue(fw) then fw = "secret" end
      print(("  mirror fs: visible=%s alpha=%.2f strW=%s | parent shown=%s size=%.0fx%.0f point=%s->%s %s(%.0f,%.0f)"):format(
        tostring(rec.fs.IsVisible and rec.fs:IsVisible()), a, tostring(fw),
        tostring(pShown), pw, ph,
        tostring(pt), rel and (rel.GetName and (rel:GetName() or "unnamed") or "?") or "nil",
        tostring(relPt), px or 0, py or 0))
    end
  end
  print(("  mirror pushes: value=%d text=%d (records=%d)"):format(
    mirDiag.value, mirDiag.fbText, nMir))
  print("  --- what Display saw per duration bar (BD.Trace) ---")
  local any = false
  for bn, t in pairs(BD.lastTrace) do
    any = true
    -- hasTotemInfo was recorded but never printed; it is the field that says
    -- whether a totem bar took the totem branch or fell through to a mirror
    print(("  bar %s: active=%s hasAuraInfo=%s hasTotemInfo=%s cooldownID=%s trackedSpellID=%s showDuration=%s secret=%s"):format(
      tostring(bn), tostring(t.active), tostring(t.hasAuraInfo), tostring(t.hasTotemInfo),
      tostring(t.cooldownID), tostring(t.trackedSpellID), tostring(t.showDuration), tostring(t.secret)))
  end
  if not any then print("  (no duration-bar updates traced yet -- is the bar active/shown?)") end
end
