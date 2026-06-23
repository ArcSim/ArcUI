-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Stack Threshold Color
-- Colors the STACK COUNT number on CDM aura icons by stack-count thresholds.
--
-- WHY THIS IS HARD (WoW 12.0 secret values):
--   In instances/M+ an aura's application count (AuraData.applications) is a
--   SECRET value. We cannot compare it, do arithmetic on it, tonumber() it, or
--   feed it to a ColorCurve. There is NO applications->color accessor.
--
-- THE SECRET-SAFE MECHANISM (the only thing that works):
--   C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID,
--       minDisplayCount, maxDisplayCount) returns a STRING:
--     - empty string  when the count is below minDisplayCount
--     - the number     when the count is at/above minDisplayCount
--     - "*"            when the count is above maxDisplayCount
--   The returned string is secret-when-restricted, but SetText is a secret-safe
--   sink and SetTextColor is OUR (non-secret) value.
--
--   So we build ONE FontString per color band {threshold T, color C}:
--     - colored once with SetTextColor(C)  (our value, never secret)
--     - updated with fs:SetText(GetAuraApplicationDisplayCount(unit, aiid, T, nil))
--       (MIN-ONLY: nil max so a band never emits "*")
--   All bands share the SAME font/size/outline/position so they overlap pixel
--   perfect, layered with the HIGHEST threshold drawn ON TOP. Below its
--   threshold a band is an empty string (invisible); at/above, every satisfied
--   band shows the SAME number perfectly overlapped, so the topmost (highest
--   threshold reached) color wins. No secret is ever compared.
--
-- BOUNDARY: this colors the NUMBER text only. It does NOT recolor the icon
-- image (impossible against secret stacks). Scope is the stack-count text.
--
-- DRIVEN BY: SetupChargeText (styling: ApplyBands/ClearBands) + the existing
-- aura event hooks already installed for the single-stack mirror (value:
-- UpdateBands). Event-driven, no polling, zero idle CPU.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

ns.StackColor = ns.StackColor or {}
local SC = ns.StackColor

-- Fixed number of color band slots. Fixed slots (not a dynamic list) match the
-- merge-safe durationColorCustom precedent: DeepMergeSettings deep-merges by
-- index, so DEFAULT->global->perIcon align cleanly per slot/field.
local MAX_BANDS = 6
SC.MAX_BANDS = MAX_BANDS

-- ───────────────────────────────────────────────────────────────────────────
-- HELPERS
-- ───────────────────────────────────────────────────────────────────────────

local function GetFontPath(fontName)
  if not fontName or fontName == "" then return "Fonts\\FRIZQT__.TTF" end
  local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
  if LSM then
    local path = LSM:Fetch("font", fontName)
    if path and path ~= "" then return path end
  end
  if fontName:find("\\") or fontName:find("/") then return fontName end
  return "Fonts\\FRIZQT__.TTF"
end

-- pcall-free SetFont: SetFont returns a boolean (false on failure), it never
-- raises, so we check the return and fall back to the default font.
local function SetFontSafe(fs, path, size, outline)
  if not fs or not fs.SetFont then return end
  if not outline or outline == "" or outline == "NONE" then outline = "" end
  if not fs:SetFont(path, size, outline) then
    fs:SetFont("Fonts\\FRIZQT__.TTF", size, outline)
  end
end

-- Secret-safe aura presence (reuse Core's helper; 0 == saved-variable default
-- "no aura", nil == gone, a secret value == present).
local function HasAuraInstanceID(value)
  if ns.API and ns.API.HasAuraInstanceID then
    return ns.API.HasAuraInstanceID(value)
  end
  if value == nil then return false end
  if issecretvalue and issecretvalue(value) then return true end
  if type(value) == "number" and value == 0 then return false end
  return value ~= nil
end

-- True if the charge-text config has at least one usable band.
function SC.HasEnabledBands(chargeCfg)
  local bands = chargeCfg and chargeCfg.thresholdBands
  if type(bands) ~= "table" then return false end
  for i = 1, MAX_BANDS do
    local b = bands[i]
    if b and b.enabled and b.threshold then return true end
  end
  return false
end

-- ───────────────────────────────────────────────────────────────────────────
-- APPLY (styling): create/style/position/layer the band FontStrings.
-- Bands inherit font/size/outline/shadow/anchor/offset from chargeCfg so they
-- sit exactly where the single-stack text would, overlapping pixel-perfect.
-- ───────────────────────────────────────────────────────────────────────────

function SC.ApplyBands(frame, chargeCfg)
  if not frame or not chargeCfg then return end
  local bands = chargeCfg.thresholdBands
  if type(bands) ~= "table" then SC.ClearBands(frame); return end

  -- Container (ArcUI-created child frame, NOT a Blizzard restricted child)
  if not frame._arcStackBandContainer then
    local c = CreateFrame("Frame", nil, frame)
    c:SetAllPoints(frame)
    frame._arcStackBandContainer = c
    frame._arcStackBands = {}
  end
  local container = frame._arcStackBandContainer
  container:SetFrameLevel(frame:GetFrameLevel() + 3)  -- above glows, like the single-stack mirror
  container:Show()

  -- Shared style/position from chargeCfg (same family as the single-stack text)
  local fontPath = GetFontPath(chargeCfg.font)
  local size     = chargeCfg.size or 16
  local outline  = chargeCfg.outline or "OUTLINE"
  local mode     = chargeCfg.mode
  local anchor   = chargeCfg.anchor or chargeCfg.position or "BOTTOMRIGHT"
  local ox       = chargeCfg.offsetX or -2
  local oy       = chargeCfg.offsetY or 2
  local fx       = chargeCfg.freeX or 0
  local fy       = chargeCfg.freeY or 0

  -- Rank enabled bands by ascending threshold -> draw sublevel (highest on top)
  local rankBySlot = {}
  do
    local order = {}
    for i = 1, MAX_BANDS do
      local b = bands[i]
      if b and b.enabled and b.threshold then
        order[#order + 1] = { slot = i, threshold = b.threshold }
      end
    end
    table.sort(order, function(a, b) return a.threshold < b.threshold end)
    for rank, e in ipairs(order) do rankBySlot[e.slot] = rank end
  end

  local fsList = frame._arcStackBands
  for i = 1, MAX_BANDS do
    local b = bands[i]
    local active = b and b.enabled and b.threshold
    local fs = fsList[i]
    if active then
      if not fs then
        fs = container:CreateFontString(nil, "OVERLAY")
        fsList[i] = fs
      end
      SetFontSafe(fs, fontPath, size, outline)

      -- Highest threshold drawn ON TOP: rank 1 = lowest threshold (bottom).
      -- OVERLAY sublevel range is -8..7; clamp.
      local sub = rankBySlot[i] or 1
      if sub > 7 then sub = 7 end
      fs:SetDrawLayer("OVERLAY", sub)

      -- Our color, never secret.
      local col = b.color or { r = 1, g = 1, b = 1, a = 1 }
      fs:SetTextColor(col.r or 1, col.g or 1, col.b or 1, col.a or 1)

      if chargeCfg.shadow then
        fs:SetShadowOffset(chargeCfg.shadowOffsetX or 1, chargeCfg.shadowOffsetY or -1)
        fs:SetShadowColor(0, 0, 0, 0.8)
      else
        fs:SetShadowOffset(0, 0)
      end

      fs:ClearAllPoints()
      if mode == "free" then
        fs:SetPoint("CENTER", frame, "CENTER", fx, fy)
      else
        fs:SetPoint(anchor, frame, anchor, ox, oy)
      end

      fs._arcThreshold = b.threshold
      fs:Show()
    elseif fs then
      fs._arcThreshold = nil
      fs:SetText("")
      fs:Hide()
    end
  end

  frame._arcStackBandsActive = true
  SC.UpdateBands(frame)
end

-- ───────────────────────────────────────────────────────────────────────────
-- UPDATE (value): the secret-safe SetText loop. Called from the aura event
-- hooks already installed for the single-stack mirror.
-- ───────────────────────────────────────────────────────────────────────────

function SC.UpdateBands(frame)
  if not frame or not frame._arcStackBandsActive then return end
  local fsList = frame._arcStackBands
  if not fsList then return end

  local auraID = frame.auraInstanceID
  if not HasAuraInstanceID(auraID) then
    for i = 1, MAX_BANDS do
      local fs = fsList[i]
      if fs then fs:SetText("") end
    end
    return
  end

  local getCount = C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount
  if not getCount then return end
  local unit = frame.auraDataUnit or "player"

  for i = 1, MAX_BANDS do
    local fs = fsList[i]
    if fs and fs._arcThreshold then
      -- MIN-ONLY (nil max): below the threshold -> empty string; at/above ->
      -- the count string (secret-when-restricted, fed straight into SetText).
      fs:SetText(getCount(unit, auraID, fs._arcThreshold, nil))
    end
  end
end

-- ───────────────────────────────────────────────────────────────────────────
-- CLEAR: hide/empty all band FontStrings (feature toggled off / native path).
-- ───────────────────────────────────────────────────────────────────────────

function SC.ClearBands(frame)
  if not frame then return end
  frame._arcStackBandsActive = false
  local fsList = frame._arcStackBands
  if fsList then
    for i = 1, MAX_BANDS do
      local fs = fsList[i]
      if fs then
        fs._arcThreshold = nil
        fs:SetText("")
        fs:Hide()
      end
    end
  end
  if frame._arcStackBandContainer then
    frame._arcStackBandContainer:Hide()
  end
end
