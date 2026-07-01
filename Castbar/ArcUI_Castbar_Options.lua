-- ===================================================================
-- ArcUI_Castbar_Options.lua
-- Castbar appearance panel — collapsible sections, styled to match the
-- shared aura/cooldown bar appearance panel (ns.AppearanceOptions).
-- ===================================================================

local ADDON, ns = ...
ns.CastbarOptions = ns.CastbarOptions or {}

local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)


-- Collapsible-section state (true = collapsed). Same mechanism the aura panel uses.
local collapsedSections = {
  autoShare      = true,
  skins          = true,
  barSize        = true,
  fill           = true,
  colorOptions   = true,
  empowerStages  = true,
  uninterruptible = true,
  background     = true,
  border         = true,
  frameStrata    = true,
  tickMarks      = true,
  barIcon        = true,
  text           = true,
  position       = true,
  groupAnchor    = true,
  behavior       = true,
  latency        = true,
  interruptFeedback = true,
  spellOverrides = true,
}

local function GetCastbarDB()
  -- Resolve via the shared-aware store so shared-castbar mode (account-wide) is honored.
  local db = ns.API and ns.API.GetCastbarStore and ns.API.GetCastbarStore()
  -- Phase 1: edit instance 1. Phase 2 will route this through the selected-instance id.
  return db and db.castbars and db.castbars[ns.CastbarOptions._selectedID or 1]
end

-- Bar POSITION config: routes through the runtime's location resolver so the X/Y sliders edit the
-- same store the bar uses (per-character in shared mode unless location sharing is on).
local function PosCfg()
  return (ns.Castbar and ns.Castbar.GetPositionCfg and ns.Castbar.GetPositionCfg()) or GetCastbarDB()
end

local _notifyToken = 0
local function Refresh()
  -- Update the bar immediately for smooth live feedback while dragging a slider...
  if ns.Castbar and ns.Castbar.ApplyAppearance then ns.Castbar.ApplyAppearance() end
  -- ...but debounce the expensive options-tree rebuild (NotifyChange) so sliders don't get
  -- sticky mid-drag — only the last call within ~0.1s actually rebuilds the panel.
  _notifyToken = _notifyToken + 1
  local token = _notifyToken
  C_Timer.After(0.1, function()
    if token == _notifyToken and AceConfigRegistry then
      AceConfigRegistry:NotifyChange("ArcUI")
    end
  end)
end

local function RefreshSegs()
  if ns.Castbar and ns.Castbar.RefreshSegmentBars then ns.Castbar.RefreshSegmentBars() end
  Refresh()
end

-- Profile-gated sections: shown ONLY when editing a given cast-type profile, or HIDDEN
-- when editing it. Empowered Stages is empower-only; Tick Marks is hidden for empower
-- (empower uses its own stage dividers).
local SECTION_ONLY_PROFILE = { empowerStages = "empower" }
local SECTION_HIDE_PROFILE = { tickMarks = "empower" }

local function SectionProfileHidden(section)
  local p = ns.CastbarOptions._editProfile or "hardcast"
  local only = SECTION_ONLY_PROFILE[section]
  if only and p ~= only then return true end
  local hide = SECTION_HIDE_PROFILE[section]
  if hide and p == hide then return true end
  return false
end

-- hidden() factory: hide when the section is collapsed, profile-gated out, or an extra test is true.
local function H(section, extra)
  return function()
    if collapsedSections[section] then return true end
    if SectionProfileHidden(section) then return true end
    if extra then return extra() end
    return false
  end
end

-- ── Cast-type profile-aware get/set ───────────────────────────────
-- Profiled keys (per-type categories that are NOT shared) read/write the selected
-- cast-type profile; shared keys read/write the base config.
local function EditTarget(c, key)
  if ns.Castbar and ns.Castbar.IsKeyProfiled and ns.Castbar.IsKeyProfiled(c, key) then
    local p = ns.CastbarOptions._editProfile or "hardcast"
    c.profiles = c.profiles or {}
    c.profiles[p] = c.profiles[p] or {}
    return c.profiles[p]
  end
  return c
end
local function PGet(c, key, default)
  local t = EditTarget(c, key)
  local v = t[key]
  if v == nil then v = c[key] end
  if v == nil then v = default end
  return v
end
local function PSet(c, key, value)
  EditTarget(c, key)[key] = value
end
local function PGetColor(c, key, dr, dg, db_, da)
  local col = PGet(c, key)
  if type(col) ~= "table" then return dr, dg, db_, da end
  return col.r, col.g, col.b, col.a or (da or 1)
end
local function PSetColor(c, key, r, g, b, a)
  PSet(c, key, { r = r, g = g, b = b, a = a })
end

-- Per-profile color-threshold slot accessor (creates the array/entry on the right target).
local function ThresholdSlot(c, i)
  local t = EditTarget(c, "colorThresholds")
  t.colorThresholds = t.colorThresholds or {}
  t.colorThresholds[i] = t.colorThresholds[i] or {}
  return t.colorThresholds[i]
end

-- Auto Share category checkbox (checked = shared across all cast types).
local function ShareToggle(label, cat, order, width)
  return {
    type   = "toggle",
    name   = label,
    order  = order,
    width  = width or 0.8,
    hidden = function() return collapsedSections.autoShare end,
    get    = function() local c = GetCastbarDB(); return c and c.autoShareCategories and c.autoShareCategories[cat] end,
    set    = function(_, v)
      local c = GetCastbarDB()
      if c then c.autoShareCategories = c.autoShareCategories or {}; c.autoShareCategories[cat] = v; Refresh() end
    end,
  }
end

-- Collapsible section header (matches ns.AppearanceOptions "CollapsibleHeader" controls).
local function Header(name, section, order)
  return {
    type          = "toggle",
    name          = name,
    desc          = "Click to expand/collapse",
    dialogControl = "CollapsibleHeader",
    get           = function() return not collapsedSections[section] end,
    set           = function(_, v) collapsedSections[section] = not v end,
    order         = order,
    width         = "full",
    hidden        = function() return SectionProfileHidden(section) end,
  }
end

-- ===================================================================
-- OPTIONS TABLE
-- ===================================================================
function ns.CastbarOptions.GetOptionsTable()
  local opts = {
    type  = "group",
    name  = "Castbar",
    order = 3.5,
    args  = {

      -- ── Top: Enable + Cast Type Profile ────────────────────────────
      selectHeader = {
        type = "description",
        name = "|cffffd100Player Castbar|r — one bar for every cast. Pick a Cast Type Profile to style hardcasts, channels and empowered casts differently; Auto Share controls what's shared vs per-type.",
        order = 0.5,
        fontSize = "medium",
      },

      enabled = {
        type  = "toggle",
        name  = "|cffffd100Enable Castbar|r",
        desc  = "Show the castbar while casting or channeling spells.",
        order = 0.55,
        width = 1.2,
        get   = function() local c = GetCastbarDB(); return c and c.enabled end,
        set   = function(_, v) local c = GetCastbarDB(); if c then c.enabled = v; Refresh() end end,
      },

      hideCastBar = {
        type  = "toggle",
        name  = "Hide Blizzard Castbar",
        desc  = "Hide the default Blizzard castbar (PlayerCastingBarFrame).",
        order = 0.56,
        width = 1.3,
        get   = function() local c = GetCastbarDB(); return c and c.hideCastBar end,
        set   = function(_, v)
          local c = GetCastbarDB()
          if c then
            c.hideCastBar = v
            if ns.Castbar and ns.Castbar.ApplyAppearance then
              ns.Castbar.ApplyAppearance()
            end
          end
        end,
      },

      shareCastbar = {
        type    = "toggle",
        name    = "Share Castbar Across Characters",
        desc    = "Use ONE castbar for every character on your account. When you turn this on, THIS character's current castbar appearance becomes the shared one. Your other characters' own castbars are kept and restored if you turn this off.\n\n|cffff9900Account-wide. Your aura bars are not affected.|r",
        order   = 0.57,
        width   = 2.0,
        confirm = function(_, v)
          if v and not (ns.db and ns.db.global and ns.db.global.castbarSharedInit) then
            return "Make THIS character's current castbar the shared one for all your characters?\n\nYour other characters' castbars are kept and restored if you turn this back off."
          end
          return false
        end,
        get     = function() return ns.db and ns.db.global and ns.db.global.castbarShared end,
        set     = function(_, v)
          local g = ns.db and ns.db.global
          if not g then return end
          if v and not g.castbarSharedInit then
            if ns.Castbar and ns.Castbar.PromoteToShared then ns.Castbar.PromoteToShared() end
            g.castbarSharedInit = true
          end
          g.castbarShared = v
          Refresh()
        end,
      },

      shareCastbarLocation = {
        type   = "toggle",
        name   = "Also Share Castbar Position",
        desc   = "When the castbar is shared, also use the SAME on-screen position on every character.\n\nOff (default): each character places the shared castbar wherever they like; only the look is shared.",
        order  = 0.575,
        width  = 2.0,
        hidden = function() return not (ns.db and ns.db.global and ns.db.global.castbarShared) end,
        get    = function() return ns.db and ns.db.global and ns.db.global.castbarShareLocation end,
        set    = function(_, v)
          local g = ns.db and ns.db.global
          if not g then return end
          g.castbarShareLocation = v
          Refresh()
        end,
      },

      profileSelector = {
        type    = "select",
        name    = "Cast Type Profile",
        desc    = "Which cast type's look you're editing. Per-type categories below apply to this profile.",
        order   = 0.6,
        width   = 1.2,
        values  = { hardcast = "Hardcast", channel = "Channel", empower = "Empowered" },
        sorting = { "hardcast", "channel", "empower" },
        get     = function() return ns.CastbarOptions._editProfile or "hardcast" end,
        set     = function(_, v)
          ns.CastbarOptions._editProfile = v
          if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
          if ns.Castbar and ns.Castbar.ApplyAppearance then ns.Castbar.ApplyAppearance() end
        end,
      },

      editingHeader = {
        type     = "description",
        order    = 0.65,
        fontSize = "medium",
        name     = function()
          local L = { hardcast = "Hardcast", channel = "Channel", empower = "Empowered" }
          local p = ns.CastbarOptions._editProfile or "hardcast"
          return "|cff00ff00Editing " .. (L[p] or p) .. ".|r Per-type categories below apply when this cast type is active."
        end,
      },

      -- ══ Auto Share ═════════════════════════════════════════════════
      autoShareHeader = Header("Auto Share", "autoShare", 5),

      autoShareDesc = {
        type     = "description",
        name     = "Which appearance categories are shared across all cast types vs customised per type. Checked = shared, unchecked = independent per type.",
        order    = 5.05,
        fontSize = "small",
        hidden   = H("autoShare"),
      },

      shareColors     = ShareToggle("Colors",     "colors",     5.1,  0.8),
      shareFill       = ShareToggle("Fill",       "fill",       5.12, 0.7),
      shareText       = ShareToggle("Text",       "text",       5.14, 0.7),
      shareBackground = ShareToggle("Background", "background", 5.16, 1.0),
      shareBorder     = ShareToggle("Border",     "border",     5.18, 0.8),
      shareTickMarks  = ShareToggle("Tick Marks", "tickMarks",  5.2,  0.9),

      resetToBase = {
        type   = "execute",
        name   = "Reset This Profile",
        desc   = "Clear the selected cast type's per-type overrides so it falls back to the base look.",
        order  = 5.5,
        width  = 1.0,
        hidden = H("autoShare"),
        func   = function()
          local c = GetCastbarDB()
          local p = ns.CastbarOptions._editProfile or "hardcast"
          if c and c.profiles then
            c.profiles[p] = {}
            Refresh()
            if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
          end
        end,
      },

      clearAllProfiles = {
        type        = "execute",
        name        = "Clear All Profiles",
        desc        = "Remove all per-type customisation; every cast type uses the base look.",
        order       = 5.6,
        width       = 1.0,
        hidden      = H("autoShare"),
        confirm     = true,
        confirmText = "Clear per-type customisation for all cast types?",
        func        = function()
          local c = GetCastbarDB()
          if c then
            c.profiles = {}
            Refresh()
            if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
          end
        end,
      },

      -- ══ Skins ══════════════════════════════════════════════════════
      skinsHeader = Header("Skins", "skins", 10),

      skinsDesc = {
        type     = "description",
        name     = "Save the current look as a skin, then add rules to load skins on spec or talent change.",
        order    = 10.05,
        fontSize = "small",
        hidden   = H("skins"),
      },

      saveSkinName = {
        type   = "input",
        name   = "Skin Name",
        order  = 10.1,
        width  = 1.4,
        hidden = H("skins"),
        get    = function() local c = GetCastbarDB(); return (c and c._saveSkinNameInput) or "" end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c._saveSkinNameInput = v end end,
      },

      saveSkinButton = {
        type   = "execute",
        name   = "Save Skin",
        order  = 10.2,
        width  = 0.6,
        hidden = H("skins"),
        func   = function()
          local c = GetCastbarDB()
          if not c then return end
          local name = c._saveSkinNameInput and c._saveSkinNameInput:match("^%s*(.-)%s*$")
          if not name or name == "" then
            print("|cff00ccffArcUI|r: Enter a skin name first.")
            return
          end
          if ns.Presets and ns.Presets.SaveSkin then
            ns.Presets.SaveSkin(name, c, "castbar")
            c._saveSkinNameInput = ""
            print("|cff00ccffArcUI|r: Castbar skin |cffffd100'" .. name .. "'|r saved.")
            if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
          end
        end,
      },

      autoSwitchAddRule = {
        type   = "execute",
        name   = "+ Add Auto-Switch Rule",
        desc   = "Add a rule to load a skin on spec or talent change. Rules are checked top-down; first match wins.",
        order  = 10.3,
        width  = "full",
        hidden = H("skins", function()
          if not ns.Presets then return true end
          return ns.Presets.GetSkinCount("castbar") == 0
        end),
        func = function()
          local c = GetCastbarDB()
          if not c then return end
          if not c.presets then c.presets = {} end
          if not c.presets.autoSwitch then c.presets.autoSwitch = { rules = {} } end
          local rules = c.presets.autoSwitch.rules
          rules[#rules + 1] = { specIndices = {}, skinName = nil, talentConditions = nil, talentMatchMode = "all" }
          if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
        end,
      },

      -- ══ Bar Size ═══════════════════════════════════════════════════
      barSizeHeader = Header("Bar Size", "barSize", 20),

      width = {
        type   = "range",
        name   = "Width",
        order  = 20.1,
        min    = 50, max = 600, step = 1,
        hidden = H("barSize"),
        get    = function() local c = GetCastbarDB(); return c and c.width or 250 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.width = v; Refresh() end end,
      },

      height = {
        type   = "range",
        name   = "Height",
        order  = 20.2,
        min    = 4, max = 80, step = 1,
        hidden = H("barSize"),
        get    = function() local c = GetCastbarDB(); return c and c.height or 20 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.height = v; Refresh() end end,
      },

      opacity = {
        type      = "range",
        name      = "Opacity",
        order     = 20.3,
        min       = 0, max = 1, step = 0.05,
        isPercent = true,
        hidden    = H("barSize"),
        get       = function() local c = GetCastbarDB(); return c and PGet(c, "opacity", 1.0) end,
        set       = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "opacity", v); Refresh() end end,
      },

      -- ══ Fill ═══════════════════════════════════════════════════════
      fillHeader = Header("Fill", "fill", 30),

      texture = {
        type          = "select",
        name          = "Texture",
        order         = 30.1,
        dialogControl = "LSM30_Statusbar",
        values        = LSM and LSM:HashTable("statusbar") or {},
        hidden        = H("fill"),
        get           = function() local c = GetCastbarDB(); return c and PGet(c, "texture", "Blizzard") end,
        set           = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "texture", v); Refresh() end end,
      },

      reverseFill = {
        type   = "toggle",
        name   = "Reverse Fill",
        desc   = "Invert fill direction: casts drain right-to-left; channels fill left-to-right.",
        order  = 30.2,
        width  = "full",
        hidden = H("fill"),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "reverseFill") end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "reverseFill", v) end end,
      },

      -- ══ Color Options ══════════════════════════════════════════════
      colorHeader = Header("Color Options", "colorOptions", 40),

      barColor = {
        type     = "color",
        name     = "Bar Color",
        desc     = "Bar color for the selected Cast Type Profile. When Colors is shared (Auto Share), every cast type uses this; otherwise it's per-type.",
        order    = 40.1,
        hasAlpha = true,
        hidden   = H("colorOptions"),
        get      = function()
          local c = GetCastbarDB(); if not c then return 0.2, 0.8, 1, 1 end
          return PGetColor(c, "barColor", 0.2, 0.8, 1, 1)
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then PSetColor(c, "barColor", r, g, b, a); Refresh() end
        end,
      },

      conditionalColorEnabled = {
        type   = "toggle",
        name   = "Conditional Color",
        desc   = "Change the bar color as the cast nears completion, based on how much is left. Works for hardcasts and channels.",
        order  = 40.3,
        width  = 1.3,
        hidden = H("colorOptions"),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "conditionalColorEnabled") end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "conditionalColorEnabled", v); Refresh() end end,
      },

      conditionalColorAsSec = {
        type   = "toggle",
        name   = "As Sec",
        desc   = "Treat each threshold value as SECONDS remaining instead of PERCENT remaining.",
        order  = 40.32,
        width  = 0.7,
        hidden = H("colorOptions", function() local c = GetCastbarDB(); return not (c and PGet(c, "conditionalColorEnabled")) end),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "conditionalColorAsSec") end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "conditionalColorAsSec", v); Refresh() end end,
      },

      -- ══ Empowered Stages ═══════════════════════════════════════════
      empowerHeader = Header("Empowered Stages", "empowerStages", 50),

      empowerStagesDesc = {
        type     = "description",
        name     = "Show each empowered stage as its own colored bar segment.",
        order    = 50.05,
        fontSize = "small",
        hidden   = H("empowerStages"),
      },

      empowerStageDividers = {
        type   = "toggle",
        name   = "Stage Dividers",
        desc   = "Show a divider line at each stage boundary during an empowered cast (uses the Tick Color/Thickness). On by default.",
        order  = 50.08,
        width  = 1.3,
        hidden = H("empowerStages"),
        get    = function() local c = GetCastbarDB(); return c and c.empowerStageDividers ~= false end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.empowerStageDividers = v; RefreshSegs() end end,
      },

      empowerDividerPerColor = {
        type   = "toggle",
        name   = "Color Per Divider",
        desc   = "Color each stage divider with that stage's segment color instead of the single Tick Color.",
        order  = 50.09,
        width  = 1.3,
        hidden = H("empowerStages", function() local c = GetCastbarDB(); return not (c and c.empowerStageDividers ~= false) end),
        get    = function() local c = GetCastbarDB(); return c and c.empowerDividerPerColor end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.empowerDividerPerColor = v; RefreshSegs() end end,
      },

      empowerSegmentColorsEnabled = {
        type   = "toggle",
        name   = "Color Stage Segments",
        desc   = "Use per-stage colored segments for empowered casts.",
        order  = 50.1,
        width  = "full",
        hidden = H("empowerStages"),
        get    = function() local c = GetCastbarDB(); return c and c.empowerSegmentColorsEnabled end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.empowerSegmentColorsEnabled = v; RefreshSegs() end end,
      },

      empowerMaxStages = {
        type   = "range",
        name   = "Max Stages",
        desc   = "How many stage colors to show. Set it to the spell's stage count.",
        order  = 50.2,
        min    = 1, max = 8, step = 1,
        hidden = H("empowerStages"),
        get    = function() local c = GetCastbarDB(); return c and c.empowerMaxStages or 4 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.empowerMaxStages = v; RefreshSegs() end end,
      },

      -- ══ Uninterruptible ════════════════════════════════════════════
      uninterruptibleHeader = Header("Uninterruptible Casts", "uninterruptible", 60),

      uninterruptibleDesc = {
        type     = "description",
        name     = "Recolor the bar and border for casts that can't be interrupted.",
        order    = 60.05,
        fontSize = "small",
        hidden   = H("uninterruptible"),
      },

      uninterruptibleEnabled = {
        type   = "toggle",
        name   = "Enable Uninterruptible Styling",
        order  = 60.1,
        width  = "full",
        hidden = H("uninterruptible"),
        get    = function() local c = GetCastbarDB(); return c and c.uninterruptibleEnabled end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.uninterruptibleEnabled = v; Refresh() end end,
      },

      uninterruptibleColor = {
        type     = "color",
        name     = "Bar Color",
        desc     = "Bar color during an uninterruptible cast.",
        order    = 60.2,
        hasAlpha = true,
        hidden   = H("uninterruptible", function() local c = GetCastbarDB(); return not (c and c.uninterruptibleEnabled) end),
        get      = function()
          local c = GetCastbarDB()
          local col = c and c.uninterruptibleColor or {r=0.5,g=0.5,b=0.5,a=1}
          return col.r, col.g, col.b, col.a or 1
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then c.uninterruptibleColor = {r=r,g=g,b=b,a=a}; Refresh() end
        end,
      },

      uninterruptibleBorderColor = {
        type     = "color",
        name     = "Border Color",
        desc     = "Border color during an uninterruptible cast (only when Show Border is on).",
        order    = 60.3,
        hasAlpha = true,
        hidden   = H("uninterruptible", function() local c = GetCastbarDB(); return not (c and c.uninterruptibleEnabled) end),
        get      = function()
          local c = GetCastbarDB()
          local col = c and c.uninterruptibleBorderColor or {r=0.3,g=0.3,b=0.5,a=1}
          return col.r, col.g, col.b, col.a or 1
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then c.uninterruptibleBorderColor = {r=r,g=g,b=b,a=a}; Refresh() end
        end,
      },

      -- ══ Background ═════════════════════════════════════════════════
      backgroundHeader = Header("Background", "background", 70),

      showBackground = {
        type   = "toggle",
        name   = "Show Background",
        order  = 70.1,
        hidden = H("background"),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "showBackground") end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "showBackground", v); Refresh() end end,
      },

      backgroundColor = {
        type     = "color",
        name     = "Background Color",
        order    = 70.2,
        hasAlpha = true,
        hidden   = H("background", function() local c = GetCastbarDB(); return not (c and PGet(c, "showBackground")) end),
        get      = function()
          local c = GetCastbarDB(); if not c then return 0.1, 0.1, 0.1, 0.9 end
          return PGetColor(c, "backgroundColor", 0.1, 0.1, 0.1, 0.9)
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then PSetColor(c, "backgroundColor", r, g, b, a); Refresh() end
        end,
      },

      -- ══ Border ═════════════════════════════════════════════════════
      borderHeader = Header("Border", "border", 80),

      showBorder = {
        type   = "toggle",
        name   = "Show Border",
        order  = 80.1,
        hidden = H("border"),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "showBorder") end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "showBorder", v); Refresh() end end,
      },

      borderColor = {
        type     = "color",
        name     = "Border Color",
        order    = 80.2,
        hasAlpha = true,
        hidden   = H("border", function() local c = GetCastbarDB(); return not (c and PGet(c, "showBorder")) end),
        get      = function()
          local c = GetCastbarDB(); if not c then return 0, 0, 0, 1 end
          return PGetColor(c, "borderColor", 0, 0, 0, 1)
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then PSetColor(c, "borderColor", r, g, b, a); Refresh() end
        end,
      },

      drawnBorderThickness = {
        type   = "range",
        name   = "Border Thickness",
        order  = 80.3,
        min    = 1, max = 8, step = 1,
        hidden = H("border", function() local c = GetCastbarDB(); return not (c and PGet(c, "showBorder")) end),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "drawnBorderThickness", 2) end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "drawnBorderThickness", v); Refresh() end end,
      },

      -- ══ Frame Strata ═══════════════════════════════════════════════
      frameStrataHeader = Header("Frame Strata", "frameStrata", 90),

      barFrameStrata = {
        type   = "select",
        name   = "Strata",
        order  = 90.1,
        values = {
          BACKGROUND = "Background",
          LOW        = "Low",
          MEDIUM     = "Medium",
          HIGH       = "High",
          DIALOG     = "Dialog",
        },
        hidden = H("frameStrata"),
        get = function() local c = GetCastbarDB(); return c and c.barFrameStrata or "MEDIUM" end,
        set = function(_, v) local c = GetCastbarDB(); if c then c.barFrameStrata = v; Refresh() end end,
      },

      barFrameLevel = {
        type   = "range",
        name   = "Frame Level",
        order  = 90.2,
        min    = 1, max = 200, step = 1,
        hidden = H("frameStrata"),
        get    = function() local c = GetCastbarDB(); return c and c.barFrameLevel or 10 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.barFrameLevel = v; Refresh() end end,
      },

      -- ══ Tick Marks / Dividers ══════════════════════════════════════
      tickHeader = Header("Tick Marks / Dividers", "tickMarks", 100),

      tickMarksDesc = {
        type     = "description",
        name     = "Dividers on channeled spells. Per % spaces them evenly (works for any channel length); Custom places them at exact percentages. Per-spell overrides take priority.",
        order    = 100.05,
        fontSize = "small",
        hidden   = H("tickMarks"),
      },

      tickMarksEnabled = {
        type   = "toggle",
        name   = "Enable Tick Marks",
        desc   = "Show tick mark dividers during channeled spells.",
        order  = 100.1,
        width  = 1.4,
        hidden = H("tickMarks"),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "tickMarksEnabled") end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "tickMarksEnabled", v); Refresh() end end,
      },

      tickShowOn = {
        type    = "select",
        name    = "Show On",
        desc    = "Which casts get tick marks. Empowered casts always use stage segments instead.",
        order   = 100.15,
        width   = 0.9,
        values  = { channels = "Channels only", all = "All casts" },
        sorting = { "channels", "all" },
        hidden  = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled")) end),
        get     = function() local c = GetCastbarDB(); return c and PGet(c, "tickShowOn", "channels") end,
        set     = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "tickShowOn", v); Refresh() end end,
      },

      tickPercentMode = {
        type   = "toggle",
        name   = "Per %",
        desc   = "Place a divider at regular percentage intervals.",
        order  = 100.2,
        width  = 0.5,
        hidden = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled")) end),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "tickMode", "percent") == "percent" end,
        set    = function(_, v) local c = GetCastbarDB(); if c and v then PSet(c, "tickMode", "percent"); if not PGet(c, "tickPercent") then PSet(c, "tickPercent", 10) end; Refresh() end end,
      },

      tickCustomMode = {
        type   = "toggle",
        name   = "Custom",
        desc   = "Place dividers at the exact percentages you enter.",
        order  = 100.3,
        width  = 0.55,
        hidden = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled")) end),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "tickMode") == "custom" end,
        set    = function(_, v) local c = GetCastbarDB(); if c and v then PSet(c, "tickMode", "custom"); Refresh() end end,
      },

      tickPercentValue = {
        type    = "select",
        name    = "Interval",
        desc    = "A divider every N% of the bar.",
        order   = 100.35,
        width   = 0.7,
        values  = { [1]="1%", [2]="2%", [5]="5%", [10]="10%", [20]="20%", [25]="25%", [50]="50%" },
        sorting = { 1, 2, 5, 10, 20, 25, 50 },
        hidden  = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled") and PGet(c, "tickMode", "percent") == "percent") end),
        get     = function() local c = GetCastbarDB(); return c and PGet(c, "tickPercent", 10) end,
        set     = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "tickPercent", v); Refresh() end end,
      },

      tickCustomValue = {
        type   = "input",
        name   = "Tick Positions (%)",
        desc   = "Comma-separated percentages, e.g. 20, 40, 55, 80.",
        order  = 100.36,
        width  = 1.2,
        hidden = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled") and PGet(c, "tickMode") == "custom") end),
        get    = function() local c = GetCastbarDB(); return (c and PGet(c, "tickCustom")) or "" end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "tickCustom", v); Refresh() end end,
      },

      tickMarksColor = {
        type     = "color",
        name     = "Tick Color",
        order    = 100.4,
        width    = 0.6,
        hasAlpha = true,
        hidden   = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled")) end),
        get      = function()
          local c = GetCastbarDB(); if not c then return 1, 1, 1, 0.6 end
          return PGetColor(c, "tickMarksColor", 1, 1, 1, 0.6)
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then PSetColor(c, "tickMarksColor", r, g, b, a); Refresh() end
        end,
      },

      tickMarksThickness = {
        type   = "range",
        name   = "Tick Thickness",
        order  = 100.5,
        min    = 1, max = 20, step = 1,
        width  = 1.2,
        hidden = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled")) end),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "tickMarksThickness", 2) end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "tickMarksThickness", v); Refresh() end end,
      },

      tickMarksHeightFraction = {
        type      = "range",
        name      = "Tick Height %",
        desc      = "Tick height relative to the bar.",
        order     = 100.6,
        min       = 0.1, max = 1.0, step = 0.05,
        isPercent = true,
        width     = 1.2,
        hidden    = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled")) end),
        get       = function() local c = GetCastbarDB(); return c and PGet(c, "tickMarksHeightFraction", 1.0) end,
        set       = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "tickMarksHeightFraction", v); Refresh() end end,
      },

      tickHeightAnchor = {
        type    = "select",
        name    = "Height Anchor",
        desc    = "Where the tick height is anchored. Center grows from the middle; Top/Bottom grows from that edge.",
        order   = 100.7,
        width   = 0.7,
        values  = { center = "Center", top = "Top", bottom = "Bottom" },
        sorting = { "center", "top", "bottom" },
        hidden  = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled")) end),
        get     = function() local c = GetCastbarDB(); return c and PGet(c, "tickHeightAnchor", "center") end,
        set     = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "tickHeightAnchor", v); Refresh() end end,
      },

      tickThicknessAnchor = {
        type    = "select",
        name    = "Thickness Anchor",
        desc    = "How the tick thickness is drawn around its position. Center straddles it; Start/End grows one way.",
        order   = 100.8,
        width   = 0.7,
        values  = { center = "Center", start = "Start", ["end"] = "End" },
        sorting = { "center", "start", "end" },
        hidden  = H("tickMarks", function() local c = GetCastbarDB(); return not (c and PGet(c, "tickMarksEnabled")) end),
        get     = function() local c = GetCastbarDB(); return c and PGet(c, "tickThicknessAnchor", "center") end,
        set     = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "tickThicknessAnchor", v); Refresh() end end,
      },

      -- ══ Bar Icon ═══════════════════════════════════════════════════
      barIconHeader = Header("Bar Icon", "barIcon", 110),

      showIcon = {
        type   = "toggle",
        name   = "Show Spell Icon",
        desc   = "Show the spell icon to the left of the bar.",
        order  = 110.1,
        hidden = H("barIcon"),
        get    = function() local c = GetCastbarDB(); return c and c.showIcon end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.showIcon = v; Refresh() end end,
      },

      iconSize = {
        type   = "range",
        name   = "Icon Size",
        order  = 110.2,
        min    = 8, max = 64, step = 1,
        hidden = H("barIcon", function() local c = GetCastbarDB(); return not (c and c.showIcon) end),
        get    = function() local c = GetCastbarDB(); return c and c.iconSize or 20 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.iconSize = v; Refresh() end end,
      },

      iconMovable = {
        type   = "toggle",
        name   = "Independent Position",
        desc   = "Allow the spell icon to be dragged to a custom position while the options panel is open.",
        order  = 110.3,
        width  = 1.2,
        hidden = H("barIcon", function() local c = GetCastbarDB(); return not (c and c.showIcon) end),
        get    = function() local c = GetCastbarDB(); return c and c.iconMovable end,
        set    = function(_, v)
          local c = GetCastbarDB()
          if c then
            c.iconMovable = v
            if not v then c.iconPosition = nil end
            Refresh()
          end
        end,
      },

      iconPositionReset = {
        type   = "execute",
        name   = "Reset Icon Position",
        desc   = "Restore the icon to its default position (left of bar).",
        order  = 110.4,
        width  = 1.0,
        hidden = H("barIcon", function()
          local c = GetCastbarDB()
          return not (c and c.showIcon and c.iconMovable)
        end),
        func   = function()
          local c = GetCastbarDB()
          if c then c.iconPosition = nil; Refresh() end
        end,
      },

      -- ══ Text ═══════════════════════════════════════════════════════
      textHeader = Header("Text", "text", 120),

      showText = {
        type   = "toggle",
        name   = "Show Spell Name",
        order  = 120.1,
        hidden = H("text"),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "showText") end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "showText", v); Refresh() end end,
      },

      spellShortenEnabled = {
        type   = "toggle",
        name   = "Shorten Long Names",
        desc   = "Truncate spell names that exceed the character limit.",
        order  = 120.12,
        width  = 1.1,
        hidden = H("text", function() local c = GetCastbarDB(); return not (c and PGet(c, "showText")) end),
        get    = function() local c = GetCastbarDB(); return c and c.spellShortenEnabled end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.spellShortenEnabled = v; Refresh() end end,
      },

      spellShortenLength = {
        type   = "range",
        name   = "Max Characters",
        desc   = "Truncate spell names longer than this many characters (appends ..).",
        order  = 120.13,
        width  = 1.0,
        min    = 5, max = 40, step = 1,
        hidden = H("text", function()
          local c = GetCastbarDB()
          return not (c and PGet(c, "showText") and c.spellShortenEnabled)
        end),
        get    = function() local c = GetCastbarDB(); return c and c.spellShortenLength or 20 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.spellShortenLength = v; Refresh() end end,
      },

      showTimer = {
        type   = "toggle",
        name   = "Show Timer",
        desc   = "Show the cast time.",
        order  = 120.2,
        width  = 0.9,
        hidden = H("text"),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "showTimer") end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "showTimer", v); Refresh() end end,
      },

      timerFormat = {
        type    = "select",
        name    = "Timer Format",
        desc    = "Remaining (1.2), Elapsed (0.8), or x/y showing elapsed over total (0.8 / 2.0).",
        order   = 120.25,
        width   = 1.1,
        values  = { remaining = "Remaining", elapsed = "Elapsed", both = "Elapsed / Total" },
        sorting = { "remaining", "elapsed", "both" },
        hidden  = H("text", function() local c = GetCastbarDB(); return not (c and PGet(c, "showTimer")) end),
        get     = function() local c = GetCastbarDB(); return c and PGet(c, "timerFormat", "remaining") end,
        set     = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "timerFormat", v); Refresh() end end,
      },

      font = {
        type          = "select",
        name          = "Font",
        order         = 120.3,
        dialogControl = "LSM30_Font",
        values        = LSM and LSM:HashTable("font") or {},
        hidden        = H("text"),
        get           = function() local c = GetCastbarDB(); return c and PGet(c, "font", "2002 Bold") end,
        set           = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "font", v); Refresh() end end,
      },

      fontSize = {
        type   = "range",
        name   = "Font Size",
        order  = 120.4,
        min    = 6, max = 32, step = 1,
        hidden = H("text"),
        get    = function() local c = GetCastbarDB(); return c and PGet(c, "fontSize", 14) end,
        set    = function(_, v) local c = GetCastbarDB(); if c then PSet(c, "fontSize", v); Refresh() end end,
      },

      textColor = {
        type     = "color",
        name     = "Text Color",
        order    = 120.5,
        hasAlpha = true,
        hidden   = H("text"),
        get      = function()
          local c = GetCastbarDB(); if not c then return 1, 1, 1, 1 end
          return PGetColor(c, "textColor", 1, 1, 1, 1)
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then PSetColor(c, "textColor", r, g, b, a); Refresh() end
        end,
      },

      textOutline = {
        type   = "select",
        name   = "Text Outline",
        order  = 120.6,
        values = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline" },
        hidden = H("text"),
        get    = function()
          local c = GetCastbarDB()
          local v = c and PGet(c, "textOutline", "THICKOUTLINE")
          return (v == "" or v == nil) and "NONE" or v
        end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then PSet(c, "textOutline", (v == "NONE") and "NONE" or v); Refresh() end
        end,
      },

      -- ══ Bar Position ═══════════════════════════════════════════════
      positionHeader = Header("Bar Position", "position", 130),

      barMovable = {
        type   = "toggle",
        name   = "Allow Dragging",
        desc   = "Let you drag the bar to move it while this options panel is open.",
        order  = 130.1,
        hidden = H("position"),
        get    = function() local c = GetCastbarDB(); return c and c.barMovable ~= false end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.barMovable = v; Refresh() end end,
      },

      positionDesc = {
        type     = "description",
        name     = "|cffaaaaaaWith this panel open, drag the bar itself to move it, or set X/Y below. Saved automatically.|r",
        order    = 130.2,
        fontSize = "small",
        hidden   = H("position"),
      },

      posX = {
        type    = "range",
        name    = "X Offset",
        desc    = "Horizontal offset from screen center.",
        order   = 130.3,
        min     = -2000, max = 2000, step = 1, bigStep = 10,
        hidden  = H("position"),
        get     = function() local c = PosCfg(); return (c and c.barPosition and c.barPosition.x) or 0 end,
        set = function(_, v)
          local c = PosCfg()
          if c then
            c.barPosition = c.barPosition or {point="CENTER",relPoint="CENTER",x=0,y=0}
            c.barPosition.x = v
            Refresh()
          end
        end,
      },

      posY = {
        type    = "range",
        name    = "Y Offset",
        desc    = "Vertical offset from screen center.",
        order   = 130.4,
        min     = -1000, max = 1000, step = 1, bigStep = 10,
        hidden  = H("position"),
        get     = function() local c = PosCfg(); return (c and c.barPosition and c.barPosition.y) or 0 end,
        set = function(_, v)
          local c = PosCfg()
          if c then
            c.barPosition = c.barPosition or {point="CENTER",relPoint="CENTER",x=0,y=0}
            c.barPosition.y = v
            Refresh()
          end
        end,
      },

      -- ══ CDM Group Anchor ═══════════════════════════════════════════
      groupAnchorHeader = Header("CDM Group Anchor", "groupAnchor", 140),

      anchorGroupDesc = {
        type     = "description",
        name     = "Attach the castbar to a CDM group so it follows the group. Match Size inherits the group's width.",
        order    = 140.05,
        fontSize = "small",
        hidden   = H("groupAnchor"),
      },

      anchorToGroup = {
        type   = "toggle",
        name   = "Anchor to Group",
        order  = 140.1,
        width  = "full",
        hidden = H("groupAnchor"),
        get    = function() local c = GetCastbarDB(); return c and c.anchorToGroup end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.anchorToGroup = v; Refresh() end end,
      },

      anchorGroupName = {
        type   = "select",
        name   = "Target Group",
        desc   = "Select which CDM group to anchor to.",
        order  = 140.2,
        width  = 1.3,
        values = function()
          local groups = {}
          if ns.CDMGroups and ns.CDMGroups.groups then
            for name, _ in pairs(ns.CDMGroups.groups) do groups[name] = name end
          end
          return groups
        end,
        hidden = H("groupAnchor", function() local c = GetCastbarDB(); return not (c and c.anchorToGroup) end),
        get    = function() local c = GetCastbarDB(); return (c and c.anchorGroupName ~= "" and c.anchorGroupName) or nil end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.anchorGroupName = v or ""; Refresh() end end,
      },

      anchorPoint = {
        type    = "select",
        name    = "Side",
        desc    = "Which side of the group to attach the castbar to.",
        order   = 140.3,
        width   = 0.8,
        values  = { TOP = "Above", BOTTOM = "Below", LEFT = "Left", RIGHT = "Right" },
        sorting = { "TOP", "BOTTOM", "LEFT", "RIGHT" },
        hidden  = H("groupAnchor", function() local c = GetCastbarDB(); return not (c and c.anchorToGroup) end),
        get     = function() local c = GetCastbarDB(); return c and c.anchorPoint or "BOTTOM" end,
        set     = function(_, v) local c = GetCastbarDB(); if c then c.anchorPoint = v; Refresh() end end,
      },

      matchGroupWidth = {
        type   = "toggle",
        name   = "Match Size",
        desc   = "Resize the castbar to match the group's width (or height for Left/Right anchors).",
        order  = 140.4,
        width  = 0.75,
        hidden = H("groupAnchor", function() local c = GetCastbarDB(); return not (c and c.anchorToGroup) end),
        get    = function() local c = GetCastbarDB(); return c and c.matchGroupWidth end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.matchGroupWidth = v; Refresh() end end,
      },

      matchSlotsOnly = {
        type   = "toggle",
        name   = "Match Slots",
        desc   = "Match the icon slot area exactly rather than the full container frame.",
        order  = 140.5,
        width  = 0.75,
        hidden = H("groupAnchor", function() local c = GetCastbarDB(); return not (c and c.anchorToGroup and c.matchGroupWidth) end),
        get    = function() local c = GetCastbarDB(); return c and c.matchSlotsOnly end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.matchSlotsOnly = v; Refresh() end end,
      },

      matchWidthAdjust = {
        type   = "range",
        name   = "Size Adjust",
        desc   = "Fine-tune the matched size in pixels. Negative values shrink the bar.",
        order  = 140.6,
        min    = -200, max = 200, step = 1,
        hidden = H("groupAnchor", function() local c = GetCastbarDB(); return not (c and c.anchorToGroup and c.matchGroupWidth) end),
        get    = function() local c = GetCastbarDB(); return c and c.matchWidthAdjust or 0 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.matchWidthAdjust = v; Refresh() end end,
      },

      anchorOffsetX = {
        type   = "range",
        name   = "X Offset",
        order  = 140.7,
        min    = -200, max = 200, step = 0.5,
        hidden = H("groupAnchor", function() local c = GetCastbarDB(); return not (c and c.anchorToGroup) end),
        get    = function() local c = GetCastbarDB(); return c and c.anchorOffsetX or 0 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.anchorOffsetX = v; Refresh() end end,
      },

      anchorOffsetY = {
        type   = "range",
        name   = "Y Offset",
        order  = 140.8,
        min    = -200, max = 200, step = 0.5,
        hidden = H("groupAnchor", function() local c = GetCastbarDB(); return not (c and c.anchorToGroup) end),
        get    = function() local c = GetCastbarDB(); return c and c.anchorOffsetY or -2 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.anchorOffsetY = v; Refresh() end end,
      },

      -- ══ Behavior ═══════════════════════════════════════════════════
      behaviorHeader = Header("Behavior", "behavior", 150),

      hideOutOfCombat = {
        type   = "toggle",
        name   = "Hide Out of Combat",
        desc   = "Do not show the castbar when out of combat.",
        order  = 150.1,
        hidden = H("behavior"),
        get    = function() local c = GetCastbarDB(); return c and c.hideOutOfCombat end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.hideOutOfCombat = v end end,
      },

      hideChannels = {
        type   = "toggle",
        name   = "Hide Channels",
        desc   = "Do not show the castbar for channeled spells.",
        order  = 150.2,
        hidden = H("behavior"),
        get    = function() local c = GetCastbarDB(); return c and c.hideChannels end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.hideChannels = v end end,
      },

      -- ══ Latency ════════════════════════════════════════════════════
      latencyHeader = Header("Latency Zone", "latency", 152),

      latencyEnabled = {
        type   = "toggle",
        name   = "Show Latency Zone",
        desc   = "A shaded strip at the finishing edge showing your latency window — the bit at the end where the cast is already done server-side, so you can start the next one early.",
        order  = 152.1,
        width  = "full",
        hidden = H("latency"),
        get    = function() local c = GetCastbarDB(); return c and c.latencyEnabled end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.latencyEnabled = v; Refresh() end end,
      },

      latencyInfo = {
        type     = "description",
        name     = function()
          local _, _, _, world = GetNetStats()
          return "|cffaaaaaaCurrent world latency: |cffffd100" .. tostring(world or 0) .. " ms|r|cffaaaaaa. At a typical latency this strip is small; use Manual to enlarge it or pin a fixed value.|r"
        end,
        order    = 152.15,
        fontSize = "small",
        hidden   = H("latency", function() local c = GetCastbarDB(); return not (c and c.latencyEnabled) end),
      },

      latencyManual = {
        type   = "toggle",
        name   = "Manual Value",
        desc   = "Use a fixed latency in milliseconds instead of your live world latency.",
        order  = 152.2,
        width  = 1.0,
        hidden = H("latency", function() local c = GetCastbarDB(); return not (c and c.latencyEnabled) end),
        get    = function() local c = GetCastbarDB(); return c and c.latencyManual end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.latencyManual = v; Refresh() end end,
      },

      latencyManualMs = {
        type   = "range",
        name   = "Latency (ms)",
        order  = 152.25,
        width  = 1.2,
        min    = 10, max = 1000, step = 5,
        hidden = H("latency", function() local c = GetCastbarDB(); return not (c and c.latencyEnabled and c.latencyManual) end),
        get    = function() local c = GetCastbarDB(); return c and c.latencyManualMs or 100 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.latencyManualMs = v; Refresh() end end,
      },

      latencyColor = {
        type     = "color",
        name     = "Zone Color",
        order    = 152.3,
        width    = 0.9,
        hasAlpha = true,
        hidden   = H("latency", function() local c = GetCastbarDB(); return not (c and c.latencyEnabled) end),
        get      = function()
          local c = GetCastbarDB()
          local col = c and c.latencyColor or {r=1, g=0, b=0, a=0.4}
          return col.r, col.g, col.b, col.a or 0.4
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then c.latencyColor = {r=r, g=g, b=b, a=a}; Refresh() end
        end,
      },

      -- ══ Interrupt / Cancel ═════════════════════════════════════════
      interruptHeader = Header("Interrupt / Cancel", "interruptFeedback", 155),

      interruptFeedbackEnabled = {
        type   = "toggle",
        name   = "Show Feedback",
        desc   = "When a cast is interrupted or cancelled, flash the bar with a label ('Interrupted' / 'Cancelled') and fade it out instead of vanishing instantly.",
        order  = 155.1,
        width  = "full",
        hidden = H("interruptFeedback"),
        get    = function() local c = GetCastbarDB(); return c and c.interruptFeedbackEnabled end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.interruptFeedbackEnabled = v end end,
      },

      interruptColor = {
        type     = "color",
        name     = "Flash Color",
        order    = 155.2,
        width    = 0.9,
        hasAlpha = true,
        hidden   = H("interruptFeedback", function() local c = GetCastbarDB(); return not (c and c.interruptFeedbackEnabled) end),
        get      = function()
          local c = GetCastbarDB()
          local col = c and c.interruptColor or {r=1, g=0.15, b=0.15, a=1}
          return col.r, col.g, col.b, col.a or 1
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB(); if c then c.interruptColor = {r=r, g=g, b=b, a=a} end
        end,
      },

      interruptFadeDuration = {
        type   = "range",
        name   = "Fade Time (sec)",
        order  = 155.3,
        width  = 1.1,
        min    = 0.2, max = 4, step = 0.1,
        hidden = H("interruptFeedback", function() local c = GetCastbarDB(); return not (c and c.interruptFeedbackEnabled) end),
        get    = function() local c = GetCastbarDB(); return c and c.interruptFadeDuration or 1.0 end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c.interruptFadeDuration = v end end,
      },

      -- ══ Spell Overrides ════════════════════════════════════════════
      spellOverrideHeader = Header("Spell Overrides", "spellOverrides", 160),

      spellOverrideDesc = {
        type     = "description",
        name     = "Override color, texture, and tick layout per spell. Enter a spell ID and click Add.",
        order    = 160.05,
        fontSize = "small",
        hidden   = H("spellOverrides"),
      },

      spellOverrideAddID = {
        type   = "input",
        name   = "Spell ID",
        desc   = "Spell ID to add an override for.",
        order  = 160.1,
        width  = 0.8,
        hidden = H("spellOverrides"),
        get    = function() local c = GetCastbarDB(); return (c and c._addSpellIDInput) or "" end,
        set    = function(_, v) local c = GetCastbarDB(); if c then c._addSpellIDInput = v end end,
      },

      spellOverrideAddBtn = {
        type   = "execute",
        name   = "Add Override",
        order  = 160.2,
        width  = 0.7,
        hidden = H("spellOverrides"),
        func   = function()
          local c = GetCastbarDB()
          if not c then return end
          local idStr = c._addSpellIDInput and c._addSpellIDInput:match("^%s*(.-)%s*$")
          local id    = idStr and tonumber(idStr)
          if not id or id <= 0 then
            print("|cff00ccffArcUI|r: Enter a valid spell ID first.")
            return
          end
          c.spellOverrides = c.spellOverrides or {}
          for _, ov in ipairs(c.spellOverrides) do
            if ov.spellID == id then
              print("|cff00ccffArcUI|r: Override for spell " .. id .. " already exists.")
              return
            end
          end
          if #c.spellOverrides >= 20 then
            print("|cff00ccffArcUI|r: Maximum of 20 spell overrides reached.")
            return
          end
          c.spellOverrides[#c.spellOverrides + 1] = {
            spellID                = id,
            barColorEnabled        = false,
            barColor               = {r=1, g=1, b=1, a=1},
            textureOverrideEnabled = false,
            texture                = "Blizzard",
            tickMode               = "count",
            tickCount              = 0,
            customTicks            = "",
          }
          c._addSpellIDInput = ""
          if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
        end,
      },

    }, -- args
  }

  local args = opts.args

  -- ── Conditional color thresholds (under Color Options, up to 4) ────
  -- Defaults expressed as PERCENT remaining (50% left, 25% left, …). Lower = closer to finishing.
  local THRESHOLD_DEFAULTS = {
    { p = 50, c = {r=1,   g=0.85, b=0.2, a=1} },
    { p = 25, c = {r=1,   g=0.5,  b=0.1, a=1} },
    { p = 10, c = {r=0.2, g=1,    b=0.3, a=1} },
    { p = 5,  c = {r=1,   g=0.2,  b=0.2, a=1} },
  }
  local function ctHidden(i, needEnabled)
    return function()
      if collapsedSections.colorOptions or SectionProfileHidden("colorOptions") then return true end
      local c = GetCastbarDB()
      if not (c and PGet(c, "conditionalColorEnabled")) then return true end
      if needEnabled then
        local s = ThresholdSlot(c, i)
        if not s.enabled then return true end
      end
      return false
    end
  end
  for i = 1, 4 do
    local idx  = i
    local base = 40.4 + (i - 1) * 0.05
    args["ctOn" .. i] = {
      type   = "toggle",
      name   = "At",
      desc   = "Enable color threshold " .. i .. ".",
      order  = base,
      width  = 0.4,
      hidden = ctHidden(idx, false),
      get    = function() local c = GetCastbarDB(); return c and ThresholdSlot(c, idx).enabled end,
      set    = function(_, v)
        local c = GetCastbarDB()
        if c then
          local s = ThresholdSlot(c, idx)
          s.enabled = v
          if v then
            s.percent = s.percent or THRESHOLD_DEFAULTS[idx].p
            s.color   = s.color   or { r = THRESHOLD_DEFAULTS[idx].c.r, g = THRESHOLD_DEFAULTS[idx].c.g, b = THRESHOLD_DEFAULTS[idx].c.b, a = 1 }
          end
          Refresh()
        end
      end,
    }
    args["ctVal" .. i] = {
      type   = "input",
      name   = "",
      desc   = "Remaining value at which this color kicks in (percent, or seconds when 'As Sec' is on).",
      order  = base + 0.01,
      width  = 0.5,
      hidden = ctHidden(idx, true),
      get    = function()
        local c = GetCastbarDB(); local s = c and ThresholdSlot(c, idx)
        return (s and s.percent) and tostring(s.percent) or ""
      end,
      set    = function(_, v)
        local c = GetCastbarDB()
        if c then local n = tonumber(v); if n and n > 0 then ThresholdSlot(c, idx).percent = n; Refresh() end end
      end,
    }
    args["ctCol" .. i] = {
      type     = "color",
      name     = "Color",
      order    = base + 0.02,
      width    = 0.55,
      hasAlpha = true,
      hidden   = ctHidden(idx, true),
      get      = function()
        local c = GetCastbarDB()
        local s = c and ThresholdSlot(c, idx)
        local col = (s and s.color) or {r=1, g=1, b=1, a=1}
        return col.r, col.g, col.b, col.a or 1
      end,
      set = function(_, r, g, b, a)
        local c = GetCastbarDB(); if c then ThresholdSlot(c, idx).color = {r=r, g=g, b=b, a=a}; Refresh() end
      end,
    }
  end

  -- ── Empower stage color pickers (under Empowered Stages) ───────────
  local EMPOWER_DEFAULTS = {
    {r=0.6,g=0.2,b=1.0,a=1}, {r=0.9,g=0.1,b=0.6,a=1}, {r=1.0,g=0.3,b=0.1,a=1}, {r=1.0,g=0.7,b=0.1,a=1},
    {r=0.1,g=0.9,b=0.3,a=1}, {r=0.1,g=0.7,b=1.0,a=1}, {r=1.0,g=1.0,b=0.2,a=1}, {r=0.8,g=0.8,b=0.8,a=1},
  }
  for si = 1, 8 do
    local stage = si
    args["empowerSegmentColor" .. si] = {
      type     = "color",
      name     = "Stage " .. si,
      desc     = "Color for stage " .. si .. ".",
      order    = 50.3 + (si - 1) * 0.02,
      width    = 0.55,
      hasAlpha = true,
      hidden   = function()
        if collapsedSections.empowerStages or SectionProfileHidden("empowerStages") then return true end
        local c = GetCastbarDB()
        if not (c and c.empowerSegmentColorsEnabled) then return true end
        return stage > (c.empowerMaxStages or 4)
      end,
      get = function()
        local c   = GetCastbarDB()
        local col = (c and c.empowerSegmentColors and c.empowerSegmentColors[stage]) or EMPOWER_DEFAULTS[stage]
        return col.r, col.g, col.b, col.a or 1
      end,
      set = function(_, r, g, b, a)
        local c = GetCastbarDB()
        if c then
          c.empowerSegmentColors = c.empowerSegmentColors or {}
          c.empowerSegmentColors[stage] = {r=r,g=g,b=b,a=a}
          RefreshSegs()
        end
      end,
    }
  end

  -- ── Dynamic auto-switch rules (under Skins) ────────────────────────
  local MAX_RULES = 10

  local function asHidden(ri)
    if collapsedSections.skins then return true end
    if not ns.Presets or ns.Presets.GetSkinCount("castbar") == 0 then return true end
    local c = GetCastbarDB()
    if not c or not c.presets or not c.presets.autoSwitch then return true end
    local rules = c.presets.autoSwitch.rules
    return not rules or ri > #rules
  end

  local function asGetRule(ri)
    local c = GetCastbarDB()
    if not c or not c.presets or not c.presets.autoSwitch then return nil end
    return c.presets.autoSwitch.rules and c.presets.autoSwitch.rules[ri]
  end

  local function asSkinNames()
    return ns.Presets and ns.Presets.GetSkinNames("castbar") or {}
  end

  local function asToggleSpec(rule, specNum, value)
    if not rule.specIndices then rule.specIndices = {} end
    if value then
      for _, s in ipairs(rule.specIndices) do if s == specNum then return end end
      table.insert(rule.specIndices, specNum)
    else
      if #rule.specIndices == 0 then
        for i = 1, (GetNumSpecializations() or 4) do table.insert(rule.specIndices, i) end
      end
      for i = #rule.specIndices, 1, -1 do
        if rule.specIndices[i] == specNum then table.remove(rule.specIndices, i) end
      end
    end
  end

  local function asHasSpec(rule, specNum)
    if not rule.specIndices or #rule.specIndices == 0 then return true end
    for _, s in ipairs(rule.specIndices) do if s == specNum then return true end end
    return false
  end

  for ri = 1, MAX_RULES do
    local ruleIdx = ri
    local base    = 10.5 + (ri - 1) * 0.01

    args["csR" .. ri .. "Skin"] = {
      type   = "select",
      name   = "|cffffd700Rule " .. ri .. "|r  Skin",
      desc   = "Skin to load when this rule matches.",
      values = asSkinNames,
      order  = base,
      width  = 1.1,
      hidden = function() return asHidden(ruleIdx) end,
      get    = function() local rule = asGetRule(ruleIdx); return rule and rule.skinName end,
      set    = function(_, v) local rule = asGetRule(ruleIdx); if rule then rule.skinName = v end end,
    }

    args["csR" .. ri .. "Talents"] = {
      type   = "execute",
      name   = function()
        local rule = asGetRule(ruleIdx)
        if rule and rule.talentConditions and #rule.talentConditions > 0 then
          return "|cff00ff00Talents *|r"
        end
        return "Talents"
      end,
      desc   = "Open the talent picker to set conditions for this rule.",
      order  = base + 0.001,
      width  = 0.6,
      hidden = function() return asHidden(ruleIdx) end,
      func   = function()
        if not (ns.TalentPicker and ns.TalentPicker.OpenPicker) then
          print("|cff00ccffArcUI|r: Talent picker not available")
          return
        end
        local rule = asGetRule(ruleIdx)
        if not rule then return end
        ns.TalentPicker.OpenPicker(rule.talentConditions, rule.talentMatchMode or "all", function(conditions, mode)
          local r = asGetRule(ruleIdx)
          if r then
            r.talentConditions = conditions
            r.talentMatchMode  = mode
            if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
          end
        end)
      end,
    }

    args["csR" .. ri .. "Remove"] = {
      type   = "execute",
      name   = "X",
      desc   = "Remove this rule.",
      order  = base + 0.002,
      width  = 0.3,
      hidden = function() return asHidden(ruleIdx) end,
      func   = function()
        local c = GetCastbarDB()
        if c and c.presets and c.presets.autoSwitch and c.presets.autoSwitch.rules then
          table.remove(c.presets.autoSwitch.rules, ruleIdx)
          if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
        end
      end,
    }

    local numSpecs = GetNumSpecializations and GetNumSpecializations() or 4
    for si = 1, numSpecs do
      local specIdx = si
      local _, specName, _, specIcon = GetSpecializationInfo(specIdx)
      local iconStr = specIcon and ("|T" .. specIcon .. ":14:14|t") or ("Spec " .. specIdx)
      args["csR" .. ri .. "Spec" .. si] = {
        type   = "toggle",
        name   = iconStr,
        desc   = specName or ("Spec " .. specIdx),
        order  = base + 0.003 + si * 0.0001,
        width  = 0.3,
        hidden = function() return asHidden(ruleIdx) end,
        get    = function()
          local rule = asGetRule(ruleIdx)
          return rule and asHasSpec(rule, specIdx)
        end,
        set    = function(_, value)
          local rule = asGetRule(ruleIdx)
          if rule then asToggleSpec(rule, specIdx, value) end
        end,
      }
    end
  end

  -- ── Dynamic spell override slots (under Spell Overrides, up to 20) ──
  local MAX_OVERRIDES = 20

  local function soHidden(oi)
    if collapsedSections.spellOverrides then return true end
    local c = GetCastbarDB()
    if not c or not c.spellOverrides then return true end
    return oi > #c.spellOverrides
  end

  local function soGet(oi)
    local c = GetCastbarDB()
    if not c or not c.spellOverrides then return nil end
    return c.spellOverrides[oi]
  end

  for oi = 1, MAX_OVERRIDES do
    local idx  = oi
    local base = 160.5 + (oi - 1) * 0.02

    args["soN" .. oi .. "Name"] = {
      type  = "description",
      order = base,
      name  = function()
        local ov = soGet(idx)
        if not ov then return "" end
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(ov.spellID)
        local nm   = (info and info.name) or "Unknown Spell"
        return "|cffffd100[" .. ov.spellID .. "]|r " .. nm
      end,
      hidden = function() return soHidden(idx) end,
    }

    args["soN" .. oi .. "ColorOn"] = {
      type   = "toggle",
      name   = "Override Color",
      order  = base + 0.001,
      width  = 0.7,
      hidden = function() return soHidden(idx) end,
      get    = function() local ov = soGet(idx); return ov and ov.barColorEnabled end,
      set    = function(_, v) local ov = soGet(idx); if ov then ov.barColorEnabled = v; Refresh() end end,
    }

    args["soN" .. oi .. "Color"] = {
      type     = "color",
      name     = "Color",
      order    = base + 0.002,
      hasAlpha = true,
      hidden   = function()
        if soHidden(idx) then return true end
        local ov = soGet(idx); return not (ov and ov.barColorEnabled)
      end,
      get = function()
        local ov  = soGet(idx)
        local col = (ov and ov.barColor) or {r=1,g=1,b=1,a=1}
        return col.r, col.g, col.b, col.a or 1
      end,
      set = function(_, r, g, b, a)
        local ov = soGet(idx); if ov then ov.barColor = {r=r,g=g,b=b,a=a}; Refresh() end
      end,
    }

    args["soN" .. oi .. "TexOn"] = {
      type   = "toggle",
      name   = "Override Texture",
      order  = base + 0.003,
      width  = 0.85,
      hidden = function() return soHidden(idx) end,
      get    = function() local ov = soGet(idx); return ov and ov.textureOverrideEnabled end,
      set    = function(_, v) local ov = soGet(idx); if ov then ov.textureOverrideEnabled = v; Refresh() end end,
    }

    args["soN" .. oi .. "Tex"] = {
      type          = "select",
      name          = "Texture",
      order         = base + 0.004,
      dialogControl = "LSM30_Statusbar",
      values        = LSM and LSM:HashTable("statusbar") or {},
      hidden        = function()
        if soHidden(idx) then return true end
        local ov = soGet(idx); return not (ov and ov.textureOverrideEnabled)
      end,
      get = function() local ov = soGet(idx); return (ov and ov.texture) or "Blizzard" end,
      set = function(_, v) local ov = soGet(idx); if ov then ov.texture = v; Refresh() end end,
    }

    args["soN" .. oi .. "TickMode"] = {
      type    = "select",
      name    = "Ticks",
      desc    = "Even = a set number of evenly-spaced ticks. Custom = dividers at the exact percentages you enter.",
      order   = base + 0.005,
      width   = 0.7,
      values  = { count = "Even", custom = "Custom %" },
      sorting = { "count", "custom" },
      hidden  = function() return soHidden(idx) end,
      get     = function() local ov = soGet(idx); return (ov and ov.tickMode) or "count" end,
      set     = function(_, v) local ov = soGet(idx); if ov then ov.tickMode = v end end,
    }

    args["soN" .. oi .. "Count"] = {
      type   = "range",
      name   = "Tick Count",
      desc   = "Number of evenly-spaced ticks for this channel. 0 = off.",
      order  = base + 0.006,
      min    = 0, max = 32, step = 1,
      width  = 0.8,
      hidden = function()
        if soHidden(idx) then return true end
        local ov = soGet(idx); return not ov or ov.tickMode == "custom"
      end,
      get    = function() local ov = soGet(idx); return (ov and ov.tickCount) or 0 end,
      set    = function(_, v) local ov = soGet(idx); if ov then ov.tickCount = v end end,
    }

    args["soN" .. oi .. "Custom"] = {
      type   = "input",
      name   = "Tick Positions (%)",
      desc   = "Comma-separated percentages where dividers should sit, e.g. 20, 40, 55, 80.",
      order  = base + 0.007,
      width  = 1.0,
      hidden = function()
        if soHidden(idx) then return true end
        local ov = soGet(idx); return not ov or ov.tickMode ~= "custom"
      end,
      get    = function() local ov = soGet(idx); return (ov and ov.customTicks) or "" end,
      set    = function(_, v) local ov = soGet(idx); if ov then ov.customTicks = v end end,
    }

    args["soN" .. oi .. "Remove"] = {
      type   = "execute",
      name   = "Remove",
      order  = base + 0.008,
      width  = 0.45,
      hidden = function() return soHidden(idx) end,
      func   = function()
        local c = GetCastbarDB()
        if c and c.spellOverrides then
          table.remove(c.spellOverrides, idx)
          if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
        end
      end,
    }
  end


  return opts
end
