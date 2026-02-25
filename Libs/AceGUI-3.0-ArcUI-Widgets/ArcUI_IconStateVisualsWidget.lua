-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Icon State Visuals Widget  (v5)
-- Custom AceGUI widget: standardized grid for per-state visual config.
-- Columns: State | Enable | Tint | Desat | Glow | Alpha | Reset | Edit
--
-- Supports two modes via bridge pattern:
--   "ArcUI-IconStateVisualsPanel"       → per-icon (via OptionsHelpers)
--   "ArcUI-GlobalIconStateVisualsPanel"  → global   (via GlobalCooldownBridge)
--
-- Styled to match AceGUI visual language (GameFontNormal gold labels,
-- Heading separator textures, matching checkbox/swatch constructors).
-- Edit buttons expand the detailed sub-sections below the grid.
-- ═══════════════════════════════════════════════════════════════════════════

local addonName, ns = ...

local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI then return end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local WIDGET_TYPE    = "ArcUI-IconStateVisualsPanel"
local WIDGET_VERSION = 5

local ROW_HEIGHT     = 36
local HEADER_HEIGHT  = 22
local PAD_TOP        = 8
local PAD_BOTTOM     = 10

-- Column center X positions (content is centered around these)
local COL_LABEL_LEFT = 12    -- left-aligned, not centered
local COL_LABEL_W    = 140
local COL_ENABLE_CX  = 185   -- center X for Enable column
local COL_TINT_CX    = 240   -- center X for Tint column
local COL_DESAT_CX   = 300   -- center X for Desat column
local COL_GLOW_CX    = 360   -- center X for Glow column
local COL_ALPHA_CX   = 460   -- center X for Alpha slider
local COL_RESET_CX   = 560   -- center X for Reset
local COL_EDIT_CX    = 600   -- center X for Edit button

-- Slider throttle
local SLIDER_THROTTLE = 0.05

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════

local STATES = {
  {
    id    = "readyNormal",
    label = "Ready / Normal",
    color = { 0.27, 1.0, 0.27 },
    enable = nil,
    tint = {
      enableKey    = "spellUsability.useNormalColor",
      colorKey     = "spellUsability.normalColor",
      defaultColor = { 1, 1, 1 },
    },
    alpha = { key = "cooldownStateVisuals.readyState.alpha", default = 1.0 },
    desat = { key = "spellUsability.normalDesaturate" },
    glow  = { key = "cooldownStateVisuals.readyState.glow" },
    editSection = "glowSettings",
    editTooltip = "Configure Ready Glow and Usable Glow: style, color, speed, particles...",
    resetKeys = {
      "spellUsability.useNormalColor",
      "spellUsability.normalColor",
      "spellUsability.normalDesaturate",
      "cooldownStateVisuals.readyState.alpha",
    },
  },
  {
    id    = "onCooldown",
    label = "On Cooldown",
    color = { 1.0, 0.53, 0.27 },
    enable = nil,
    tint = {
      enableKey    = "spellUsability.useOnCooldownColor",
      colorKey     = "spellUsability.onCooldownColor",
      defaultColor = { 0.4, 0.4, 0.4 },
    },
    alpha = { key = "cooldownStateVisuals.cooldownState.alpha", default = 1.0 },
    desat = { key = "spellUsability.onCooldownDesaturate" },
    glow  = nil,
    editSection = "onCooldownState",
    editTooltip = "Preserve duration text, wait for no charges...",
    resetKeys = {
      "spellUsability.useOnCooldownColor",
      "spellUsability.onCooldownColor",
      "spellUsability.onCooldownDesaturate",
      "cooldownStateVisuals.cooldownState.alpha",
    },
  },
  {
    id    = "auraActive",
    label = "Aura Active",
    color = { 0.27, 0.87, 1.0 },
    enable = {
      key     = "auraActiveState.ignoreAuraOverride",
      legacyKey = "cooldownSwipe.ignoreAuraOverride",
      default = false,
      inverted = true,
    },
    tint  = nil,
    desat = nil,
    alpha = nil,
    tooltip = "When enabled, aura/buff duration overrides the cooldown display.\nDisable to always show the spell cooldown instead.",
    resetKeys = {
      "auraActiveState.ignoreAuraOverride",
    },
  },
  {
    id    = "outOfRange",
    label = "Out of Range",
    color = { 1.0, 0.27, 0.27 },
    enable = { key = "rangeIndicator.enabled", default = true },
    tint    = nil,
    desat   = nil,
    alpha   = nil,
    tooltip = "Toggle the out-of-range darkening overlay.",
    resetKeys = {
      "rangeIndicator.enabled",
    },
  },
  {
    id    = "notEnoughResource",
    label = "Not Enough Resource",
    color = { 0.5, 0.5, 1.0 },
    enable = nil,
    tint = {
      enableKey    = nil,
      colorKey     = "spellUsability.notEnoughResourceColor",
      defaultColor = { 0.5, 0.5, 1.0 },
    },
    alpha = { key = "spellUsability.notEnoughResourceAlpha", default = 1.0 },
    desat = { key = "spellUsability.notEnoughResourceDesaturate" },
    resetKeys = {
      "spellUsability.notEnoughResourceColor",
      "spellUsability.notEnoughResourceDesaturate",
      "spellUsability.notEnoughResourceAlpha",
    },
  },
  {
    id    = "notUsable",
    label = "Not Usable",
    color = { 0.6, 0.6, 0.6 },
    enable = nil,
    tint = {
      enableKey    = nil,
      colorKey     = "spellUsability.notUsableColor",
      defaultColor = { 0.4, 0.4, 0.4 },
    },
    alpha = { key = "spellUsability.notUsableAlpha", default = 1.0 },
    desat = { key = "spellUsability.notUsableDesaturate" },
    resetKeys = {
      "spellUsability.notUsableColor",
      "spellUsability.notUsableDesaturate",
      "spellUsability.notUsableAlpha",
    },
  },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- NESTED KEY HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function GetNested(tbl, dotKey)
  if not tbl or not dotKey then return nil end
  for part in dotKey:gmatch("[^.]+") do
    if type(tbl) ~= "table" then return nil end
    tbl = tbl[part]
  end
  return tbl
end

local function SetNested(tbl, dotKey, value)
  if not tbl or not dotKey then return end
  local parts = {}
  for part in dotKey:gmatch("[^.]+") do parts[#parts + 1] = part end
  for i = 1, #parts - 1 do
    if not tbl[parts[i]] then tbl[parts[i]] = {} end
    tbl = tbl[parts[i]]
  end
  tbl[parts[#parts]] = value
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONFIG BRIDGE (per-instance via frame._bridge)
--
-- Each widget instance stores a bridge table on its frame:
--   frame._bridge = { getCfg, apply, refreshVisuals, collapsedSections }
--
-- Per-icon widget: reads/writes via OptionsHelpers (selected icons)
-- Global widget:   reads/writes via GlobalCooldownBridge (global config)
-- ═══════════════════════════════════════════════════════════════════════════

local function H()   return ns.OptionsHelpers end

local function NotifyAceConfig()
  local reg = LibStub("AceConfigRegistry-3.0", true)
  if reg then reg:NotifyChange("ArcUI") end
end

-- Default per-icon bridge (set on frame._bridge in Constructor)
local function MakePerIconBridge()
  return {
    getCfg = function()
      local h = H()
      return h and h.GetCooldownCfg and h.GetCooldownCfg() or nil
    end,
    apply = function(setter)
      local h = H()
      if h and h.ApplySharedCooldownSetting then
        h.ApplySharedCooldownSetting(setter)
      end
    end,
    refreshVisuals = function()
      if ns.CDMEnhance and ns.CDMEnhance.InvalidateCache then
        ns.CDMEnhance.InvalidateCache()
      end
      if ns.CDMSpellUsability and ns.CDMSpellUsability.RefreshAll then
        ns.CDMSpellUsability.RefreshAll()
      end
      if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshAllSpellVisuals then
        ns.ArcAurasCooldown.RefreshAllSpellVisuals()
      end
    end,
    collapsedSections = function()
      local h = H()
      return h and h.collapsedSections
    end,
  }
end

-- Global bridge (uses ns.GlobalCooldownBridge set by CDMEnhanceOptions)
-- Key difference from per-icon: NO live preview during drag.
-- Config is written immediately, but the heavy RefreshIconType only runs
-- once on finalize (mouse-up, picker close, checkbox click).
local function MakeGlobalBridge()
  return {
    getCfg = function()
      local b = ns.GlobalCooldownBridge
      return b and b.getCfg and b.getCfg() or nil
    end,
    apply = function(setter)
      local b = ns.GlobalCooldownBridge
      if b and b.getCfg then
        local cfg = b.getCfg()
        if cfg then setter(cfg) end
      end
    end,
    refreshVisuals = function()
      -- NO-OP for globals: skip the heavy RefreshIconType during drag.
      -- Config is already written by apply(). Icons update on finalRefresh.
    end,
    finalRefresh = function()
      -- Called ONCE on finalize (checkbox click, slider release, picker close)
      local b = ns.GlobalCooldownBridge
      if b and b.refresh then b.refresh() end
    end,
    collapsedSections = function()
      local b = ns.GlobalCooldownBridge
      return b and b.collapsedSections
    end,
  }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UI FACTORIES
-- ═══════════════════════════════════════════════════════════════════════════

--- Color swatch (matches AceGUI-3.0 ColorPicker constructor exactly)
local function MakeSwatch(parent)
  local f = CreateFrame("Button", nil, parent)
  f:SetSize(19, 19)

  -- Matches AceGUI ColorPicker constructor layout:
  -- colorSwatch (OVERLAY) > background (BACKGROUND, 16x16 white) > checkers (BACKGROUND, 14x14)
  local colorTex = f:CreateTexture(nil, "OVERLAY")
  colorTex:SetSize(19, 19)
  colorTex:SetPoint("CENTER")
  colorTex:SetTexture(130939) -- Interface\\ChatFrame\\ChatFrameColorSwatch
  f.colorTex = colorTex

  local background = f:CreateTexture(nil, "BACKGROUND")
  background:SetSize(16, 16)
  background:SetColorTexture(1, 1, 1)
  background:SetPoint("CENTER", colorTex)

  local checkers = f:CreateTexture(nil, "BACKGROUND")
  checkers:SetSize(14, 14)
  checkers:SetTexture(188523) -- Tileset\\Generic\\Checkers
  checkers:SetTexCoord(0.25, 0, 0.5, 0.25)
  checkers:SetDesaturated(true)
  checkers:SetVertexColor(1, 1, 1, 0.75)
  checkers:SetPoint("CENTER", colorTex)

  -- Highlight on hover
  local hl = f:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(colorTex)
  hl:SetColorTexture(1, 1, 1, 0.2)

  function f:SetColor(r, g, b)
    self.colorTex:SetVertexColor(r, g, b)
    self._r, self._g, self._b = r, g, b
  end

  return f
end

--- Checkbox (matches AceGUI-3.0 CheckBox constructor exactly)
local function MakeCheck(parent)
  local f = CreateFrame("CheckButton", nil, parent)
  f:SetSize(24, 24)

  local checkbg = f:CreateTexture(nil, "ARTWORK")
  checkbg:SetAllPoints()
  checkbg:SetTexture(130755) -- Interface\\Buttons\\UI-CheckBox-Up

  local check = f:CreateTexture(nil, "OVERLAY")
  check:SetAllPoints()
  check:SetTexture(130751) -- Interface\\Buttons\\UI-CheckBox-Check
  f:SetCheckedTexture(check)
  f:SetDisabledCheckedTexture(130749) -- Interface\\Buttons\\UI-CheckBox-Check-Disabled

  local highlight = f:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetTexture(130753) -- Interface\\Buttons\\UI-CheckBox-Highlight
  highlight:SetBlendMode("ADD")
  highlight:SetAllPoints()

  return f
end

--- Compact alpha slider with throttled apply
local function MakeAlphaSlider(parent)
  local container = CreateFrame("Frame", nil, parent)
  container:SetSize(140, ROW_HEIGHT)

  local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
  slider:SetSize(100, 16)
  slider:SetPoint("LEFT", 0, 0)
  slider:SetOrientation("HORIZONTAL")
  slider:SetMinMaxValues(0, 1)
  slider:SetValueStep(0.05)
  slider:SetObeyStepOnDrag(true)

  -- Blizzard slider backdrop
  slider:SetBackdrop({
    bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile     = true, tileSize = 8, edgeSize = 8,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
  })

  -- Thumb
  local thumb = slider:CreateTexture(nil, "OVERLAY")
  thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  thumb:SetSize(22, 22)
  slider:SetThumbTexture(thumb)

  -- Value text
  local val = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  val:SetPoint("LEFT", slider, "RIGHT", 8, 0)
  val:SetWidth(36)
  val:SetJustifyH("LEFT")
  container.valText = val

  -- Throttled apply
  local lastApply = 0
  local pendingValue = nil

  slider:SetScript("OnValueChanged", function(self, v)
    v = math.floor(v * 20 + 0.5) / 20
    val:SetText(string.format("%.2f", v))
    pendingValue = v
    local now = GetTime()
    if (now - lastApply) >= SLIDER_THROTTLE then
      lastApply = now
      if container._onChange then container._onChange(v) end
      pendingValue = nil
    end
  end)

  slider:SetScript("OnMouseUp", function()
    if pendingValue and container._onChange then
      container._onChange(pendingValue)
      pendingValue = nil
    end
    lastApply = 0
    -- Flush any pending throttled apply immediately on release
    if container._onRelease then container._onRelease() end
  end)

  function container:SetValue(v) slider:SetValue(v) end
  function container:GetValue() return slider:GetValue() end

  container.slider = slider
  return container
end

--- Reset button — arrow icon with pixel-snap fixes for crispness
local function MakeResetButton(parent)
  local f = CreateFrame("Button", nil, parent)
  f:SetSize(22, 22)

  -- Arrow texture with anti-blur settings
  local icon = f:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
  icon:SetAllPoints()
  -- Prevent WoW's pixel snapping from blurring small textures
  if icon.SetSnapToPixelGrid then icon:SetSnapToPixelGrid(false) end
  if icon.SetTexelSnappingBias then icon:SetTexelSnappingBias(0) end
  icon:SetVertexColor(0.7, 0.35, 0.35)
  f.icon = icon

  -- Highlight
  local hl = f:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.15)

  f:SetScript("OnEnter", function(self)
    icon:SetVertexColor(1, 0.5, 0.5)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Reset Row", 1, 0.82, 0)
    GameTooltip:AddLine("Reset this state's settings to defaults.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  f:SetScript("OnLeave", function(self)
    icon:SetVertexColor(0.7, 0.35, 0.35)
    GameTooltip:Hide()
  end)
  f:SetScript("OnMouseDown", function() icon:SetVertexColor(0.5, 0.25, 0.25) end)
  f:SetScript("OnMouseUp", function() icon:SetVertexColor(1, 0.5, 0.5) end)

  return f
end

-- N/A placeholder centered in cell
local function MakeNA(parent, cx)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  fs:SetPoint("CENTER", parent, "LEFT", cx, 0)
  fs:SetText("--")
  return fs
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DEFERRED APPLY SYSTEM
--
-- The root cause of FPS drops: Apply() calls ApplySharedCooldownSetting()
-- which iterates all icons, writes config, InvalidateCache, UpdateCooldown,
-- RefreshAllGroupLayouts, Masque, preview refresh. And NotifyAceConfig()
-- causes AceConfigDialog to REBUILD the entire options panel (every slider,
-- toggle, color picker below the widget gets destroyed and recreated).
--
-- AceConfig's built-in color type never has this problem because its set()
-- callback only fires ONCE when the picker closes, not during drag.
--
-- Our approach:
--   COLOR PICKER: swatchFunc updates swatch visual ONLY. Zero Apply.
--                 Apply fires once when picker closes (OnHide).
--   ALPHA SLIDER: Throttled Apply (config write + icon refresh) during drag,
--                 but NO NotifyAceConfig. NotifyAceConfig on mouse-up only.
--   CHECKBOXES:   Immediate full chain (one-shot, no performance concern).
-- ═══════════════════════════════════════════════════════════════════════════

--- Full apply + refresh + panel rebuild (one-shot actions only)
local function FullApply(bridge, setter)
  bridge.apply(setter)
  bridge.refreshVisuals()
  -- For global bridge: heavy refresh runs ONCE here (not during drag)
  if bridge.finalRefresh then bridge.finalRefresh() end
  NotifyAceConfig()
end

--- Quiet apply: writes config + refreshes icons, but does NOT rebuild panel
local function QuietApply(bridge, setter)
  bridge.apply(setter)
  bridge.refreshVisuals()
  -- Deliberately no NotifyAceConfig here
end

-- ── Alpha slider throttle ──
local sliderPendingSetter = nil
local sliderPendingBridge = nil
local sliderTimerActive = false
local SLIDER_APPLY_INTERVAL = 0.2  -- max 5 quiet applies per second

local function FlushSliderApply()
  sliderTimerActive = false
  if sliderPendingSetter and sliderPendingBridge then
    local fn = sliderPendingSetter
    local br = sliderPendingBridge
    sliderPendingSetter = nil
    sliderPendingBridge = nil
    QuietApply(br, fn)
  end
end

local function ThrottledSliderApply(bridge, setter)
  sliderPendingSetter = setter
  sliderPendingBridge = bridge
  if not sliderTimerActive then
    sliderTimerActive = true
    C_Timer.After(SLIDER_APPLY_INTERVAL, FlushSliderApply)
  end
end

--- Called on slider mouse-up: flush pending + rebuild panel once
local function FinalizeSlider(bridge)
  if sliderPendingSetter and sliderPendingBridge then
    local fn = sliderPendingSetter
    local br = sliderPendingBridge
    sliderPendingSetter = nil
    sliderPendingBridge = nil
    sliderTimerActive = false
    FullApply(br, fn)
  else
    -- Pending already flushed by timer, just do final refresh + sync
    if bridge and bridge.finalRefresh then bridge.finalRefresh() end
    NotifyAceConfig()
  end
end

-- ── Color picker: zero Apply during drag ──
-- Single OnHide hook registered once. Fires the stored callback on close.
local pickerCloseCallback = nil

local function OnPickerHide()
  if pickerCloseCallback then
    local fn = pickerCloseCallback
    pickerCloseCallback = nil
    fn()
  end
end

-- Register hook exactly once
if ColorPickerFrame then
  ColorPickerFrame:HookScript("OnHide", OnPickerHide)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPEN COLOR PICKER (zero Apply during drag — only visual swatch update)
-- ═══════════════════════════════════════════════════════════════════════════

local function OpenColorPicker(swatch, def, bridge)
  local cfg = bridge.getCfg()
  local col = GetNested(cfg, def.tint.colorKey)
  local r = col and col.r or def.tint.defaultColor[1]
  local g = col and col.g or def.tint.defaultColor[2]
  local b = col and col.b or def.tint.defaultColor[3]

  -- Raise above options panel (matches AceGUI ColorPicker widget)
  pickerCloseCallback = nil  -- Prevent OnHide hook from firing stale callback
  ColorPickerFrame:Hide()    -- Reset state before reopening
  ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
  ColorPickerFrame:SetFrameLevel(swatch:GetFrameLevel() + 10)
  ColorPickerFrame:SetClampedToScreen(true)

  -- Track whether cancel was pressed
  local wasCancelled = false

  -- Register the close callback: apply final color when picker hides
  pickerCloseCallback = function()
    if wasCancelled then return end  -- cancelFunc already handled it
    local fr, fg, fb = swatch._r or 1, swatch._g or 1, swatch._b or 1
    FullApply(bridge, function(c)
      SetNested(c, def.tint.colorKey, { r = fr, g = fg, b = fb })
      if def.tint.enableKey then
        SetNested(c, def.tint.enableKey, true)
      end
    end)
  end

  local info = {
    r = r, g = g, b = b,
    swatchFunc = function()
      local nr, ng, nb = ColorPickerFrame:GetColorRGB()
      -- Instant: update swatch visual
      swatch:SetColor(nr, ng, nb)
      -- Throttled: write config + refresh icons (NO panel rebuild)
      ThrottledSliderApply(bridge, function(c)
        SetNested(c, def.tint.colorKey, { r = nr, g = ng, b = nb })
        if def.tint.enableKey then
          SetNested(c, def.tint.enableKey, true)
        end
      end)
    end,
    cancelFunc = function(prev)
      wasCancelled = true
      pickerCloseCallback = nil
      swatch:SetColor(prev.r, prev.g, prev.b)
      -- Restore original — full apply since it's one-shot
      FullApply(bridge, function(c)
        SetNested(c, def.tint.colorKey, { r = prev.r, g = prev.g, b = prev.b })
      end)
    end,
  }

  -- WoW 12.0+ API
  if ColorPickerFrame.SetupColorPickerAndShow then
    ColorPickerFrame:SetupColorPickerAndShow(info)
  else
    ColorPickerFrame.func = info.swatchFunc
    ColorPickerFrame.cancelFunc = info.cancelFunc
    ColorPickerFrame.previousValues = { r = r, g = g, b = b }
    ColorPickerFrame:SetColorRGB(r, g, b)
    ColorPickerFrame:Show()
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW BUILDER
-- ═══════════════════════════════════════════════════════════════════════════

local function BuildRow(parent, def, index)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_HEIGHT)
  row.def = def
  row._bridge = parent._bridge  -- inherit bridge from frame

  -- Alternating background
  local bg = row:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local odd = (index % 2 == 1)
  bg:SetColorTexture(
    odd and 0.05 or 0.09,
    odd and 0.05 or 0.09,
    odd and 0.07 or 0.11,
    0.5
  )

  -- Hover highlight (same as CollapsibleHeader)
  local highlight = row:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetColorTexture(1, 1, 1, 0.04)
  row:EnableMouse(true)

  -- ── STATE LABEL (left-aligned, prominent, colored) ──
  local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  label:SetPoint("LEFT", COL_LABEL_LEFT, 0)
  label:SetWidth(COL_LABEL_W)
  label:SetJustifyH("LEFT")
  label:SetText(def.label)
  if def.color then
    label:SetTextColor(def.color[1], def.color[2], def.color[3])
  end
  row.label = label

  -- Row tooltip for N/A states
  if def.tooltip and not def.enable then
    row:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(def.label, def.color[1] or 1, def.color[2] or 1, def.color[3] or 1)
      GameTooltip:AddLine(def.tooltip, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end

  local hasControls = (def.tint or def.desat or def.glow or def.alpha or def.enable)

  -- ── ENABLE COLUMN (centered) ──
  if def.enable then
    local check = MakeCheck(row)
    check:SetPoint("CENTER", row, "LEFT", COL_ENABLE_CX, 0)
    check:SetScript("OnClick", function(self)
      local checked = self:GetChecked()
      local storeVal = def.enable.inverted and (not checked) or checked
      FullApply(row._bridge, function(c)
        SetNested(c, def.enable.key, storeVal)
        if def.enable.legacyKey then
          SetNested(c, def.enable.legacyKey, nil)
        end
      end)
    end)
    check:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Enable", 1, 0.82, 0)
      if def.tooltip then
        GameTooltip:AddLine(def.tooltip, 1, 1, 1, true)
      end
      GameTooltip:Show()
    end)
    check:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.enableCheck = check
  else
    MakeNA(row, COL_ENABLE_CX)
  end

  -- ── TINT COLOR COLUMN (centered swatch) ──
  -- ── TINT COLUMN ──
  if def.tint then
    local swatch = MakeSwatch(row)
    swatch:SetPoint("CENTER", row, "LEFT", COL_TINT_CX, 0)
    swatch:SetScript("OnClick", function(self)
      OpenColorPicker(self, def, row._bridge)
    end)
    swatch:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Tint Color", 1, 0.82, 0)
      local r, g, b = self._r or 1, self._g or 1, self._b or 1
      GameTooltip:AddLine(
        string.format("|cff%02x%02x%02xR:%.0f  G:%.0f  B:%.0f|r",
          r * 255, g * 255, b * 255, r * 255, g * 255, b * 255),
        1, 1, 1)
      GameTooltip:AddLine("Click to pick a color.", 0.6, 0.6, 0.6)
      if def.tint.enableKey then
        GameTooltip:AddLine("Picking a color auto-enables the tint override.", 0.6, 0.6, 0.6)
      end
      GameTooltip:Show()
    end)
    swatch:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.swatch = swatch
  else
    MakeNA(row, COL_TINT_CX)
  end

  -- ── DESAT COLUMN (centered checkbox, no label — header says it) ──
  if def.desat then
    local check = MakeCheck(row)
    check:SetPoint("CENTER", row, "LEFT", COL_DESAT_CX, 0)
    check:SetScript("OnClick", function(self)
      local checked = self:GetChecked()
      FullApply(row._bridge, function(c) SetNested(c, def.desat.key, checked) end)
    end)
    check:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Desaturate", 1, 0.82, 0)
      GameTooltip:AddLine("Grayscale the icon in this state.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    check:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.desatCheck = check
  else
    MakeNA(row, COL_DESAT_CX)
  end

  -- ── GLOW COLUMN (enable toggle) ──
  if def.glow then
    local check = MakeCheck(row)
    check:SetPoint("CENTER", row, "LEFT", COL_GLOW_CX, 0)
    check:SetScript("OnClick", function(self)
      local checked = self:GetChecked()
      FullApply(row._bridge, function(c) SetNested(c, def.glow.key, checked) end)
    end)
    check:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Glow", 1, 0.82, 0)
      GameTooltip:AddLine("Enable glow effect in this state.", 1, 1, 1, true)
      if def.editSection then
        GameTooltip:AddLine("Use Edit to configure glow style, color, speed.", 0.5, 0.8, 1.0, true)
      end
      GameTooltip:Show()
    end)
    check:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.glowCheck = check
  else
    MakeNA(row, COL_GLOW_CX)
  end

  -- ── ALPHA COLUMN (centered slider) ──
  if def.alpha then
    local alphaSlider = MakeAlphaSlider(row)
    -- Center the slider container around COL_ALPHA_CX
    alphaSlider:SetPoint("CENTER", row, "LEFT", COL_ALPHA_CX, 0)
    alphaSlider._onChange = function(val)
      ThrottledSliderApply(row._bridge, function(c) SetNested(c, def.alpha.key, val) end)
    end
    alphaSlider._onRelease = function() FinalizeSlider(row._bridge) end
    row.alphaSlider = alphaSlider
  else
    MakeNA(row, COL_ALPHA_CX)
  end

  -- ── RESET BUTTON (centered) ──
  if hasControls and def.resetKeys then
    local resetBtn = MakeResetButton(row)
    resetBtn:SetPoint("CENTER", row, "LEFT", COL_RESET_CX, 0)
    resetBtn:SetScript("OnClick", function()
      FullApply(row._bridge, function(c)
        for _, key in ipairs(def.resetKeys) do
          SetNested(c, key, nil)
        end
      end)
      if row._refreshFunc then row._refreshFunc() end
    end)
    row.resetBtn = resetBtn
  end

  -- ── EDIT BUTTON (opens detailed sub-section below grid) ──
  if def.editSection then
    local editBtn = CreateFrame("Button", nil, row)
    editBtn:SetSize(30, 16)
    editBtn:SetPoint("CENTER", row, "LEFT", COL_EDIT_CX, 0)

    local editText = editBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    editText:SetPoint("CENTER")
    editText:SetText("Edit")
    editText:SetTextColor(0.4, 0.7, 1.0)
    editBtn._text = editText

    local editHl = editBtn:CreateTexture(nil, "HIGHLIGHT")
    editHl:SetAllPoints()
    editHl:SetColorTexture(1, 1, 1, 0.08)

    editBtn:SetScript("OnEnter", function(self)
      editText:SetTextColor(0.6, 0.85, 1.0)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Edit Details", 1, 0.82, 0)
      if def.editTooltip then
        GameTooltip:AddLine(def.editTooltip, 1, 1, 1, true)
      end
      GameTooltip:Show()
    end)
    editBtn:SetScript("OnLeave", function()
      editText:SetTextColor(0.4, 0.7, 1.0)
      GameTooltip:Hide()
    end)
    editBtn:SetScript("OnClick", function()
      -- Expand the relevant sub-section and refresh panel
      local sections = row._bridge and row._bridge.collapsedSections and row._bridge.collapsedSections()
      if sections then
        sections[def.editSection] = false
        -- Also ensure parent umbrella is expanded
        if sections.iconStateVisuals ~= nil then
          sections.iconStateVisuals = false
        end
      end
      NotifyAceConfig()
    end)
    row.editBtn = editBtn
  end

  return row
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REFRESH ROW FROM CONFIG
-- ═══════════════════════════════════════════════════════════════════════════

local function RefreshRow(row)
  local def = row.def
  local bridge = row._bridge
  local cfg = bridge and bridge.getCfg() or nil
  if not cfg then return end

  -- Enable
  if def.enable and row.enableCheck then
    local val = GetNested(cfg, def.enable.key)
    -- Check legacy key if primary is nil
    if val == nil and def.enable.legacyKey then
      val = GetNested(cfg, def.enable.legacyKey)
    end
    if val == nil then val = def.enable.default end
    -- Invert for display if needed (e.g. ignoreAuraOverride → show as "enabled")
    local displayVal = def.enable.inverted and (not val) or val
    row.enableCheck:SetChecked(displayVal and true or false)
  end

  -- Tint swatch
  if def.tint and row.swatch then
    local col = GetNested(cfg, def.tint.colorKey)
    local r = col and col.r or def.tint.defaultColor[1]
    local g = col and col.g or def.tint.defaultColor[2]
    local b = col and col.b or def.tint.defaultColor[3]
    row.swatch:SetColor(r, g, b)

    -- Dim swatch if enableKey exists and is off
    if def.tint.enableKey then
      local on = GetNested(cfg, def.tint.enableKey) or false
      row.swatch:SetAlpha(on and 1.0 or 0.4)
    end
  end

  -- Desat
  if def.desat and row.desatCheck then
    row.desatCheck:SetChecked(GetNested(cfg, def.desat.key) or false)
  end

  -- Glow
  if def.glow and row.glowCheck then
    row.glowCheck:SetChecked(GetNested(cfg, def.glow.key) or false)
  end

  -- Alpha
  if def.alpha and row.alphaSlider then
    local v = GetNested(cfg, def.alpha.key)
    if v == nil then v = def.alpha.default end
    row.alphaSlider:SetValue(v)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WIDGET CONSTRUCTOR
-- ═══════════════════════════════════════════════════════════════════════════

local function Constructor(isGlobal)
  local totalHeight = PAD_TOP + HEADER_HEIGHT + (#STATES * ROW_HEIGHT) + PAD_BOTTOM

  local frame = CreateFrame("Frame", nil, UIParent)
  frame:SetHeight(totalHeight)

  -- Set bridge based on mode
  frame._bridge = isGlobal and MakeGlobalBridge() or MakePerIconBridge()

  -- ── Top separator (matches AceGUI Heading widget texture) ──
  local topLine = frame:CreateTexture(nil, "BACKGROUND")
  topLine:SetPoint("TOPLEFT", 3, -PAD_TOP)
  topLine:SetPoint("TOPRIGHT", -3, -PAD_TOP)
  topLine:SetHeight(8)
  topLine:SetTexture(137057) -- Interface\\Tooltips\\UI-Tooltip-Border (same as AceGUI Heading)
  topLine:SetTexCoord(0.81, 0.94, 0.5, 1)

  -- ── Column labels (GameFontNormal gold — matches AceGUI labels) ──
  local function HdrLabel(text, x, w, justify)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local yCenter = -(PAD_TOP + 2 + HEADER_HEIGHT * 0.5)
    if justify == "LEFT" then
      fs:SetPoint("LEFT", frame, "TOPLEFT", x, yCenter)
    else
      fs:SetPoint("CENTER", frame, "TOPLEFT", x, yCenter)
    end
    if w then fs:SetWidth(w) end
    fs:SetText(text)
    -- GameFontNormal is already gold (1, 0.82, 0) — no override needed
    return fs
  end

  HdrLabel("State",  COL_LABEL_LEFT, COL_LABEL_W, "LEFT")
  HdrLabel("Enable", COL_ENABLE_CX,  60)
  HdrLabel("Tint",   COL_TINT_CX,    50)
  HdrLabel("Desat",  COL_DESAT_CX,   50)
  HdrLabel("Glow",   COL_GLOW_CX,    50)
  HdrLabel("Alpha",  COL_ALPHA_CX,   80)

  -- Separator below headers (same AceGUI Heading texture)
  local hdrLine = frame:CreateTexture(nil, "BACKGROUND")
  hdrLine:SetPoint("TOPLEFT", 3, -(PAD_TOP + HEADER_HEIGHT))
  hdrLine:SetPoint("TOPRIGHT", -3, -(PAD_TOP + HEADER_HEIGHT))
  hdrLine:SetHeight(8)
  hdrLine:SetTexture(137057) -- Interface\\Tooltips\\UI-Tooltip-Border
  hdrLine:SetTexCoord(0.81, 0.94, 0.5, 1)

  -- ── Build rows ──
  local rows = {}
  local yOff = PAD_TOP + HEADER_HEIGHT + 1
  for i, def in ipairs(STATES) do
    local row = BuildRow(frame, def, i)
    row:SetPoint("TOPLEFT", 0, -yOff)
    row:SetPoint("TOPRIGHT", 0, -yOff)
    rows[i] = row
    yOff = yOff + ROW_HEIGHT
    row._refreshFunc = function() RefreshRow(row) end
  end

  -- ── Bottom separator (AceGUI Heading style) ──
  local bLine = frame:CreateTexture(nil, "BACKGROUND")
  bLine:SetPoint("BOTTOMLEFT", 3, PAD_BOTTOM - 2)
  bLine:SetPoint("BOTTOMRIGHT", -3, PAD_BOTTOM - 2)
  bLine:SetHeight(8)
  bLine:SetTexture(137057) -- Interface\\Tooltips\\UI-Tooltip-Border
  bLine:SetTexCoord(0.81, 0.94, 0.5, 1)

  -- ═════════════════════════════════════════════════════════════════════
  -- Widget object
  -- ═════════════════════════════════════════════════════════════════════
  local widget = {}
  widget.type  = WIDGET_TYPE
  widget.frame = frame
  widget.rows  = rows

  widget.OnAcquire = function(self)
    self.frame:Show()
    C_Timer.After(0, function()
      if self.frame:IsShown() then self:RefreshAll() end
    end)
  end

  widget.OnRelease = function(self)
    self.frame:Hide()
  end

  -- AceConfigDialog calls these on description widgets
  widget.SetText       = function(self, _) self:RefreshAll() end
  widget.SetLabel       = function(self, _) end
  widget.SetFontObject  = function(self, _) end
  widget.SetImageSize   = function(self, _, _) end
  widget.SetImage       = function(self, ...) end
  widget.SetJustifyH    = function(self, _) end
  widget.SetJustifyV    = function(self, _) end

  widget.SetWidth = function(self, width)
    self.frame:SetWidth(width)
  end

  widget.RefreshAll = function(self)
    for _, row in ipairs(self.rows) do
      RefreshRow(row)
    end
  end

  return AceGUI:RegisterAsWidget(widget)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REGISTER
-- ═══════════════════════════════════════════════════════════════════════════

local GLOBAL_WIDGET_TYPE    = "ArcUI-GlobalIconStateVisualsPanel"

AceGUI:RegisterWidgetType(WIDGET_TYPE, function() return Constructor(false) end, WIDGET_VERSION)
AceGUI:RegisterWidgetType(GLOBAL_WIDGET_TYPE, function() return Constructor(true) end, WIDGET_VERSION)