-- ===================================================================
-- ArcUI_Textures_Options.lua
-- Options panel for the Aura Textures feature (top-level "Textures" tab).
--
-- One selected-texture editor (mirrors the bar Appearance pattern): pick
-- a tracked buff/debuff to create a texture, then edit its source, size,
-- position, render transforms, and per-state (active / inactive) styling.
-- ===================================================================
local ADDON, ns = ...

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

ns.TexturesOptions = ns.TexturesOptions or {}

-- Transient (non-saved) UI state.
local availableBuffs = nil          -- cached result of ns.API.ScanAvailableBuffs()
local selectedTexCategory = 1       -- index into ns.TextureLibrary.categories

-- ===================================================================
-- SHARED LISTS
-- ===================================================================
local ANCHOR_POINTS = {
  TOPLEFT = "Top Left",       TOP = "Top",       TOPRIGHT = "Top Right",
  LEFT = "Left",              CENTER = "Center", RIGHT = "Right",
  BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
}
local ANCHOR_ORDER = {
  "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

local STRATA_VALUES = {
  BACKGROUND = "Background", LOW = "Low", MEDIUM = "Medium", HIGH = "High",
  DIALOG = "Dialog", FULLSCREEN = "Fullscreen", FULLSCREEN_DIALOG = "Fullscreen Dialog", TOOLTIP = "Tooltip",
}
local STRATA_ORDER = {
  "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP",
}

-- ===================================================================
-- HELPERS
-- ===================================================================
local function NotifyChange()
  LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
end

local function CurNum()
  local db = ns.API and ns.API.GetDB and ns.API.GetDB()
  return (db and db.selectedTexture) or 1
end

local function Cfg()
  return ns.API and ns.API.GetTextureConfig and ns.API.GetTextureConfig(CurNum())
end

-- Returns the array of enabled texture slot numbers.
local function ActiveTextures()
  return (ns.API and ns.API.GetActiveTextures and ns.API.GetActiveTextures()) or {}
end

local function HasAnyTexture()
  return #ActiveTextures() > 0
end

-- Apply a display field then re-render the selected texture.
local function SetDisplay(field, value)
  local cfg = Cfg()
  if not cfg then return end
  cfg.display[field] = value
  if ns.Textures and ns.Textures.ApplyAppearance then
    ns.Textures.ApplyAppearance(CurNum())
  end
end

local function GetDisplay(field, default)
  local cfg = Cfg()
  if not cfg then return default end
  local v = cfg.display[field]
  if v == nil then return default end
  return v
end

-- Color get/set (RGB only; alpha is a separate slider per state).
local function GetColor(field)
  local cfg = Cfg()
  local c = cfg and cfg.display[field]
  if type(c) ~= "table" then return 1, 1, 1 end
  return c.r or 1, c.g or 1, c.b or 1
end
local function SetColor(field, r, g, b)
  local cfg = Cfg()
  if not cfg then return end
  cfg.display[field] = { r = r, g = g, b = b, a = 1 }
  if ns.Textures and ns.Textures.ApplyAppearance then ns.Textures.ApplyAppearance(CurNum()) end
end

local function CurrentSpecIndex()
  return (GetSpecialization and GetSpecialization()) or 0
end

-- Lazily (re)scan the CD Manager aura list, out of combat only.
local function RefreshAvailableBuffs()
  if InCombatLockdown and InCombatLockdown() then return end
  local list = ns.API and ns.API.ScanAvailableBuffs and ns.API.ScanAvailableBuffs()
  if type(list) == "table" then availableBuffs = list end
end

-- ===================================================================
-- ADD-AURA DROPDOWN VALUES
-- ===================================================================
local function GetAddBuffValues()
  if not availableBuffs then RefreshAvailableBuffs() end
  local out = {}
  if availableBuffs then
    for i, b in ipairs(availableBuffs) do
      local icon = b.iconTextureID or 134400
      out[i] = string.format("|T%d:16:16|t %s", icon, b.buffName or ("Spell " .. tostring(b.spellID or 0)))
    end
  end
  return out
end

-- ===================================================================
-- TEXTURE LIBRARY PICKER VALUES
-- ===================================================================
local function GetCategoryValues()
  local out = {}
  local cats = ns.TextureLibrary and ns.TextureLibrary.categories or {}
  for i, cat in ipairs(cats) do
    out[i] = cat.name
  end
  return out
end

-- ===================================================================
-- VISUAL TEXTURE PICKER (standalone frame, WeakAuras-style)
-- A scrollable grid of REAL texture/atlas thumbnails with a category
-- dropdown and a search box. Standalone frame (not AceConfig), so it
-- renders atlases too and shows true previews. Applies live on click.
-- ===================================================================
local pickerFrame, pickerContent, pickerSearch, pickerCatDD
local pickerButtons = {}
local pickerCategory = 1
local pickerOnPick
local PICKER_CELL = 64
local PickerRebuildGrid     -- forward declaration

local function PickerCurrentID()
  local c = Cfg()
  return c and c.display and c.display.textureID
end

local function GetPickerButton(i)
  local b = pickerButtons[i]
  if b then return b end
  b = CreateFrame("Button", nil, pickerContent)
  b:SetSize(PICKER_CELL, PICKER_CELL)

  local tex = b:CreateTexture(nil, "ARTWORK")
  tex:SetPoint("CENTER")
  tex:SetSize(PICKER_CELL - 12, PICKER_CELL - 12)
  b.tex = tex

  local hl = b:CreateTexture(nil, "OVERLAY")
  hl:SetPoint("TOPLEFT", 1, -1)
  hl:SetPoint("BOTTOMRIGHT", -1, 1)
  hl:SetColorTexture(1, 0.82, 0, 0.35)
  hl:Hide()
  b.hl = hl

  local hover = b:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 1, 1, 0.15)

  b:SetScript("OnEnter", function(self)
    if GameTooltip and self.texname then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(self.texname)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  b:SetScript("OnClick", function(self)
    if pickerOnPick and self.texid ~= nil then pickerOnPick(self.texid) end
    PickerRebuildGrid()
  end)

  pickerButtons[i] = b
  return b
end

PickerRebuildGrid = function()
  if not pickerContent then return end
  local cats = ns.TextureLibrary and ns.TextureLibrary.categories or {}
  local cat = cats[pickerCategory]
  local list = (cat and cat.textures) or {}

  local filter = pickerSearch and pickerSearch:GetText()
  filter = (filter and filter ~= "") and filter:lower() or nil

  local width = pickerContent:GetWidth()
  if not width or width < PICKER_CELL then width = 500 end
  local perRow = math.max(1, math.floor(width / PICKER_CELL))

  local curID = PickerCurrentID()
  local shown = 0
  for _, entry in ipairs(list) do
    if (not filter) or (entry.name and entry.name:lower():find(filter, 1, true)) then
      shown = shown + 1
      local b = GetPickerButton(shown)
      b.texid = entry.id
      b.texname = entry.name
      if type(entry.id) == "number" then
        b.tex:SetTexture(entry.id)
        b.tex:SetTexCoord(0, 1, 0, 1)
      else
        b.tex:SetAtlas(tostring(entry.id))
      end
      if entry.id == curID then b.hl:Show() else b.hl:Hide() end
      local idx = shown - 1
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", pickerContent, "TOPLEFT", (idx % perRow) * PICKER_CELL, -math.floor(idx / perRow) * PICKER_CELL)
      b:Show()
    end
  end
  for i = shown + 1, #pickerButtons do pickerButtons[i]:Hide() end
  pickerContent:SetHeight(math.max(1, math.ceil(shown / perRow) * PICKER_CELL))
end

local function EnsurePicker()
  if pickerFrame then return pickerFrame end
  local f = CreateFrame("Frame", "ArcUITexturePicker", UIParent, "BackdropTemplate")
  f:SetSize(560, 470)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetPoint("CENTER")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  f:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
  f:Hide()

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -12)
  title:SetText("Choose Texture")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  pickerCatDD = CreateFrame("Frame", "ArcUITexturePickerCat", f, "UIDropDownMenuTemplate")
  pickerCatDD:SetPoint("TOPLEFT", -2, -34)
  UIDropDownMenu_SetWidth(pickerCatDD, 150)
  UIDropDownMenu_Initialize(pickerCatDD, function(_, level)
    local cats = ns.TextureLibrary and ns.TextureLibrary.categories or {}
    for i, c in ipairs(cats) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = c.name
      info.checked = (i == pickerCategory)
      info.func = function()
        pickerCategory = i
        UIDropDownMenu_SetText(pickerCatDD, c.name)
        if pickerSearch then pickerSearch:SetText("") end
        PickerRebuildGrid()
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)

  pickerSearch = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
  pickerSearch:SetSize(180, 20)
  pickerSearch:SetPoint("TOPRIGHT", -14, -40)
  pickerSearch:SetScript("OnTextChanged", function(self)
    if SearchBoxTemplate_OnTextChanged then SearchBoxTemplate_OnTextChanged(self) end
    PickerRebuildGrid()
  end)

  local scroll = CreateFrame("ScrollFrame", "ArcUITexturePickerScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 10, -70)
  scroll:SetPoint("BOTTOMRIGHT", -32, 14)
  pickerContent = CreateFrame("Frame", nil, scroll)
  pickerContent:SetSize(500, 1)
  scroll:SetScrollChild(pickerContent)
  scroll:SetScript("OnSizeChanged", function(_, w)
    if w and w > 1 then pickerContent:SetWidth(w) end
    PickerRebuildGrid()
  end)

  pickerFrame = f
  return f
end

local function OpenTexturePicker()
  local f = EnsurePicker()
  pickerOnPick = function(id)
    local c = Cfg(); if not c then return end
    c.display.textureID = id
    c.display.textureSource = "library"
    if ns.Textures and ns.Textures.ApplyAppearance then ns.Textures.ApplyAppearance(CurNum()) end
    NotifyChange()
  end

  -- Jump to the category containing the current texture, if any.
  local curID = PickerCurrentID()
  local cats = ns.TextureLibrary and ns.TextureLibrary.categories or {}
  local catName = cats[pickerCategory] and cats[pickerCategory].name or ""
  if curID ~= nil then
    for i, c in ipairs(cats) do
      for _, e in ipairs(c.textures) do
        if e.id == curID then pickerCategory = i; catName = c.name; break end
      end
    end
  end
  if pickerCatDD then UIDropDownMenu_SetText(pickerCatDD, catName) end
  if pickerSearch then pickerSearch:SetText("") end
  PickerRebuildGrid()
  f:Show()
  f:Raise()
end

-- ===================================================================
-- ACTIVE-TEXTURE SELECTOR VALUES
-- ===================================================================
local function GetTextureSelectorValues()
  local out = {}
  local db = ns.API and ns.API.GetDB and ns.API.GetDB()
  if not db or not db.textures then return out end
  for _, num in ipairs(ActiveTextures()) do
    local cfg = db.textures[num]
    local name = (cfg and cfg.tracking and cfg.tracking.buffName) or "(unconfigured)"
    out[num] = string.format("#%d  %s", num, name)
  end
  return out
end

-- ===================================================================
-- DELETE / CREATE
-- ===================================================================
local function DeleteSelectedTexture()
  local num = CurNum()
  local cfg = ns.API.GetTextureConfig(num)
  if cfg then cfg.tracking.enabled = false end
  if ns.API.InvalidateActiveTextureCache then ns.API.InvalidateActiveTextureCache() end
  if ns.Textures and ns.Textures.RefreshAll then ns.Textures.RefreshAll() end

  -- Select the first remaining texture, if any.
  local remaining = ActiveTextures()
  local db = ns.API.GetDB()
  if db then db.selectedTexture = remaining[1] or 1 end
  NotifyChange()
end

-- ===================================================================
-- EDITOR (operates on the currently selected texture)
-- ===================================================================
local function BuildEditor()
  return {
    -- (Trigger tab removed -- the tracked aura is chosen in Buffs/Debuffs > Catalog,
    --  and Aura Type / spec / talent conditions live in the catalog's texture row.)

    -- ---- SOURCE ----
    sourceGroup = {
      type = "group",
      name = "Texture Source",
      inline = true,
      order = 40,
      hidden = function() return not HasAnyTexture() end,
      args = {
        sourceMode = {
          type = "select",
          name = "Source",
          values = { library = "Texture Library", custom = "Custom Path" },
          get = function() return GetDisplay("textureSource", "library") end,
          set = function(_, v) SetDisplay("textureSource", v); NotifyChange() end,
          order = 1,
          width = 1.2,
        },
        choose = {
          type = "execute",
          name = "Choose Texture",
          desc = "Open the texture browser to pick from the library (with live previews and search).",
          image = function()
            local c = Cfg()
            local id = c and c.display and c.display.textureID
            if type(id) == "number" and id > 0 then return id end
            return nil
          end,
          imageWidth = 28,
          imageHeight = 28,
          func = function() OpenTexturePicker() end,
          order = 2,
          width = 1.5,
          hidden = function() return GetDisplay("textureSource", "library") ~= "library" end,
        },
        currentName = {
          type = "description",
          name = function()
            local c = Cfg()
            local id = c and c.display and c.display.textureID
            local n = (id ~= nil) and ns.TextureLibrary and ns.TextureLibrary.GetName and ns.TextureLibrary.GetName(id) or nil
            if n and n ~= "" then return "|cffffd700Current:|r " .. n end
            return "|cff888888No texture chosen yet.|r"
          end,
          order = 2.5,
          width = "full",
          hidden = function() return GetDisplay("textureSource", "library") ~= "library" end,
        },
        customPath = {
          type = "input",
          name = "Custom Texture Path",
          desc = "Full path to a texture file, e.g. Interface\\AddOns\\MyStuff\\image.tga",
          get = function() return GetDisplay("customTexturePath", "") end,
          set = function(_, v) SetDisplay("customTexturePath", v or "") end,
          order = 4,
          width = "full",
          hidden = function() return GetDisplay("textureSource", "library") ~= "custom" end,
        },
        blendMode = {
          type = "select",
          name = "Blend Mode",
          desc = "Opaque draws normally; Glow adds light (good for spell-alert art).",
          values = { BLEND = "Opaque", ADD = "Glow" },
          get = function() return GetDisplay("blendMode", "BLEND") end,
          set = function(_, v) SetDisplay("blendMode", v) end,
          order = 5,
          width = 1.2,
        },
      },
    },

    -- ---- SIZE & POSITION ----
    layoutGroup = {
      type = "group",
      name = "Size & Position",
      inline = true,
      order = 50,
      hidden = function() return not HasAnyTexture() end,
      args = {
        dragHint = {
          type = "description",
          name = "|cff888888Tip: while this panel is open, drag the texture on screen to move it, or grab a gold corner handle to resize it.|r",
          order = 0,
          width = "full",
        },
        width = {
          type = "range",
          name = "Width",
          min = 4, max = 1024, step = 1, bigStep = 2,
          get = function() return GetDisplay("width", 64) end,
          set = function(_, v) SetDisplay("width", v) end,
          order = 1,
          width = 1.2,
        },
        height = {
          type = "range",
          name = "Height",
          min = 4, max = 1024, step = 1, bigStep = 2,
          get = function() return GetDisplay("height", 64) end,
          set = function(_, v) SetDisplay("height", v) end,
          order = 2,
          width = 1.2,
        },
        movable = {
          type = "toggle",
          name = "Movable (drag)",
          get = function() return GetDisplay("movable", true) end,
          set = function(_, v) SetDisplay("movable", v) end,
          order = 3,
          width = 1.0,
        },
        lockAspect = {
          type = "toggle",
          name = "Lock Aspect Ratio",
          desc = "Keep the width/height ratio when resizing with the on-screen corner handles.",
          get = function() return GetDisplay("lockAspect", false) end,
          set = function(_, v) SetDisplay("lockAspect", v) end,
          order = 3.5,
          width = 1.4,
        },
        posX = {
          type = "range",
          name = "X Offset",
          min = -2000, max = 2000, step = 1, bigStep = 1,
          get = function() local p = GetDisplay("position", {}); return p.x or 0 end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.position = cfg.display.position or {}
            cfg.display.position.x = v
            if ns.Textures then ns.Textures.ApplyAppearance(CurNum()) end
          end,
          order = 4,
          width = 1.2,
        },
        posY = {
          type = "range",
          name = "Y Offset",
          min = -2000, max = 2000, step = 1, bigStep = 1,
          get = function() local p = GetDisplay("position", {}); return p.y or 0 end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.position = cfg.display.position or {}
            cfg.display.position.y = v
            if ns.Textures then ns.Textures.ApplyAppearance(CurNum()) end
          end,
          order = 5,
          width = 1.2,
        },
        strata = {
          type = "select",
          name = "Frame Strata",
          values = STRATA_VALUES,
          sorting = STRATA_ORDER,
          get = function() return GetDisplay("frameStrata", "MEDIUM") end,
          set = function(_, v) SetDisplay("frameStrata", v) end,
          order = 7,
          width = 1.3,
        },
        level = {
          type = "range",
          name = "Frame Level",
          min = 1, max = 100, step = 1,
          get = function() return GetDisplay("frameLevel", 10) end,
          set = function(_, v) SetDisplay("frameLevel", v) end,
          order = 8,
          width = 1.2,
        },
      },
    },

    -- ---- TRANSFORM ----
    transformGroup = {
      type = "group",
      name = "Transform",
      inline = true,
      order = 60,
      hidden = function() return not HasAnyTexture() end,
      args = {
        drainConflictNote = {
          type = "description",
          name = "|cffff9900Duration Drain is on. Rotation works with the drain; Mirror, Zoom and Crop don't apply while draining.|r",
          order = 0,
          width = "full",
          hidden = function() return not GetDisplay("progressEnabled", false) end,
        },
        rotateEnabled = {
          type = "toggle",
          name = "Rotate",
          desc = "Rotate the texture by the angle below. Works in both static and Duration Drain mode.",
          get = function() return GetDisplay("rotateEnabled", false) end,
          set = function(_, v) SetDisplay("rotateEnabled", v) end,
          order = 1,
          width = 0.8,
        },
        rotation = {
          type = "range",
          name = "Rotation (degrees)",
          min = -180, max = 180, step = 1,
          get = function() return GetDisplay("rotation", 0) end,
          set = function(_, v) SetDisplay("rotation", v) end,
          order = 2,
          width = 1.6,
          disabled = function() return not GetDisplay("rotateEnabled", false) end,
        },
        mirrorH = {
          type = "toggle",
          name = "Mirror Horizontal",
          get = function() return GetDisplay("mirrorH", false) end,
          set = function(_, v) SetDisplay("mirrorH", v) end,
          order = 3,
          width = 1.2,
        },
        mirrorV = {
          type = "toggle",
          name = "Mirror Vertical",
          get = function() return GetDisplay("mirrorV", false) end,
          set = function(_, v) SetDisplay("mirrorV", v) end,
          order = 4,
          width = 1.2,
        },
        atlasNote = {
          type = "description",
          name = "|cff888888Zoom, crop and mirror apply to file textures. Atlas-based library textures (e.g. Sparks) keep their built-in cropping.|r",
          order = 5,
          width = "full",
        },
        zoomEnabled = {
          type = "toggle",
          name = "Zoom",
          get = function() return GetDisplay("zoomEnabled", false) end,
          set = function(_, v) SetDisplay("zoomEnabled", v) end,
          order = 6,
          width = 0.8,
        },
        zoomPct = {
          type = "range",
          name = "Zoom Amount",
          min = 0, max = 50, step = 1,
          get = function() return GetDisplay("zoomPct", 0) end,
          set = function(_, v) SetDisplay("zoomPct", v) end,
          order = 7,
          width = 1.6,
          disabled = function() return not GetDisplay("zoomEnabled", false) end,
        },
        cropEnabled = {
          type = "toggle",
          name = "Crop",
          get = function() return GetDisplay("cropEnabled", false) end,
          set = function(_, v) SetDisplay("cropEnabled", v) end,
          order = 8,
          width = "full",
        },
        cropL = {
          type = "range",
          name = "Crop Left",
          min = 0, max = 100, step = 1,
          get = function() return GetDisplay("cropL", 0) end,
          set = function(_, v) SetDisplay("cropL", v) end,
          order = 9,
          width = 1.2,
          disabled = function() return not GetDisplay("cropEnabled", false) end,
        },
        cropR = {
          type = "range",
          name = "Crop Right",
          min = 0, max = 100, step = 1,
          get = function() return GetDisplay("cropR", 0) end,
          set = function(_, v) SetDisplay("cropR", v) end,
          order = 10,
          width = 1.2,
          disabled = function() return not GetDisplay("cropEnabled", false) end,
        },
        cropT = {
          type = "range",
          name = "Crop Top",
          min = 0, max = 100, step = 1,
          get = function() return GetDisplay("cropT", 0) end,
          set = function(_, v) SetDisplay("cropT", v) end,
          order = 11,
          width = 1.2,
          disabled = function() return not GetDisplay("cropEnabled", false) end,
        },
        cropB = {
          type = "range",
          name = "Crop Bottom",
          min = 0, max = 100, step = 1,
          get = function() return GetDisplay("cropB", 0) end,
          set = function(_, v) SetDisplay("cropB", v) end,
          order = 12,
          width = 1.2,
          disabled = function() return not GetDisplay("cropEnabled", false) end,
        },
      },
    },

    -- ---- DURATION DRAIN ----
    durationGroup = {
      type = "group",
      name = "Duration Drain",
      inline = true,
      order = 65,
      hidden = function() return not HasAnyTexture() end,
      args = {
        progressHint = {
          type = "description",
          name = "|cff888888As the tracked aura runs down, the texture depletes like a bar (secret-safe), with a dimmed full-texture ghost behind it (the WeakAuras look). Works with file textures; atlas textures (e.g. Sparks) fall back to the static image.|r",
          order = 0,
          width = "full",
        },
        progressEnabled = {
          type = "toggle",
          name = "Drain As It Expires",
          get = function() return GetDisplay("progressEnabled", false) end,
          set = function(_, v) SetDisplay("progressEnabled", v); NotifyChange() end,
          order = 1,
          width = 1.4,
        },
        progressDir = {
          type = "select",
          name = "Drain Direction",
          values = {
            TOP_TO_BOTTOM = "Top to Bottom",
            BOTTOM_TO_TOP = "Bottom to Top",
            LEFT_TO_RIGHT = "Left to Right",
            RIGHT_TO_LEFT = "Right to Left",
          },
          get = function() return GetDisplay("progressDir", "TOP_TO_BOTTOM") end,
          set = function(_, v) SetDisplay("progressDir", v) end,
          order = 2,
          width = 1.6,
          disabled = function() return not GetDisplay("progressEnabled", false) end,
        },
        progressHideGhost = {
          type = "toggle",
          name = "Hide Background Ghost",
          desc = "The full texture shows dimmed behind the draining portion by default (the WeakAuras look). Enable this to hide it and show only the draining part.",
          get = function() return GetDisplay("progressHideGhost", false) end,
          set = function(_, v) SetDisplay("progressHideGhost", v) end,
          order = 3,
          width = 1.8,
          disabled = function() return not GetDisplay("progressEnabled", false) end,
        },
        regionHeader = {
          type = "description",
          name = "|cffffd700Drain Region|r |cff888888-- optionally confine the drain to a band of the texture; inset each edge inward (%). The rest of the texture stays solid. All 0 = the whole texture drains.|r",
          order = 4,
          width = "full",
          hidden = function() return not GetDisplay("progressEnabled", false) end,
        },
        drainInsetT = {
          type = "range",
          name = "Region Inset: Top",
          min = 0, max = 49, step = 1, isPercent = false,
          get = function() return (GetDisplay("drainInsetT", 0)) * 100 end,
          set = function(_, v) SetDisplay("drainInsetT", (tonumber(v) or 0) / 100) end,
          order = 5,
          width = 1.5,
          disabled = function() return not GetDisplay("progressEnabled", false) end,
        },
        drainInsetB = {
          type = "range",
          name = "Region Inset: Bottom",
          min = 0, max = 49, step = 1,
          get = function() return (GetDisplay("drainInsetB", 0)) * 100 end,
          set = function(_, v) SetDisplay("drainInsetB", (tonumber(v) or 0) / 100) end,
          order = 6,
          width = 1.5,
          disabled = function() return not GetDisplay("progressEnabled", false) end,
        },
        drainInsetL = {
          type = "range",
          name = "Region Inset: Left",
          min = 0, max = 49, step = 1,
          get = function() return (GetDisplay("drainInsetL", 0)) * 100 end,
          set = function(_, v) SetDisplay("drainInsetL", (tonumber(v) or 0) / 100) end,
          order = 7,
          width = 1.5,
          disabled = function() return not GetDisplay("progressEnabled", false) end,
        },
        drainInsetR = {
          type = "range",
          name = "Region Inset: Right",
          min = 0, max = 49, step = 1,
          get = function() return (GetDisplay("drainInsetR", 0)) * 100 end,
          set = function(_, v) SetDisplay("drainInsetR", (tonumber(v) or 0) / 100) end,
          order = 8,
          width = 1.5,
          disabled = function() return not GetDisplay("progressEnabled", false) end,
        },
      },
    },

    -- ---- ACTIVE STYLE ----
    activeGroup = {
      type = "group",
      name = "Active Style (aura present)",
      inline = true,
      order = 70,
      hidden = function() return not HasAnyTexture() end,
      args = {
        activeColor = {
          type = "color",
          name = "Tint Color",
          hasAlpha = false,
          get = function() return GetColor("activeColor") end,
          set = function(_, r, g, b) SetColor("activeColor", r, g, b) end,
          order = 1,
          width = 1.0,
        },
        activeAlpha = {
          type = "range",
          name = "Opacity",
          min = 0, max = 1, step = 0.05, isPercent = true,
          get = function() return GetDisplay("activeAlpha", 1) end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.activeAlpha = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
          end,
          order = 2,
          width = 1.4,
        },
        activeDesaturate = {
          type = "toggle",
          name = "Desaturate",
          get = function() return GetDisplay("activeDesaturate", false) end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.activeDesaturate = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
          end,
          order = 3,
          width = 1.0,
        },
        activeDesaturatePct = {
          type = "range",
          name = "Desaturate Amount",
          min = 0, max = 100, step = 1,
          get = function() return GetDisplay("activeDesaturatePct", 100) end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.activeDesaturatePct = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
          end,
          order = 4,
          width = 1.6,
          disabled = function() return not GetDisplay("activeDesaturate", false) end,
        },
        fadeOutEnabled = {
          type = "toggle",
          name = "Fade Out As It Expires",
          desc = "As the tracked aura runs down, fade the texture toward invisible. Secret-safe (uses Blizzard's duration curve). Ignored while Duration Drain is on.",
          get = function() return GetDisplay("fadeOutEnabled", false) end,
          set = function(_, v) SetDisplay("fadeOutEnabled", v) end,
          order = 5,
          width = "full",
        },
        fadeStartPct = {
          type = "range",
          name = "Start Fading Below (% remaining)",
          min = 1, max = 100, step = 1,
          get = function() return GetDisplay("fadeStartPct", 50) end,
          set = function(_, v) SetDisplay("fadeStartPct", v) end,
          order = 6,
          width = 2.0,
          disabled = function() return not GetDisplay("fadeOutEnabled", false) end,
        },
      },
    },

    -- ---- INACTIVE STYLE ----
    inactiveGroup = {
      type = "group",
      name = "Inactive Style (aura absent)",
      inline = true,
      order = 80,
      hidden = function() return not HasAnyTexture() end,
      args = {
        showWhenInactive = {
          type = "toggle",
          name = "Show When Inactive",
          desc = "When off, the texture is hidden while the aura is absent. When on, it shows using the inactive style below.",
          get = function() return GetDisplay("showWhenInactive", false) end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.showWhenInactive = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
          end,
          order = 1,
          width = "full",
        },
        inactiveColor = {
          type = "color",
          name = "Tint Color",
          hasAlpha = false,
          get = function() return GetColor("inactiveColor") end,
          set = function(_, r, g, b) SetColor("inactiveColor", r, g, b) end,
          order = 2,
          width = 1.0,
          disabled = function() return not GetDisplay("showWhenInactive", false) end,
        },
        inactiveAlpha = {
          type = "range",
          name = "Opacity",
          min = 0, max = 1, step = 0.05, isPercent = true,
          get = function() return GetDisplay("inactiveAlpha", 0.5) end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.inactiveAlpha = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
          end,
          order = 3,
          width = 1.4,
          disabled = function() return not GetDisplay("showWhenInactive", false) end,
        },
        inactiveDesaturate = {
          type = "toggle",
          name = "Desaturate",
          get = function() return GetDisplay("inactiveDesaturate", true) end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.inactiveDesaturate = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
          end,
          order = 4,
          width = 1.0,
          disabled = function() return not GetDisplay("showWhenInactive", false) end,
        },
        inactiveDesaturatePct = {
          type = "range",
          name = "Desaturate Amount",
          min = 0, max = 100, step = 1,
          get = function() return GetDisplay("inactiveDesaturatePct", 100) end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.inactiveDesaturatePct = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
          end,
          order = 5,
          width = 1.6,
          disabled = function()
            return (not GetDisplay("showWhenInactive", false)) or (not GetDisplay("inactiveDesaturate", true))
          end,
        },
      },
    },

    -- ---- EFFECTS ----
    effectsGroup = {
      type = "group",
      name = "Effects (Active)",
      inline = true,
      order = 85,
      hidden = function() return not HasAnyTexture() end,
      args = {
        pulseHint = {
          type = "description",
          name = "|cff888888The size pulse plays while the aura is active, and previews here in the editor as you toggle it. It pauses only while you drag a resize handle.|r",
          order = 0,
          width = "full",
        },
        pulseEnabled = {
          type = "toggle",
          name = "Pulse (size)",
          desc = "Gently pulse the texture's size while the aura is active. Uses a Blizzard animation, no per-frame CPU.",
          get = function() return GetDisplay("pulseEnabled", false) end,
          set = function(_, v) SetDisplay("pulseEnabled", v) end,
          order = 1,
          width = 1.2,
        },
        pulseScale = {
          type = "range",
          name = "Pulse Size",
          min = 0.5, max = 2.0, step = 0.05, isPercent = true,
          get = function() return GetDisplay("pulseScale", 1.15) end,
          set = function(_, v) SetDisplay("pulseScale", v) end,
          order = 2,
          width = 1.4,
          disabled = function() return not GetDisplay("pulseEnabled", false) end,
        },
        pulseSpeed = {
          type = "range",
          name = "Pulse Speed (sec)",
          min = 0.1, max = 3.0, step = 0.05,
          get = function() return GetDisplay("pulseSpeed", 0.5) end,
          set = function(_, v) SetDisplay("pulseSpeed", v) end,
          order = 3,
          width = 1.4,
          disabled = function() return not GetDisplay("pulseEnabled", false) end,
        },
      },
    },

    -- ---- BEHAVIOR ----
    behaviorGroup = {
      type = "group",
      name = "Behavior",
      inline = true,
      order = 90,
      hidden = function() return not HasAnyTexture() end,
      args = {
        hideWhenInfo = {
          type = "description",
          name = "|cff888888Spec and talent conditions are set per texture in Buffs/Debuffs > Catalog (expand the texture's row). These are the same state-based hide conditions the Aura Bars use.|r",
          order = 0,
          width = "full",
        },
        hideWhen = {
          type = "multiselect",
          name = "Hide When...",
          desc = "Conditions that HIDE this texture. With nothing checked, visibility is controlled only by the tracked aura (and the spec/talent conditions in the catalog row).",
          get = function(_, key)
            local c = Cfg()
            if not c or not c.behavior then return false end
            local hw = c.behavior.hideWhen
            if type(hw) ~= "table" then return false end
            return hw[key] or false
          end,
          set = function(_, key, val)
            local c = Cfg(); if not c then return end
            c.behavior = c.behavior or {}
            if type(c.behavior.hideWhen) ~= "table" then c.behavior.hideWhen = {} end
            c.behavior.hideWhen[key] = val or nil
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
            NotifyChange()
          end,
          values = function()
            if ns.CooldownBars and ns.CooldownBars.GetHideConditions then
              return ns.CooldownBars.GetHideConditions()
            end
            return { hideOOC = "Out of Combat" }
          end,
          order = 1,
          width = 1.5,
        },
        hideLogic = {
          type = "select",
          name = "Condition Match Mode",
          desc = "|cff00ff00Match Any|r: hide if ANY checked condition is true.\n|cff00ff00Match All|r: hide only when ALL checked conditions are true.",
          values = { any = "Match Any", all = "Match All" },
          sorting = { "any", "all" },
          get = function() local c = Cfg(); return (c and c.behavior and c.behavior.hideLogic) or "any" end,
          set = function(_, v)
            local c = Cfg(); if not c then return end
            c.behavior = c.behavior or {}
            c.behavior.hideLogic = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
            NotifyChange()
          end,
          order = 2,
          width = 1.5,
        },
        hideWhenAlpha = {
          type = "range",
          name = "Hidden Opacity",
          desc = "Opacity when a Hide When condition is active. 0 = fully hidden (default); higher fades the texture instead of hiding it.",
          min = 0, max = 1, step = 0.05, isPercent = true,
          get = function() local c = Cfg(); return (c and c.behavior and c.behavior.hideWhenAlpha) or 0 end,
          set = function(_, v)
            local c = Cfg(); if not c then return end
            c.behavior = c.behavior or {}
            c.behavior.hideWhenAlpha = v
            if ns.Textures then ns.Textures.UpdateTexture(CurNum()) end
          end,
          order = 3,
          width = 1.5,
          hidden = function()
            local c = Cfg()
            local hw = c and c.behavior and c.behavior.hideWhen
            if type(hw) ~= "table" then return true end
            for _, vv in pairs(hw) do if vv then return false end end
            return true
          end,
        },
      },
    },

    -- ---- DURATION TEXT (mirrors the Aura Bars' duration-text options) ----
    durationTextGroup = {
      type = "group",
      name = "Duration Text",
      inline = true,
      order = 95,
      hidden = function() return not HasAnyTexture() end,
      args = {
        showDuration = {
          type = "toggle",
          name = "Show Duration",
          desc = "Show a secret-safe countdown of the tracked aura's remaining time on the texture.",
          get = function() return GetDisplay("showDuration", false) end,
          set = function(_, v) SetDisplay("showDuration", v) end,
          order = 1, width = 1.2,
        },
        durationColor = {
          type = "color",
          name = "Color",
          hasAlpha = true,
          get = function()
            local c = GetDisplay("durationColor", nil)
            if type(c) == "table" then return c.r or 1, c.g or 1, c.b or 1, c.a or 1 end
            return 1, 1, 1, 1
          end,
          set = function(_, r, g, b, a)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.durationColor = { r = r, g = g, b = b, a = a }
            if ns.Textures then ns.Textures.ApplyAppearance(CurNum()) end
          end,
          order = 2, width = 0.7,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationFont = {
          type = "select",
          dialogControl = "LSM30_Font",
          name = "Font",
          values = function() return (LSM and LSM:HashTable("font")) or {} end,
          get = function() return GetDisplay("durationFont", "2002 Bold") end,
          set = function(_, v) SetDisplay("durationFont", v) end,
          order = 3, width = 1.1,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationFontSize = {
          type = "range",
          name = "Size",
          min = 6, max = 48, step = 1,
          get = function() return GetDisplay("durationFontSize", 18) end,
          set = function(_, v) SetDisplay("durationFontSize", v) end,
          order = 4, width = 1.0,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationOutline = {
          type = "select",
          name = "Outline",
          values = { NONE = "None", OUTLINE = "Thin", THICKOUTLINE = "Thick" },
          get = function() return GetDisplay("durationOutline", "THICKOUTLINE") end,
          set = function(_, v) SetDisplay("durationOutline", v) end,
          order = 5, width = 0.8,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationShadow = {
          type = "toggle",
          name = "Shadow",
          get = function() return GetDisplay("durationShadow", false) end,
          set = function(_, v) SetDisplay("durationShadow", v) end,
          order = 6, width = 0.7,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationDecimals = {
          type = "select",
          name = "Decimals",
          values = { [0] = "0 (27)", [1] = "1 (27.4)", [2] = "2 (27.44)", [3] = "3 (27.448)" },
          get = function() return GetDisplay("durationDecimals", 1) end,
          set = function(_, v) SetDisplay("durationDecimals", v) end,
          order = 7, width = 0.9,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationAnchor = {
          type = "select",
          name = "Anchor",
          desc = "Where the duration text sits relative to the texture.",
          values = {
            CENTER = "Center",
            TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
            OUTERTOP = "Outer Top", OUTERBOTTOM = "Outer Bottom", OUTERLEFT = "Outer Left", OUTERRIGHT = "Outer Right",
            OUTERTOPLEFT = "Outer Top Left", OUTERTOPRIGHT = "Outer Top Right",
            OUTERBOTTOMLEFT = "Outer Bottom Left", OUTERBOTTOMRIGHT = "Outer Bottom Right",
          },
          get = function() return GetDisplay("durationAnchor", "CENTER") end,
          set = function(_, v)
            local cfg = Cfg(); if not cfg then return end
            cfg.display.durationAnchor = v
            cfg.display.durationAnchorOffsetX = 0
            cfg.display.durationAnchorOffsetY = 0
            if ns.Textures then ns.Textures.ApplyAppearance(CurNum()) end
            NotifyChange()
          end,
          order = 8, width = 1.2,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationAnchorOffsetX = {
          type = "range",
          name = "X Offset",
          min = -200, max = 200, step = 1,
          get = function() return GetDisplay("durationAnchorOffsetX", 0) end,
          set = function(_, v) SetDisplay("durationAnchorOffsetX", v) end,
          order = 9, width = 1.0,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationAnchorOffsetY = {
          type = "range",
          name = "Y Offset",
          min = -200, max = 200, step = 1,
          get = function() return GetDisplay("durationAnchorOffsetY", 0) end,
          set = function(_, v) SetDisplay("durationAnchorOffsetY", v) end,
          order = 10, width = 1.0,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationTextStrata = {
          type = "select",
          name = "Strata",
          values = { BACKGROUND = "BACKGROUND", LOW = "LOW", MEDIUM = "MEDIUM", HIGH = "HIGH", DIALOG = "DIALOG", TOOLTIP = "TOOLTIP" },
          sorting = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "TOOLTIP" },
          get = function() return GetDisplay("durationTextStrata", "HIGH") end,
          set = function(_, v) SetDisplay("durationTextStrata", v) end,
          order = 11, width = 1.0,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        durationTextLevel = {
          type = "range",
          name = "Level",
          min = 1, max = 500, step = 1,
          get = function() return GetDisplay("durationTextLevel", 13) end,
          set = function(_, v) SetDisplay("durationTextLevel", v) end,
          order = 12, width = 1.0,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },

        -- ---- Conditional colouring of the duration text (independent of the bar) ----
        -- Helper gates: bands appear only once "Color by Remaining Time" is on, and
        -- each band's value/colour greys until its "Below" toggle is checked. Each
        -- band sits on its own row (full-width line breaks) so they align in columns.
        thresholdHeader = {
          type = "header", name = "Conditional Color", order = 20,
          hidden = function() return not GetDisplay("showDuration", false) end,
        },
        durationTextColorEnabled = {
          type = "toggle",
          name = "Color by Remaining Time",
          desc = "Recolor the duration text as the aura runs down, using the thresholds below.",
          get = function() return GetDisplay("durationTextColorEnabled", false) end,
          set = function(_, v) SetDisplay("durationTextColorEnabled", v) end,
          order = 21, width = 1.5,
          disabled = function() return not GetDisplay("showDuration", false) end,
        },
        thresholdHint = {
          type = "description",
          name = "Recolor the countdown when fewer than this many seconds remain. The lowest value reached wins. (Colour is driven by the game, with no per-frame updates.)",
          fontSize = "medium",
          order = 23,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
        },

        durationTextThreshold2Enable = {
          type = "toggle", name = "Below", desc = "Enable this threshold band.",
          get = function() return GetDisplay("durationTextThreshold2Enabled", false) end,
          set = function(_, v) SetDisplay("durationTextThreshold2Enabled", v) end,
          order = 24, width = 0.5,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
        },
        durationTextThreshold2Value = {
          type = "input", name = "",
          desc = "Recolor when remaining falls below this value.",
          get = function() local v = GetDisplay("durationTextThreshold2Value", nil); return v ~= nil and tostring(v) or "75" end,
          set = function(_, val) SetDisplay("durationTextThreshold2Value", tonumber(val) or 75) end,
          order = 25, width = 0.5,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
          disabled = function() return not GetDisplay("durationTextThreshold2Enabled", false) end,
        },
        durationTextThreshold2Color = {
          type = "color", name = "Color", hasAlpha = true,
          get = function() local c = GetDisplay("durationTextThreshold2Color", nil); if type(c)=="table" then return c.r,c.g,c.b,c.a or 1 end return 0.8,0.8,0,1 end,
          set = function(_, r, g, b, a) SetDisplay("durationTextThreshold2Color", { r=r, g=g, b=b, a=a }) end,
          order = 26, width = 0.8,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
          disabled = function() return not GetDisplay("durationTextThreshold2Enabled", false) end,
        },
        lineBreak2 = { type = "description", name = "", order = 26.5, width = "full",
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end },

        durationTextThreshold3Enable = {
          type = "toggle", name = "Below", desc = "Enable this threshold band.",
          get = function() return GetDisplay("durationTextThreshold3Enabled", false) end,
          set = function(_, v) SetDisplay("durationTextThreshold3Enabled", v) end,
          order = 27, width = 0.5,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
        },
        durationTextThreshold3Value = {
          type = "input", name = "",
          desc = "Recolor when remaining falls below this value.",
          get = function() local v = GetDisplay("durationTextThreshold3Value", nil); return v ~= nil and tostring(v) or "50" end,
          set = function(_, val) SetDisplay("durationTextThreshold3Value", tonumber(val) or 50) end,
          order = 28, width = 0.5,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
          disabled = function() return not GetDisplay("durationTextThreshold3Enabled", false) end,
        },
        durationTextThreshold3Color = {
          type = "color", name = "Color", hasAlpha = true,
          get = function() local c = GetDisplay("durationTextThreshold3Color", nil); if type(c)=="table" then return c.r,c.g,c.b,c.a or 1 end return 1,0.5,0,1 end,
          set = function(_, r, g, b, a) SetDisplay("durationTextThreshold3Color", { r=r, g=g, b=b, a=a }) end,
          order = 29, width = 0.8,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
          disabled = function() return not GetDisplay("durationTextThreshold3Enabled", false) end,
        },
        lineBreak3 = { type = "description", name = "", order = 29.5, width = "full",
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end },

        durationTextThreshold4Enable = {
          type = "toggle", name = "Below", desc = "Enable this threshold band.",
          get = function() return GetDisplay("durationTextThreshold4Enabled", false) end,
          set = function(_, v) SetDisplay("durationTextThreshold4Enabled", v) end,
          order = 30, width = 0.5,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
        },
        durationTextThreshold4Value = {
          type = "input", name = "",
          desc = "Recolor when remaining falls below this value.",
          get = function() local v = GetDisplay("durationTextThreshold4Value", nil); return v ~= nil and tostring(v) or "25" end,
          set = function(_, val) SetDisplay("durationTextThreshold4Value", tonumber(val) or 25) end,
          order = 31, width = 0.5,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
          disabled = function() return not GetDisplay("durationTextThreshold4Enabled", false) end,
        },
        durationTextThreshold4Color = {
          type = "color", name = "Color", hasAlpha = true,
          get = function() local c = GetDisplay("durationTextThreshold4Color", nil); if type(c)=="table" then return c.r,c.g,c.b,c.a or 1 end return 1,0.3,0,1 end,
          set = function(_, r, g, b, a) SetDisplay("durationTextThreshold4Color", { r=r, g=g, b=b, a=a }) end,
          order = 32, width = 0.8,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
          disabled = function() return not GetDisplay("durationTextThreshold4Enabled", false) end,
        },
        lineBreak4 = { type = "description", name = "", order = 32.5, width = "full",
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end },

        durationTextThreshold5Enable = {
          type = "toggle", name = "Below", desc = "Enable this threshold band (critical).",
          get = function() return GetDisplay("durationTextThreshold5Enabled", false) end,
          set = function(_, v) SetDisplay("durationTextThreshold5Enabled", v) end,
          order = 33, width = 0.5,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
        },
        durationTextThreshold5Value = {
          type = "input", name = "",
          desc = "Recolor when remaining falls below this value (critical).",
          get = function() local v = GetDisplay("durationTextThreshold5Value", nil); return v ~= nil and tostring(v) or "10" end,
          set = function(_, val) SetDisplay("durationTextThreshold5Value", tonumber(val) or 10) end,
          order = 34, width = 0.5,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
          disabled = function() return not GetDisplay("durationTextThreshold5Enabled", false) end,
        },
        durationTextThreshold5Color = {
          type = "color", name = "Color", hasAlpha = true,
          get = function() local c = GetDisplay("durationTextThreshold5Color", nil); if type(c)=="table" then return c.r,c.g,c.b,c.a or 1 end return 1,0,0,1 end,
          set = function(_, r, g, b, a) SetDisplay("durationTextThreshold5Color", { r=r, g=g, b=b, a=a }) end,
          order = 35, width = 0.8,
          hidden = function() return not (GetDisplay("showDuration", false) and GetDisplay("durationTextColorEnabled", false)) end,
          disabled = function() return not GetDisplay("durationTextThreshold5Enabled", false) end,
        },
      },
    },
  }
end

-- ===================================================================
-- TOP-LEVEL TABLE
-- ===================================================================
function ns.GetTexturesOptionsTable()
  local ed = BuildEditor()
  local function notEmpty() return not HasAnyTexture() end

  local args = {
    -- Persistent controls: with childGroups="tab" these render ABOVE the tab row,
    -- so the selected texture stays visible/changeable while editing any tab.
    selectTexture = {
      type = "select",
      name = "Editing Texture",
      desc = "Which texture the tabs below are editing.",
      values = function() return GetTextureSelectorValues() end,
      get = function() return CurNum() end,
      set = function(_, v)
        local db = ns.API.GetDB()
        if db then db.selectedTexture = v end
        -- Move the on-screen resize handles to the newly selected texture.
        if ns.Textures and ns.Textures.RefreshAll then ns.Textures.RefreshAll() end
        NotifyChange()
      end,
      order = 1,
      width = "double",
      hidden = notEmpty,
    },
    noTextures = {
      type = "description",
      name = "|cff888888No textures yet. Create one in the |r|cffffd700Buffs/Debuffs > Catalog|r|cff888888 tab: select an aura, then Create Texture.|r",
      fontSize = "medium",
      order = 2,
      hidden = function() return HasAnyTexture() end,
    },

    -- Editor tabs (hidden until at least one texture exists).
    texture = {
      type = "group", name = "Texture", order = 30,
      hidden = notEmpty,
      args = { sourceGroup = ed.sourceGroup, transformGroup = ed.transformGroup, durationGroup = ed.durationGroup },
    },
    position = {
      type = "group", name = "Position", order = 40,
      hidden = notEmpty, args = ed.layoutGroup.args,
    },
    states = {
      type = "group", name = "States", order = 60,
      hidden = notEmpty,
      args = { activeGroup = ed.activeGroup, inactiveGroup = ed.inactiveGroup },
    },
    text = {
      type = "group", name = "Duration Text", order = 65,
      hidden = notEmpty, args = ed.durationTextGroup.args,
    },
    effects = {
      type = "group", name = "Effects", order = 70,
      hidden = notEmpty, args = ed.effectsGroup.args,
    },
    behavior = {
      type = "group", name = "Behavior", order = 80,
      hidden = notEmpty, args = ed.behaviorGroup.args,
    },

    -- (Creation moved to the shared Buffs/Debuffs > Catalog tab; no Setup tab here.)
  }

  return {
    type = "group",
    name = "Textures",
    childGroups = "tab",
    args = args,
  }
end
