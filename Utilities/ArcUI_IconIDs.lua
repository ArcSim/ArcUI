-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Icon IDs (developer hover readout)
--
-- Opt-in toggle that appends an ID block to the tooltip of any icon ArcUI can
-- identify: CDM icons (cooldown ID, spell ID, override/linked, equip slot,
-- spell category, the category's last-used item) and Arc icons (arcID), plus
-- the icon's texture file ID.
--
-- WHY IT IS FRAME-KEYED, not tooltip-data keyed:
--   The Cooldown Reminder's "Spell IDs in Tooltips" rides
--   TooltipDataProcessor post-calls, which only fire for tooltips built from
--   real spell/item DATA. Blizzard's CDM bag-item path
--   (CheckDisplaySpellCategoryTooltip) prefers SetItemByGUID / SetItemByID,
--   but when neither is available -- combat and health potions have no
--   tooltipItemIDFallback, unlike healthstones -- it falls back to plain
--   GameTooltip_SetTitle + AddNormalLine. That tooltip carries NO data type,
--   so no post-call ever fires. That is exactly why the healthstone showed an
--   ID and the combat potion did not. Reading the tooltip's OWNER frame works
--   for every case, including that static-text one.
--
-- TAINT: we only READ fields off Blizzard frames and add our own lines to
-- GameTooltip. No CDM methods are called (calling their mixins from our stack
-- is what made their tooltip code throw on secret item fields), and every
-- value is printed through a secret-safe formatter.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

ns.IconIDs = ns.IconIDs or {}
local IconIDs = ns.IconIDs

local HEADER = "|cff00ccffArcUI IDs|r"
local KEY_COLOR = "|cffffd100"

-- Named spell categories CDM uses for bag items (Blizzard's own lookup).
local CATEGORY_NAMES = {
  [4]    = "combat potion",
  [30]   = "health potion",
  [1711] = "healthstone",
  [2566] = "demonic healthstone",
}

function IconIDs.IsEnabled()
  return ns.db and ns.db.global and ns.db.global.showIconIDs == true
end

function IconIDs.SetEnabled(v)
  if not (ns.db and ns.db.global) then return end
  ns.db.global.showIconIDs = v and true or nil
end

-- Secret-safe: never compare or format a secret, just say so.
local function Val(v)
  if v == nil then return nil end
  if issecretvalue and issecretvalue(v) then return "<secret>" end
  if type(v) == "number" or type(v) == "string" then return tostring(v) end
  if type(v) == "boolean" then return tostring(v) end
  return nil
end

-- Walk up from whatever owns the tooltip (our overlays own it sometimes) to
-- the frame carrying an ArcUI/CDM identity.
local function ResolveIconFrame(owner)
  local f, hops = owner, 0
  while f and hops < 4 do
    if f.cooldownInfo ~= nil or f.cooldownID ~= nil or f._arcAuraID ~= nil then
      return f
    end
    f = f.GetParent and f:GetParent() or nil
    hops = hops + 1
  end
  return nil
end

local function AddLine(tooltip, key, value)
  if value == nil then return end
  tooltip:AddDoubleLine(KEY_COLOR .. key .. "|r", value, 1, 1, 1, 1, 1, 1)
end

-- Label per tooltip data type, for everything that is NOT an ArcUI icon:
-- action bars, buffs and debuffs, bags, spellbook, merchants... anywhere the
-- game builds a tooltip from real data.
local GENERIC_LABELS
local function BuildGenericLabels()
  if GENERIC_LABELS or not (Enum and Enum.TooltipDataType) then return end
  local T = Enum.TooltipDataType
  GENERIC_LABELS = {}
  local map = {
    { T.Spell,        "Spell ID"       },
    { T.Item,         "Item ID"        },
    { T.UnitAura,     "Aura Spell ID"  },
    { T.Toy,          "Toy Item ID"    },
    { T.Mount,        "Mount ID"       },
    { T.Currency,     "Currency ID"    },
    { T.Achievement,  "Achievement ID" },
    { T.Quest,        "Quest ID"       },
  }
  for _, e in ipairs(map) do
    if e[1] then GENERIC_LABELS[e[1]] = e[2] end
  end
end

function IconIDs.Append(tooltip, data)
  if not IconIDs.IsEnabled() then return end
  if not tooltip or not tooltip.GetOwner then return end
  if tooltip:IsForbidden() then return end

  local owner = tooltip:GetOwner()
  local frame = ResolveIconFrame(owner)

  -- GENERIC TOOLTIP (not one of our icons): print what the tooltip's own data
  -- says. This is what makes the toggle work on action bars, buffs, bags and
  -- the spellbook rather than only on ArcUI/CDM icons.
  if not frame then
    if not data then return end
    BuildGenericLabels()
    local label = GENERIC_LABELS and GENERIC_LABELS[data.type]
    local id = data.id
    if not label or id == nil then return end
    if tooltip._arcIDDone and tooltip._arcIDGeneric == id then return end
    tooltip._arcIDFrame = nil
    tooltip._arcIDGeneric = id
    tooltip._arcIDDone = true
    tooltip:AddLine(" ")
    tooltip:AddLine(HEADER)
    AddLine(tooltip, label, Val(id))
    tooltip:Show()
    return
  end

  -- ONE BLOCK PER TOOLTIP BUILD.
  -- The flag is cleared by OnTooltipCleared (ClearLines, i.e. a real rebuild)
  -- and OnHide, so a genuine refresh still re-adds the block. A line-COUNT
  -- guard cannot be used here: any other addon appending its own ID lines
  -- after ours changes the count, which reads as "rebuilt" and appends again,
  -- and the two addons then ping-pong -- that is what produced four stacked
  -- ArcUI ID blocks.
  if tooltip._arcIDDone and tooltip._arcIDFrame == frame then return end
  tooltip._arcIDFrame = frame
  tooltip._arcIDDone = true

  local ci = frame.cooldownInfo
  local arcID = frame._arcAuraID

  tooltip:AddLine(" ")
  tooltip:AddLine(HEADER)

  if arcID then
    AddLine(tooltip, "Arc ID", Val(arcID))
  end
  -- Arc icons reuse cooldownID as their arcID, so only print it when numeric
  local cdID = frame.cooldownID
  if type(cdID) == "number" then
    AddLine(tooltip, "Cooldown ID", Val(cdID))
  end

  if ci then
    AddLine(tooltip, "Spell ID", Val(ci.spellID))
    AddLine(tooltip, "Override Spell", Val(ci.overrideSpellID))
    AddLine(tooltip, "Tooltip Override", Val(ci.overrideTooltipSpellID))
    AddLine(tooltip, "Linked Spell", Val(ci.linkedSpellID))
    AddLine(tooltip, "Equip Slot", Val(ci.equipSlot))
    local cat = ci.spellCategoryID
    if cat then
      local name = CATEGORY_NAMES[cat]
      AddLine(tooltip, "Spell Category", name and (cat .. " (" .. name .. ")") or Val(cat))
      AddLine(tooltip, "Last Used Item", Val(ci.lastItemIDForCategory))
    end
  elseif frame._arcSpellID then
    AddLine(tooltip, "Spell ID", Val(frame._arcSpellID))
  end

  -- equipped item for trinket entries
  local eq = ci and ci.equipSlot
  if eq and GetInventoryItemID then
    AddLine(tooltip, "Equipped Item", Val(GetInventoryItemID("player", eq)))
  end

  -- icon art: a number is a FileDataID, a string is a texture path
  local iconTex = frame.Icon or frame.icon
  if iconTex and not iconTex.GetTexture and iconTex.Icon then iconTex = iconTex.Icon end
  if iconTex and iconTex.GetTexture then
    local tex = iconTex:GetTexture()
    AddLine(tooltip, "Icon ID", Val(tex))
  end

  tooltip:Show()
end

-- ── Wiring ──────────────────────────────────────────────────────────────────
-- Data tooltips (spell / item) go through the post-call; the static-text CDM
-- category tooltip only ever gets shown, so OnShow is the catch-all. The
-- per-frame guard above keeps the two from double-printing.
local function Install()
  if IconIDs._installed then return end
  IconIDs._installed = true

  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    for _, key in ipairs({ "Spell", "Item", "UnitAura", "Toy", "Mount", "Currency", "Achievement", "Quest" }) do
      local dt = Enum.TooltipDataType[key]
      if dt then
        TooltipDataProcessor.AddTooltipPostCall(dt, function(tooltip, data)
          -- protected widget tooltips must never be touched from addon code
          if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then return end
          IconIDs.Append(tooltip, data)
        end)
      end
    end
  end

  -- THE UNIVERSAL HOOK: every tooltip route ends by calling Show() on the
  -- tooltip -- Blizzard's RefreshTooltip does it explicitly on EVERY hover,
  -- even when the tooltip is already on screen, and our own overlay path does
  -- too. OnShow only fires on a hidden->shown transition, which is why moving
  -- between icons (and the potion's static-text tooltip) slipped past it.
  -- Re-entrant by nature (we Show() after adding lines), so it is guarded.
  if GameTooltip and hooksecurefunc then
    hooksecurefunc(GameTooltip, "Show", function(self)
      if IconIDs._inShow then return end
      IconIDs._inShow = true
      IconIDs.Append(self)
      IconIDs._inShow = false
    end)
  end

  if GameTooltip and GameTooltip.HookScript then
    -- reset the per-build guard so the next hover prints again
    GameTooltip:HookScript("OnHide", function(self)
      self._arcIDFrame = nil
      self._arcIDDone = nil
      self._arcIDGeneric = nil
    end)
    if GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipCleared") then
      GameTooltip:HookScript("OnTooltipCleared", function(self)
        self._arcIDDone = nil
        self._arcIDGeneric = nil
      end)
    end
  end
end

-- ── PER-FRAME HOVER HOOK (the reliable path) ────────────────────────────────
-- Tooltip-route hooks are not enough for CDM item entries. A combat potion
-- with nothing matching in bags gets a plain title+text tooltip: no data type
-- (so no post-call) and, when the tooltip is already on screen from another
-- icon, no OnShow either. hooksecurefunc on the frame's own OnEnter fires on
-- every hover regardless of which route Blizzard takes -- and it is the safe
-- kind of hook: it runs AFTER their handler and never taints it.
local function HookFrame(frame)
  if not frame or frame._arcIDHovHooked then return end
  if type(frame.OnEnter) ~= "function" then return end
  frame._arcIDHovHooked = true
  hooksecurefunc(frame, "OnEnter", function(self)
    if not IconIDs.IsEnabled() then return end
    local tooltip = (GetAppropriateTooltip and GetAppropriateTooltip()) or GameTooltip
    if not tooltip then return end
    -- CDM re-anchors its tooltip to the frame, so the owner is already right;
    -- force a fresh block for this frame even if the tooltip never re-showed
    tooltip._arcIDDone = nil
    IconIDs.Append(tooltip)
  end)
end
IconIDs.HookFrame = HookFrame

function IconIDs.Sweep()
  local frames = ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrames
    and ns.CDMEnhance.GetEnhancedFrames()
  if not frames then return end
  for _, data in pairs(frames) do
    local f = type(data) == "table" and data.frame or nil
    if f then HookFrame(f) end
  end
end

local sweepQueued = false
local function QueueSweep(delay)
  if sweepQueued then return end
  sweepQueued = true
  C_Timer.After(delay or 1, function()
    sweepQueued = false
    IconIDs.Sweep()
  end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
  Install()
  -- Catch frames CDM builds or rebinds later (viewer growth, dungeon
  -- rebuilds). Subscribed HERE, not at file scope: this file loads well
  -- before the CDM module, so ns.FrameController does not exist yet then.
  if not IconIDs._rebindHooked and ns.FrameController and ns.FrameController.OnFrameRebind then
    IconIDs._rebindHooked = true
    ns.FrameController.OnFrameRebind(function(frame) HookFrame(frame) end)
  end
  QueueSweep(3)
  QueueSweep(8)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF ArcUI_IconIDs.lua
-- ═══════════════════════════════════════════════════════════════════════════
