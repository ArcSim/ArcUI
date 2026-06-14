-- ===================================================================
-- ArcUI_Castbar_Options.lua
-- Options panel for the player castbar
-- ===================================================================

local ADDON, ns = ...
ns.CastbarOptions = ns.CastbarOptions or {}

local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- ===================================================================
-- DB ACCESSOR
-- ===================================================================
local function GetCastbarDB()
  local db = ns.API and ns.API.GetDB and ns.API.GetDB()
  return db and db.castbar
end

local function Refresh()
  if AceConfigRegistry then
    AceConfigRegistry:NotifyChange("ArcUI")
  end
  if ns.Castbar and ns.Castbar.ApplyAppearance then
    ns.Castbar.ApplyAppearance()
  end
end

-- ===================================================================
-- OPTIONS TABLE
-- ===================================================================
function ns.CastbarOptions.GetOptionsTable()
  return {
    type = "group",
    name = "Castbar",
    order = 3.5,
    args = {

      -- ── Enable ─────────────────────────────────────────────────────
      enabled = {
        type = "toggle",
        name = "|cffffd100Enable Castbar|r",
        desc = "Show a castbar while casting or channeling spells.",
        order = 1,
        width = "full",
        get = function() local c = GetCastbarDB(); return c and c.enabled end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.enabled = v; Refresh() end
        end,
      },

      spacer1 = { type = "description", name = "", order = 2 },

      -- ── Bar Appearance ─────────────────────────────────────────────
      barHeader = {
        type = "header",
        name = "Bar",
        order = 10,
      },

      barColor = {
        type = "color",
        name = "Cast Color",
        desc = "Color of the bar during a normal (non-channel) cast.",
        order = 11,
        hasAlpha = true,
        get = function()
          local c = GetCastbarDB()
          local col = c and c.barColor or {r=0.2, g=0.8, b=1, a=1}
          return col.r, col.g, col.b, col.a or 1
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB()
          if c then c.barColor = {r=r, g=g, b=b, a=a}; Refresh() end
        end,
      },

      channelColor = {
        type = "color",
        name = "Channel Color",
        desc = "Color of the bar during a channeled spell.",
        order = 12,
        hasAlpha = true,
        get = function()
          local c = GetCastbarDB()
          local col = c and c.channelColor or {r=0.2, g=1, b=0.4, a=1}
          return col.r, col.g, col.b, col.a or 1
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB()
          if c then c.channelColor = {r=r, g=g, b=b, a=a}; Refresh() end
        end,
      },

      texture = {
        type = "select",
        name = "Texture",
        order = 13,
        dialogControl = "LSM30_Statusbar",
        values = LSM and LSM:HashTable("statusbar") or {},
        get = function()
          local c = GetCastbarDB()
          return c and c.texture or "Blizzard"
        end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.texture = v; Refresh() end
        end,
      },

      width = {
        type = "range",
        name = "Width",
        order = 14,
        min = 50, max = 600, step = 1,
        get = function() local c = GetCastbarDB(); return c and c.width or 250 end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.width = v; Refresh() end
        end,
      },

      height = {
        type = "range",
        name = "Height",
        order = 15,
        min = 4, max = 80, step = 1,
        get = function() local c = GetCastbarDB(); return c and c.height or 20 end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.height = v; Refresh() end
        end,
      },

      opacity = {
        type = "range",
        name = "Opacity",
        order = 16,
        min = 0, max = 1, step = 0.05,
        isPercent = true,
        get = function() local c = GetCastbarDB(); return c and c.opacity or 1.0 end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.opacity = v; Refresh() end
        end,
      },

      -- ── Background ─────────────────────────────────────────────────
      bgHeader = {
        type = "header",
        name = "Background",
        order = 20,
      },

      showBackground = {
        type = "toggle",
        name = "Show Background",
        order = 21,
        get = function() local c = GetCastbarDB(); return c and c.showBackground end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.showBackground = v; Refresh() end
        end,
      },

      backgroundColor = {
        type = "color",
        name = "Background Color",
        order = 22,
        hasAlpha = true,
        hidden = function()
          local c = GetCastbarDB()
          return not (c and c.showBackground)
        end,
        get = function()
          local c = GetCastbarDB()
          local col = c and c.backgroundColor or {r=0.1, g=0.1, b=0.1, a=0.9}
          return col.r, col.g, col.b, col.a or 0.9
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB()
          if c then c.backgroundColor = {r=r, g=g, b=b, a=a}; Refresh() end
        end,
      },

      -- ── Border ─────────────────────────────────────────────────────
      borderHeader = {
        type = "header",
        name = "Border",
        order = 30,
      },

      showBorder = {
        type = "toggle",
        name = "Show Border",
        order = 31,
        get = function() local c = GetCastbarDB(); return c and c.showBorder end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.showBorder = v; Refresh() end
        end,
      },

      borderColor = {
        type = "color",
        name = "Border Color",
        order = 32,
        hasAlpha = true,
        hidden = function()
          local c = GetCastbarDB()
          return not (c and c.showBorder)
        end,
        get = function()
          local c = GetCastbarDB()
          local col = c and c.borderColor or {r=0, g=0, b=0, a=1}
          return col.r, col.g, col.b, col.a or 1
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB()
          if c then c.borderColor = {r=r, g=g, b=b, a=a}; Refresh() end
        end,
      },

      drawnBorderThickness = {
        type = "range",
        name = "Border Thickness",
        order = 33,
        min = 1, max = 8, step = 1,
        hidden = function()
          local c = GetCastbarDB()
          return not (c and c.showBorder)
        end,
        get = function() local c = GetCastbarDB(); return c and c.drawnBorderThickness or 2 end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.drawnBorderThickness = v; Refresh() end
        end,
      },

      -- ── Icon ───────────────────────────────────────────────────────
      iconHeader = {
        type = "header",
        name = "Icon",
        order = 40,
      },

      showIcon = {
        type = "toggle",
        name = "Show Spell Icon",
        desc = "Show the spell icon to the left of the cast bar.",
        order = 41,
        get = function() local c = GetCastbarDB(); return c and c.showIcon end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.showIcon = v; Refresh() end
        end,
      },

      iconSize = {
        type = "range",
        name = "Icon Size",
        order = 42,
        min = 8, max = 64, step = 1,
        hidden = function()
          local c = GetCastbarDB()
          return not (c and c.showIcon)
        end,
        get = function() local c = GetCastbarDB(); return c and c.iconSize or 20 end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.iconSize = v; Refresh() end
        end,
      },

      -- ── Text ───────────────────────────────────────────────────────
      textHeader = {
        type = "header",
        name = "Text",
        order = 50,
      },

      showText = {
        type = "toggle",
        name = "Show Spell Name",
        order = 51,
        get = function() local c = GetCastbarDB(); return c and c.showText end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.showText = v; Refresh() end
        end,
      },

      showTimer = {
        type = "toggle",
        name = "Show Timer",
        desc = "Show the remaining cast time.",
        order = 52,
        get = function() local c = GetCastbarDB(); return c and c.showTimer end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.showTimer = v; Refresh() end
        end,
      },

      font = {
        type = "select",
        name = "Font",
        order = 53,
        dialogControl = "LSM30_Font",
        values = LSM and LSM:HashTable("font") or {},
        get = function()
          local c = GetCastbarDB()
          return c and c.font or "2002 Bold"
        end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.font = v; Refresh() end
        end,
      },

      fontSize = {
        type = "range",
        name = "Font Size",
        order = 54,
        min = 6, max = 32, step = 1,
        get = function() local c = GetCastbarDB(); return c and c.fontSize or 14 end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.fontSize = v; Refresh() end
        end,
      },

      textColor = {
        type = "color",
        name = "Text Color",
        order = 55,
        hasAlpha = true,
        get = function()
          local c = GetCastbarDB()
          local col = c and c.textColor or {r=1, g=1, b=1, a=1}
          return col.r, col.g, col.b, col.a or 1
        end,
        set = function(_, r, g, b, a)
          local c = GetCastbarDB()
          if c then c.textColor = {r=r, g=g, b=b, a=a}; Refresh() end
        end,
      },

      textOutline = {
        type = "select",
        name = "Text Outline",
        order = 56,
        values = {
          NONE         = "None",
          OUTLINE      = "Outline",
          THICKOUTLINE = "Thick Outline",
        },
        get = function()
          local c = GetCastbarDB()
          local v = c and c.textOutline or "THICKOUTLINE"
          if v == "" or v == nil then return "NONE" end
          return v
        end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then
            c.textOutline = (v == "NONE") and "NONE" or v
            Refresh()
          end
        end,
      },

      -- ── Behavior ───────────────────────────────────────────────────
      behaviorHeader = {
        type = "header",
        name = "Behavior",
        order = 60,
      },

      hideOutOfCombat = {
        type = "toggle",
        name = "Hide Out of Combat",
        desc = "Do not show the castbar when out of combat.",
        order = 61,
        get = function() local c = GetCastbarDB(); return c and c.hideOutOfCombat end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.hideOutOfCombat = v end
        end,
      },

      hideChannels = {
        type = "toggle",
        name = "Hide Channels",
        desc = "Do not show the castbar for channeled spells.",
        order = 62,
        get = function() local c = GetCastbarDB(); return c and c.hideChannels end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.hideChannels = v end
        end,
      },

      -- ── Position ───────────────────────────────────────────────────
      positionHeader = {
        type = "header",
        name = "Position",
        order = 70,
      },

      barMovable = {
        type = "toggle",
        name = "Allow Dragging",
        desc = "Left-click and drag the castbar to reposition it.",
        order = 71,
        get = function() local c = GetCastbarDB(); return c and c.barMovable ~= false end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.barMovable = v; Refresh() end
        end,
      },

      positionDesc = {
        type = "description",
        name = "|cffaaaaaaLeft-click and drag the bar to reposition it. The position is saved automatically.|r",
        order = 72,
        fontSize = "small",
      },

      -- ── Frame Strata ───────────────────────────────────────────────
      strataHeader = {
        type = "header",
        name = "Frame Strata",
        order = 80,
      },

      barFrameStrata = {
        type = "select",
        name = "Strata",
        order = 81,
        values = {
          BACKGROUND = "Background",
          LOW        = "Low",
          MEDIUM     = "Medium",
          HIGH       = "High",
          DIALOG     = "Dialog",
        },
        get = function()
          local c = GetCastbarDB()
          return c and c.barFrameStrata or "MEDIUM"
        end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.barFrameStrata = v; Refresh() end
        end,
      },

      barFrameLevel = {
        type = "range",
        name = "Frame Level",
        order = 82,
        min = 1, max = 200, step = 1,
        get = function() local c = GetCastbarDB(); return c and c.barFrameLevel or 10 end,
        set = function(_, v)
          local c = GetCastbarDB()
          if c then c.barFrameLevel = v; Refresh() end
        end,
      },

    }, -- args
  }
end

-- ===================================================================
-- END OF ArcUI_Castbar_Options.lua
-- ===================================================================
