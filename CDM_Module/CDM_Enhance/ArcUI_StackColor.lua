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
  -- 12.1: GetAuraApplicationDisplayCount THROWS "cannot be accessed when secret" while the unit's
  -- auras are secret -- and the auraInstanceID stays NON-secret in that state, so gate on the
  -- ns.API.AurasSecret probe, not issecretvalue(auraID). Treat secret as no-aura: clear, bail. Inert on live.
  if not HasAuraInstanceID(auraID) or (ns.API and ns.API.AurasSecret and ns.API.AurasSecret(frame.auraDataUnit or "player")) then
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

-- ═══════════════════════════════════════════════════════════════════════════
-- 12.1 CDM AURA-ICON COUNT OVERLAY (field-proven mechanism, 2026-08-12)
--
-- On 12.1 the layered min-band trick above is walled (the display-count API
-- throws for tainted callers), and CDM's own Applications number is a game-
-- drawn fontstring we can neither re-threshold nor recolor. The proven
-- replacement (live-tested on Arc aura icons the same night): an INVISIBLE
-- engine aura button whose only job is the application count — its fontstring
-- is driven C-side by SetApplicationCount with a banded NumericRuleFormatter
-- (Show at 1 + per-band color escapes), overlaid on the CDM icon while CDM's
-- own count is alpha-hidden (CDM re-asserts SetShown, never alpha).
--
-- Structure per overlaid icon: two tiny AuraContainers (player/HELPFUL +
-- target/HARMFUL — the BD dual-unit model, whichever unit holds the aura
-- populates) PARENTED TO THE CDM FRAME so the overlay inherits every
-- visibility path the icon has (hide-when, force-hide, group alpha) with zero
-- extra plumbing. Candidate spell IDs come from BD.ResolveCandidateSpellIDs
-- (base + override + linked). Buttons reuse ArcBarDurButtonTemplate (already
-- carries ArcStackHolder.ArcStacks). Desk-time rebuild model: slots can't
-- unregister, so refreshes park old generations and add fresh keys.
-- ═══════════════════════════════════════════════════════════════════════════

local IS_121_SC = select(4, GetBuildInfo()) >= 120100
if IS_121_SC then

local overlayGen  = 0
local overlayRecs = {}   -- [cdID] = { frame, subs = {{container, key}}, dimmed }

local function WantsOverlay(cfg)
  local cht = cfg and cfg.chargeText
  if not cht then return false end
  if cht.enabled == false then return false end
  return cht.showSingleStack == true or cht.thresholdColorEnabled == true
end

local function WireOverlayButton(btn, cdmFrame, cdID)
  local sh = btn.ArcStackHolder
  local fs = sh and sh.ArcStacks
  if not fs then return end
  btn:ClearAllPoints()
  btn:SetAllPoints(cdmFrame)
  btn:SetFrameStrata(cdmFrame:GetFrameStrata())
  btn:SetFrameLevel((cdmFrame:GetFrameLevel() or 1) + 7)
  if btn.EnableMouse then btn:EnableMouse(false) end
  local fmt = ns.AuraIcons and ns.AuraIcons.BuildStackFormatter
    and ns.AuraIcons.BuildStackFormatter(cdID)
  btn:SetApplicationCount(fs, { formatter = fmt })
  -- style from chargeText — the same recipe the arc aura icons use, so the
  -- overlaid number sits exactly where the user's stack text settings say
  local cfg = ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(cdID)
  local cht = (cfg and cfg.chargeText) or {}
  local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
  local fontPath = (cht.font and lsm and lsm:Fetch("font", cht.font, true)) or select(1, fs:GetFont())
  local outline = cht.outline or "OUTLINE"
  if outline == "NONE" then outline = "" end
  fs:SetFont(fontPath, cht.size or 16, outline)
  fs:SetDrawLayer("OVERLAY", 7)
  local c = cht.color
  if c then fs:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1) end
  if cht.shadow then
    fs:SetShadowOffset(cht.shadowOffsetX or 1, cht.shadowOffsetY or -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
  else
    fs:SetShadowOffset(0, 0)
  end
  fs:ClearAllPoints()
  if cht.mode == "free" then
    fs:SetPoint("CENTER", btn, "CENTER", cht.freeX or 0, cht.freeY or 0)
  else
    local a = cht.anchor or cht.position or "BOTTOMRIGHT"
    fs:SetPoint(a, btn, a, cht.offsetX or -2, cht.offsetY or 2)
  end
  fs:Show()
  if sh and sh.SetFrameLevel then
    sh:SetFrameStrata(cdmFrame:GetFrameStrata())
    sh:SetFrameLevel(btn:GetFrameLevel() + 1)
  end
end

local function ParkOverlayRec(rec)
  for _, sub in ipairs(rec.subs) do
    if sub.container and sub.container.SetAuraSlotCandidateFilters then
      sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = { [0] = true } })
    end
  end
  wipe(rec.subs)
  if rec.frame and rec.frame.Applications and rec.dimmed then
    rec.frame.Applications:SetAlpha(1)
    rec.dimmed = nil
  end
end

-- Desk-time full rebuild: called at login and from the stack-text setters.
-- Under secrecy (combat/instance) slot creation is illegal — QUEUE and flush
-- on regen/zone (a silent skip left mid-combat toggles dead until reload).
local overlayPending = false
local overlayFlush = CreateFrame("Frame")
overlayFlush:RegisterEvent("PLAYER_REGEN_ENABLED")
overlayFlush:RegisterEvent("PLAYER_ENTERING_WORLD")
overlayFlush:SetScript("OnEvent", function()
  if overlayPending
     and not (C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()) then
    overlayPending = false
    SC.RefreshOverlays()
  end
end)

function SC.RefreshOverlays()
  if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
    overlayPending = true
    return
  end
  local GetEnhancedFrames = ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrames
  local GetIconSettings   = ns.CDMEnhance and ns.CDMEnhance.GetIconSettings
  if not (GetEnhancedFrames and GetIconSettings) then return end
  local frames = GetEnhancedFrames()
  if not frames then return end
  overlayGen = overlayGen + 1
  for _, rec in pairs(overlayRecs) do ParkOverlayRec(rec) end
  for cdID, data in pairs(frames) do
    local f = data.frame
    if f and data.viewerType == "aura" and type(cdID) == "number" then
      local cfg = GetIconSettings(cdID)
      if WantsOverlay(cfg) then
        local ids = ns.BarDuration and ns.BarDuration.ResolveCandidateSpellIDs
          and ns.BarDuration.ResolveCandidateSpellIDs(cdID, nil)
        if ids and next(ids) then
          local rec = overlayRecs[cdID] or { subs = {} }
          rec.frame = f
          overlayRecs[cdID] = rec
          for _, unit in ipairs({ "player", "target" }) do
            local ckey = "_arcSCOv_" .. unit
            local cont = f[ckey]
            if not cont then
              cont = CreateFrame("AuraContainer", nil, f, "CustomAuraContainerTemplate")
              if not (cont and cont.AddAuraSlot) then return end
              cont:SetUnit(unit)
              cont:SetEnabled(true)
              cont:SetPoint("CENTER", f, "CENTER", 0, 0)
              cont:SetSize(1, 1)
              cont:Show()
              f[ckey] = cont   -- _arc* field on a Blizzard frame: taint-safe
            end
            local key = "arcscov" .. cdID .. "_" .. unit .. "_g" .. overlayGen
            cont:AddAuraSlot(key, (unit == "player") and "HELPFUL" or "HARMFUL", {
              maxFrameCount    = 1,
              candidateFilters = { includeSpellIDs = ids },
              templateNames    = { "ArcBarDurButtonTemplate" },
              initializeFrame  = function(b) WireOverlayButton(b, f, cdID) end,
            })
            if cont.UpdateAllAuras then cont:UpdateAllAuras() end
            table.insert(rec.subs, { container = cont, key = key })
          end
          if f.Applications then
            f.Applications:SetAlpha(0)
            rec.dimmed = true
          end
        end
      else
        overlayRecs[cdID] = nil   -- already parked + restored above
      end
    end
  end
end

local scOvLoader = CreateFrame("Frame")
scOvLoader:RegisterEvent("PLAYER_ENTERING_WORLD")
scOvLoader:SetScript("OnEvent", function(self, event)
  self:UnregisterAllEvents()
  -- CDM frames get enhanced/assigned over the first seconds of a session
  C_Timer.After(5, function() SC.RefreshOverlays() end)
end)

end -- IS_121_SC
