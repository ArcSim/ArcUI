-- ===================================================================
-- ArcUI_Changelog.lua
-- "What's New" window. On the first login after an ArcUI update it pops a
-- styled changelog so players see what changed (the same notes we post on
-- CurseForge). Shown once per version; can be turned off in Settings, or
-- reopened any time via the "View Changelog" button / /arcchangelog.
--
-- TO UPDATE EACH RELEASE: add a new entry at the TOP of ns.Changelog.versions
-- (newest first) mirroring the CurseForge changelog. That's the only edit.
-- ===================================================================

local ADDON, ns = ...
ns = ns or {}
ns.Changelog = ns.Changelog or {}
local CL = ns.Changelog

-- Section colours (header tint).
local C_NEW   = "ff4ade80"  -- green  — New Features
local C_IMP   = "ff60a5fa"  -- blue   — Improvements
local C_FIX   = "fffbbf24"  -- amber  — Bug Fixes
local C_BRAND = "ff00ccff"  -- ArcUI cyan
local C_TITLE = "ffffffff"  -- entry title
local C_DESC  = "ffb0b0b0"  -- entry description

-- ===================================================================
-- CHANGELOG CONTENT  (newest version first)
-- Each version: { version = "x.y.z", sections = { { header, color, items = {
--   { title = "...", desc = "..." }, ... } } } }
-- ===================================================================
CL.versions = {
  {
    version = "3.7.5",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Aura Textures", desc = "A new Buffs/Debuffs display type. Place any image on screen that turns on when a buff or debuff is active and off when it's gone. Pick from a built-in art gallery or your own file, drag and resize it in place, and optionally make it drain like a bar as the aura runs down, pulse, fade as it expires, or show a built-in countdown, with per-spec/talent and Hide When conditions." },
          { title = "Duration Text Threshold Colors", desc = "Aura bars and Aura Textures can recolor their remaining-time countdown through seconds-based thresholds, so the number changes color as the aura nears expiry." },
          { title = "Stack Threshold Colors", desc = "Color a tracked buff's stack number by how many stacks are up, with up to six adjustable count-and-color bands, working even in Mythic+ and instances." },
          { title = "Show Icon Toggle", desc = "A new per-icon switch hides the icon art, swipe and flash while keeping just the stack and duration text, for clean text-only trackers." },
          { title = "Desaturate When Aura Inactive", desc = "A new per-cooldown-icon option grays out the icon whenever its tracked buff drops, for an at-a-glance signal that the buff is down." },
          { title = "Kick Assist Smart Open", desc = "An opt-in mode that, after a ready check, briefly watches party chat and only opens the marker picker if someone else calls out your marker, so you only re-pick when there's an actual clash." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Reorganized Options Menu", desc = "Settings are regrouped for clarity, with a Buffs/Debuffs section gathering the aura Catalog, Textures and Appearance, and a dedicated Cooldowns section gathering Cooldown Bars, Custom Bars and Cooldown Reminder." },
          { title = "Bars Stay Out of the Way", desc = "Cooldown, charge, resource, custom and timer bars are now click-through during normal play and only become draggable while the options panel is open, so they no longer intercept clicks in combat." },
          { title = "Bar Name Text Fine-Tuning", desc = "Buff and debuff bars now expose X and Y offset on their name text, so you can nudge it after choosing a left, center or right position." },
          { title = "Cooldown Display Stability", desc = "Further back-end hardening of the cooldown icon display to reduce the chance of it breaking partway through Mythic+ or other instanced content." },
          { title = "Kick Marker Stays on Your Focus", desc = "Your interrupt marker is always placed on your focus and stays there, so re-pressing your kick key never moves it onto your current target." },
          { title = "Account-Wide Kick Assist Toggle", desc = "Turning Kick Assist on or off now applies to all your characters, with your existing setting carried over automatically." },
          { title = "Clearer Marker Macro Wording", desc = "Macro templates and the editor use a clearer marker placeholder and a renamed Add / Sync Marker Line button; older macros keep working." },
          { title = "Clearer Dynamic Cooldowns Help", desc = "The Dynamic Cooldowns option now explains that an icon only collapses out of the row when its alpha is set to 0, and points you to the exact setting." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Bar Text Alignment", desc = "Left- and right-aligned bar name and duration text now pin their first character to the chosen edge instead of centering on it, so long names read correctly and no longer drift." },
          { title = "Resource Text Color in Instances", desc = "Fixed resource bar value text that could break its threshold coloring inside dungeons, raids and PvP." },
          { title = "Self-Buff Icons Display Correctly", desc = "Cooldown icons, custom labels and glows that track a personal self-buff (like Voidfall) now correctly recognize the buff as active instead of treating it as missing." },
        },
      },
    },
  },
  {
    version = "3.7.4",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Kick Assist", desc = "A built-in interrupt helper in its own tab. Claim your kick raid marker, have it automatically called out to your group on a ready check, and drag ready-made one-press interrupt macros straight onto your bars. Pick which instances it triggers in: Mythic+, Mythic, Heroic, Normal, or Raids. Also available as a separate addon if you want just this without ArcUI." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Smoother Bars", desc = "Bar and resource animations no longer do work every frame. Rune fill updates are throttled and go idle when all runes are ready, lowering background CPU use during play." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Duration Text on Refresh", desc = "Buff and debuff bar countdowns now update correctly when a buff is refreshed, for example Bone Shield, instead of freezing on the old time." },
        },
      },
    },
  },
  {
    version = "3.7.3",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Patch 12.1 Support", desc = "ArcUI is now compatible with patch 12.1. That patch is brand new, so some new errors may show up there that did not happen before; please report anything you run into so it can be fixed quickly." },
          { title = "Share Castbar Across Characters", desc = "Optional setting, off by default, that uses one castbar look on every character, starting from the castbar you already have set up, with each character keeping its own on-screen position unless you also share the position." },
          { title = "Castbar Import and Export", desc = "Share your full castbar setup as a string and load it on another character, or bundle it into your bars export so colors, fonts, per-cast-type profiles, thresholds, and position travel together." },
          { title = "Import a Castbar as a Saved Skin", desc = "When a shared string includes a castbar, the import lets you either replace your live castbar or save the incoming one as a named skin you can apply later." },
          { title = "Hide Blizzard Castbar", desc = "Optional toggle, off by default, that hides the default Blizzard castbar, and turning it back on restores the bar without reloading." },
          { title = "Movable Spell Icon", desc = "Optional setting, off by default, that lets you drag the castbar's spell icon to a custom position while the options panel is open, with a reset button to restore it." },
          { title = "Shorten Long Spell Names", desc = "Optional setting, off by default, that trims spell names longer than a chosen length so they fit on the castbar." },
          { title = "Resource Bar Text Color by Value", desc = "Optional, off by default: resource bar value text can change color based on how full the resource is, with up to four color zones plus a base color and a choice of Fill or Drain direction." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Lighter Casting Updates", desc = "The castbar now listens only for your own casting events, reducing background work during play." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Cooldown Display Stability", desc = "Back-end fixes to make the cooldown display less likely to stop working partway through a dungeon or raid." },
          { title = "Cooldown Group Positioning", desc = "Back-end improvements to cooldown group icon placement, to help reduce icons doubling up, overlapping, or leaving stray empty gaps after talent changes, when opening the options panel, or on login." },
          { title = "Castbar No Longer Lingers After a Failed Cast", desc = "The castbar now correctly clears when a cast is rejected, queued, or fails instead of staying on screen." },
        },
      },
    },
  },
  {
    version = "3.7.2",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Castbar", desc = "A brand-new player cast bar, with per-cast-type profiles, an optional Auto Share toggle so one cast type's look carries across the others, full support for empowered spells (proper stage segments and timing), and threshold-based color changes. Big thanks to Sadraii, who created the original cast bar module this was expanded from." },
          { title = "Dynamic Cooldowns", desc = "A new per-group option that compacts your cooldown icons the same way Dynamic Auras does: icons drop out and the rest slide together based on whether they're ready or on cooldown. Works hand-in-hand with Dynamic Auras." },
          { title = "Smooth Movement", desc = "When a dynamic group rearranges, icons now glide smoothly into their new spot instead of snapping, with an adjustable speed. Opt-in per group." },
          { title = "Icon Order: First Come, First Served", desc = "Choose how a dynamic group orders its icons: classic Priority order, or First Come First Served, where the icon that became active first keeps its spot and new ones line up after it instead of everything reshuffling." },
          { title = "Custom Icon Stacks: Start Full & Recharge", desc = "Custom timer icons can now show full stacks from the start before the first cast, plus a new \"Timer Complete\" generator with \"Recharge until full\" to build charge-style stack behavior." },
          { title = "What's New Window", desc = "ArcUI now shows a changelog after each update so you always know what changed. Toggle it off in Settings." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Bar Performance", desc = "The buff/debuff/stack bar tracking engine was rebuilt from the ground up for smoother updates and noticeably lower CPU use, especially when tracking lots of auras at once." },
          { title = "Lower CPU Spikes", desc = "Big reductions in the CPU hitch when leaving combat and when players join your party or raid." },
          { title = "Cleaner Custom Icon Options", desc = "The Custom Icons (timer) settings panel now only shows options that actually apply to timers, with the Active / Not Active states behaving correctly and \"Hide at 0\" working properly for stacks." },
          { title = "Totem Dynamic Placement", desc = "Empty totem slots now collapse and compact with Dynamic Auras, keeping your totem icons tidy." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Reverse Swipe While Aura Active", desc = "Fixed the swipe reverting to its normal direction when you left combat while the aura was still active; it now stays reversed for the full duration." },
          { title = "Charge Spell Placement", desc = "Fixed dynamic placement sometimes failing on charge spells, where an icon wouldn't collapse or return as a charge was spent or came back." },
          { title = "Hide CDM Icon Staying Hidden", desc = "Fixed the Blizzard cooldown frame reappearing when a bar had \"Hide CDM Icon\" turned on: after logging in or reloading, on entering or leaving combat, and when opening the options panel. It now stays hidden at all times, including free-floating icons." },
        },
      },
    },
  },
}

-- ===================================================================
-- HELPERS
-- ===================================================================
local function GetCurrentVersion()
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    return C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
  elseif GetAddOnMetadata then
    return GetAddOnMetadata(ADDON, "Version") or "?"
  end
  return "?"
end

-- Base version with any minor hotfix suffix stripped: "3.7.2.a" -> "3.7.2".
-- The auto-show tracks the BASE version so a minor hotfix (.a/.b) does NOT re-pop
-- the What's New window for players who already saw the base release. Players who
-- never saw the base release still get it (their lastSeen won't match the base),
-- and a hotfix's notes are merged into the base entry so they see those too.
local function GetBaseVersion()
  return (GetCurrentVersion():gsub("%.%a+$", ""))
end

-- Build the coloured body text for ONE version (its sections + items only). The
-- version number lives on the collapsible header row, not in the body.
local function BuildVersionBody(ver)
  local lines = {}
  for _, section in ipairs(ver.sections or {}) do
    lines[#lines + 1] = string.format("|c%s%s|r", section.color or C_TITLE, section.header or "")
    for _, item in ipairs(section.items or {}) do
      if item.desc and item.desc ~= "" then
        lines[#lines + 1] = string.format("  |c%s>|r |c%s%s|r  |c%s%s|r",
          section.color or C_TITLE, C_TITLE, item.title or "", C_DESC, item.desc)
      else
        lines[#lines + 1] = string.format("  |c%s>|r |c%s%s|r",
          section.color or C_TITLE, C_TITLE, item.title or "")
      end
    end
    lines[#lines + 1] = " "
  end
  return table.concat(lines, "\n")
end

-- ===================================================================
-- WINDOW
-- ===================================================================
local frame

local function BuildFrame()
  if frame then return frame end

  local f = CreateFrame("Frame", "ArcUIChangelogFrame", UIParent, "BackdropTemplate")
  f:SetSize(540, 580)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  f:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
  f:SetBackdropBorderColor(0, 0.8, 1, 0.55)
  f:Hide()

  -- Accent bar along the top
  local accent = f:CreateTexture(nil, "ARTWORK")
  accent:SetColorTexture(0, 0.8, 1, 0.85)
  accent:SetPoint("TOPLEFT", 1, -1)
  accent:SetPoint("TOPRIGHT", -1, -1)
  accent:SetHeight(3)

  -- Title
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 18, -16)
  title:SetText(string.format("|c%sArc UI|r  |cffffffffWhat's New|r", C_BRAND))

  local ver = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ver:SetPoint("TOPRIGHT", -38, -20)
  ver:SetText(string.format("|cff888888v%s|r", GetCurrentVersion()))
  f._versionText = ver

  -- Close (X)
  local x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  x:SetPoint("TOPRIGHT", 2, 2)
  x:SetScript("OnClick", function() f:Hide() end)

  -- Divider under the title
  local div = f:CreateTexture(nil, "ARTWORK")
  div:SetColorTexture(1, 1, 1, 0.10)
  div:SetPoint("TOPLEFT", 16, -44)
  div:SetPoint("TOPRIGHT", -16, -44)
  div:SetHeight(1)

  -- Scroll body
  local scroll = CreateFrame("ScrollFrame", "ArcUIChangelogScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -52)
  scroll:SetPoint("BOTTOMRIGHT", -34, 50)

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(470, 10)
  scroll:SetScrollChild(content)
  f._content = content
  f._scroll = scroll

  -- One collapsible block per version: a clickable header row plus the version's
  -- body text. The newest version is expanded by default; older versions start
  -- collapsed and expand when the player clicks their header.
  f._blocks = {}
  for i, verData in ipairs(CL.versions) do
    local block = { ver = verData, expanded = (i == 1) }

    local hdr = CreateFrame("Button", nil, content)
    hdr:SetHeight(22)
    local hbg = hdr:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints()
    hbg:SetColorTexture(1, 1, 1, 0.05)
    hdr._bg = hbg
    local htext = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    htext:SetPoint("LEFT", 4, 0)
    htext:SetJustifyH("LEFT")
    hdr._text = htext
    hdr:SetScript("OnEnter", function(self) self._bg:SetColorTexture(0, 0.8, 1, 0.13) end)
    hdr:SetScript("OnLeave", function(self) self._bg:SetColorTexture(1, 1, 1, 0.05) end)
    hdr:SetScript("OnClick", function()
      block.expanded = not block.expanded
      if f._Relayout then f._Relayout() end
    end)
    block.header = hdr

    local b = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b:SetWidth(452)
    b:SetJustifyH("LEFT")
    b:SetJustifyV("TOP")
    b:SetSpacing(4)
    b:SetText(BuildVersionBody(verData))
    block.body = b

    f._blocks[i] = block
  end

  -- Stack the blocks top-to-bottom, showing each body only while its version is
  -- expanded, then size the scroll child to the total height.
  f._Relayout = function()
    local y = 0
    for i, block in ipairs(f._blocks) do
      local arrow = block.expanded and "|cff00ccff-|r" or "|cff888888+|r"
      local tag = (i == 1) and "   |cff4ade80Latest|r" or ""
      block.header._text:SetText(string.format("%s  |cffffd100Version %s|r%s", arrow, block.ver.version, tag))
      block.header:ClearAllPoints()
      block.header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
      block.header:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
      y = y + 24
      if block.expanded then
        block.body:ClearAllPoints()
        block.body:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -y)
        block.body:Show()
        y = y + (block.body:GetStringHeight() or 0) + 10
      else
        block.body:Hide()
      end
    end
    content:SetSize(470, math.max(y, 10))
    if f._scroll then f._scroll:SetVerticalScroll(0) end
  end

  -- Footer divider
  local fdiv = f:CreateTexture(nil, "ARTWORK")
  fdiv:SetColorTexture(1, 1, 1, 0.10)
  fdiv:SetPoint("BOTTOMLEFT", 16, 42)
  fdiv:SetPoint("BOTTOMRIGHT", -16, 42)
  fdiv:SetHeight(1)

  -- "Show on update" checkbox
  local cb = CreateFrame("CheckButton", "ArcUIChangelogCheck", f, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("BOTTOMLEFT", 14, 12)
  local cbText = _G[cb:GetName() .. "Text"]
  if cbText then cbText:SetText("Show automatically on each update") end
  cb:SetScript("OnClick", function(self)
    local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if g then
      g.changelog = g.changelog or {}
      g.changelog.disabled = not self:GetChecked()
    end
  end)
  f._check = cb

  -- Close button
  local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  close:SetSize(100, 24)
  close:SetPoint("BOTTOMRIGHT", -14, 10)
  close:SetText("Close")
  close:SetScript("OnClick", function() f:Hide() end)

  -- Escape closes it
  if not tContains(UISpecialFrames, "ArcUIChangelogFrame") then
    tinsert(UISpecialFrames, "ArcUIChangelogFrame")
  end

  frame = f
  return f
end

-- Populate + show.
function CL.Show()
  local f = BuildFrame()
  if f._versionText then
    f._versionText:SetText(string.format("|cff888888v%s|r", GetCurrentVersion()))
  end
  -- Open with the newest version expanded and older ones collapsed every time,
  -- so players always land on the latest notes.
  for i, block in ipairs(f._blocks) do block.expanded = (i == 1) end
  f._Relayout()
  -- Reflect the current setting on the checkbox.
  local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
  local disabled = g and g.changelog and g.changelog.disabled
  if f._check then f._check:SetChecked(not disabled) end
  f:Show()
  f:Raise()
end

function CL.Hide()
  if frame then frame:Hide() end
end

function CL.Toggle()
  if frame and frame:IsShown() then frame:Hide() else CL.Show() end
end

-- ===================================================================
-- AUTO-SHOW ON UPDATE
-- ===================================================================
local function CheckOnLogin()
  local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
  if not g then
    -- DB not ready yet (AceDB created at PLAYER_LOGIN) — retry shortly.
    C_Timer.After(2, CheckOnLogin)
    return
  end
  g.changelog = g.changelog or {}
  if g.changelog.disabled then return end

  local cur = GetBaseVersion()   -- base version: minor hotfixes (.a/.b) don't re-pop
  if g.changelog.lastSeen ~= cur then
    g.changelog.lastSeen = cur   -- mark seen so it only pops once per base version
    CL.Show()
  end
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loginFrame:SetScript("OnEvent", function(self)
  -- Fire on the FIRST PLAYER_ENTERING_WORLD (initial login, after the loading
  -- screen has finished) and never again this session — unregister so later
  -- zone/instance loading screens don't re-trigger it.
  self:UnregisterEvent("PLAYER_ENTERING_WORLD")
  -- Small cushion so it lands right after the screen clears, not on its tail.
  C_Timer.After(1, CheckOnLogin)
end)

-- ===================================================================
-- SLASH
-- ===================================================================
SLASH_ARCCHANGELOG1 = "/arcchangelog"
SLASH_ARCCHANGELOG2 = "/arccl"
SlashCmdList["ARCCHANGELOG"] = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "reset" or msg == "test" then
    -- Forget the "seen" version so the popup auto-shows again on next login/reload.
    local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if g then
      g.changelog = g.changelog or {}
      g.changelog.lastSeen = nil
      g.changelog.disabled = false
    end
    print("|cff00ccffArcUI|r: changelog reset \226\128\148 it'll pop automatically on your next /reload (or run /arccl to open it now).")
  else
    CL.Show()
  end
end
