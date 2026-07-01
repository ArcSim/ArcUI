-- ===================================================================
-- ArcUI_DB.lua
-- Database structure with support for multiple bar slots, resource bars,
-- and cooldown bars (charge-based ability tracking)
-- v2.8.0: Added ColorCurve threshold support for duration bars
-- ===================================================================

local ADDON, ns = ...
ns.API = ns.API or {}  -- Initialize API table

-- 12.1-forward compat: the global SetDesaturation(region, bool) helper was REMOVED in
-- 12.1 (the texture methods SetDesaturated/SetDesaturation still exist). AceGUI's
-- CheckBox (and other libs) call the global -> "attempt to call a nil value" when the
-- options panel opens. Polyfill it once. Inert on 12.0.7 where the global still exists.
if not SetDesaturation then
  function SetDesaturation(region, desaturation)
    if region and region.SetDesaturated then
      region:SetDesaturated(desaturation)
    end
  end
end

-- ===================================================================
-- DEFAULT THRESHOLD PRESETS
-- ===================================================================
local DEFAULT_THRESHOLDS = {
  simple = {
    { enabled = true, minValue = 0, maxValue = 100, color = {r=0, g=0.8, b=1, a=1} }
  },
  threshold = {
    { enabled = true, minValue = 0,  maxValue = 100, color = {r=1, g=0, b=0, a=1} },
    { enabled = true, minValue = 50, maxValue = 100, color = {r=1, g=1, b=0, a=1} },
    { enabled = true, minValue = 80, maxValue = 100, color = {r=0, g=1, b=0, a=1} },
    { enabled = false, minValue = 50, color = {r=1, g=0.5, b=0, a=1} },
    { enabled = false, minValue = 70, color = {r=0.5, g=0, b=1, a=1} },
    { enabled = false, minValue = 90, color = {r=1, g=0, b=1, a=1} }
  }
}

ns.DB_DEFAULTS = {
  global = {
    profileSnapshots = {},
    migrationWarningSeen = false,
    minimap = {
      hide = false,
      minimapPos = 220,
      radius = 80
    },
    menuBackgroundAlpha = 1.0,
    -- Options panel saved position/size
    optionsPanelPos = nil,   -- { point, x, y }
    optionsPanelSize = nil,  -- { width, height }
    -- CDM Master Kill Switch - stored in global so it's checked before CDM modules init
    cdmStylingEnabled = true,
    -- Pending CDM profiles from master import (for classes not yet logged)
    masterCDMPending = nil,
    -- Skin preset library (shared across all characters)
    skinLibrary = {},
  },
  
  -- Profile storage (shared across characters using same profile)
  profile = {
    -- CDM Enhancement settings (per-profile for cross-character use)
    cdmEnhance = {
      enabled = true,
      enableAuraCustomization = true,
      enableCooldownCustomization = true,
      unlocked = false,
      textDragMode = false,
      iconSettings = {},        -- [cooldownID] = { per-icon settings }
      globalAuraSettings = {},  -- Default settings for all aura icons
      globalCooldownSettings = {}, -- Default settings for all cooldown icons
      globalApplyScale = false,
      globalApplyHideShadow = false,
      groupSettings = {         -- Group-level settings per viewer type
        aura = { padding = nil, scale = nil },
        cooldown = { padding = nil, scale = nil },
        utility = { padding = nil, scale = nil },
      },
    },
    -- CDM Groups settings (per-profile for cross-character use)
    cdmGroups = {
      specData = {},        -- [specIndex] = { groups = {}, savedPositions = {}, freeIcons = {} }
      specInheritedFrom = {},
      lastActiveSpec = nil,
    },
  },
  
  char = {
    -- NOTE: cdmGroups is NOT in defaults anymore!
    -- We manage cdmGroups storage directly in ArcUIDB.char[charKey].cdmGroups
    -- to bypass AceDB's removeDefaults which strips our nested specData.
    -- See ArcUI_CDM_Shared.lua GetCDMGroupsDB() for the storage implementation.
    
    selectedBar = 1,
    selectedResourceBar = 1,
    selectedCooldownBar = 1,
    selectedTexture = 1,
    
    -- Array of buff/debuff bar configurations (up to 30 bars)
    bars = {
      [1] = {
        tracking = {
          enabled = false,
          trackType = "buff",
          spellID = 0,
          buffName = "",
          iconTextureID = 0,
          cooldownID = 0,
          alternateCooldownIDs = {},  -- Additional cooldownIDs for cross-spec support
          excludedCooldownIDs = {},   -- CooldownIDs manually removed; never auto-discovered
          slotNumber = 0,
          maxStacks = 10,
          auraInstanceID = 0,
          useBaseSpell = false,  -- Ignore CDM override spell, use base spell for icon

          sourceType = "icon",
          useDurationBar = false,
          dynamicMaxDuration = false,
          maxDuration = 30,
        },
        display = {
          enabled = true,
          displayMode = "single",
          width = 200,
          height = 20,
          barScale = 1.0,
          opacity = 1.0,
          
          displayType = "bar",
          iconSize = 48,
          iconShowTexture = true,
          iconShowStacks = true,
          iconStackAnchor = "TOPRIGHT",
          iconStackPosition = nil,
          iconStackFont = "2002 Bold",
          iconStackFontSize = 16,
          iconStackColor = {r=1, g=1, b=1, a=1},
          iconStackOutline = "THICKOUTLINE",
          iconStackShadow = false,
          iconShowDuration = true,
          iconDurationFont = "2002 Bold",
          iconDurationFontSize = 14,
          iconDurationColor = {r=1, g=1, b=1, a=1},
          iconDurationOutline = "THICKOUTLINE",
          iconDurationShadow = false,
          iconShowBorder = true,
          iconBorderColor = {r=0, g=0, b=0, a=1},
          iconMultiMode = false,
          iconMultiFreeMode = false,
          iconMultiLockPositions = false,
          iconMultiShowDesatBg = true,
          iconMultiSpacing = 4,
          iconMultiDirection = "RIGHT",
          iconMultiPositions = {},
          iconMultiShowDurationOn = 1,
          iconMultiDurationAnchor = "BOTTOM",
          
          -- ═══════════════════════════════════════════════════════════════
          -- COOLDOWN DISPLAY OPTIONS
          -- ═══════════════════════════════════════════════════════════════
          -- Cooldown Swipe (COOLDOWNS ONLY)
          iconShowCooldownSwipe = true,
          iconCooldownReverse = false,
          iconCooldownDrawEdge = true,
          iconCooldownDrawBling = true,
          
          -- Desaturation options
          iconDesaturateOnCooldown = true,
          iconDesaturateWhenInactive = false,
          
          -- Icon Zoom (crop edges)
          iconZoom = 0,
          
          texture = "Blizzard",
          rotateTexture = false,
          fillTextureScale = 1.0,
          barOrientation = "horizontal",  -- "horizontal" or "vertical"
          barReverseFill = false,         -- Reverse fill direction (right-to-left / top-to-bottom)
          useGradient = false,
          gradientSecondColor = {r=0, g=0, b=0, a=0.5},  -- Second color for gradient (darker by default)
          gradientDirection = "VERTICAL",  -- "VERTICAL" or "HORIZONTAL"
          gradientIntensity = 0.5,  -- How much the second color affects the gradient (0-1)
          barColor = {r=0, g=0.5, b=1, a=1},
          thresholdMode = "simple",
          fragmentedSpacing = 2,
          fragmentedColors = {},
          fragmentedChargingColor = {r=0.4, g=0.4, b=0.4, a=1},
          fragmentedShowSegmentText = false,
          fragmentedTextSize = 10,
          -- Icons mode settings (for secondary resources like Runes/Essence)
          iconsMode = "row",  -- "row" or "freeform"
          iconsSize = 32,
          iconsSpacing = 4,
          iconsShape = "square",  -- "square" or "circle"
          iconsPositions = {},  -- saved positions for freeform mode
          iconsShowCooldownText = true,
          iconsCooldownTextSize = 12,
          enableMaxColor = false,
          maxColor = {r=0, g=1, b=0, a=1},
          foldedColor1 = {r=0, g=0.5, b=1, a=1},
          foldedColor2 = {r=0, g=1, b=0, a=1},
          enableSmoothing = false,
          showBackground = true,
          backgroundColor = {r=0.2, g=0.2, b=0.2, a=0.8},
          showBorder = true,
          borderStyle = "Drawn",
          drawnBorderThickness = 2,
          borderColor = {r=0, g=0, b=0, a=1},
          showTickMarks = true,
          tickMode = "all",
          tickThickness = 1,
          tickHeightPercent = 100,
          tickHeightAnchor = "center",
          tickThicknessAnchor = "center",
          tickColor = {r=0, g=0, b=0, a=1},
          showText = true,
          font = "2002 Bold",
          fontSize = 24,
          textColor = {r=1, g=1, b=1, a=1},
          textOutline = "THICKOUTLINE",
          textShadow = false,
          textAnchor = "OUTERTOP",
          textAnchorOffsetX = 0,
          textAnchorOffsetY = 0,
          showDuration = false,
          durationFont = "2002 Bold",
          durationFontSize = 18,
          durationColor = {r=1, g=1, b=1, a=1},
          durationOutline = "THICKOUTLINE",
          durationShadow = false,
          durationAnchor = "CENTER",
          durationAnchorOffsetX = 0,
          durationAnchorOffsetY = 0,
          durationDecimals = 1,
          durationShowWhenReady = false,
          
          -- ═══════════════════════════════════════════════════════════════
          -- DURATION BAR COLORCURVE THRESHOLD SETTINGS (v2.8.0)
          -- Uses WoW 12.0 ColorCurve API for secret-safe color transitions
          -- ═══════════════════════════════════════════════════════════════
          durationColorCurveEnabled = false,       -- Enable ColorCurve thresholds
          durationColorCurveMode = "step",         -- "step" (threshold) or "gradient"
          durationColorCurveThreshold = 0.30,      -- Percentage (0-1) for threshold
          durationColorCurveLowColor = {r=1, g=0, b=0, a=1},   -- Color below threshold (red)
          durationColorCurveHighColor = {r=0, g=1, b=0, a=1},  -- Color at/above threshold (green)
          durationColorCurveMidColor = {r=1, g=1, b=0, a=1},   -- Mid color for gradient mode (yellow)
          durationBarFillMode = "drain",   -- "drain" (shrinks as time passes) or "fill" (grows as time passes)
          
          -- Multi-threshold duration bar settings (v2 migration adds these)
          -- Must be in defaults so compaction can strip them when unchanged
          durationThreshold2Enabled = false,
          durationThreshold2Value = 75,
          durationThreshold2Color = {r=0.8, g=0.8, b=0, a=1},
          durationThreshold3Enabled = false,
          durationThreshold3Value = 50,
          durationThreshold3Color = {r=1, g=0.5, b=0, a=1},
          durationThreshold4Enabled = false,
          durationThreshold4Value = 25,
          durationThreshold4Color = {r=1, g=0.3, b=0, a=1},
          durationThreshold5Enabled = false,
          durationThreshold5Value = 10,
          durationThreshold5Color = {r=1, g=0, b=0, a=1},
          durationThresholdAsSeconds = false,
          durationThresholdMaxDuration = 30,
          
          showName = false,
          nameFont = "2002 Bold",
          nameFontSize = 14,
          nameColor = {r=1, g=1, b=1, a=1},
          nameOutline = "THICKOUTLINE",
          nameShadow = false,
          nameAnchor = "CENTER",
          nameAnchorOffsetX = 0,
          nameAnchorOffsetY = 0,
          showBarIcon = false,
          barIconSize = 32,
          iconOverride = nil,    -- Spell ID or texture ID to override the bar icon
          barIconAnchor = "LEFT",
          barIconAnchorOffsetX = 0,
          barIconAnchorOffsetY = 0,
          barIconShowBorder = true,
          barIconBorderColor = {r=0, g=0, b=0, a=1},
          barMovable = true,
          textMovable = true,
          textLocked = true,
          barPosition = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = 200
          },
          textPosition = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = 230
          },
          -- Frame strata settings
          barFrameStrata = "MEDIUM",
          barFrameLevel = 10,
        },
        behavior = {
          hideBuffIcon = false,
          hideWhenZeroStacks = false,
          hideWhenInactive = false,
          hideOutOfCombat = false,
          showOnSpec = 0,
          showOnSpecs = {}
        },
        thresholds = {
          [1] = { enabled = true, minValue = 0, maxValue = 10, color = {r=0, g=0.5, b=1, a=1} },
          [2] = { enabled = false, minValue = 5, maxValue = 10, color = {r=1, g=1, b=0, a=1} },
          [3] = { enabled = false, minValue = 8, maxValue = 10, color = {r=0, g=1, b=0, a=1} }
        },
        stackColors = {},
        colorRanges = {
          [1] = { from = 1, to = 4, color = {r=0, g=0.5, b=1, a=1} },
          [2] = { enabled = false, from = 5, to = 8, color = {r=1, g=1, b=0, a=1} },
          [3] = { enabled = false, from = 9, to = 12, color = {r=0, g=1, b=0, a=1} }
        },
        
        -- ═══════════════════════════════════════════════════════════════
        -- CONDITIONAL EVENTS
        -- ═══════════════════════════════════════════════════════════════
        events = {},
      },
    },

    -- ===============================================================
    -- AURA TEXTURES
    -- Freely-placeable images that flip between active and inactive
    -- styling based on a tracked buff/debuff. Mirrors the buff/debuff
    -- bar trigger model (tracking block is intentionally shaped the same
    -- so it can reuse the CDM aura resolution); rendering is its own
    -- texture-display engine (ns.Textures).
    -- ===============================================================
    textures = {
      [1] = {
        tracking = {
          enabled = false,
          trackType = "buff",          -- "buff" or "debuff"
          spellID = 0,
          buffName = "",
          iconTextureID = 0,
          cooldownID = 0,
          alternateCooldownIDs = {},   -- Additional cooldownIDs for cross-spec support
          excludedCooldownIDs = {},    -- CooldownIDs manually removed; never auto-discovered
          slotNumber = 0,
          auraInstanceID = 0,
          useBaseSpell = false,
        },
        display = {
          enabled = true,

          -- SOURCE
          textureSource = "library",   -- "library" (FileDataID / atlas) or "custom" (file path)
          textureID = 0,               -- FileDataID number OR atlas string when source = "library"
          customTexturePath = "",      -- file path when source = "custom"

          -- SIZE / POSITION
          width = 64,
          height = 64,
          position = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = 0,
          },
          frameStrata = "MEDIUM",
          frameLevel = 10,
          movable = true,

          -- RENDER (shared by both states)
          blendMode = "BLEND",         -- "BLEND" (opaque) or "ADD" (glow)
          rotateEnabled = false,
          rotation = 0,                -- degrees (-180..180)
          mirrorH = false,
          mirrorV = false,
          zoomEnabled = false,
          zoomPct = 0,                 -- 0..50
          cropEnabled = false,
          cropL = 0,                   -- per-side crop percent (0..100)
          cropR = 0,
          cropT = 0,
          cropB = 0,

          -- ACTIVE STATE STYLE (aura present)
          activeColor = {r=1, g=1, b=1, a=1},
          activeAlpha = 1,
          activeDesaturate = false,
          activeDesaturatePct = 100,

          -- INACTIVE STATE STYLE (aura absent)
          showWhenInactive = false,    -- false = hide when inactive; true = show with inactive style
          inactiveColor = {r=1, g=1, b=1, a=1},
          inactiveAlpha = 0.5,
          inactiveDesaturate = true,
          inactiveDesaturatePct = 100,

          -- DURATION FADE-OUT (active state; secret-safe via ColorCurve alpha)
          fadeOutEnabled = false,
          fadeStartPct = 50,           -- begin fading once remaining drops below this %

          -- RESIZE
          lockAspect = false,          -- on-screen resize keeps the width/height ratio

          -- LOOPING PULSE (size) + GLOW (active state)
          pulseEnabled = false,
          pulseScale = 1.15,           -- target scale for the size pulse
          pulseSpeed = 0.5,            -- seconds per pulse half-cycle
          glowEnabled = false,
          glowType = "pixel",          -- pixel / autocast / button / proc

          -- DURATION DRAIN (active state): the texture depletes directionally
          -- like a bar, driven secret-safely by StatusBar:SetTimerDuration.
          progressEnabled = false,
          progressDir = "TOP_TO_BOTTOM",  -- TOP_TO_BOTTOM / BOTTOM_TO_TOP / LEFT_TO_RIGHT / RIGHT_TO_LEFT
          progressHideGhost = false,      -- the dim full-texture "ghost" shows by default (WeakAuras look); true hides it
          -- DRAIN REGION: inset fractions (0..0.49) from each edge defining the
          -- sub-rectangle that drains. All 0 = whole texture (default). When any
          -- inset > 0, only that band depletes and the rest of the texture stays solid.
          drainInsetL = 0,
          drainInsetR = 0,
          drainInsetT = 0,
          drainInsetB = 0,

          -- DURATION TEXT (countdown) -- mirrors the Aura Bars' duration-text options.
          showDuration = false,
          durationFont = "2002 Bold",
          durationFontSize = 18,
          durationColor = { r = 1, g = 1, b = 1, a = 1 },
          durationOutline = "THICKOUTLINE",
          durationShadow = false,
          durationDecimals = 1,
          durationAnchor = "CENTER",
          durationAnchorOffsetX = 0,
          durationAnchorOffsetY = 0,
          durationTextStrata = "HIGH",
          durationTextLevel = 13,
        },
        behavior = {
          hideWhen = {},          -- shared "Hide When..." conditions (same evaluator as the Aura Bars)
          hideLogic = "any",      -- "any" = hide if ANY condition met; "all" = only if ALL met
          hideWhenAlpha = 0,      -- opacity when a hide condition is active (0 = fully hidden)
          showOnSpec = 0,         -- spec restriction lives in the catalog row now; runtime gate stays
          showOnSpecs = {},
        },
      },
    },

    -- ===============================================================
    -- RESOURCE BARS (Primary AND Secondary resources with threshold color layers)
    -- v2.6.0: Added resourceCategory, secondaryType for secondary resource support
    -- ===============================================================
    resourceBars = {
      [1] = {
        tracking = {
          enabled = false,
          resourceCategory = "primary",  -- "primary" or "secondary"
          powerType = 0,                 -- For primary resources (Enum.PowerType)
          secondaryType = nil,           -- "comboPoints", "holyPower", "chi", "runes", "soulShards", "essence", "arcaneCharges", "stagger", "soulFragments", "soulFragmentsDevourer", "maelstromWeapon", "mana"
          powerName = "",
          maxValue = 100,
          overrideMax = false,
          -- Rune-specific settings
          showRuneTimer = false,         -- Show time until next rune ready
        },
        thresholds = {
          { enabled = true, minValue = 0, maxValue = 100, color = {r=0, g=0.8, b=1, a=1} },
          { enabled = false, minValue = 50, maxValue = 100, color = {r=1, g=1, b=0, a=1} },
          { enabled = false, minValue = 80, maxValue = 100, color = {r=0, g=1, b=0, a=1} }
        },
        abilityThresholds = {},
        display = {
          enabled = true,
          thresholdMode = "simple",
          enableMaxColor = false,
          maxColor = {r=0, g=1, b=0, a=1},
          foldedColor1 = {r=0, g=0.5, b=1, a=1},
          foldedColor2 = {r=0, g=1, b=0, a=1},
          enableSmoothing = false,
          width = 250,
          height = 25,
          barScale = 1.0,
          opacity = 1.0,
          
          texture = "Blizzard",
          rotateTexture = false,
          fillTextureScale = 1.0,
          barOrientation = "horizontal",  -- "horizontal" or "vertical"
          barReverseFill = false,         -- Reverse fill direction
          showBackground = true,
          backgroundColor = {r=0.1, g=0.1, b=0.1, a=0.9},
          showBorder = true,
          drawnBorderThickness = 2,
          borderColor = {r=0, g=0, b=0, a=1},
          showTickMarks = false,
          tickMode = "all",
          tickThickness = 2,
          tickHeightPercent = 100,
          tickHeightAnchor = "center",
          tickThicknessAnchor = "center",
          tickColor = {r=1, g=1, b=1, a=0.8},
          showText = true,
          textFormat = "value",  -- "value" or "percent"
          font = "Friz Quadrata TT",
          fontSize = 20,
          textColor = {r=1, g=1, b=1, a=1},
          textAnchor = "OUTERTOP",
          textAnchorOffsetX = 0,
          textAnchorOffsetY = 0,
          barMovable = true,
          textMovable = true,
          textLocked = true,
          barPosition = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = -100
          },
          textPosition = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = -70
          },
          -- Frame strata settings
          barFrameStrata = "MEDIUM",
          barFrameLevel = 10,
          -- Text color thresholds (resource bars only; all off by default)
          textColorThresholdEnabled = false,
          textColorThresholdFill = false,
          textColorThresholdBaseColor = {r=1, g=1, b=1, a=1},
          textColorThresholdT1Enabled = false,
          textColorThresholdT1Value = 15,
          textColorThresholdT1Color = {r=1, g=0.6, b=0.8, a=1},
          textColorThresholdT2Enabled = false,
          textColorThresholdT2Value = 30,
          textColorThresholdT2Color = {r=0.5, g=1, b=0.5, a=1},
          textColorThresholdT3Enabled = false,
          textColorThresholdT3Value = 90,
          textColorThresholdT3Color = {r=1, g=0.3, b=0.3, a=1},
          textColorThresholdT4Enabled = false,
          textColorThresholdT4Value = 100,
          textColorThresholdT4Color = {r=1, g=1, b=0.3, a=1},
        },
        behavior = {
          hideOutOfCombat = false,
          hideWhenFull = false,
          hideWhenEmpty = false,
          hideBlizzardFrame = false,  -- Hide corresponding Blizzard resource frame
          showOnSpec = 0,
          showOnSpecs = {},
          talentConditions = nil,
          talentMatchMode = nil,
        },
        prediction = {
          spells = {},
        },
      }
    },
    
    -- ===============================================================
    -- COOLDOWN BARS (Charge-based ability tracking)
    -- Structure mirrors buff bars for Appearance panel compatibility
    -- ===============================================================
    cooldownBars = {
      [1] = {
        tracking = {
          enabled = false,
          cooldownID = 0,
          spellID = 0,
          spellName = "",
          buffName = "",  -- Alias for spellName (display compatibility)
          iconTextureID = 0,
          maxStacks = 3,  -- Max charges
          trackType = "charge",
        },
        display = {
          enabled = true,
          displayType = "bar",  -- "bar" or "icon"
          
          -- Size
          width = 200,
          height = 20,
          barScale = 1.0,
          opacity = 1.0,
          
          
          -- Icon Mode Settings
          iconSize = 48,
          iconShowTexture = true,
          iconShowStacks = true,
          iconStackAnchor = "TOPRIGHT",
          iconStackPosition = nil,
          iconStackFont = "2002 Bold",
          iconStackFontSize = 16,
          iconStackColor = {r=1, g=1, b=1, a=1},
          iconStackOutline = "THICKOUTLINE",
          iconStackShadow = false,
          iconShowBorder = true,
          iconBorderColor = {r=0, g=0, b=0, a=1},
          
          -- Texture and fill
          texture = "Blizzard",
          rotateTexture = false,
          fillTextureScale = 1.0,
          barOrientation = "horizontal",  -- "horizontal" or "vertical"
          barReverseFill = false,         -- Reverse fill direction
          
          -- Colors
          useGradient = false,
          barColor = {r=0.2, g=0.8, b=1, a=1},
          thresholdMode = "simple",
          enableMaxColor = false,
          maxColor = {r=0, g=1, b=0, a=1},
          
          -- Background
          showBackground = true,
          backgroundColor = {r=0.2, g=0.2, b=0.2, a=0.8},
          
          -- Border
          showBorder = true,
          borderStyle = "Drawn",
          drawnBorderThickness = 2,
          borderColor = {r=0, g=0, b=0, a=1},
          
          -- Tick marks
          showTickMarks = true,
          tickMode = "all",
          tickThickness = 1,
          tickHeightPercent = 100,
          tickHeightAnchor = "center",
          tickThicknessAnchor = "center",
          tickColor = {r=0, g=0, b=0, a=1},
          
          -- Stack/Charge Text
          showText = true,
          font = "2002 Bold",
          fontSize = 18,
          textColor = {r=1, g=1, b=1, a=1},
          textOutline = "THICKOUTLINE",
          textShadow = false,
          textAnchor = "CENTER",
          textAnchorOffsetX = 0,
          textAnchorOffsetY = 0,
          
          -- Bar Icon
          showBarIcon = true,
          barIconSize = 20,
          barIconAnchor = "LEFT",
          barIconAnchorOffsetX = 0,
          barIconAnchorOffsetY = 0,
          barIconShowBorder = true,
          barIconBorderColor = {r=0, g=0, b=0, a=1},
          
          -- Position
          barMovable = true,
          textMovable = true,
          textLocked = true,
          barPosition = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = -200
          },
          textPosition = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = -170
          },
          iconPosition = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = -200
          },
          -- Frame strata settings
          barFrameStrata = "MEDIUM",
          barFrameLevel = 10,
        },
        behavior = {
          hideOutOfCombat = false,
          hideWhenFull = false,
          hideWhenZero = false,
          showOnSpec = 0,
          showOnSpecs = {},
          talentConditions = nil,
          talentMatchMode = nil,
        },
        thresholds = {
          [1] = { enabled = true, minValue = 0, maxValue = 3, color = {r=0.2, g=0.8, b=1, a=1} },
          [2] = { enabled = false, minValue = 2, maxValue = 3, color = {r=1, g=1, b=0, a=1} },
          [3] = { enabled = false, minValue = 3, maxValue = 3, color = {r=0, g=1, b=0, a=1} }
        },
        stackColors = {},
        colorRanges = {
          [1] = { from = 1, to = 1, color = {r=0.2, g=0.8, b=1, a=1} },
          [2] = { enabled = false, from = 2, to = 2, color = {r=1, g=1, b=0, a=1} },
          [3] = { enabled = false, from = 3, to = 3, color = {r=0, g=1, b=0, a=1} }
        }
      }
    },
    
    -- ===============================================================
    -- CASTBAR
    -- Multi-instance player castbars (resource-bar style). ["*"] gives every index full
    -- defaults; instance 1 is the default bar. castType filters which casts an instance shows.
    -- ===============================================================
    castbars = {
      ["*"] = {
      enabled = false,
      castType = "all",   -- "all" | "hardcast" | "channel" | "empower"
      width = 250,
      height = 20,
      barColor = {r=0.2, g=0.8, b=1, a=1},  -- base/fallback; per-type colors live in profiles
      -- Conditional (threshold) coloring: bar color changes as the cast nears completion,
      -- based on how much is REMAINING (percent by default, or seconds when AsSec).
      conditionalColorEnabled = false,
      conditionalColorAsSec = false,
      colorThresholds = {},  -- array of { enabled, percent (= remaining value), color }
      texture = "Blizzard",
      opacity = 1.0,
      showBackground = true,
      backgroundColor = {r=0.1, g=0.1, b=0.1, a=0.9},
      showBorder = true,
      borderColor = {r=0, g=0, b=0, a=1},
      drawnBorderThickness = 2,
      showIcon = true,
      iconSize = 20,
      showText = true,
      showTimer = true,
      timerFormat = "remaining",  -- "remaining" | "elapsed" | "both" (elapsed/total)
      font = "2002 Bold",
      fontSize = 14,
      textColor = {r=1, g=1, b=1, a=1},
      textOutline = "THICKOUTLINE",
      barMovable = true,
      barPosition = {point="CENTER", relPoint="CENTER", x=0, y=0},
      barFrameStrata = "MEDIUM",
      barFrameLevel = 10,
      hideOutOfCombat = false,
      hideChannels = false,
      empowerSegmentColorsEnabled = false,
      empowerStageDividers = true,   -- dividers at each empowered stage boundary
      empowerDividerPerColor = false, -- color each stage divider with its stage's segment color
      empowerMaxStages = 4,
      empowerSegmentColors = {
        [1] = {r=0.6, g=0.2, b=1.0, a=1},
        [2] = {r=0.9, g=0.1, b=0.6, a=1},
        [3] = {r=1.0, g=0.3, b=0.1, a=1},
        [4] = {r=1.0, g=0.7, b=0.1, a=1},
        [5] = {r=0.1, g=0.9, b=0.3, a=1},
        [6] = {r=0.1, g=0.7, b=1.0, a=1},
        [7] = {r=1.0, g=1.0, b=0.2, a=1},
        [8] = {r=0.8, g=0.8, b=0.8, a=1},
      },
      -- Uninterruptible cast styling
      uninterruptibleEnabled = false,
      uninterruptibleColor = {r=0.5, g=0.5, b=0.5, a=1},
      uninterruptibleBorderColor = {r=0.3, g=0.3, b=0.5, a=1},
      -- Channel tick marks (aura-bar style: Per % interval or Custom positions)
      tickMarksEnabled = false,
      tickShowOn = "channels",         -- "channels" | "all" (empowered always uses stage segments)
      tickMode = "percent",            -- "percent" | "custom"
      tickPercent = 10,                -- Per % mode: a divider every N%
      tickCustom = "",                 -- Custom mode: comma-separated %s, e.g. "20, 40, 55"
      tickMarksColor = {r=1, g=1, b=1, a=0.6},
      tickMarksThickness = 2,
      tickMarksHeightFraction = 1.0,
      tickHeightAnchor = "center",     -- center | top | bottom
      tickThicknessAnchor = "center",  -- center | start | end
      -- Per-spell appearance overrides: array of {spellID, barColorEnabled, barColor, textureOverrideEnabled, texture, tickCount}
      spellOverrides = {},
      -- Anchor to CDM group
      anchorToGroup = false,
      anchorGroupName = "",
      anchorPoint = "BOTTOM",
      anchorOffsetX = 0,
      anchorOffsetY = -2,
      matchGroupWidth = false,
      matchSlotsOnly = true,
      matchWidthAdjust = 0,
      -- Reverse fill direction: channels fill instead of drain; casts drain instead of fill
      reverseFill = false,
      -- Latency "safe zone" overlay at the finishing edge (auto = world latency, or manual ms)
      latencyEnabled = false,
      latencyManual = false,
      latencyManualMs = 100,
      latencyColor = {r=1, g=0, b=0, a=0.4},
      -- Interrupt / cancel feedback: flash the bar red with a label, then fade out
      interruptFeedbackEnabled = false,
      interruptColor = {r=1, g=0.15, b=0.15, a=1},
      interruptFadeDuration = 1.0,
      -- Hide the default Blizzard castbar (PlayerCastingBarFrame)
      hideCastBar = false,
      -- Spell name shortening (display only; off by default)
      spellShortenEnabled = false,
      spellShortenLength = 20,
      -- Movable spell icon (off = default left-of-bar position)
      iconMovable = false,
      iconPosition = nil,
      -- Cast-type appearance profiles + Auto Share. Checked category = shared across all
      -- cast types; unchecked = customised per type. All categories default OFF (per-type),
      -- so each cast type has its own colors/border/text/etc. out of the box.
      autoShareCategories = {},
      profiles = {
        hardcast = { barColor = {r=0.2, g=0.8, b=1,   a=1} },
        channel  = { barColor = {r=0.2, g=1,   b=0.4, a=1} },
        empower  = { barColor = {r=0.6, g=0.2, b=1,   a=1} },
      },
      presets = {},
      },  -- end ["*"] per-instance template
    },

    -- LEGACY: CDM Enhancement settings were moved to profile storage
    -- This stub exists only for migration purposes (CDMEnhance.lua migrates to profile)
    -- DO NOT add new fields here - use profile.cdmEnhance instead
    cdmEnhance = nil,
    
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- COOLDOWN BAR SETUP (ArcUI_CooldownBars.lua active bar tracking)
    -- Stores which spells have bars created (spellID lists/maps)
    -- ═══════════════════════════════════════════════════════════════════════════
    cooldownBarSetup = {
      activeCooldowns = {},  -- {spellID, spellID, ...} - Duration bars
      activeCharges = {},    -- {spellID, spellID, ...} - Charge bars  
      activeResources = {},  -- {[spellID] = true, ...} - Resource bars
      manualSpells = {},     -- {spellID, ...} - Manually added spells
      hiddenSpells = {},     -- {[spellID] = true, ...} - Hidden from catalog
    },
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- ADVANCED DEBUFFS (standalone draggable icon frame)
    -- Shows harmful auras on the player with dispel-type border coloring.
    -- ═══════════════════════════════════════════════════════════════════════════
    advancedDebuffs = {
      enabled = false,
      iconSize = 40,
      iconSpacing = 4,
      iconsPerRow = 8,
      maxRows = 2,
      showSwipe = true,
      reverseSwipe = true,
      showTooltips = true,
      growHorizontal = "RIGHT",
      growVertical = "DOWN",
      borderColorMode = "dispel",
      borderColor = { r=0.8, g=0.8, b=0.8, a=1 },
      borderWidth = 2,
      borderGlow = false,
      glowWidth = 2,
      strata = "MEDIUM",
      position = { point="CENTER", relativePoint="CENTER", x=0, y=-200, relativeFrame="UIParent" },
      filters = {
        PLAYER = false,
        RAID = false,
        CROWD_CONTROL = false,
        RAID_IN_COMBAT = false,
        RAID_PLAYER_DISPELLABLE = false,
        IMPORTANT = false,
      },
      blacklistEnabled = true,
      blacklist = {
        -- Bloodlust / Heroism family — pre-populated to match NorskenUI defaults
        [57723]  = true,   -- Exhaustion (Bloodlust)
        [57724]  = true,   -- Sated (Heroism)
        [80354]  = true,   -- Temporal Displacement (Time Warp – Mage)
        [160455] = true,   -- Fatigued (Drums of Fury / Battle)
        [390435] = true,   -- Exhaustion (variant / Warlords-era token)
        [95809]  = true,   -- Exhaustion (variant)
        [264689] = true,   -- Fatigued (variant)
        [308312] = true,   -- Time Trial (Mythic+ BL mechanic)
      },
      watchlist = {},
    },

    advancedExternals = {
      enabled = false,
      iconSize = 40,
      iconSpacing = 4,
      iconsPerRow = 8,
      maxRows = 1,
      showSwipe = true,
      reverseSwipe = true,
      showTooltips = true,
      growHorizontal = "RIGHT",
      growVertical = "DOWN",
      borderColor = { r=0.2, g=0.8, b=0.2, a=1 },
      borderWidth = 2,
      borderGlow = false,
      glowWidth = 2,
      strata = "MEDIUM",
      position = { point="CENTER", relativePoint="CENTER", x=0, y=-260, relativeFrame="UIParent" },
      showBigDefensives = false,
      blacklistEnabled = true,
      blacklist = {},
    },

    focusCastbar = {
      enabled             = false,
      width               = 220,
      height              = 18,
      barPosition         = { point="CENTER", relPoint="CENTER", x=0, y=-120 },
      barAnchorPoint      = "CENTER",
      anchorToFrame       = false,
      anchorFrameName     = "",
      anchorPoint         = "CENTER",
      anchorRelativePoint = "CENTER",
      anchorOffsetX       = 0,
      anchorOffsetY       = 0,
      barFrameStrata      = "MEDIUM",
      barColor            = { r=1, g=0.65, b=0, a=1 },
      showBackground      = true,
      backgroundColor     = { r=0.1, g=0.1, b=0.1, a=0.9 },
      showBorder          = true,
      borderColor         = { r=0, g=0, b=0, a=1 },
      drawnBorderThickness = 2,
      showGlow            = false,
      glowType            = "pixel",
      glowColor           = { r=1, g=0.65, b=0, a=1 },
      glowWidth           = 2,
      glowLines           = 8,
      glowFrequency       = 0.25,
      showSpellName       = true,
      spellNameMaxWidth   = 0,
      showTimer           = true,
      showCasterName      = true,
      casterNameColor     = { r=1, g=0.82, b=0, a=1 },
      casterNameOffsetX   = 0,
      casterNameOffsetY   = 0,
      casterNameAnchor    = "RIGHT",
      showFocusTarget     = false,
      focusTargetColor    = { r=0.6, g=0.8, b=1, a=1 },
      focusTargetOffsetX  = 0,
      focusTargetOffsetY  = 0,
      focusTargetAnchor   = "RIGHT",
      showRaidMarker      = true,
      raidMarkerSize      = 32,
      raidMarkerAnchor    = "LEFT",
      raidMarkerOffsetX   = -36,
      raidMarkerOffsetY   = 0,
      font                = "Friz Quadrata TT",
      fontSize            = 11,
      textOutline         = "THICKOUTLINE",
      textColor           = { r=1, g=1, b=1, a=1 },
      texture             = "Blizzard",
      uninterruptibleEnabled = false,
      uninterruptibleColor   = { r=0.5, g=0.5, b=0.5, a=1 },
      raidMarkerDefault    = 8,      -- index shown in preview (moon=8); 0 = off
      hideNotInterruptible = false,
      importantGlowEnabled   = false,
      importantGlowType      = "pixel",
      importantGlowColor     = { r=1, g=0.2, b=0.2, a=1 },
      importantGlowLines     = 8,
      importantGlowFrequency = 0.25,
      importantGlowThickness = 2,
      kickEnabled       = false,
      kickNotReadyColor = { r=0.55, g=0.55, b=0.55, a=1 },
      kickTickColor     = { r=1, g=1, b=1, a=1 },
      holdEnabled          = false,
      holdDuration         = 0.8,
      holdSuccessColor     = { r=0.2, g=1.0, b=0.2, a=1 },
      holdFailColor        = { r=1.0, g=0.5, b=0.0, a=1 },
      holdInterruptedColor = { r=0.2, g=0.4, b=1.0, a=1 },
    },

    configVersion = 1
  }
}

-- Store presets for easy access
ns.ThresholdPresets = DEFAULT_THRESHOLDS

-- ===================================================================
-- ACCOUNT-WIDE SHARED CASTBAR (opt-in, default OFF)
-- When ns.db.global.castbarShared is true, the castbar accessors (ns.API.GetCastbarStore)
-- return global.castbars instead of the per-character char.castbars, so ONE castbar config
-- applies to every character. global.castbars is its OWN deep copy of the per-instance
-- template, so it never aliases the per-character store and the two stay independent.
-- ===================================================================
ns.DB_DEFAULTS.global.castbarShared        = false
ns.DB_DEFAULTS.global.castbarShareLocation = false  -- when sharing, keep the bar POSITION per-character unless opted in
ns.DB_DEFAULTS.global.castbarSharedInit    = false
ns.DB_DEFAULTS.global.castbars             = { ["*"] = CopyTable(ns.DB_DEFAULTS.char.castbars["*"]) }

-- ===================================================================
-- HELPER: Get Bar Config (Buff/Debuff bars)
-- ===================================================================
function ns.API.GetBarConfig(barNumber)
  local db = ns.db and ns.db.char  -- Inline GetDB() to avoid function call overhead
  if not db or not db.bars then return nil end
  
  barNumber = barNumber or db.selectedBar or 1
  
  if not db.bars[barNumber] then
    db.bars[barNumber] = CopyTable(ns.DB_DEFAULTS.char.bars[1])
    local yOffset = 200 - ((barNumber - 1) * 30)
    db.bars[barNumber].display.barPosition.y = yOffset
    db.bars[barNumber].display.textPosition.y = yOffset + 30
  end
  
  local barConfig = db.bars[barNumber]
  
  -- FAST PATH: Already migrated = most common case during combat (400+ calls/sec)
  local CURRENT_MIGRATION_VERSION = 3
  local migrated = barConfig._migrated
  if migrated == CURRENT_MIGRATION_VERSION or (type(migrated) == "number" and migrated >= CURRENT_MIGRATION_VERSION) then
    return barConfig
  end
  
  -- Migration versioning: _migrated was originally a boolean (true).
  -- Now uses a version number to allow incremental migrations.
  -- Old _migrated = true is treated as version 1.
  local currentVersion = 0
  if migrated == true then
    currentVersion = 1  -- Old boolean flag = version 1
  elseif type(migrated) == "number" then
    currentVersion = migrated
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- VERSION 1 MIGRATIONS (original)
  -- All use == nil checks so they're idempotent / safe to re-run
  -- ═══════════════════════════════════════════════════════════════════
  
  -- Migration: ensure events table exists
  if not barConfig.events then
    barConfig.events = {}
  end
  
  -- Migration: ensure new display options exist
  local display = barConfig.display
  if display.iconShowCooldownSwipe == nil then display.iconShowCooldownSwipe = true end
  if display.iconCooldownReverse == nil then display.iconCooldownReverse = false end
  if display.iconCooldownDrawEdge == nil then display.iconCooldownDrawEdge = true end
  if display.iconCooldownDrawBling == nil then display.iconCooldownDrawBling = true end
  if display.iconDesaturateOnCooldown == nil then display.iconDesaturateOnCooldown = true end
  if display.iconDesaturateWhenInactive == nil then display.iconDesaturateWhenInactive = false end
  if display.iconZoom == nil then display.iconZoom = 0 end
  if display.durationShowWhenReady == nil then display.durationShowWhenReady = false end
  -- v2.8.0: Migration for ColorCurve duration bar settings (legacy keys)
  if display.durationColorCurveEnabled == nil then display.durationColorCurveEnabled = false end
  if display.durationColorCurveMode == nil then display.durationColorCurveMode = "step" end
  if display.durationColorCurveThreshold == nil then display.durationColorCurveThreshold = 0.30 end
  if display.durationColorCurveLowColor == nil then display.durationColorCurveLowColor = {r=1, g=0, b=0, a=1} end
  if display.durationColorCurveHighColor == nil then display.durationColorCurveHighColor = {r=0, g=1, b=0, a=1} end
  if display.durationColorCurveMidColor == nil then display.durationColorCurveMidColor = {r=1, g=1, b=0, a=1} end
  if display.durationBarFillMode == nil then display.durationBarFillMode = "drain" end
  -- Migration: fillDirection -> barOrientation
  if display.fillDirection and not display.barOrientation then
    -- Convert old 4-way direction to new orientation system
    if display.fillDirection == "BOTTOM_TO_TOP" or display.fillDirection == "TOP_TO_BOTTOM" then
      display.barOrientation = "vertical"
    else
      display.barOrientation = "horizontal"
    end
    display.fillDirection = nil  -- Remove old setting
  end
  if display.barOrientation == nil then display.barOrientation = "horizontal" end
  if display.barReverseFill == nil then display.barReverseFill = false end
  if display.rotateTexture == nil then display.rotateTexture = false end
  if display.showBackground == nil then display.showBackground = true end
  -- Migration: ensure text anchor defaults exist (prevents free-drag mode for old bars)
  if display.textAnchor == nil then display.textAnchor = "OUTERTOP" end
  if display.durationAnchor == nil then display.durationAnchor = "CENTER" end
  if display.nameAnchor == nil then display.nameAnchor = "CENTER" end
  if display.barIconAnchor == nil then display.barIconAnchor = "LEFT" end
  -- Migration: ensure frame strata defaults exist
  if display.barFrameStrata == nil then display.barFrameStrata = "MEDIUM" end
  if display.barFrameLevel == nil then display.barFrameLevel = 10 end
  
  -- Migration: ensure behavior table exists
  if not barConfig.behavior then
    barConfig.behavior = {
      hideBuffIcon = false,
      hideWhenZeroStacks = false,
      hideWhenInactive = false,
      hideOutOfCombat = false,
      showOnSpec = 0,
      showOnSpecs = {}
    }
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- VERSION 2 MIGRATIONS (conditional color thresholds + spec fix)
  -- Fixes old bars created before multi-threshold system existed
  -- ═══════════════════════════════════════════════════════════════════
  
  -- Migration: ensure new multi-threshold keys exist
  -- Old system used: durationColorCurveLowColor/HighColor/MidColor + single threshold
  -- New system uses: durationThreshold2-5 Enabled/Value/Color
  if display.durationThreshold2Enabled == nil then
    -- Check if old-style settings had actual customization we should convert
    local hadOldSettings = display.durationColorCurveEnabled and display.durationColorCurveThreshold
    
    if hadOldSettings then
      -- Convert old single-threshold to new multi-threshold format
      -- Old: one threshold at durationColorCurveThreshold % with lowColor below it
      local oldPct = (display.durationColorCurveThreshold or 0.30) * 100  -- Convert 0-1 to 0-100
      local oldLowColor = display.durationColorCurveLowColor or {r=1, g=0, b=0, a=1}
      
      -- Enable threshold 2 with the old settings
      display.durationThreshold2Enabled = true
      display.durationThreshold2Value = oldPct
      display.durationThreshold2Color = {
        r = oldLowColor.r, g = oldLowColor.g, b = oldLowColor.b, a = oldLowColor.a or 1
      }
    else
      -- No old settings - just set defaults (disabled)
      display.durationThreshold2Enabled = false
      display.durationThreshold2Value = 75
      display.durationThreshold2Color = {r=0.8, g=0.8, b=0, a=1}
    end
  end
  
  -- Ensure thresholds 3-5 have defaults
  if display.durationThreshold3Enabled == nil then display.durationThreshold3Enabled = false end
  if display.durationThreshold3Value == nil then display.durationThreshold3Value = 50 end
  if display.durationThreshold3Color == nil then display.durationThreshold3Color = {r=1, g=0.5, b=0, a=1} end
  if display.durationThreshold4Enabled == nil then display.durationThreshold4Enabled = false end
  if display.durationThreshold4Value == nil then display.durationThreshold4Value = 25 end
  if display.durationThreshold4Color == nil then display.durationThreshold4Color = {r=1, g=0.3, b=0, a=1} end
  if display.durationThreshold5Enabled == nil then display.durationThreshold5Enabled = false end
  if display.durationThreshold5Value == nil then display.durationThreshold5Value = 10 end
  if display.durationThreshold5Color == nil then display.durationThreshold5Color = {r=1, g=0, b=0, a=1} end
  -- Ensure threshold mode settings exist
  if display.durationThresholdAsSeconds == nil then display.durationThresholdAsSeconds = false end
  if display.durationThresholdMaxDuration == nil then display.durationThresholdMaxDuration = 30 end
  
  -- Migration: convert old showOnSpec (single number) to showOnSpecs (table)
  -- Old system: showOnSpec = 2 means "only show on spec 2"
  -- New system: showOnSpecs = {2} means "only show on spec 2"
  if barConfig.behavior then
    -- Ensure showOnSpecs table exists
    if not barConfig.behavior.showOnSpecs then
      barConfig.behavior.showOnSpecs = {}
    end
    -- Convert old single-spec to new multi-spec format
    local oldSpec = barConfig.behavior.showOnSpec
    if oldSpec and oldSpec > 0 and #barConfig.behavior.showOnSpecs == 0 then
      barConfig.behavior.showOnSpecs = { oldSpec }
    end
  end
  
  -- Migration: convert old showInForms (positive) or hideInForms (negative) → hideWhen keys
  -- Old positive: showInForms = {cat=true, bear=true} → "show ONLY in cat and bear"
  -- Old negative: hideInForms = {cat=true} → "hide in cat"
  -- New unified: hideWhen = {hideInCatForm=true, ...}
  local FORM_KEY_TO_HIDEWHEN = {
    caster  = "hideInCasterForm",
    cat     = "hideInCatForm",
    bear    = "hideInBearForm",
    moonkin = "hideInMoonkinForm",
    travel  = "hideInTravelForm",
    tree    = "hideInTreeForm",
    none            = "hideInNoStance",
    battleStance    = "hideInBattleStance",
    defensiveStance = "hideInDefensiveStance",
    shadowform      = "hideInShadowform",
    stealth         = "hideInStealth",
  }
  if barConfig.behavior then
    -- First: convert old positive showInForms → negative hideInForms
    if barConfig.behavior.showInForms and type(barConfig.behavior.showInForms) == "table" then
      local showForms = barConfig.behavior.showInForms
      local anySelected = false
      for _, v in pairs(showForms) do
        if v then anySelected = true; break end
      end
      if anySelected then
        -- Druid form set (the only class that had the old positive system)
        local allDruidForms = { "caster", "cat", "bear", "moonkin", "travel", "tree" }
        if not barConfig.behavior.hideInForms then barConfig.behavior.hideInForms = {} end
        for _, form in ipairs(allDruidForms) do
          if not showForms[form] then
            barConfig.behavior.hideInForms[form] = true
          end
        end
        barConfig.behavior.hideInFormsAlpha = barConfig.behavior.hideInFormsAlpha or 0
      end
      barConfig.behavior.showInForms = nil
    end
    -- Second: convert hideInForms → hideWhen keys
    if barConfig.behavior.hideInForms and type(barConfig.behavior.hideInForms) == "table" then
      if not barConfig.behavior.hideWhen or type(barConfig.behavior.hideWhen) ~= "table" then
        barConfig.behavior.hideWhen = {}
      end
      for formKey, enabled in pairs(barConfig.behavior.hideInForms) do
        if enabled then
          local hwKey = FORM_KEY_TO_HIDEWHEN[formKey]
          if hwKey then
            barConfig.behavior.hideWhen[hwKey] = true
          end
        end
      end
      -- Migrate alpha
      if barConfig.behavior.hideInFormsAlpha and barConfig.behavior.hideInFormsAlpha > 0 then
        barConfig.behavior.hideWhenAlpha = barConfig.behavior.hideInFormsAlpha
      end
      barConfig.behavior.hideInForms = nil
      barConfig.behavior.hideInFormsAlpha = nil
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- VERSION 3 MIGRATIONS (border thickness pixel-perfect fix)
  -- The border rendering changed from GetNearestPixelSize (which rounded
  -- 1 WoW unit to 2 physical pixels at sub-1 UI scales) to an exact
  -- physical pixel formula (1 WoW unit = exactly 1 physical pixel).
  -- Double any existing drawnBorderThickness so bars look identical after
  -- the update. New bars created after migration are unaffected.
  -- ═══════════════════════════════════════════════════════════════════
  if currentVersion < 3 then
    -- Rendering changed from GetNearestPixelSize (which could round 1 WoW unit to 2px
    -- at sub-1 UI scales due to btRaw minimum) to exact physical pixel formula (1 = 1px).
    -- Compute how many physical pixels the OLD code actually rendered and store that count
    -- as the new value — so everyone gets identical visuals regardless of UI scale.
    local _, _h = GetPhysicalScreenSize()
    local _s = UIParent:GetScale()
    local _ppu = (_h and _h > 0 and _s and _s > 0) and (_h / 768) * _s or 1
    local d = barConfig.display
    if d and d.showBorder then
      local bt = d.drawnBorderThickness
      if type(bt) == "number" and bt > 0 then
        d.drawnBorderThickness = math.max(bt, math.floor(bt * _ppu + 0.5))
      end
    end
    if d then
      local tt = d.tickThickness
      if type(tt) == "number" and tt > 0 then
        d.tickThickness = math.max(tt, math.floor(tt * _ppu + 0.5))
      end
    end
  end

  -- Mark as migrated with version number
  barConfig._migrated = CURRENT_MIGRATION_VERSION
  
  return barConfig
end

-- ===================================================================
-- HELPER: Get Resource Bar Config
-- ===================================================================
function ns.API.GetResourceBarConfig(barNumber)
  local db = ns.API.GetDB()
  if not db then return nil end
  
  if not db.resourceBars then
    db.resourceBars = {}
  end
  
  barNumber = barNumber or db.selectedResourceBar or 1
  
  if not db.resourceBars[barNumber] then
    db.resourceBars[barNumber] = CopyTable(ns.DB_DEFAULTS.char.resourceBars[1])
    local yOffset = -100 - ((barNumber - 1) * 35)
    db.resourceBars[barNumber].display.barPosition.y = yOffset
    db.resourceBars[barNumber].display.textPosition.y = yOffset + 30
  end
  
  -- Migration: ensure new fields exist
  local tracking = db.resourceBars[barNumber].tracking
  if not tracking.resourceCategory then
    tracking.resourceCategory = "primary"
  end
  
  return db.resourceBars[barNumber]
end

-- ===================================================================
-- HELPER: Get Cooldown Bar Config
-- ===================================================================
function ns.API.GetCooldownBarConfig(barNumber)
  local db = ns.API.GetDB()
  if not db then return nil end
  
  if not db.cooldownBars then
    db.cooldownBars = {}
  end
  
  barNumber = barNumber or db.selectedCooldownBar or 1
  
  if not db.cooldownBars[barNumber] then
    db.cooldownBars[barNumber] = CopyTable(ns.DB_DEFAULTS.char.cooldownBars[1])
    local yOffset = -200 - ((barNumber - 1) * 30)
    db.cooldownBars[barNumber].display.barPosition.y = yOffset
    db.cooldownBars[barNumber].display.textPosition.y = yOffset + 30
    db.cooldownBars[barNumber].display.iconPosition.y = yOffset
  end
  
  return db.cooldownBars[barNumber]
end

-- ===================================================================
-- HELPER: Get Selected Bar Number
-- ===================================================================
function ns.API.GetSelectedBar()
  local db = ns.API.GetDB()
  return db and db.selectedBar or 1
end

-- ===================================================================
-- HELPER: Set Selected Bar
-- ===================================================================
function ns.API.SetSelectedBar(barNumber)
  local db = ns.API.GetDB()
  if db then
    db.selectedBar = barNumber
  end
end

-- ===================================================================
-- HELPER: Get Selected Resource Bar Number
-- ===================================================================
function ns.API.GetSelectedResourceBar()
  local db = ns.API.GetDB()
  return db and db.selectedResourceBar or 1
end

-- ===================================================================
-- HELPER: Set Selected Resource Bar
-- ===================================================================
function ns.API.SetSelectedResourceBar(barNumber)
  local db = ns.API.GetDB()
  if db then
    db.selectedResourceBar = barNumber
  end
end

-- ===================================================================
-- HELPER: Get Selected Cooldown Bar Number
-- ===================================================================
function ns.API.GetSelectedCooldownBar()
  local db = ns.API.GetDB()
  return db and db.selectedCooldownBar or 1
end

-- ===================================================================
-- HELPER: Set Selected Cooldown Bar
-- ===================================================================
function ns.API.SetSelectedCooldownBar(barNumber)
  local db = ns.API.GetDB()
  if db then
    db.selectedCooldownBar = barNumber
  end
end

-- ===================================================================
-- HELPER: Get All Active Bars (Buff/Debuff)
-- ===================================================================
-- ===================================================================
-- ACTIVE BAR CACHE
-- Avoids scanning 500 slots on every call. Invalidated whenever a bar
-- is enabled/disabled or created/deleted via InvalidateActiveBarCache().
-- ===================================================================
local activeBarCache         = nil  -- [barNum, ...] or nil (dirty)
local activeResourceBarCache = nil
local activeCooldownBarCache = nil
local activeTextureCache     = nil  -- [textureNum, ...] or nil (dirty)

function ns.API.InvalidateActiveBarCache()
  activeBarCache         = nil
  activeResourceBarCache = nil
  activeCooldownBarCache = nil
end

function ns.API.InvalidateActiveTextureCache()
  activeTextureCache = nil
end

function ns.API.GetActiveBars()
  if activeBarCache then return activeBarCache end
  local db = ns.API.GetDB()
  if not db or not db.bars then activeBarCache = {}; return activeBarCache end
  local activeBars = {}
  for i = 1, 500 do
    if db.bars[i] and db.bars[i].tracking.enabled then
      table.insert(activeBars, i)
    end
  end
  activeBarCache = activeBars
  return activeBarCache
end

-- ===================================================================
-- HELPER: Get All Active Resource Bars
-- ===================================================================
function ns.API.GetActiveResourceBars()
  if activeResourceBarCache then return activeResourceBarCache end
  local db = ns.API.GetDB()
  if not db or not db.resourceBars then activeResourceBarCache = {}; return activeResourceBarCache end
  local activeBars = {}
  for i = 1, 500 do
    if db.resourceBars[i] and db.resourceBars[i].tracking.enabled then
      table.insert(activeBars, i)
    end
  end
  activeResourceBarCache = activeBars
  return activeResourceBarCache
end

-- ===================================================================
-- HELPER: Get All Active Cooldown Bars
-- ===================================================================
function ns.API.GetActiveCooldownBars()
  if activeCooldownBarCache then return activeCooldownBarCache end
  local db = ns.API.GetDB()
  if not db or not db.cooldownBars then activeCooldownBarCache = {}; return activeCooldownBarCache end
  local activeBars = {}
  for i = 1, 500 do
    if db.cooldownBars[i] and db.cooldownBars[i].tracking and db.cooldownBars[i].tracking.enabled then
      table.insert(activeBars, i)
    end
  end
  activeCooldownBarCache = activeBars
  return activeCooldownBarCache
end

-- ===================================================================
-- HELPER: Aura Textures (config / active list / create / bind)
-- Mirrors the buff/debuff bar helpers. The tracking block is shaped the
-- same as a bar's so the texture engine can reuse the CDM aura resolution.
-- ===================================================================
function ns.API.GetTextureConfig(textureNumber)
  local db = ns.db and ns.db.char
  if not db then return nil end
  db.textures = db.textures or {}

  textureNumber = textureNumber or db.selectedTexture or 1

  if not db.textures[textureNumber] then
    db.textures[textureNumber] = CopyTable(ns.DB_DEFAULTS.char.textures[1])
    -- Stagger default position so newly created textures don't stack exactly.
    local off = (textureNumber - 1) * 20
    db.textures[textureNumber].display.position.x = off
    db.textures[textureNumber].display.position.y = -off
  end

  return db.textures[textureNumber]
end

function ns.API.GetActiveTextures()
  if activeTextureCache then return activeTextureCache end
  local db = ns.API.GetDB()
  if not db or not db.textures then activeTextureCache = {}; return activeTextureCache end
  local active = {}
  for i = 1, 500 do
    if db.textures[i] and db.textures[i].tracking and db.textures[i].tracking.enabled then
      table.insert(active, i)
    end
  end
  activeTextureCache = active
  return activeTextureCache
end

-- Enable the first free texture slot (makes it appear in the UI list).
function ns.API.InitializeNewTexture()
  local db = ns.API.GetDB()
  if not db then return nil end
  db.textures = db.textures or {}

  for i = 1, 500 do
    local cfg = db.textures[i]
    if not cfg or not cfg.tracking or not cfg.tracking.enabled then
      cfg = ns.API.GetTextureConfig(i)
      cfg.tracking.enabled = true
      cfg.tracking.buffName = "(Not configured yet)"
      cfg.tracking.spellID = 0
      cfg.tracking.cooldownID = 0
      ns.API.InvalidateActiveTextureCache()

      if ns.Textures and ns.Textures.ShowTexture then
        ns.Textures.ShowTexture(i)
      end

      return i
    end
  end

  return nil
end

-- Bind a catalog buff (from ns.API.ScanAvailableBuffs) to a texture slot.
function ns.API.SelectBuffForTexture(buffInfo, textureNumber)
  local db = ns.API.GetDB()
  if not db or not buffInfo then return false end

  textureNumber = textureNumber or db.selectedTexture or 1
  local cfg = ns.API.GetTextureConfig(textureNumber)
  if not cfg then return false end

  cfg.tracking.spellID = buffInfo.spellID
  cfg.tracking.buffName = buffInfo.buffName
  cfg.tracking.iconTextureID = buffInfo.iconTextureID
  cfg.tracking.cooldownID = buffInfo.cooldownID
  cfg.tracking.slotNumber = buffInfo.slotNumber
  cfg.tracking.enabled = true
  ns.API.InvalidateActiveTextureCache()

  if ns.Textures and ns.Textures.UpdateTexture then
    ns.Textures.UpdateTexture(textureNumber)
  end

  return true
end

-- ===================================================================
-- HELPER: Apply Threshold Preset
-- ===================================================================
function ns.API.ApplyThresholdPreset(barNumber, presetName, maxValue)
  local cfg = ns.API.GetResourceBarConfig(barNumber)
  if not cfg then return false end
  
  local preset = ns.ThresholdPresets[presetName]
  if not preset then return false end
  
  cfg.thresholds = {}
  for i, threshold in ipairs(preset) do
    local scaled = CopyTable(threshold)
    scaled.minValue = math.floor((threshold.minValue / 100) * maxValue)
    scaled.maxValue = math.floor((threshold.maxValue / 100) * maxValue)
    cfg.thresholds[i] = scaled
  end
  
  return true
end

-- Initialize a new empty bar slot (makes it appear in UI)
function ns.API.InitializeNewBar()
  local db = ns.API.GetDB()
  if not db or not db.bars then return nil end
  
  for i = 1, 500 do
    if db.bars[i] and not db.bars[i].tracking.enabled then
      db.bars[i].tracking.enabled = true
      db.bars[i].tracking.buffName = "(Not configured yet)"
      db.bars[i].tracking.spellID = 0
      db.bars[i].tracking.maxStacks = 10
      ns.API.InvalidateActiveBarCache()
      
      if ns.Display and ns.Display.ShowBar then
        ns.Display.ShowBar(i)
      end
      
      return i
    end
  end
  
  return nil
end

-- ===================================================================
-- HELPER: Initialize New Resource Bar
-- ===================================================================
function ns.API.InitializeNewResourceBar(powerType, powerName, resourceCategory, secondaryType)
  local db = ns.API.GetDB()
  if not db then return nil end
  
  if not db.resourceBars then
    db.resourceBars = {}
  end
  
  resourceCategory = resourceCategory or "primary"
  
  for i = 1, 500 do
    local cfg = db.resourceBars[i]
    
    local isEmpty = not cfg or 
                    not cfg.tracking or 
                    not cfg.tracking.enabled or 
                    (not cfg.tracking.powerType and (not cfg.tracking.powerName or cfg.tracking.powerName == ""))
    
    if isEmpty then
      cfg = ns.API.GetResourceBarConfig(i)
      
      cfg.tracking.enabled = true
      cfg.tracking.resourceCategory = resourceCategory
      cfg.tracking.powerType = powerType
      cfg.tracking.secondaryType = secondaryType
      cfg.tracking.powerName = powerName
      ns.API.InvalidateActiveBarCache()
      
      -- ═══════════════════════════════════════════════════════════
      -- CRITICAL: Reset display mode when reusing a slot.
      -- A previously deleted bar (e.g. Runes in "fragmented" mode)
      -- would contaminate the new bar if we don't reset this.
      -- ═══════════════════════════════════════════════════════════
      cfg.display.thresholdMode = "simple"
      cfg.display.showTickMarks = false
      cfg.display.enableActiveCountColors = nil
      cfg.display.activeCountColors = nil
      cfg.display.fragmentedColors = nil
      cfg.display.fragmentedChargingColor = nil
      cfg.display.fragmentedSpecColors = nil
      cfg.display.smartChargingColor = nil
      cfg.display.colorCurveEnabled = false
      cfg.display.chargedComboColor = nil
      cfg.display.showInForms = nil
      cfg.display.iconsLayout = nil
      cfg.display.iconShape = nil
      cfg.display.iconsBorderStyle = nil
      cfg.stackColors = nil
      cfg.colorRanges = nil
      
      -- Get max value based on resource type
      if resourceCategory == "secondary" and secondaryType then
        cfg.tracking.maxValue = ns.Resources and ns.Resources.GetSecondaryMaxValue(secondaryType) or 5
      elseif resourceCategory == "autoPrimary" then
        -- Auto-switching: resolve current power type dynamically
        local autoPower = UnitPowerType("player")
        local max = UnitPowerMax("player", autoPower)
        cfg.tracking.maxValue = (max and max > 0) and max or 100
      else
        local max = UnitPowerMax("player", powerType)
        -- Use queried value if valid, otherwise default to 100 (will be updated at runtime)
        cfg.tracking.maxValue = (max and max > 0) and max or 100
      end
      
      if cfg.behavior then
        cfg.behavior.talentConditions = nil
        cfg.behavior.talentMatchMode = nil
        if resourceCategory == "autoPrimary" then
          -- Auto-switching bar: show on ALL specs (it resolves powerType dynamically)
          cfg.behavior.showOnSpecs = {}
        else
          -- Manual bar: lock to current spec
          cfg.behavior.showOnSpecs = { GetSpecialization() or 1 }
        end
      end
      
      cfg.display.enabled = true
      
      -- Enable tick marks for discrete secondary resources
      if resourceCategory == "secondary" then
        local discreteTypes = {
          comboPoints = true, holyPower = true, chi = true,
          runes = true, soulShards = true, essence = true, arcaneCharges = true,
          soulFragments = true, maelstromWeapon = true,
        }
        if discreteTypes[secondaryType] then
          cfg.display.showTickMarks = true
          cfg.display.tickMode = "all"
        end
        
        -- Auto-enable fragmented mode for runes and essence
        local fragmentedTypes = {
          runes = true, essence = true
        }
        if fragmentedTypes[secondaryType] then
          cfg.display.thresholdMode = "fragmented"
          cfg.display.showTickMarks = false  -- No ticks needed for fragmented
          
          -- Set up per-segment colors for fragmented resources
          if not cfg.display.fragmentedColors then cfg.display.fragmentedColors = {} end
          
          if secondaryType == "runes" then
            -- DK Rune colors: handled dynamically by GetFragmentedReadyColor via DK_SPEC_DEFAULT_COLORS
            -- Don't set fragmentedColors here — per-segment overrides would block the spec color system
            cfg.display.fragmentedChargingColor = {r=0.4, g=0.4, b=0.4, a=1}
          elseif secondaryType == "essence" then
            -- Evoker Essence colors - bright teal
            local essenceColor = {r=0, g=0.8, b=0.8, a=1}
            for j = 1, 5 do
              cfg.display.fragmentedColors[j] = {r=essenceColor.r, g=essenceColor.g, b=essenceColor.b, a=essenceColor.a}
            end
            cfg.display.fragmentedChargingColor = {r=0, g=0.4, b=0.4, a=1}
          end
          
          -- Skip the standard preset
          if ns.Resources and ns.Resources.ApplyAppearance then
            ns.Resources.ApplyAppearance(i)
          end
          
          return i
        end
      end
      
      -- Set bar color to match resource type color
      if secondaryType and ns.Resources and ns.Resources.SecondaryTypesLookup then
        local typeInfo = ns.Resources.SecondaryTypesLookup[secondaryType]
        if typeInfo and typeInfo.color then
          cfg.display.barColor = {r=typeInfo.color.r, g=typeInfo.color.g, b=typeInfo.color.b, a=1}
          -- Also update threshold[1] color for simple mode
          if cfg.thresholds and cfg.thresholds[1] then
            cfg.thresholds[1].color = {r=typeInfo.color.r, g=typeInfo.color.g, b=typeInfo.color.b, a=1}
          end
        end
      end
      
      -- Auto-enable hideBlizzardFrame for secondary resources
      if cfg.behavior then
        cfg.behavior.hideBlizzardFrame = true
      end
      
      ns.API.ApplyThresholdPreset(i, "threeTone", cfg.tracking.maxValue)
      
      if ns.Resources and ns.Resources.ApplyAppearance then
        ns.Resources.ApplyAppearance(i)
      end
      
      return i
    end
  end
  
  return nil
end

-- ===================================================================
-- HELPER: Initialize New Cooldown Bar
-- ===================================================================
function ns.API.InitializeNewCooldownBar(cooldownID, spellID, spellName, maxCharges, iconTexture)
  local db = ns.API.GetDB()
  if not db then return nil end
  
  if not db.bars then
    db.bars = {}
  end
  
  -- Find an empty bar slot (cooldown bars share slots with regular bars)
  for i = 1, 500 do
    local cfg = db.bars[i]
    
    local isEmpty = not cfg or 
                    not cfg.tracking or 
                    not cfg.tracking.enabled
    
    if isEmpty then
      cfg = ns.API.GetBarConfig(i)
      
      cfg.tracking.enabled = true
      cfg.tracking.cooldownID = cooldownID
      cfg.tracking.spellID = spellID
      cfg.tracking.spellName = spellName
      cfg.tracking.buffName = spellName  -- For display compatibility
      cfg.tracking.iconTextureID = iconTexture or (spellID and C_Spell.GetSpellTexture(spellID)) or 134400
      cfg.tracking.maxStacks = maxCharges or 3
      cfg.tracking.trackType = "cooldownCharge"  -- CRITICAL: Use correct trackType
      
      cfg.display.enabled = true
      cfg.behavior.showOnSpecs = { GetSpecialization() or 1 }
      
      if ns.Display and ns.Display.ApplyAppearance then
        ns.Display.ApplyAppearance(i)
      end
      
      return i
    end
  end
  
  return nil
end

-- ===================================================================
-- END OF ArcUI_DB.lua
-- ===================================================================