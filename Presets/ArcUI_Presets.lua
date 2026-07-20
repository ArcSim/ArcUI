-- =====================================================================
-- ArcUI_Presets.lua — Profile system with category filtering,
--   copy/paste, save/load library, auto-switch, active profile tracking
-- =====================================================================
local _, ns = ...
ns.Presets = ns.Presets or {}
local Presets = ns.Presets

-- =====================================================================
-- SKIN CATEGORIES
-- Each category groups related display keys so the user can choose
-- what a profile includes (colors only, size only, etc).
-- Keys not in any category are "misc" and always included.
-- =====================================================================
Presets.ALL_CATEGORIES = {
  "colors", "fill", "size", "text", "background", "border", "tickMarks", "position",
}

Presets.CATEGORY_LABELS = {
  colors     = "Colors",
  fill       = "Fill & Texture",
  size       = "Size",
  text       = "Text",
  textStacks   = "Stack Text",
  textDuration = "Duration Text",
  textName     = "Name Text",
  textReady    = "Ready Text",
  background = "Background",
  border     = "Border",
  tickMarks  = "Tick Marks",
  position   = "Position",
}

Presets.CATEGORY_DESCS = {
  colors     = "Bar/fill coloring: bar color, max color, folded/fragmented colors, color curves, bar thresholds, slot colors, prediction bar colors, desaturation",
  fill       = "Texture, orientation, smoothing, gradient, reverse fill, fill mode, icon-mode swipe rendering",
  size       = "Width, height, scale, spacing, padding, slot dimensions, icon-mode layout",
  text       = "Everything about text elements: fonts, sizes, formats, visibility, anchors, offsets AND text colors (stack, duration, name, ready, cooldown text)",
  textStacks   = "The stack/value number: font, size, format, anchor, offsets, colors, threshold coloring, segment and prediction text",
  textDuration = "The duration/countdown text: font, size, decimals, anchor, offsets, color, color curve and thresholds (includes cooldown-bar countdown and timer text)",
  textName     = "The bar name text: font, size, anchor, offsets, color",
  textReady    = "The ready text: wording, font placement, offsets, color",
  background = "Background texture, color, visibility",
  border     = "Border color, thickness, visibility, class color border",
  tickMarks  = "Tick marks, dividers, ability cost markers",
  position   = "Bar screen position (castbar skins only) -- lets per-spec castbar skins restore where the bar sits",
}

-- Default categories for new profiles (all enabled EXCEPT position: a skin must
-- never move a bar unless it was explicitly saved with position included --
-- castbar skins opt in at SaveSkin). Text sub-element flags default true so the
-- umbrella and the fine-grained toggles agree out of the box.
function Presets.DefaultCategories()
  local cats = {}
  for _, c in ipairs(Presets.ALL_CATEGORIES) do
    cats[c] = true
  end
  cats.textStacks   = true
  cats.textDuration = true
  cats.textName     = true
  cats.textReady    = true
  cats.position = false
  return cats
end

-- =====================================================================
-- CATEGORY → DISPLAY KEY MAPPING
-- Explicit keys + prefix patterns per category.
-- Keys not matching any category are "misc" (always included).
-- =====================================================================

-- Explicit key → category
local KEY_TO_CATEGORY = {
  -- Colors
  barColor = "colors",
  maxColor = "colors",
  enableMaxColor = "colors",
  useDifferentFullColor = "colors",
  foldedColor1 = "colors",
  foldedColor2 = "colors",
  fragmentedColors = "colors",
  fragmentedSpecColors = "colors",
  fragmentedChargingColor = "colors",
  activeCountColors = "colors",
  enableActiveCountColors = "colors",
  usePerSlotColors = "colors",
  slotColors = "colors",
  chargedComboColor = "colors",
  smartChargingColor = "colors",
  thresholdMode = "colors",
  displayMode = "colors",           -- continuous/perStack/fragmented/icons
  opacity = "colors",
  -- Color curve keys handled by prefix below
  -- Prediction BAR colors (the text colors live under "text")
  predCostColor = "colors",
  predGainColor = "colors",
  fullChargeColor = "colors",
  -- Icon-mode desaturation (coloring behavior)
  iconDesaturateOnCooldown = "colors",
  iconDesaturateWhenInactive = "colors",
  -- TEXT COLORS live under "text": everything about a text element — font,
  -- size, position AND color — applies together when the user checks Text.
  -- (They used to sit under "colors", so Apply with Text checked moved the
  -- duration text but not its color — reported and wrong.)
  textColor = "text",
  textColorByState = "text",
  textUsableColor = "text",
  textUnusableColor = "text",
  durationColor = "text",
  nameColor = "text",
  readyColor = "text",
  cdTextColor = "text",
  iconStackColor = "text",
  iconDurationColor = "text",
  predTextCostColor = "text",
  predTextGainColor = "text",
  -- Slot colors
  slotBackgroundColor = "colors",
  slotBorderColor = "colors",

  -- Fill & Texture
  texture = "fill",
  displayType = "fill",             -- bar vs icon render mode: without a category this was
                                    -- "misc/always included" — a Colors-only push would silently
                                    -- flip a bar between bar and icon mode
  barOrientation = "fill",
  rotateTexture = "fill",
  barReverseFill = "fill",
  enableSmoothing = "fill",
  useGradient = "fill",
  fragmentedFillOrientation = "fill",
  fragmentedLayoutDirection = "fill",
  durationBarFillMode = "fill",
  -- Icon-mode rendering behavior
  iconShowTexture = "fill",
  iconShowCooldownSwipe = "fill",
  iconCooldownDrawBling = "fill",
  iconCooldownDrawEdge = "fill",
  iconCooldownReverse = "fill",
  -- gradient* keys handled by prefix below

  -- Size
  width = "size",
  height = "size",
  barScale = "size",
  iconSize = "size",
  frameWidth = "size",
  frameHeight = "size",
  barIconSize = "size",
  barPadding = "size",
  barPosition = "position",
  barPaddingL = "size",
  barPaddingR = "size",
  barPaddingT = "size",
  barPaddingB = "size",
  fragmentedSpacing = "size",
  segmentedSpacing = "size",
  slotSpacing = "size",
  slotWidth = "size",
  slotHeight = "size",
  slotOffsetX = "size",
  slotOffsetY = "size",
  drawnBorderThickness = "size",
  -- Bar icon + icon-mode geometry
  showBarIcon = "size",
  barIconAnchor = "size",
  iconBarSpacing = "size",
  iconOffsetX = "size",
  iconOffsetY = "size",
  iconZoom = "size",
  iconsMode = "size",
  iconsShape = "size",
  iconsSize = "size",
  iconsSpacing = "size",

  -- Text (fonts, formats, visibility, anchors — NOT strata/level)
  font = "text",
  fontSize = "text",
  textOutline = "text",
  textShadow = "text",
  textFormat = "text",
  showText = "text",
  showMaxText = "text",
  showZeroWhenReady = "text",
  textShowPercentSymbol = "text",
  textAnchor = "text",
  textAnchorOffsetX = "text",
  textAnchorOffsetY = "text",
  showDuration = "text",
  durationShowWhenReady = "text",
  durationFont = "text",
  durationFontSize = "text",
  durationOutline = "text",
  durationShadow = "text",
  durationDecimals = "text",
  durationThreshold = "text",
  durationThresholdAsSeconds = "text",
  durationThresholdMaxDuration = "text",
  durationAnchor = "text",
  durationAnchorOffsetX = "text",
  durationAnchorOffsetY = "text",
  durationTextFrameWidth = "text",
  showName = "text",
  nameFont = "text",
  nameFontSize = "text",
  nameAnchor = "text",
  nameOffsetX = "text",
  nameOffsetY = "text",
  showReadyText = "text",
  readyText = "text",
  readyTextAnchor = "text",
  readyTextOffsetX = "text",
  readyTextOffsetY = "text",
  cdTextFont = "text",
  cdTextSize = "text",
  cdTextOutline = "text",
  cdTextDecimalPrecision = "text",
  cdTextOffsetX = "text",
  cdTextOffsetY = "text",
  cdTextShow = "text",
  fragmentedShowSegmentText = "text",
  fragmentedTextSize = "text",
  fragmentedTextOffsetX = "text",
  fragmentedTextOffsetY = "text",
  dynamicTextOnSlot = "text",
  chargeTextAnchor = "text",
  chargeTextOffsetX = "text",
  chargeTextOffsetY = "text",
  predTextFormat = "text",
  showPrediction = "text",
  timerTextAnchor = "text",
  timerTextOffsetX = "text",
  timerTextOffsetY = "text",
  dynamicTextOffsetX = "text",
  dynamicTextOffsetY = "text",
  -- Icon-mode text elements (stack + duration text on icon-mode bars)
  iconShowStacks = "text",
  iconStackFont = "text",
  iconStackFontSize = "text",
  iconStackOutline = "text",
  iconStackShadow = "text",
  iconStackAnchor = "text",
  iconShowDuration = "text",
  iconDurationFont = "text",
  iconDurationFontSize = "text",
  iconDurationOutline = "text",
  iconDurationShadow = "text",
  iconsShowCooldownText = "text",
  iconsCooldownTextSize = "text",
  iconsCDTextOffsetX = "text",
  iconsCDTextOffsetY = "text",

  -- Background
  showBackground = "background",
  showBarBackground = "background",
  backgroundTexture = "background",
  backgroundColor = "background",
  barBackgroundColor = "background",
  showSlotBackground = "background",
  slotBackgroundTexture = "background",

  -- Border
  showBorder = "border",
  showBarBorder = "border",
  borderColor = "border",
  showSlotBorder = "border",
  slotBorderThickness = "border",
  useClassColorBorder = "border",
  barIconShowBorder = "border",
  iconShowBorder = "border",
  iconBorderColor = "border",
  iconsBorderStyle = "border",

  -- Tick Marks
  showTickMarks = "tickMarks",
  tickColor = "tickMarks",
  tickMode = "tickMarks",
  tickPercent = "tickMarks",
  tickThickness = "tickMarks",
  tickHeightPercent = "tickMarks",
  tickHeightAnchor = "tickMarks",
  tickThicknessAnchor = "tickMarks",
  customTicksAsPercent = "tickMarks",
  thresholdAsPercent = "tickMarks",
}

-- Prefix patterns: keys starting with these prefixes get auto-categorized.
-- Checked in order; explicit KEY_TO_CATEGORY entries win over prefixes, and
-- EXCLUDED_DISPLAY_KEYS wins over everything.
local KEY_CATEGORY_PREFIXES = {
  { prefix = "colorCurve", category = "colors" },
  { prefix = "durationColor", category = "text" },         -- duration TEXT color + curve family
  { prefix = "durationText", category = "text" },          -- duration TEXT threshold colors
  { prefix = "textColorThreshold", category = "text" },    -- stack-text threshold coloring
  { prefix = "durationThreshold", category = "colors" },   -- duration BAR threshold colors
  { prefix = "chargeSlot", category = "colors" },          -- per-slot charge colors
  { prefix = "iconMulti", category = "size" },             -- icon-mode multi-icon layout
  { prefix = "gradient",   category = "fill" },
  { prefix = "tick",       category = "tickMarks" },
  { prefix = "divider",    category = "tickMarks" },
}

-- Top-level (cfg.*) keys and their category
local TOP_LEVEL_KEY_CATEGORIES = {
  thresholds        = "colors",
  colorRanges       = "colors",
  abilityThresholds = "tickMarks",
}

-- All top-level visual keys (union of TOP_LEVEL_KEY_CATEGORIES keys)
local TOP_LEVEL_VISUAL_KEYS = {}
for key in pairs(TOP_LEVEL_KEY_CATEGORIES) do
  TOP_LEVEL_VISUAL_KEYS[#TOP_LEVEL_VISUAL_KEYS + 1] = key
end

-- =====================================================================
-- TEXT SUB-ELEMENTS (second-level fidelity inside the "text" category)
-- Every text key still belongs to category "text" (saved skins, Auto Share
-- and old filters keep working), but each maps to a SUB-element so the
-- Include toggles can apply e.g. only the duration text. Filter semantics:
-- filter[sub] wins when set; nil falls back to filter.text (old skins have
-- only .text -> all sub-elements apply, exactly as before).
-- Keys not listed default to "textStacks" (the main stack/value text).
-- =====================================================================
local TEXT_SUBCATEGORY = {
  -- Duration text (incl. cooldown-bar countdown + timer text + icon-mode duration)
  showDuration = "textDuration",
  durationShowWhenReady = "textDuration",
  durationFont = "textDuration",
  durationFontSize = "textDuration",
  durationOutline = "textDuration",
  durationShadow = "textDuration",
  durationDecimals = "textDuration",
  durationThreshold = "textDuration",
  durationThresholdAsSeconds = "textDuration",
  durationThresholdMaxDuration = "textDuration",
  durationAnchor = "textDuration",
  durationAnchorOffsetX = "textDuration",
  durationAnchorOffsetY = "textDuration",
  durationTextFrameWidth = "textDuration",
  durationColor = "textDuration",
  cdTextFont = "textDuration",
  cdTextSize = "textDuration",
  cdTextOutline = "textDuration",
  cdTextDecimalPrecision = "textDuration",
  cdTextOffsetX = "textDuration",
  cdTextOffsetY = "textDuration",
  cdTextShow = "textDuration",
  cdTextColor = "textDuration",
  timerTextAnchor = "textDuration",
  timerTextOffsetX = "textDuration",
  timerTextOffsetY = "textDuration",
  iconShowDuration = "textDuration",
  iconDurationFont = "textDuration",
  iconDurationFontSize = "textDuration",
  iconDurationOutline = "textDuration",
  iconDurationShadow = "textDuration",
  iconDurationColor = "textDuration",
  iconsShowCooldownText = "textDuration",
  iconsCooldownTextSize = "textDuration",
  iconsCDTextOffsetX = "textDuration",
  iconsCDTextOffsetY = "textDuration",
  -- Name text
  showName = "textName",
  nameFont = "textName",
  nameFontSize = "textName",
  nameAnchor = "textName",
  nameOffsetX = "textName",
  nameOffsetY = "textName",
  nameColor = "textName",
  -- Ready text
  showReadyText = "textReady",
  readyText = "textReady",
  readyTextAnchor = "textReady",
  readyTextOffsetX = "textReady",
  readyTextOffsetY = "textReady",
  readyColor = "textReady",
}

Presets.TEXT_SUBCATEGORIES = { "textStacks", "textDuration", "textName", "textReady" }

-- Sub-element for a text-category key (prefix families included)
local function GetTextSubcategory(key)
  local sub = TEXT_SUBCATEGORY[key]
  if sub then return sub end
  if key:sub(1, 13) == "durationColor" or key:sub(1, 12) == "durationText" then
    return "textDuration"
  end
  return "textStacks"
end
Presets.GetTextSubcategory = GetTextSubcategory

-- Resolve a display key to its category (or nil for misc/always-included)
local function GetKeyCategory(key)
  -- Check explicit mapping first
  if KEY_TO_CATEGORY[key] then return KEY_TO_CATEGORY[key] end
  -- Check prefix patterns
  for _, entry in ipairs(KEY_CATEGORY_PREFIXES) do
    if key:sub(1, #entry.prefix) == entry.prefix then
      return entry.category
    end
  end
  return nil  -- misc: always included
end
Presets.GetKeyCategory = GetKeyCategory

-- Build reverse mapping: category → list of known explicit keys
-- Used by Auto Share seeding to find ALL keys for a category
-- (including ones that pairs() on AceDB-backed tables might miss)
local categoryKeysCache = {}
for key, cat in pairs(KEY_TO_CATEGORY) do
  if not categoryKeysCache[cat] then categoryKeysCache[cat] = {} end
  categoryKeysCache[cat][#categoryKeysCache[cat] + 1] = key
end

-- Returns a list of all known display keys for a category, plus any
-- prefix-matched keys found in the provided display table.
-- categoryName: "colors", "fill", "text", "background", "border", "tickMarks"
-- displayTable: optional cfg.display to also scan for prefix-matched keys
function Presets.GetCategoryKeys(categoryName, displayTable)
  local result = {}
  local seen = {}
  -- Add all explicit keys from the mapping
  if categoryKeysCache[categoryName] then
    for _, key in ipairs(categoryKeysCache[categoryName]) do
      result[#result + 1] = key
      seen[key] = true
    end
  end
  -- Scan display table for prefix-matched keys (colorCurve*, gradient*, etc.)
  if displayTable then
    for key in pairs(displayTable) do
      if not seen[key] then
        for _, entry in ipairs(KEY_CATEGORY_PREFIXES) do
          if entry.category == categoryName and key:sub(1, #entry.prefix) == entry.prefix then
            result[#result + 1] = key
            seen[key] = true
            break
          end
        end
      end
    end
  end
  return result
end

-- =====================================================================
-- EXCLUDED DISPLAY KEYS (never part of any skin)
-- Position, strata, layout state — always excluded from snapshots
-- =====================================================================
local EXCLUDED_DISPLAY_KEYS = {
  -- Position / anchor
  barPosition = true,
  barMovable = true,
  textMovable = true,
  anchorPoint = true,
  anchorGroupName = true,
  anchorToGroup = true,
  anchorOffsetX = true,
  anchorOffsetY = true,
  matchGroupWidth = true,
  matchWidthAdjust = true,
  matchIconEdges = true,
  matchSlotsOnly = true,
  -- Per-bar identity: a custom icon override belongs to THAT bar's tracked
  -- spell — pushing it would stamp the source's icon onto every target
  iconOverride = true,
  -- Frame layering
  barFrameLevel = true,
  barFrameStrata = true,
  -- State toggles
  enabled = true,
  -- Per-icon positional data
  iconsPositions = true,
  -- Text position locks
  textPosition = true,
  textLocked = true,
  textDragMode = true,
  readyTextLocked = true,
  iconStackLocked = true,
  -- Text strata/level
  textLevel = true,
  textStrata = true,
  nameTextLevel = true,
  nameTextStrata = true,
  stackTextLevel = true,
  stackTextStrata = true,
  durationTextLevel = true,
  durationTextStrata = true,
  readyTextLevel = true,
  readyTextStrata = true,
  iconStackLevel = true,
  iconStackStrata = true,
  -- Auto power profiles state (internal)
  autoPowerColors = true,
  -- Flat-config behavior/meta keys (castbar uses a flat schema, not .display)
  presets         = true,
  hideOutOfCombat = true,
  hideChannels    = true,
}
Presets.EXCLUDED_DISPLAY_KEYS = EXCLUDED_DISPLAY_KEYS

-- =====================================================================
-- DEEP COPY UTILITY
-- =====================================================================
local function DeepCopy(src)
  if type(src) ~= "table" then return src end
  local copy = {}
  for k, v in pairs(src) do
    copy[k] = DeepCopy(v)
  end
  return copy
end
Presets.DeepCopy = DeepCopy

-- =====================================================================
-- SNAPSHOT: Extract skin data from a bar config
-- Always captures EVERYTHING — categories filter at apply time.
-- Returns { display = { ... }, topLevel = { ... }, categories = { ... } }
-- =====================================================================
function Presets.SnapshotSkin(barConfig, categories)
  if not barConfig then return nil end
  -- Flat configs (e.g. castbar) have no .display sub-table; use the config itself as the source.
  local displaySrc = barConfig.display or barConfig
  if not displaySrc then return nil end
  local skin = {
    display = {},
    topLevel = {},
    categories = categories or Presets.DefaultCategories(),
  }
  -- Capture visual fields (minus excluded keys). Keys starting with "_" are
  -- runtime/UI scratch (e.g. the castbar's _saveSkinNameInput input buffer) —
  -- never part of a look, never captured.
  for k, v in pairs(displaySrc) do
    if not EXCLUDED_DISPLAY_KEYS[k] and not (type(k) == "string" and k:sub(1, 1) == "_") then
      skin.display[k] = DeepCopy(v)
    end
  end
  -- Flat (castbar) configs: capture barPosition explicitly. It's in
  -- EXCLUDED_DISPLAY_KEYS (bar skins must never carry position), but castbar
  -- skins opt in via the "position" category -- the gate is at APPLY time, so
  -- capturing here is harmless for skins saved without the category.
  if not barConfig.display and displaySrc.barPosition ~= nil then
    skin.display.barPosition = DeepCopy(displaySrc.barPosition)
  end
  -- Capture top-level visual keys (thresholds, colorRanges, etc.) — only for structured configs
  if barConfig.display then
    for _, key in ipairs(TOP_LEVEL_VISUAL_KEYS) do
      if barConfig[key] ~= nil then
        skin.topLevel[key] = DeepCopy(barConfig[key])
      end
    end
  end
  return skin
end

-- =====================================================================
-- SANITIZE: Prevent incompatible thresholdMode from bricking bars.
-- Resets invalid modes AND clears stale mode-specific keys that can
-- hide UI elements (e.g. fragmentedSpecColors hiding color picker).
-- =====================================================================
local STALE_FRAGMENTED_KEYS = {
  "fragmentedSpecColors", "fragmentedColors", "fragmentedChargingColor",
  "fragmentedSpacing", "fragmentedFillOrientation",
  "fragmentedShowSegmentText", "fragmentedTextSize",
  "fragmentedTextOffsetX", "fragmentedTextOffsetY",
  "iconsMode", "iconsPositions", "iconsShowCooldownText",
}

function Presets.SanitizeDisplayMode(barConfig)
  if not barConfig or not barConfig.display then return end
  local mode = barConfig.display.thresholdMode or "simple"
  local tracking = barConfig.tracking
  if not tracking then return end

  local resCat = tracking.resourceCategory
  local needsReset = false

  if resCat then
    if resCat == "secondary" then return end  -- All modes valid
    -- Primary/autoPrimary: only simple, colorCurve allowed
    if mode == "fragmented" or mode == "icons" or mode == "perStack" then
      needsReset = true
    end
  elseif tracking.trackType == "buff" or tracking.trackType == "debuff" then
    if mode == "fragmented" or mode == "icons" then
      needsReset = true
    end
  else
    -- Cooldown/timer: continuous only
    if mode ~= "simple" and mode ~= "colorCurve" then
      needsReset = true
    end
  end

  if needsReset then
    barConfig.display.thresholdMode = "simple"
  end

  -- Clear stale fragmented/icons keys on bars that can't use them.
  -- These keys (especially fragmentedSpecColors.enabled) can hide the color picker.
  if resCat and resCat ~= "secondary" then
    for _, key in ipairs(STALE_FRAGMENTED_KEYS) do
      barConfig.display[key] = nil
    end
  end
end

-- =====================================================================
-- APPLY: Write skin data onto a bar config
-- Only applies keys whose category is enabled in the filter.
-- categories = nil means apply everything (backward compat).
-- =====================================================================
function Presets.ApplySkin(barConfig, skinData, categoryFilter)
  if not barConfig or not skinData then return false end
  -- Flat configs (e.g. castbar) have no .display sub-table; write directly onto barConfig.
  local displayTarget = barConfig.display or barConfig

  -- Determine which categories to apply
  local filter = categoryFilter or skinData.categories or nil  -- nil = everything

  -- Apply display keys. "_"-prefixed keys are runtime/UI scratch — skins saved
  -- before the snapshot-side exclusion may still contain them; never write them.
  -- "text" keys check their SUB-element flag first (textStacks/textDuration/
  -- textName/textReady) and fall back to the umbrella .text flag — old skins
  -- carry only .text and behave exactly as before.
  local displayData = skinData.display or skinData  -- Backward compat: old snapshots were flat
  for k, v in pairs(displayData) do
    if not EXCLUDED_DISPLAY_KEYS[k] and not (type(k) == "string" and k:sub(1, 1) == "_") then
      local cat = GetKeyCategory(k)
      local allowed
      if not filter or not cat then
        allowed = true
      elseif cat == "text" then
        allowed = filter[GetTextSubcategory(k)]
        if allowed == nil then allowed = filter.text end
      else
        allowed = filter[cat]
      end
      if allowed then
        displayTarget[k] = DeepCopy(v)
      end
    end
  end

  -- Flat (castbar) configs: barPosition applies ONLY when the skin's category
  -- filter explicitly includes position. Never on a nil filter -- old export
  -- strings / clipboard pastes must not move bars. This is what lets per-spec
  -- castbar skins restore their saved screen position on auto-switch.
  if not barConfig.display and displayData.barPosition ~= nil
     and filter and filter.position then
    displayTarget.barPosition = DeepCopy(displayData.barPosition)
  end

  -- Apply top-level visual keys (thresholds, colorRanges — only structured configs use these)
  if skinData.topLevel and barConfig.display then
    for _, key in ipairs(TOP_LEVEL_VISUAL_KEYS) do
      if skinData.topLevel[key] ~= nil then
        local cat = TOP_LEVEL_KEY_CATEGORIES[key]
        if not filter or not cat or filter[cat] then
          barConfig[key] = DeepCopy(skinData.topLevel[key])
        end
      end
    end
  end

  -- Bust caches and sanitize — only for structured bar configs with a .display table
  if barConfig.display then
    barConfig.display.stackColors = nil
    barConfig.stackColors = nil
    Presets.SanitizeDisplayMode(barConfig)
  end

  return true
end

-- =====================================================================
-- BAR TYPE CLASSIFICATION
-- =====================================================================
local BAR_TYPE_GROUPS = {
  resource    = "resource",
  buff        = "buff",
  cooldown    = "cooldown",
  timer       = "timer",
  cd_cooldown = "cd_cooldown",
  cd_charge   = "cd_charge",
  cd_resource = "cd_resource",
  castbar     = "castbar",
}

function Presets.GetBarTypeGroup(barType)
  if not barType then return "unknown" end
  -- Strip instance suffix (cd_cooldown_2 -> cd_cooldown) for grouping
  local base = barType:match("^(cd_%a+)_%d+$") or barType
  return BAR_TYPE_GROUPS[base] or base
end

function Presets.AreBarTypesCompatible(typeA, typeB)
  if not typeA or not typeB then return false end
  return Presets.GetBarTypeGroup(typeA) == Presets.GetBarTypeGroup(typeB)
end

-- =====================================================================
-- CLIPBOARD (in-memory only, not saved to DB)
-- =====================================================================
Presets.clipboard = nil

function Presets.CopySkin(barConfig, barType, barName)
  local skin = Presets.SnapshotSkin(barConfig)
  if not skin then return false end
  Presets.clipboard = {
    data = skin,
    barType = barType or "unknown",
    barName = barName or "Unknown Bar",
  }
  return true
end

function Presets.PasteSkin(barConfig, targetBarType, categoryFilter)
  if not Presets.clipboard then return false, "Nothing copied" end
  if not Presets.AreBarTypesCompatible(Presets.clipboard.barType, targetBarType) then
    return false, ("Incompatible bar types: %s → %s"):format(
      Presets.clipboard.barType, targetBarType or "unknown")
  end
  return Presets.ApplySkin(barConfig, Presets.clipboard.data, categoryFilter), nil
end

function Presets.HasClipboard()
  return Presets.clipboard ~= nil
end

function Presets.GetClipboardInfo()
  if not Presets.clipboard then return nil end
  return Presets.clipboard.barType, Presets.clipboard.barName
end

-- =====================================================================
-- PROFILE LIBRARY (saved to DB global)
-- Renamed from "Skin Library" to "Profile Library" for UX consistency.
-- The underlying key is still ns.db.global.skinLibrary for compat.
-- =====================================================================
local function GetProfileLibrary()
  if not ns.db or not ns.db.global then return nil end
  if not ns.db.global.skinLibrary then
    ns.db.global.skinLibrary = {}
  end
  return ns.db.global.skinLibrary
end
Presets.GetProfileLibrary = GetProfileLibrary
Presets.GetSkinLibrary = GetProfileLibrary  -- Backward compat alias

function Presets.SaveSkin(name, barConfig, barType, categories)
  local lib = GetProfileLibrary()
  if not lib then return false end
  -- Castbar skins carry position by default: per-spec castbar skins exist to
  -- restore the whole per-spec look INCLUDING where the bar sits (per-spec Y
  -- offsets were silently kept from the previous spec without this). Regular
  -- bar skins never carry position (a skin must not teleport a bar).
  if categories == nil and barType == "castbar" then
    categories = Presets.DefaultCategories()
    categories.position = true
  end
  local skin = Presets.SnapshotSkin(barConfig, categories)
  if not skin then return false end
  lib[name] = {
    data = skin,
    barType = barType or "unknown",
    savedAt = time(),
    categories = categories or Presets.DefaultCategories(),
  }
  return true
end
Presets.SaveProfile = Presets.SaveSkin  -- Backward compat alias

-- =====================================================================
-- PUSH LOOK: apply one bar's current style onto other bars of the
-- same type (all of them or a chosen subset), category-filtered.
-- =====================================================================

-- Enumerate bar configs a look can be pushed onto.
-- allTypes=false: only bars of sourceBarType's group. allTypes=true: every bar
-- type (cross-type push — shared appearance keys apply; type-specific keys are
-- ignored by types that don't use them, and SanitizeDisplayMode guards modes).
-- Only CONFIGURED bars are listed: pre-seeded empty DB slots ("Aura Bar N"
-- with no tracking target) are not real bars and only bloated the picker.
-- Returns a sorted array of { key, label, cfg }.
function Presets.EnumeratePushTargets(sourceBarType, allTypes)
  local out = {}
  local db = ns.API and ns.API.GetDB and ns.API.GetDB()
  if not db then return out end
  local group = allTypes and "" or Presets.GetBarTypeGroup(sourceBarType)

  local function want(g) return allTypes or group == g end
  local function tag(t) return allTypes and ("[" .. t .. "] ") or "" end

  if want("buff") and db.bars then
    for num, cfg in pairs(db.bars) do
      if type(cfg) == "table" and cfg.display then
        local t = cfg.tracking
        local configured = t and (t.enabled
          or (t.buffName and t.buffName ~= "")
          or (t.spellID and t.spellID ~= 0)
          or (t.cooldownID and t.cooldownID ~= 0))
        if configured then
          local nm = t.buffName
          if not nm or nm == "" then nm = "Aura Bar " .. tostring(num) end
          out[#out + 1] = { key = "buff:" .. tostring(num), label = tag("Aura") .. nm, cfg = cfg }
        end
      end
    end
  end

  if want("resource") and db.resourceBars then
    for num, cfg in pairs(db.resourceBars) do
      if type(cfg) == "table" and cfg.display then
        local t = cfg.tracking
        if t and t.enabled then
          local nm = (t.secondaryType or t.resourceCategory) or "Resource"
          out[#out + 1] = { key = "res:" .. tostring(num), label = tag("Resource") .. tostring(nm) .. " (" .. tostring(num) .. ")", cfg = cfg }
        end
      end
    end
  end

  if db.cooldownBarConfigs and (allTypes or group:find("^cd_")) then
    for spellID, configs in pairs(db.cooldownBarConfigs) do
      if type(configs) == "table" then
        for cdKey, cfg in pairs(configs) do
          if type(cfg) == "table" and cfg.display then
            -- Keys may carry an instance suffix ("charge_2") — group by the base type
            local base = tostring(cdKey):match("^(%a+)") or tostring(cdKey)
            if allTypes or ("cd_" .. base) == group then
              local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
              out[#out + 1] = {
                key = "cd:" .. tostring(spellID) .. ":" .. tostring(cdKey),
                label = tag("Cooldown") .. (nm or ("Spell " .. tostring(spellID))),
                cfg = cfg,
              }
            end
          end
        end
      end
    end
  end

  if want("timer") and db.timerBarConfigs then
    for timerID, cfg in pairs(db.timerBarConfigs) do
      if type(cfg) == "table" and cfg.display then
        local nm = cfg.name or cfg.label or ("Timer " .. tostring(timerID))
        out[#out + 1] = { key = "timer:" .. tostring(timerID), label = tag("Timer") .. tostring(nm), cfg = cfg }
      end
    end
  end

  table.sort(out, function(a, b) return tostring(a.label) < tostring(b.label) end)
  return out
end

-- Re-style every live bar. Mirrors the options panel's own per-bar refresh
-- (RefreshBarImmediate): bump config version + ApplyAppearance + a full update
-- pass. The update pass is REQUIRED: duration/stack TEXT is styled in
-- UpdateBar/UpdateDurationBar, not ApplyAppearance — without it an applied
-- look changed stack text but left duration text stale until the next aura
-- event (reported).
function Presets.RefreshAllBarVisuals()
  local db = ns.API and ns.API.GetDB and ns.API.GetDB()

  -- Aura bars: invalidate Display's cached setup first (version gates skip
  -- SetTexture/SetOrientation/text styling otherwise), then apply + update.
  if db and db.bars and ns.Display and ns.Display.BumpConfigVersion then
    for num, cfg in pairs(db.bars) do
      if type(cfg) == "table" and cfg.display then
        ns.Display.BumpConfigVersion(num)
      end
    end
  end
  if ns.Display and ns.Display.ApplyAllBars then ns.Display.ApplyAllBars() end
  if db and db.bars and ns.API and ns.API.RefreshDisplay then
    for num, cfg in pairs(db.bars) do
      if type(cfg) == "table" and cfg.tracking and cfg.tracking.enabled then
        ns.API.RefreshDisplay(num)
      end
    end
  end

  if ns.Resources and ns.Resources.ApplyAllBars then ns.Resources.ApplyAllBars() end
  if ns.Resources and ns.Resources.UpdateAllBars then ns.Resources.UpdateAllBars() end

  if db and db.cooldownBarConfigs and ns.CooldownBars and ns.CooldownBars.ApplyAppearance then
    for spellID, configs in pairs(db.cooldownBarConfigs) do
      if type(configs) == "table" then
        for barType in pairs(configs) do
          ns.CooldownBars.ApplyAppearance(spellID, barType)
          if ns.CooldownBars.ForceUpdate then
            ns.CooldownBars.ForceUpdate(spellID, barType)
          end
        end
      end
    end
  end
  if db and db.timerBarConfigs and ns.TimerBars and ns.TimerBars.ApplyAppearance then
    for timerID in pairs(db.timerBarConfigs) do
      ns.TimerBars.ApplyAppearance(timerID)
      if ns.CooldownBars and ns.CooldownBars.ForceUpdate then
        ns.CooldownBars.ForceUpdate(timerID, "timer")
      end
    end
  end
end

-- Snapshot sourceCfg's CURRENT look (category-filtered) and apply it onto each
-- target config. Pushed bars detach from any active skin (their look is now
-- "Custom" — it no longer matches a saved skin). Returns the number pushed.
function Presets.PushLook(sourceCfg, categories, targets)
  if not sourceCfg or not targets then return 0 end
  local snap = Presets.SnapshotSkin(sourceCfg, categories)
  if not snap then return 0 end
  local pushed = 0
  for _, t in ipairs(targets) do
    if t.cfg and t.cfg ~= sourceCfg then
      Presets.ApplySkin(t.cfg, snap, categories)
      if t.cfg.presets then t.cfg.presets.activeProfile = nil end
      pushed = pushed + 1
    end
  end
  if pushed > 0 then
    Presets.RefreshAllBarVisuals()
  end
  return pushed
end

function Presets.LoadSkin(name, barConfig, targetBarType, categoryOverride)
  local lib = GetProfileLibrary()
  if not lib or not lib[name] then return false, "Skin not found: " .. (name or "nil") end
  local entry = lib[name]
  if not Presets.AreBarTypesCompatible(entry.barType, targetBarType) then
    return false, ("Incompatible: saved as %s, target is %s"):format(entry.barType, targetBarType)
  end
  -- Use override categories if provided, otherwise use what the profile was saved with
  local filter = categoryOverride or entry.categories
  return Presets.ApplySkin(barConfig, entry.data, filter), nil
end
Presets.LoadProfile = Presets.LoadSkin  -- Backward compat alias

function Presets.DeleteSkin(name)
  local lib = GetProfileLibrary()
  if not lib then return false end
  -- Clear activeSkin references on any bar that was using this profile
  if ns.db and ns.db.char then
    local function clearActive(cfgList)
      if not cfgList then return end
      for _, cfg in pairs(cfgList) do
        if type(cfg) == "table" and cfg.presets and cfg.presets.activeProfile == name then
          cfg.presets.activeProfile = nil
        end
      end
    end
    clearActive(ns.db.char.resourceBars)
    clearActive(ns.db.char.bars)
    if ns.db.char.cooldownBarConfigs then
      for _, configs in pairs(ns.db.char.cooldownBarConfigs) do
        clearActive(configs)
      end
    end
    clearActive(ns.db.char.timerBarConfigs)
    clearActive(ns.db.char.cooldownBars)  -- legacy cooldown bars
  end
  -- Castbars live on the shared-aware store (account-wide in shared mode),
  -- not ns.db.char — without this a deleted castbar skin left a ghost
  -- activeProfile reference and a blank Load Skin dropdown.
  local cbStore = ns.API and ns.API.GetCastbarStore and ns.API.GetCastbarStore()
  if cbStore and cbStore.castbars then
    for _, cb in pairs(cbStore.castbars) do
      if type(cb) == "table" and cb.presets and cb.presets.activeProfile == name then
        cb.presets.activeProfile = nil
      end
    end
  end
  lib[name] = nil
  return true
end
Presets.DeleteProfile = Presets.DeleteSkin  -- Backward compat alias

function Presets.GetSkinNames(barType)
  local lib = GetProfileLibrary()
  if not lib then return {} end
  local names = {}
  local targetGroup = barType and Presets.GetBarTypeGroup(barType) or nil
  for name, entry in pairs(lib) do
    if not targetGroup or Presets.GetBarTypeGroup(entry.barType) == targetGroup then
      names[name] = name
    end
  end
  return names
end
Presets.GetProfileNames = Presets.GetSkinNames  -- Backward compat alias

function Presets.GetSkinCount(barType)
  local lib = GetProfileLibrary()
  if not lib then return 0 end
  local count = 0
  local targetGroup = barType and Presets.GetBarTypeGroup(barType) or nil
  for name, entry in pairs(lib) do
    if not targetGroup or Presets.GetBarTypeGroup(entry.barType) == targetGroup then
      count = count + 1
    end
  end
  return count
end
Presets.GetProfileCount = Presets.GetSkinCount  -- Backward compat alias

function Presets.GetSkinInfo(name)
  local lib = GetProfileLibrary()
  if not lib or not lib[name] then return nil end
  local entry = lib[name]
  return {
    barType = entry.barType,
    savedAt = entry.savedAt,
    categories = entry.categories or Presets.DefaultCategories(),
  }
end

function Presets.SkinExists(name)
  local lib = GetProfileLibrary()
  return lib and lib[name] ~= nil
end
Presets.ProfileExists = Presets.SkinExists  -- Backward compat alias

-- =====================================================================
-- ACTIVE SKIN TRACKING
-- Each bar stores cfg.presets.activeProfile = "skin name" or nil.
-- Setting a skin loads it and marks the bar as "wearing" it.
-- Editing the bar detaches it (sets to nil) — shown as "Custom".
-- =====================================================================

-- Set active skin: load it onto the bar and track the name
function Presets.SetActiveSkin(barConfig, barType, profileName)
  if not barConfig then return false end
  if not barConfig.presets then barConfig.presets = {} end

  if profileName == nil or profileName == "" then
    -- Detach: bar is now custom
    barConfig.presets.activeProfile = nil
    return true
  end

  local ok, err = Presets.LoadSkin(profileName, barConfig, barType)
  if ok then
    barConfig.presets.activeProfile = profileName
    return true
  end
  return false, err
end

-- Get the active skin name for a bar (nil = custom/none)
function Presets.GetActiveSkin(barConfig)
  if not barConfig or not barConfig.presets then return nil end
  return barConfig.presets.activeProfile
end

-- Detach (mark as custom) — called when user edits any skin-tracked setting
function Presets.DetachSkin(barConfig)
  if barConfig and barConfig.presets then
    barConfig.presets.activeProfile = nil
  end
  Presets.SanitizeDisplayMode(barConfig)
end

-- Check if a bar is currently wearing a skin
function Presets.HasActiveSkin(barConfig)
  return barConfig and barConfig.presets and barConfig.presets.activeProfile ~= nil
end

-- Re-save the active skin with current bar settings (update in place)
function Presets.UpdateActiveSkin(barConfig, barType)
  local name = Presets.GetActiveSkin(barConfig)
  if not name then return false end
  local lib = GetProfileLibrary()
  if not lib or not lib[name] then return false end
  local cats = lib[name].categories
  return Presets.SaveSkin(name, barConfig, barType, cats)
end

-- Backward compat aliases
Presets.SetActiveProfile   = Presets.SetActiveSkin
Presets.GetActiveProfile   = Presets.GetActiveSkin
Presets.DetachProfile      = Presets.DetachSkin
Presets.HasActiveProfile   = Presets.HasActiveSkin
Presets.UpdateActiveProfile = Presets.UpdateActiveSkin
Presets.GetProfileInfo     = Presets.GetSkinInfo

-- =====================================================================
-- AUTO-SWITCH ENGINE
-- Spec-first, then talent conditions refine.
-- Rules stored per-bar in cfg.presets.autoSwitch
-- =====================================================================

function Presets.EvaluateAutoSwitch(barConfig)
  if not barConfig or not barConfig.presets then return nil end
  local as = barConfig.presets.autoSwitch
  if not as or not as.rules or #as.rules == 0 then return nil end

  local currentSpec = GetSpecialization and GetSpecialization() or nil
  if not currentSpec then return nil end

  local function SpecMatches(rule)
    if not rule.specIndices or #rule.specIndices == 0 then return true end
    for _, si in ipairs(rule.specIndices) do
      if si == currentSpec then return true end
    end
    return false
  end

  -- Phase 1: talent-specific match (highest priority)
  for _, rule in ipairs(as.rules) do
    if rule.skinName and SpecMatches(rule) then
      if rule.talentConditions and #rule.talentConditions > 0 then
        if ns.TalentPicker and ns.TalentPicker.CheckTalentConditions then
          if ns.TalentPicker.CheckTalentConditions(rule.talentConditions, rule.talentMatchMode or "all") then
            return rule.skinName
          end
        end
      end
    end
  end

  -- Phase 2: spec-only fallback
  for _, rule in ipairs(as.rules) do
    if rule.skinName and SpecMatches(rule) then
      if not rule.talentConditions or #rule.talentConditions == 0 then
        return rule.skinName
      end
    end
  end

  return nil
end

function Presets.RunAutoSwitch(barConfig, barType)
  local profileName = Presets.EvaluateAutoSwitch(barConfig)
  if not profileName then return false end
  -- Skip if already wearing this skin
  local current = Presets.GetActiveSkin(barConfig)
  if current == profileName then return false end
  local ok, err = Presets.SetActiveSkin(barConfig, barType, profileName)
  if ok then
    if ns.devMode then
      print("|cff00ccffArcUI|r: Auto-switch [" .. tostring(barType) .. "] -> '" .. profileName .. "'")
    end
    return true
  else
    if ns.devMode then
      print("|cffFF6600[ArcUI]|r Auto-switch failed for '" .. profileName .. "': " .. tostring(err))
    end
    return false
  end
end

function Presets.RunAutoSwitchAll()
  local changed = false
  local db = ns.db and ns.db.char
  if not db then return end

  -- Resource bars (pairs for sparse tables)
  if db.resourceBars then
    for i, cfg in pairs(db.resourceBars) do
      if type(cfg) == "table" and cfg.presets then
        if Presets.RunAutoSwitch(cfg, "resource") then changed = true end
      end
    end
  end

  -- Buff/Aura bars (pairs for sparse tables - ipairs skips gaps!)
  if db.bars then
    for i, cfg in pairs(db.bars) do
      if type(cfg) == "table" and cfg.presets then
        if Presets.RunAutoSwitch(cfg, "buff") then changed = true end
      end
    end
  end

  -- Cooldown bars
  if db.cooldownBarConfigs then
    for spellID, configs in pairs(db.cooldownBarConfigs) do
      for barType, cfg in pairs(configs) do
        if type(cfg) == "table" and cfg.presets then
          if Presets.RunAutoSwitch(cfg, "cd_" .. barType) then changed = true end
        end
      end
    end
  end

  -- Timer bars
  if db.timerBarConfigs then
    for timerID, cfg in pairs(db.timerBarConfigs) do
      if type(cfg) == "table" and cfg.presets then
        if Presets.RunAutoSwitch(cfg, "timer") then changed = true end
      end
    end
  end

  -- Castbars (all instances). In shared mode the live castbar is the account-wide store,
  -- so auto-switch must evaluate that table (not the per-character one the rest of this loop uses).
  local cbStore = (ns.API and ns.API.GetCastbarStore and ns.API.GetCastbarStore()) or db
  if cbStore and cbStore.castbars then
    for _, cb in pairs(cbStore.castbars) do
      if type(cb) == "table" and cb.presets then
        if Presets.RunAutoSwitch(cb, "castbar") then changed = true end
      end
    end
  end

  if changed then
    -- Refresh resource bars
    if ns.Resources and ns.Resources.ApplyAllBars then
      ns.Resources.ApplyAllBars()
    end
    -- Refresh buff/aura bars
    if ns.Display and ns.Display.ApplyAllBars then
      ns.Display.ApplyAllBars()
    end
    -- Refresh cooldown bars
    if ns.CooldownBars and ns.CooldownBars.RefreshAllBarVisibility then
      ns.CooldownBars.RefreshAllBarVisibility()
    end
    if db.cooldownBarConfigs and ns.CooldownBars and ns.CooldownBars.ApplyAppearance then
      for spellID, configs in pairs(db.cooldownBarConfigs) do
        for barType in pairs(configs) do
          ns.CooldownBars.ApplyAppearance(spellID, barType)
        end
      end
    end
    -- Refresh timer bars (auto-switched timer skins otherwise sat unstyled
    -- until the next unrelated update)
    if db.timerBarConfigs and ns.TimerBars and ns.TimerBars.ApplyAppearance then
      for timerID in pairs(db.timerBarConfigs) do
        ns.TimerBars.ApplyAppearance(timerID)
      end
    end
    -- Refresh castbar
    if ns.Castbar and ns.Castbar.ApplyAppearance then
      ns.Castbar.ApplyAppearance()
    end
    -- Notify options panel if open
    local r = LibStub and LibStub("AceConfigRegistry-3.0", true)
    if r then r:NotifyChange("ArcUI") end
  end
end

-- =====================================================================
-- EVENT REGISTRATION
-- Auto-switch only fires on actual spec/talent CHANGES, not initial login.
-- =====================================================================
local eventFrame = CreateFrame("Frame")
local loginSuppressed = true  -- suppress until initial burst is over
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_LOGIN" then
    self:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
    self:RegisterEvent("PLAYER_TALENT_UPDATE")
    self:RegisterEvent("TRAIT_CONFIG_UPDATED")
    self:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
    -- Allow auto-switch after the login event burst settles (~3s)
    C_Timer.After(3, function() loginSuppressed = false end)
  elseif event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED"
      or event == "PLAYER_TALENT_UPDATE"
      or event == "TRAIT_CONFIG_UPDATED"
      or event == "ACTIVE_COMBAT_CONFIG_CHANGED" then
    if loginSuppressed then return end
    if not Presets._autoSwitchPending then
      Presets._autoSwitchPending = true
      C_Timer.After(0.5, function()
        Presets._autoSwitchPending = false
        Presets.RunAutoSwitchAll()
      end)
    end
  end
end)