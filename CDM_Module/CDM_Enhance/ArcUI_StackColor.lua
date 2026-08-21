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

-- One rec per CDM FRAME (identity-stable across cooldownID remaps — the
-- old cdID-keyed model orphaned overlays every time CDM reassigned frames
-- in M+, leaving stale counts on the wrong icons):
--   overlayRecs[frame] = { cdID, active, dimmed, hooked,
--                          subs = { {unit, container, key, btn} } }
-- Slots are created ONCE per frame (stable key, never regenerated): each
-- container receives exactly one AddAuraSlot while its pool is empty, the
-- proven-safe pattern. Everything else — candidate filters, UpdateAllAuras,
-- native-count alpha — is data-side and legal in ANY context, so overlays
-- can retarget/park/re-arm inside a key.
local overlayRecs = {}

local function AurasSecretNowSC()
  return (C_Secrets and C_Secrets.ShouldAurasBeSecret
      and C_Secrets.ShouldAurasBeSecret()) and true or false
end

local function WantsOverlay(cfg)
  local cht = cfg and cfg.chargeText
  if not cht then return false end
  if cht.enabled == false then return false end
  return cht.showSingleStack == true or cht.thresholdColorEnabled == true
end

-- SINGLE-WRITER contract: ns.CDMEnhance.SetupChargeText asks this on every
-- style pass and re-asserts the native count's hide itself while true. The
-- .c build had two independent alpha writers and the 12.1 secrecy branch
-- restored alpha 1 over a live overlay = TWO counts on one icon in keys.
function SC.IsOverlayActive(frame)
  local rec = frame and overlayRecs[frame]
  return (rec and rec.active) and true or false
end

-- Create-time geometry only; formatter/style land in SetOverlayState (they
-- depend on the frame's CURRENT occupant, which changes over the session).
local function WireOverlayButton(btn, cdmFrame)
  local sh = btn.ArcStackHolder
  local fs = sh and sh.ArcStacks
  if not fs then return end
  btn._arcStacksFS = fs
  btn:ClearAllPoints()
  btn:SetAllPoints(cdmFrame)
  btn:SetFrameStrata(cdmFrame:GetFrameStrata())
  btn:SetFrameLevel((cdmFrame:GetFrameLevel() or 1) + 7)
  if btn.EnableMouse then btn:EnableMouse(false) end
  if sh and sh.SetFrameLevel then
    sh:SetFrameStrata(cdmFrame:GetFrameStrata())
    sh:SetFrameLevel(btn:GetFrameLevel() + 1)
  end
  fs:Show()
end

-- style from chargeText — the same recipe the arc aura icons use, so the
-- overlaid number sits exactly where the user's stack text settings say.
-- Accessible-context only (the fontstring lives in the button partition).
local function StyleOverlayText(btn, cdID)
  local fs = btn._arcStacksFS
  if not fs then return end
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
end

local function IsButtonAccessible(btn)
  if not btn then return false end
  if btn.CanBeAccessedInContext then return btn:CanBeAccessedInContext() end
  return not (btn.IsForbidden and btn:IsForbidden())
end

-- Candidate spell IDs per cooldownID, resolved at DESK time (data-provider
-- reads stay out of restricted contexts) and cached for the whole session —
-- the CDM cooldown set is spec-fixed, so a mid-key retarget always finds its
-- ids here. This is what lets the overlay FOLLOW frame shuffles inside keys.
local idsByCdID = {}

local function ResolveIDs(cdID)
  local ids = idsByCdID[cdID]
  if ids then return ids end
  if AurasSecretNowSC() then return nil end   -- desk-only resolve; cache serves keys
  ids = ns.BarDuration and ns.BarDuration.ResolveCandidateSpellIDs
      and ns.BarDuration.ResolveCandidateSpellIDs(cdID, nil)
  if ids and next(ids) then
    idsByCdID[cdID] = ids
    return ids
  end
  return nil
end

-- Point the overlay at an occupant (cdID + ids) or release it (nil, nil).
-- Legal in ANY context: filter edits (the engine rescans internally), the
-- per-frame formatter's breakpoint rewrite (plain userdata + saved-var
-- reads), and the native-count alpha. Only the SetApplicationCount re-bind
-- and text restyle need an accessible button (desk) — under secrecy the
-- existing binding keeps serving rec.fmt, whose rules we just rewrote.
local function SetOverlayState(f, rec, cdID, ids)
  if cdID and ids then
    rec.cdID = cdID
    rec.active = true
    if rec.fmt and ns.AuraIcons and ns.AuraIcons.ComputeStackBreakpoints then
      rec.fmt:SetBreakpoints(ns.AuraIcons.ComputeStackBreakpoints(cdID))
    end
    for _, sub in ipairs(rec.subs) do
      if sub.container.SetAuraSlotCandidateFilters then
        -- triggers the engine's own UpdateAllAuras internally
        sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = ids })
      end
      local btn = sub.btn
      if btn and btn._arcStacksFS and IsButtonAccessible(btn) then
        StyleOverlayText(btn, cdID)
        btn:SetApplicationCount(btn._arcStacksFS, { formatter = rec.fmt
          or (ns.AuraIcons and ns.AuraIcons.GetLiveFormatter and ns.AuraIcons.GetLiveFormatter(cdID)) })
      end
    end
    if f.Applications then
      f.Applications:SetAlpha(0)
      rec.dimmed = true
    end
  else
    rec.cdID = nil
    rec.active = false
    for _, sub in ipairs(rec.subs) do
      if sub.container.SetAuraSlotCandidateFilters then
        sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = {} })
      end
    end
    if f.Applications and rec.dimmed then
      f.Applications:SetAlpha(1)
      rec.dimmed = nil
    end
  end
end

-- OnCooldownIDSet: the frame's occupant changed. Pool RELEASE clears
-- cooldownID silently (ResetCooldownData writes the field directly — no
-- OnCooldownIDSet, source-verified), so this only fires on ASSIGNMENT — and
-- after a release the same-ID guard in SetCooldownID never suppresses it,
-- meaning every reacquire lands here, including frame SHUFFLES (CDM rebuilds
-- reassign cooldownIDs across frames constantly in keys). With the per-frame
-- formatter + the desk-cached ids, a retarget is fully legal under secrecy —
-- the first cut parked instead and one shuffle killed the overlay for the
-- rest of the dungeon ("stack count goes away completely"). Only a cdID with
-- no cached ids (cannot happen mid-key: the set is spec-fixed) degrades to
-- the native count.
function SC.RetargetFrame(f)
  local rec = overlayRecs[f]
  if not rec then return end
  local cdID = f.cooldownID
  local cfg = (type(cdID) == "number") and ns.CDMEnhance
      and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(cdID) or nil
  if cfg and WantsOverlay(cfg) then
    local ids = ResolveIDs(cdID)
    if ids then
      SetOverlayState(f, rec, cdID, ids)
      return
    end
  end
  SetOverlayState(f, rec, nil, nil)
end

-- Containers + slots + remap hook for a frame, created ONCE (desk only —
-- caller gates). Each container gets its single AddAuraSlot while fresh.
local function EnsureOverlayInfra(f)
  local rec = overlayRecs[f]
  if rec then return rec end
  rec = { subs = {} }
  -- PER-FRAME formatter object: bound once to this frame's overlay button,
  -- rules rewritten on every retarget/settings settle. A registry-shared
  -- per-cdID object could not follow mid-key frame shuffles (re-binding
  -- needs an accessible button; rewriting rules is legal anywhere, and
  -- mutating a shared object would corrupt its other consumers).
  if C_StringUtil and C_StringUtil.CreateNumericRuleFormatter then
    rec.fmt = C_StringUtil.CreateNumericRuleFormatter()
  end
  overlayRecs[f] = rec
  for _, unit in ipairs({ "player", "target" }) do
    local ckey = "_arcSCOv_" .. unit
    local cont = f[ckey]
    if not cont then
      cont = CreateFrame("AuraContainer", nil, f, "CustomAuraContainerTemplate")
      if not (cont and cont.AddAuraSlot) then
        overlayRecs[f] = nil
        return nil
      end
      cont:SetUnit(unit)
      cont:SetEnabled(true)
      cont:SetPoint("CENTER", f, "CENTER", 0, 0)
      cont:SetSize(1, 1)
      cont:Show()
      -- Show Icon off (force-hide) holds the frame at alpha 0 and floats the
      -- text widgets — a container born AFTER the toggle must float too, or
      -- the count is invisible until the next full style pass
      if f._arcForceHideActive and cont.SetIgnoreParentAlpha then
        cont:SetIgnoreParentAlpha(true)
      end
      f[ckey] = cont   -- _arc* field on a Blizzard frame: taint-safe
    end
    local key = "arcscov_" .. unit
    local sub = { unit = unit, container = cont, key = key }
    if not cont._arcSlotAdded then
      cont._arcSlotAdded = true
      -- target lane = OWN debuffs only (|PLAYER): the CDM icon under this
      -- overlay tracks the player's aura, so counting another player's
      -- stacks of the same debuff would disagree with the icon itself
      sub.btn = cont:AddAuraSlot(key, (unit == "player") and "HELPFUL" or "HARMFUL|PLAYER", {
        maxFrameCount    = 1,
        candidateFilters = { includeSpellIDs = {} },   -- parked until targeted
        templateNames    = { "ArcBarDurButtonTemplate" },
        initializeFrame  = function(b) WireOverlayButton(b, f) end,
      })
    end
    table.insert(rec.subs, sub)
  end
  if not rec.hooked and f.OnCooldownIDSet then
    rec.hooked = true
    hooksecurefunc(f, "OnCooldownIDSet", function(self)
      -- defer one frame so CDM's own aura linking completes first
      C_Timer.After(0, function() SC.RetargetFrame(self) end)
    end)
  end
  return rec
end

-- Target-unit containers do NOT self-refresh on a target SWAP (only on
-- UNIT_AURA of the token) — without this the old target's count sticks on
-- the icon ("shows a 1 until it resets itself"). Same gap the arc aura
-- icons module closes with its own watcher.
local swapWatcher = CreateFrame("Frame")
swapWatcher:RegisterEvent("PLAYER_TARGET_CHANGED")
swapWatcher:SetScript("OnEvent", function()
  for _, rec in pairs(overlayRecs) do
    if rec.active then
      for _, sub in ipairs(rec.subs) do
        if sub.unit == "target" and sub.container.UpdateAllAuras then
          sub.container:UpdateAllAuras()
        end
      end
    end
  end
end)

-- Infra creation is desk-only — QUEUE under secrecy and flush on regen/zone
-- (a silent skip left mid-combat toggles dead until reload). The STATE pass
-- inside RefreshOverlays still runs under secrecy, so existing overlays
-- follow settings/occupant changes even mid-key.
local overlayPending = false
local overlayFlush = CreateFrame("Frame")
overlayFlush:RegisterEvent("PLAYER_REGEN_ENABLED")
overlayFlush:RegisterEvent("PLAYER_ENTERING_WORLD")
overlayFlush:SetScript("OnEvent", function()
  if overlayPending and not AurasSecretNowSC() then
    overlayPending = false
    SC.RefreshOverlays()
  end
end)

function SC.RefreshOverlays()
  local GetEnhancedFrames = ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrames
  local GetIconSettings   = ns.CDMEnhance and ns.CDMEnhance.GetIconSettings
  if not (GetEnhancedFrames and GetIconSettings) then return end
  local frames = GetEnhancedFrames()
  if not frames then return end

  -- STATE PASS (legal in any context): re-point every existing overlay at
  -- its frame's CURRENT occupant + current settings. This is what makes a
  -- mid-key settings change take effect on already-built overlays.
  for f in pairs(overlayRecs) do
    SC.RetargetFrame(f)
  end

  -- INFRA PASS (desk only): containers/slots/hooks for newly-wanted frames.
  if AurasSecretNowSC() then
    overlayPending = true
    return
  end
  for cdID, data in pairs(frames) do
    local f = data.frame
    if f and data.viewerType == "aura" and type(cdID) == "number"
       and not overlayRecs[f] then
      local cfg = GetIconSettings(cdID)
      if WantsOverlay(cfg) then
        -- ResolveIDs caches into idsByCdID — the bank mid-key retargets draw from
        local ids = ResolveIDs(cdID)
        if ids then
          local rec = EnsureOverlayInfra(f)
          if rec then SetOverlayState(f, rec, cdID, ids) end
        end
      end
    end
  end
end

-- ── DIAGNOSTICS (/arcstacks, defined in ArcUI_ArcAurasAuraIcons.lua) ────────

function SC.DebugDump(chtSummary)
  print("|cffFFD100-- CDM count overlays --|r")
  local n = 0
  for f, rec in pairs(overlayRecs) do
    n = n + 1
    local nativeA = f.Applications and string.format("%.2f", f.Applications:GetAlpha()) or "-"
    local cht = (type(f.cooldownID) == "number" and chtSummary) and chtSummary(f.cooldownID) or ""
    local idsCached = type(rec.cdID) == "number" and idsByCdID[rec.cdID] ~= nil
    print(string.format("  %s cdID=%s recCd=%s active=%s dimmed=%s fmt=%s ids=%s nativeAlpha=%s subs=%d  %s",
      f:GetName() or tostring(f), tostring(f.cooldownID), tostring(rec.cdID),
      tostring(rec.active or false), tostring(rec.dimmed or false),
      tostring(rec.fmt ~= nil), tostring(idsCached), nativeA, #rec.subs, cht))
  end
  if n == 0 then print("  (no overlays)") end
end

-- Caller attribution on the native count's SetAlpha — catches any writer
-- fighting the overlay's hide (debugstack is secret-gated, DesatLab pattern).
local alphaWatch = false
function SC.ToggleAlphaWatch()
  alphaWatch = not alphaWatch
  print("|cff00CCFF[ArcStacks]|r native-count alpha watch: " .. (alphaWatch and "ON" or "OFF"))
  if not alphaWatch then return end
  for f in pairs(overlayRecs) do
    local app = f.Applications
    if app and not app._arcSCAlphaWatchHooked then
      app._arcSCAlphaWatchHooked = true
      app._arcSCWatchOwner = f
      hooksecurefunc(app, "SetAlpha", function(self, a)
        if not alphaWatch then return end
        local stack = debugstack and debugstack(3, 3, 0) or "?"
        if issecretvalue and issecretvalue(stack) then stack = "<secret caller>" end
        if issecretvalue and issecretvalue(a) then a = "<secret>" end
        local owner = self._arcSCWatchOwner
        print(string.format("|cffFF8800[ArcStacks]|r cdID=%s Applications:SetAlpha(%s) from:\n%s",
          tostring(owner and owner.cooldownID), tostring(a), tostring(stack)))
      end)
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


-- CONTAINER REPAIR (12.1 engine bug -- full write-up in ns.CDMShared).
-- Stack overlays hold one container per unit per frame. Cycle them, then
-- re-push the ACTIVE overlay's candidate ids; an inactive overlay keeps its
-- released (empty) filter, which is already the correct state for it.
-- MUST live INSIDE the IS_121_SC block: overlayRecs and ResolveIDs are locals
-- scoped to it, and a copy of this placed after the closing `end` compiled fine
-- and then failed at runtime with "bad argument #1 to 'pairs'" because the
-- reference resolved to a nil GLOBAL instead.
function ns.StackColor.RepairContainers()
  local Sh = ns.CDMShared
  for _, rec in pairs(overlayRecs) do
    if rec and rec.subs then
      for _, sub in ipairs(rec.subs) do
        if sub.container then
          if Sh and Sh.RepairAuraContainer then
            Sh.RepairAuraContainer(sub.container)
          end
          if sub.key and sub.container.SetAuraSlotCandidateFilters then
            local ids = (rec.active and type(rec.cdID) == "number") and ResolveIDs(rec.cdID) or nil
            sub.container:SetAuraSlotCandidateFilters(sub.key,
              { includeSpellIDs = ids or {} })
          end
        end
      end
    end
  end
end

if ns.CDMShared and ns.CDMShared.RegisterAuraContainerRepair then
  ns.CDMShared.RegisterAuraContainerRepair(ns.StackColor.RepairContainers)
end
end -- IS_121_SC
