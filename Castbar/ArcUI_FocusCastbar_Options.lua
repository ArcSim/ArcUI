-- ===================================================================
-- ArcUI_FocusCastbar_Options.lua
-- Options panel for the Focus Castbar feature.
-- Registered as a tab under the Castbar panel in ArcUI_Options.lua.
-- ===================================================================

local ADDON, ns = ...
ns.FocusCastbarOptions = ns.FocusCastbarOptions or {}

local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
local LSM               = LibStub and LibStub("LibSharedMedia-3.0", true)

local collapsed = {
  appearance   = true,
  colors       = true,
  background   = true,
  border       = true,
  glow         = true,
  importGlow   = true,
  content      = true,
  raidMarker   = true,
  text         = true,
  position     = true,
  reset        = true,
}

local ANCHOR_POINTS = {
  TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
  LEFT="Left", CENTER="Center", RIGHT="Right",
  BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right",
}

local function GetDB()
  return ns.db and ns.db.char and ns.db.char.focusCastbar
end

-- True when the bar is pinned to another frame (free-position controls hide).
local function AnchoredOn()
  local c = GetDB(); return c and c.anchorToFrame
end

local function Refresh()
  if ns.FocusCastbar and ns.FocusCastbar.ApplyAppearance then
    ns.FocusCastbar.ApplyAppearance()
  end
  if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
end

-- Reset every Focus Castbar setting to its DB default. The feature's on/off
-- state is preserved so the preview stays visible and the user isn't surprised
-- by the bar vanishing mid-edit.
local function ResetAllToDefaults()
  local c = GetDB(); if not c then return end
  local d = ns.DB_DEFAULTS and ns.DB_DEFAULTS.char and ns.DB_DEFAULTS.char.focusCastbar
  if not d then return end
  local wasEnabled = c.enabled
  wipe(c)
  for k, v in pairs(d) do
    if type(v) == "table" then c[k] = CopyTable(v) else c[k] = v end
  end
  c.enabled = wasEnabled
  Refresh()
end

local function Header(label, key, order)
  return {
    type          = "toggle",
    name          = label,
    desc          = "Click to expand/collapse",
    dialogControl = "CollapsibleHeader",
    order         = order,
    width         = "full",
    get           = function() return not collapsed[key] end,
    set           = function(_, v) collapsed[key] = not v end,
  }
end

local function H(key, extra)
  return function()
    if collapsed[key] then return true end
    if extra then return extra() end
    return false
  end
end

-- ===================================================================
-- OPTIONS TABLE
-- ===================================================================
function ns.FocusCastbarOptions.GetOptionsTable()
  local opts = { type="group", name="Focus Castbar", order=2, args={} }
  local a = opts.args

  a.desc = {
    type     = "description",
    name     = "|cffffd100Focus Castbar|r — shows what your focus target is casting. Enable below, then drag the bar into position while this panel is open.",
    order    = 0.1,
    fontSize = "medium",
  }

  a.enabled = {
    type  = "toggle",
    name  = "|cffffd100Enable Focus Castbar|r",
    desc  = "Show a castbar while your focus target is casting or channeling.",
    order = 0.2,
    width = 1.5,
    get   = function() local c = GetDB(); return c and c.enabled end,
    set   = function(_, v)
      local c = GetDB(); if not c then return end
      c.enabled = v
      if v then
        if ns.FocusCastbar and ns.FocusCastbar.Enable then ns.FocusCastbar.Enable() end
      else
        if ns.FocusCastbar and ns.FocusCastbar.Disable then ns.FocusCastbar.Disable() end
      end
      Refresh()
    end,
  }

  -- ── Appearance ─────────────────────────────────────────────────
  a.appearanceHeader = Header("Appearance", "appearance", 10)

  a.fcWidth = {
    type = "range", name = "Width", order = 10.1,
    min = 50, max = 600, step = 1, hidden = H("appearance"),
    get = function() local c = GetDB(); return c and c.width or 220 end,
    set = function(_, v) local c = GetDB(); if c then c.width = v; Refresh() end end,
  }
  a.fcHeight = {
    type = "range", name = "Height", order = 10.2,
    min = 8, max = 60, step = 1, hidden = H("appearance"),
    get = function() local c = GetDB(); return c and c.height or 18 end,
    set = function(_, v) local c = GetDB(); if c then c.height = v; Refresh() end end,
  }
  a.fcStrata = {
    type = "select", name = "Frame Strata", order = 10.3, width = 1.1,
    values = { BACKGROUND="Background", LOW="Low", MEDIUM="Medium", HIGH="High", DIALOG="Dialog" },
    hidden = H("appearance"),
    get = function() local c = GetDB(); return c and c.barFrameStrata or "MEDIUM" end,
    set = function(_, v) local c = GetDB(); if c then c.barFrameStrata = v; Refresh() end end,
  }
  a.fcTexture = {
    type = "select", name = "Bar Texture", order = 10.4,
    dialogControl = "LSM30_Statusbar",
    values = LSM and LSM:HashTable("statusbar") or {},
    hidden = H("appearance"),
    get = function() local c = GetDB(); return c and c.texture or "Blizzard" end,
    set = function(_, v) local c = GetDB(); if c then c.texture = v; Refresh() end end,
  }

  -- ── Colors & Indicators ────────────────────────────────────────
  a.colorsHeader = Header("Colors & Indicators", "colors", 20)

  -- Base bar color
  a.fcBarColor = {
    type = "color", name = "Bar Color", order = 20.1, hasAlpha = true,
    hidden = H("colors"),
    get = function()
      local c = GetDB(); local col = c and c.barColor or {r=1,g=0.65,b=0,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.barColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }

  -- Uninterruptible color
  a.fcUninterruptibleEnabled = {
    type = "toggle", name = "Different Color When Uninterruptible", order = 20.2,
    width = 2.0, hidden = H("colors"),
    get = function() local c = GetDB(); return c and c.uninterruptibleEnabled end,
    set = function(_, v) local c = GetDB(); if c then c.uninterruptibleEnabled = v; Refresh() end end,
  }
  a.fcUninterruptibleColor = {
    type = "color", name = "Uninterruptible Color", order = 20.3, width = 1.2, hasAlpha = true,
    hidden = H("colors", function() local c = GetDB(); return not (c and c.uninterruptibleEnabled) end),
    get = function()
      local c = GetDB(); local col = c and c.uninterruptibleColor or {r=0.5,g=0.5,b=0.5,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.uninterruptibleColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }

  -- Hide non-interruptible
  a.fcHideNotInterruptible = {
    type = "toggle", name = "Hide Non-Interruptible Casts", order = 20.4,
    desc = "Fully hide the bar when the cast cannot be interrupted.",
    width = 2.0, hidden = H("colors"),
    get = function() local c = GetDB(); return c and c.hideNotInterruptible end,
    set = function(_, v) local c = GetDB(); if c then c.hideNotInterruptible = v; Refresh() end end,
  }

  -- Kick Indicator
  a.fcKickSep = {
    type = "description", name = "|cff888888— Kick Indicator —|r",
    order = 20.5, hidden = H("colors"),
  }
  a.fcKickEnabled = {
    type = "toggle", name = "Kick Indicator", order = 20.6,
    desc = "Show a tick mark on the bar marking when your interrupt will come off cooldown during the cast. Colors the bar based on whether your kick is ready.",
    width = 1.5, hidden = H("colors"),
    get = function() local c = GetDB(); return c and c.kickEnabled end,
    set = function(_, v) local c = GetDB(); if c then c.kickEnabled = v; Refresh() end end,
  }
  a.fcKickNotReadyColor = {
    type = "color", name = "Not Ready Color", order = 20.7, width = 1.2, hasAlpha = true,
    desc = "Bar color when your interrupt is still on cooldown.",
    hidden = H("colors", function() local c = GetDB(); return not (c and c.kickEnabled) end),
    get = function()
      local c = GetDB(); local col = c and c.kickNotReadyColor or {r=0.55,g=0.55,b=0.55,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.kickNotReadyColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }
  a.fcKickTickColor = {
    type = "color", name = "Tick Color", order = 20.8, width = 1.1, hasAlpha = true,
    desc = "Color of the 2px tick mark showing where your kick comes off cooldown.",
    hidden = H("colors", function() local c = GetDB(); return not (c and c.kickEnabled) end),
    get = function()
      local c = GetDB(); local col = c and c.kickTickColor or {r=1,g=1,b=1,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.kickTickColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }

  -- Hold Timer
  a.fcHoldSep = {
    type = "description", name = "|cff888888— Hold Timer —|r",
    order = 20.9, hidden = H("colors"),
  }
  a.fcHoldEnabled = {
    type = "toggle", name = "Hold Timer", order = 21.0,
    desc = "Keep the bar visible for a brief moment after a cast ends, colored to show whether it succeeded, failed, or was interrupted.",
    width = 1.5, hidden = H("colors"),
    get = function() local c = GetDB(); return c and c.holdEnabled end,
    set = function(_, v) local c = GetDB(); if c then c.holdEnabled = v; Refresh() end end,
  }
  a.fcHoldDuration = {
    type = "range", name = "Hold Duration (sec)", order = 21.1, width = 1.5,
    min = 0.1, max = 3.0, step = 0.1,
    hidden = H("colors", function() local c = GetDB(); return not (c and c.holdEnabled) end),
    get = function() local c = GetDB(); return c and c.holdDuration or 0.8 end,
    set = function(_, v) local c = GetDB(); if c then c.holdDuration = v; Refresh() end end,
  }
  a.fcHoldSuccessColor = {
    type = "color", name = "Cast Completed", order = 21.2, width = 1.2, hasAlpha = true,
    hidden = H("colors", function() local c = GetDB(); return not (c and c.holdEnabled) end),
    get = function()
      local c = GetDB(); local col = c and c.holdSuccessColor or {r=0.2,g=1,b=0.2,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.holdSuccessColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }
  a.fcHoldFailColor = {
    type = "color", name = "Cast Failed", order = 21.3, width = 1.1, hasAlpha = true,
    hidden = H("colors", function() local c = GetDB(); return not (c and c.holdEnabled) end),
    get = function()
      local c = GetDB(); local col = c and c.holdFailColor or {r=1,g=0.5,b=0,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.holdFailColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }
  a.fcHoldInterruptedColor = {
    type = "color", name = "Interrupted", order = 21.4, width = 1.1, hasAlpha = true,
    hidden = H("colors", function() local c = GetDB(); return not (c and c.holdEnabled) end),
    get = function()
      local c = GetDB(); local col = c and c.holdInterruptedColor or {r=0.2,g=0.4,b=1,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.holdInterruptedColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }

  -- ── Background ─────────────────────────────────────────────────
  a.backgroundHeader = Header("Background", "background", 30)

  a.fcShowBackground = {
    type = "toggle", name = "Show Background", order = 30.1, hidden = H("background"),
    get = function() local c = GetDB(); return c and c.showBackground end,
    set = function(_, v) local c = GetDB(); if c then c.showBackground = v; Refresh() end end,
  }
  a.fcBackgroundColor = {
    type = "color", name = "Background Color", order = 30.2, hasAlpha = true,
    hidden = H("background", function() local c = GetDB(); return not (c and c.showBackground) end),
    get = function()
      local c = GetDB(); local col = c and c.backgroundColor or {r=0.1,g=0.1,b=0.1,a=0.9}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.backgroundColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }

  -- ── Border ─────────────────────────────────────────────────────
  a.borderHeader = Header("Border", "border", 40)

  a.fcShowBorder = {
    type = "toggle", name = "Show Border", order = 40.1, hidden = H("border"),
    get = function() local c = GetDB(); return c and c.showBorder end,
    set = function(_, v) local c = GetDB(); if c then c.showBorder = v; Refresh() end end,
  }
  a.fcBorderColor = {
    type = "color", name = "Border Color", order = 40.2, hasAlpha = true,
    hidden = H("border", function() local c = GetDB(); return not (c and c.showBorder) end),
    get = function()
      local c = GetDB(); local col = c and c.borderColor or {r=0,g=0,b=0,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.borderColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }
  a.fcBorderThickness = {
    type = "range", name = "Border Thickness", order = 40.3,
    min = 1, max = 8, step = 1,
    hidden = H("border", function() local c = GetDB(); return not (c and c.showBorder) end),
    get = function() local c = GetDB(); return c and c.drawnBorderThickness or 2 end,
    set = function(_, v) local c = GetDB(); if c then c.drawnBorderThickness = v; Refresh() end end,
  }

  -- ── Cast Glow (always-on outline glow) ─────────────────────────
  a.glowHeader = Header("Glow Outline", "glow", 50)

  a.fcShowGlow = {
    type = "toggle", name = "Glow Outline", order = 50.1,
    desc = "Show a pixel glow around the bar while the focus target is casting.",
    hidden = H("glow"),
    get = function() local c = GetDB(); return c and c.showGlow end,
    set = function(_, v) local c = GetDB(); if c then c.showGlow = v; Refresh() end end,
  }
  a.fcGlowColor = {
    type = "color", name = "Glow Color", order = 50.2, hasAlpha = true,
    hidden = H("glow", function() local c = GetDB(); return not (c and c.showGlow) end),
    get = function()
      local c = GetDB(); local col = c and c.glowColor or {r=1,g=0.65,b=0,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.glowColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }
  a.fcGlowType = {
    type = "select", name = "Glow Type", order = 50.25, width = 1.1,
    values = { pixel="Pixel", autocast="Autocast", button="Button", proc="Proc" },
    hidden = H("glow", function() local c = GetDB(); return not (c and c.showGlow) end),
    get = function() local c = GetDB(); return c and c.glowType or "pixel" end,
    set = function(_, v) local c = GetDB(); if c then c.glowType = v; Refresh() end end,
  }
  a.fcGlowLines = {
    type = "range", name = "Glow Lines", order = 50.26,
    desc = "Number of lines for Pixel glow type.",
    min = 2, max = 20, step = 1,
    hidden = H("glow", function() local c = GetDB(); return not (c and c.showGlow) end),
    get = function() local c = GetDB(); return c and c.glowLines or 8 end,
    set = function(_, v) local c = GetDB(); if c then c.glowLines = v; Refresh() end end,
  }
  a.fcGlowSpeed = {
    type = "range", name = "Glow Speed", order = 50.27, width = 1.1,
    desc = "Animation speed of the glow. Lower = slower.",
    min = 0.05, max = 2.0, step = 0.05,
    hidden = H("glow", function() local c = GetDB(); return not (c and c.showGlow) end),
    get = function() local c = GetDB(); return c and c.glowFrequency or 0.25 end,
    set = function(_, v) local c = GetDB(); if c then c.glowFrequency = v; Refresh() end end,
  }
  a.fcGlowWidth = {
    type = "range", name = "Glow Width", order = 50.3,
    desc = "Thickness of Pixel glow lines.",
    min = 1, max = 10, step = 1,
    hidden = H("glow", function() local c = GetDB(); return not (c and c.showGlow) end),
    get = function() local c = GetDB(); return c and c.glowWidth or 2 end,
    set = function(_, v) local c = GetDB(); if c then c.glowWidth = v; Refresh() end end,
  }

  -- ── Important Spell Glow ────────────────────────────────────────
  a.importGlowHeader = Header("Important Spell Glow", "importGlow", 55)

  a.fcImportGlowDesc = {
    type = "description", order = 55.05,
    name = "|cff888888Triggers a glow when the focus target casts a spell marked as important by Blizzard (typically major cooldowns or dangerous abilities).|r",
    hidden = H("importGlow"),
  }
  a.fcImportGlowEnabled = {
    type = "toggle", name = "Enable Important Spell Glow", order = 55.1,
    width = 1.8, hidden = H("importGlow"),
    get = function() local c = GetDB(); return c and c.importantGlowEnabled end,
    set = function(_, v) local c = GetDB(); if c then c.importantGlowEnabled = v; Refresh() end end,
  }
  a.fcImportGlowType = {
    type = "select", name = "Glow Type", order = 55.2, width = 1.1,
    values = { pixel="Pixel", autocast="Autocast" },
    hidden = H("importGlow", function() local c = GetDB(); return not (c and c.importantGlowEnabled) end),
    get = function() local c = GetDB(); return c and c.importantGlowType or "pixel" end,
    set = function(_, v) local c = GetDB(); if c then c.importantGlowType = v; Refresh() end end,
  }
  a.fcImportGlowColor = {
    type = "color", name = "Glow Color", order = 55.3, hasAlpha = true,
    hidden = H("importGlow", function() local c = GetDB(); return not (c and c.importantGlowEnabled) end),
    get = function()
      local c = GetDB(); local col = c and c.importantGlowColor or {r=1,g=0.2,b=0.2,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.importantGlowColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }
  a.fcImportGlowLines = {
    type = "range", name = "Lines", order = 55.4,
    min = 2, max = 20, step = 1,
    hidden = H("importGlow", function() local c = GetDB(); return not (c and c.importantGlowEnabled) end),
    get = function() local c = GetDB(); return c and c.importantGlowLines or 8 end,
    set = function(_, v) local c = GetDB(); if c then c.importantGlowLines = v; Refresh() end end,
  }
  a.fcImportGlowFreq = {
    type = "range", name = "Speed", order = 55.5, width = 1.1,
    min = 0.05, max = 2.0, step = 0.05,
    hidden = H("importGlow", function() local c = GetDB(); return not (c and c.importantGlowEnabled) end),
    get = function() local c = GetDB(); return c and c.importantGlowFrequency or 0.25 end,
    set = function(_, v) local c = GetDB(); if c then c.importantGlowFrequency = v; Refresh() end end,
  }
  a.fcImportGlowThick = {
    type = "range", name = "Thickness", order = 55.6,
    min = 1, max = 10, step = 1,
    hidden = H("importGlow", function() local c = GetDB(); return not (c and c.importantGlowEnabled) end),
    get = function() local c = GetDB(); return c and c.importantGlowThickness or 2 end,
    set = function(_, v) local c = GetDB(); if c then c.importantGlowThickness = v; Refresh() end end,
  }

  -- ── Content ────────────────────────────────────────────────────
  a.contentHeader = Header("Content", "content", 60)

  a.fcShowSpellName = {
    type = "toggle", name = "Show Spell Name", order = 60.1, hidden = H("content"),
    get = function() local c = GetDB(); return c and c.showSpellName end,
    set = function(_, v) local c = GetDB(); if c then c.showSpellName = v; Refresh() end end,
  }
  a.fcSpellNameMaxWidth = {
    type = "range", name = "Spell Name Max Width", order = 60.15, width = 1.5,
    desc = "Maximum pixel width for the spell name text. 0 = auto (fills available bar width).",
    min = 0, max = 400, step = 5,
    hidden = H("content", function() local c = GetDB(); return not (c and c.showSpellName) end),
    get = function() local c = GetDB(); return c and c.spellNameMaxWidth or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.spellNameMaxWidth = v; Refresh() end end,
  }
  a.fcShowTimer = {
    type = "toggle", name = "Show Timer", order = 60.2, hidden = H("content"),
    get = function() local c = GetDB(); return c and c.showTimer end,
    set = function(_, v) local c = GetDB(); if c then c.showTimer = v; Refresh() end end,
  }
  a.fcShowCasterName = {
    type = "toggle", name = "Show Caster Name", order = 60.3, width = 1.2,
    desc = "Show the focus target's name below the bar.",
    hidden = H("content"),
    get = function() local c = GetDB(); return c and c.showCasterName end,
    set = function(_, v) local c = GetDB(); if c then c.showCasterName = v; Refresh() end end,
  }
  a.fcCasterNameColor = {
    type = "color", name = "Caster Name Color", order = 60.32, width = 1.2, hasAlpha = true,
    desc = "Color of the caster (focus target) name shown below the bar.",
    hidden = H("content", function() local c = GetDB(); return not (c and c.showCasterName) end),
    get = function()
      local c = GetDB(); local col = c and c.casterNameColor or {r=1,g=0.82,b=0,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.casterNameColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }
  a.fcCasterNameAnchor = {
    type = "select", name = "Caster Name Align", order = 60.34, width = 1.1,
    desc = "Which edge of the bar the caster name is anchored to.",
    values = { LEFT="Left", CENTER="Center", RIGHT="Right" },
    hidden = H("content", function() local c = GetDB(); return not (c and c.showCasterName) end),
    get = function() local c = GetDB(); return c and c.casterNameAnchor or "RIGHT" end,
    set = function(_, v) local c = GetDB(); if c then c.casterNameAnchor = v; Refresh() end end,
  }
  a.fcCasterOffsetX = {
    type = "range", name = "Caster Name Offset X", order = 60.35, width = 1.5,
    min = -200, max = 200, step = 1,
    hidden = H("content", function() local c = GetDB(); return not (c and c.showCasterName) end),
    get = function() local c = GetDB(); return c and c.casterNameOffsetX or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.casterNameOffsetX = v; Refresh() end end,
  }
  a.fcCasterOffsetY = {
    type = "range", name = "Caster Name Offset Y", order = 60.36, width = 1.5,
    min = -200, max = 200, step = 1,
    hidden = H("content", function() local c = GetDB(); return not (c and c.showCasterName) end),
    get = function() local c = GetDB(); return c and c.casterNameOffsetY or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.casterNameOffsetY = v; Refresh() end end,
  }
  a.fcShowFocusTarget = {
    type = "toggle", name = "Show Focus Target", order = 60.4, width = 1.2,
    desc = "Show who the focus target is currently targeting, during a cast.",
    hidden = H("content"),
    get = function() local c = GetDB(); return c and c.showFocusTarget end,
    set = function(_, v) local c = GetDB(); if c then c.showFocusTarget = v; Refresh() end end,
  }
  a.fcFocusTargetColor = {
    type = "color", name = "Focus Target Color", order = 60.403, width = 1.2, hasAlpha = true,
    desc = "Color of the focus-target text (who your focus is currently targeting) shown below the bar.",
    hidden = H("content", function() local c = GetDB(); return not (c and c.showFocusTarget) end),
    get = function()
      local c = GetDB(); local col = c and c.focusTargetColor or {r=0.6,g=0.8,b=1,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.focusTargetColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }
  a.fcFocusTargetAnchor = {
    type = "select", name = "Focus Target Align", order = 60.405, width = 1.1,
    desc = "Which edge of the bar the focus target text is anchored to.",
    values = { LEFT="Left", CENTER="Center", RIGHT="Right" },
    hidden = H("content", function() local c = GetDB(); return not (c and c.showFocusTarget) end),
    get = function() local c = GetDB(); return c and c.focusTargetAnchor or "RIGHT" end,
    set = function(_, v) local c = GetDB(); if c then c.focusTargetAnchor = v; Refresh() end end,
  }
  a.fcFocusTargetOffsetX = {
    type = "range", name = "Focus Target Offset X", order = 60.41, width = 1.5,
    min = -200, max = 200, step = 1,
    hidden = H("content", function() local c = GetDB(); return not (c and c.showFocusTarget) end),
    get = function() local c = GetDB(); return c and c.focusTargetOffsetX or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.focusTargetOffsetX = v; Refresh() end end,
  }
  a.fcFocusTargetOffsetY = {
    type = "range", name = "Focus Target Offset Y", order = 60.42, width = 1.5,
    min = -200, max = 200, step = 1,
    hidden = H("content", function() local c = GetDB(); return not (c and c.showFocusTarget) end),
    get = function() local c = GetDB(); return c and c.focusTargetOffsetY or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.focusTargetOffsetY = v; Refresh() end end,
  }

  -- ── Raid Marker ────────────────────────────────────────────────
  a.raidMarkerHeader = Header("Raid Marker", "raidMarker", 70)

  a.fcShowRaidMarker = {
    type = "toggle", name = "Show Raid Marker", order = 70.1, width = 1.2,
    desc = "Show the focus target's raid marker icon.",
    hidden = H("raidMarker"),
    get = function() local c = GetDB(); return c and c.showRaidMarker end,
    set = function(_, v) local c = GetDB(); if c then c.showRaidMarker = v; Refresh() end end,
  }
  a.fcRaidMarkerDefault = {
    type = "range", name = "Preview Marker Index", order = 70.15,
    desc = "Which marker to show in preview when focus has no marker. 0 = hide in preview. (1=Star 2=Circle 3=Diamond 4=Triangle 5=Moon 6=Square 7=Cross 8=Skull)",
    width = 1.8,
    min = 0, max = 8, step = 1,
    hidden = H("raidMarker", function() local c = GetDB(); return not (c and c.showRaidMarker) end),
    get = function() local c = GetDB(); return c and c.raidMarkerDefault or 8 end,
    set = function(_, v) local c = GetDB(); if c then c.raidMarkerDefault = v; Refresh() end end,
  }
  a.fcRaidMarkerSize = {
    type = "range", name = "Marker Size", order = 70.2,
    min = 8, max = 64, step = 2,
    hidden = H("raidMarker", function() local c = GetDB(); return not (c and c.showRaidMarker) end),
    get = function() local c = GetDB(); return c and c.raidMarkerSize or 32 end,
    set = function(_, v) local c = GetDB(); if c then c.raidMarkerSize = v; Refresh() end end,
  }
  a.fcRaidMarkerAnchor = {
    type = "select", name = "Marker Anchor", order = 70.3, width = 1.1,
    desc = "Which edge of the castbar the marker is anchored to.",
    values = { LEFT="Left", RIGHT="Right", CENTER="Center", TOP="Top", BOTTOM="Bottom" },
    hidden = H("raidMarker", function() local c = GetDB(); return not (c and c.showRaidMarker) end),
    get = function() local c = GetDB(); return c and c.raidMarkerAnchor or "LEFT" end,
    set = function(_, v) local c = GetDB(); if c then c.raidMarkerAnchor = v; Refresh() end end,
  }
  a.fcRaidMarkerOffsetX = {
    type = "range", name = "Marker Offset X", order = 70.4,
    min = -200, max = 200, step = 1,
    hidden = H("raidMarker", function() local c = GetDB(); return not (c and c.showRaidMarker) end),
    get = function() local c = GetDB(); return c and c.raidMarkerOffsetX or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.raidMarkerOffsetX = v; Refresh() end end,
  }
  a.fcRaidMarkerOffsetY = {
    type = "range", name = "Marker Offset Y", order = 70.5,
    min = -200, max = 200, step = 1,
    hidden = H("raidMarker", function() local c = GetDB(); return not (c and c.showRaidMarker) end),
    get = function() local c = GetDB(); return c and c.raidMarkerOffsetY or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.raidMarkerOffsetY = v; Refresh() end end,
  }

  -- ── Text ───────────────────────────────────────────────────────
  a.textHeader = Header("Text", "text", 80)

  a.fcFont = {
    type = "select", name = "Font", order = 80.1,
    dialogControl = "LSM30_Font",
    values = LSM and LSM:HashTable("font") or {},
    hidden = H("text"),
    get = function() local c = GetDB(); return c and c.font or "Friz Quadrata TT" end,
    set = function(_, v) local c = GetDB(); if c then c.font = v; Refresh() end end,
  }
  a.fcFontSize = {
    type = "range", name = "Font Size", order = 80.2,
    min = 6, max = 24, step = 1, hidden = H("text"),
    get = function() local c = GetDB(); return c and c.fontSize or 11 end,
    set = function(_, v) local c = GetDB(); if c then c.fontSize = v; Refresh() end end,
  }
  a.fcTextOutline = {
    type = "select", name = "Text Outline", order = 80.3,
    values = { NONE="None", OUTLINE="Thin", THICKOUTLINE="Thick" },
    hidden = H("text"),
    get = function() local c = GetDB(); return c and c.textOutline or "THICKOUTLINE" end,
    set = function(_, v) local c = GetDB(); if c then c.textOutline = v; Refresh() end end,
  }
  a.fcTextColor = {
    type = "color", name = "Text Color", order = 80.4, hasAlpha = true, hidden = H("text"),
    get = function()
      local c = GetDB(); local col = c and c.textColor or {r=1,g=1,b=1,a=1}
      return col.r, col.g, col.b, col.a or 1
    end,
    set = function(_, r, g, b, a)
      local c = GetDB(); if c then c.textColor = {r=r,g=g,b=b,a=a}; Refresh() end
    end,
  }

  -- ── Position ───────────────────────────────────────────────────
  a.positionHeader = Header("Position", "position", 90)

  a.fcPositionNote = {
    type = "description", order = 90.05, hidden = H("position"),
    name = "|cff888888Drag the castbar (or use the handle icon) while this panel is open, or set X/Y below. After changing the anchor point, drag to reposition.|r",
  }
  -- ── Anchor to another frame ────────────────────────────────────
  a.fcAnchorSep = {
    type = "description", name = "|cff888888— Anchor to Another Frame —|r",
    order = 90.06, hidden = H("position"),
  }
  a.fcAnchorToFrame = {
    type = "toggle", name = "Anchor to Frame", order = 90.061, width = 1.5,
    desc = "Pin the castbar to another UI frame instead of a fixed screen position. When on, use the point and offset controls below; dragging is disabled.",
    hidden = H("position"),
    get = function() local c = GetDB(); return c and c.anchorToFrame end,
    set = function(_, v) local c = GetDB(); if c then c.anchorToFrame = v; Refresh() end end,
  }
  a.fcAnchorFrameName = {
    type = "input", name = "Anchor Frame Name", order = 90.062, width = 1.8,
    desc = "Global name of the frame to anchor to (e.g. PlayerFrame, TargetFrame, FocusFrame). If the frame isn't found, the castbar falls back to its normal position.",
    hidden = H("position", function() return not AnchoredOn() end),
    get = function() local c = GetDB(); return c and c.anchorFrameName or "" end,
    set = function(_, v)
      local c = GetDB(); if not c then return end
      c.anchorFrameName = (type(v) == "string" and v:trim()) or ""
      Refresh()
    end,
  }
  a.fcAnchorCommon = {
    type = "select", name = "Common Frames", order = 90.063, width = 1.2,
    desc = "Quick-pick a common frame to fill the name above.",
    values = {
      PlayerFrame="Player Frame", TargetFrame="Target Frame",
      FocusFrame="Focus Frame", PetFrame="Pet Frame",
      EssentialCooldownViewer="CDM: Essential", UtilityCooldownViewer="CDM: Utility",
      BuffIconCooldownViewer="CDM: Buff Icons", BuffBarCooldownViewer="CDM: Buff Bars",
    },
    hidden = H("position", function() return not AnchoredOn() end),
    get = function() local c = GetDB(); return c and c.anchorFrameName end,
    set = function(_, v) local c = GetDB(); if c then c.anchorFrameName = v; Refresh() end end,
  }
  a.fcAnchorPoint = {
    type = "select", name = "Castbar Point", order = 90.064, width = 1.2,
    desc = "Which point of the castbar attaches to the target frame.",
    values = ANCHOR_POINTS,
    hidden = H("position", function() return not AnchoredOn() end),
    get = function() local c = GetDB(); return c and c.anchorPoint or "CENTER" end,
    set = function(_, v) local c = GetDB(); if c then c.anchorPoint = v; Refresh() end end,
  }
  a.fcAnchorRelPoint = {
    type = "select", name = "Target Frame Point", order = 90.065, width = 1.4,
    desc = "Which point of the target frame the castbar attaches to.",
    values = ANCHOR_POINTS,
    hidden = H("position", function() return not AnchoredOn() end),
    get = function() local c = GetDB(); return c and c.anchorRelativePoint or "CENTER" end,
    set = function(_, v) local c = GetDB(); if c then c.anchorRelativePoint = v; Refresh() end end,
  }
  a.fcAnchorOffsetX = {
    type = "range", name = "Anchor Offset X", order = 90.066, width = 1.2,
    min = -600, max = 600, step = 1,
    hidden = H("position", function() return not AnchoredOn() end),
    get = function() local c = GetDB(); return c and c.anchorOffsetX or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.anchorOffsetX = v; Refresh() end end,
  }
  a.fcAnchorOffsetY = {
    type = "range", name = "Anchor Offset Y", order = 90.067, width = 1.2,
    min = -600, max = 600, step = 1,
    hidden = H("position", function() return not AnchoredOn() end),
    get = function() local c = GetDB(); return c and c.anchorOffsetY or 0 end,
    set = function(_, v) local c = GetDB(); if c then c.anchorOffsetY = v; Refresh() end end,
  }
  a.fcFreeSep = {
    type = "description", name = "|cff888888— Free Position —|r",
    order = 90.07, hidden = H("position", AnchoredOn),
  }
  a.fcBarAnchorPoint = {
    type = "select", name = "Bar Anchor Point", order = 90.08, width = 1.3,
    desc = "Which point of the castbar frame is pinned to the screen. Drag to reposition after changing.",
    values = ANCHOR_POINTS,
    hidden = H("position", AnchoredOn),
    get = function() local c = GetDB(); return c and c.barAnchorPoint or "CENTER" end,
    set = function(_, v)
      local c = GetDB(); if not c then return end
      c.barAnchorPoint = v
      -- Wipe stored position so the bar snaps to a neutral offset with the new anchor
      c.barPosition = { point=v, relPoint=v, x=0, y=0 }
      Refresh()
    end,
  }
  a.fcPosX = {
    type = "range", name = "Position X", order = 90.1,
    min = -2000, max = 2000, step = 1, hidden = H("position", AnchoredOn),
    get = function() local c = GetDB(); return (c and c.barPosition and c.barPosition.x) or 0 end,
    set = function(_, v)
      local c = GetDB(); if not c then return end
      c.barPosition = c.barPosition or {point="CENTER",relPoint="CENTER",x=0,y=-120}
      c.barPosition.x = v; Refresh()
    end,
  }
  a.fcPosY = {
    type = "range", name = "Position Y", order = 90.2,
    min = -2000, max = 2000, step = 1, hidden = H("position", AnchoredOn),
    get = function() local c = GetDB(); return (c and c.barPosition and c.barPosition.y) or -120 end,
    set = function(_, v)
      local c = GetDB(); if not c then return end
      c.barPosition = c.barPosition or {point="CENTER",relPoint="CENTER",x=0,y=-120}
      c.barPosition.y = v; Refresh()
    end,
  }
  a.fcResetPos = {
    type = "execute", name = "Reset Position", order = 90.3, width = 1.0,
    hidden = H("position", AnchoredOn),
    func = function()
      local c = GetDB(); if not c then return end
      c.barPosition = {point="CENTER",relPoint="CENTER",x=0,y=-120}; Refresh()
    end,
  }

  -- ── Reset ──────────────────────────────────────────────────────
  a.resetHeader = Header("Reset", "reset", 100)

  a.fcResetDesc = {
    type = "description", order = 100.05, hidden = H("reset"),
    name = "|cff888888Reset every Focus Castbar setting (appearance, colors, glows, kick, hold, text, position and anchoring) back to its default. The feature stays enabled.|r",
  }
  a.fcResetAll = {
    type = "execute", name = "|cffff5555Reset All to Default|r", order = 100.1, width = 1.5,
    desc = "Restore all Focus Castbar settings to their defaults.",
    confirm = true,
    confirmText = "Reset ALL Focus Castbar settings to their defaults?",
    hidden = H("reset"),
    func = ResetAllToDefaults,
  }

  return opts
end
