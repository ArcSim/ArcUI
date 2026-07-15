-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Bar Duration Driver  (12.1 ONLY)
--
-- On 12.1 an addon cannot read an aura's remaining duration (the C_UnitAuras
-- durObj APIs throw while tainted+secret), so a duration bar can't be driven the
-- way stack bars are (SetValue of a static secret count). The ONLY object that
-- can legally hold an aura durObj is a Blizzard AuraButton. So we borrow one as an
-- INVISIBLE ENGINE: for each aura duration bar we add an AuraSlot filtered to the
-- CDM entry's candidate spell IDs, whose AuraButton drives our EXISTING bar's
-- StatusBar (SetDurationBar) and, if enabled, our countdown FontString
-- (SetDurationText). The button draws nothing; the container is invisible. So the
-- bar and every appearance option stay ours; only the fill VALUE is driven.
--
-- SPELL-ID RESOLUTION (critical): the buff can land on ANY of base spellID +
-- overrideSpellID + overrideTooltipSpellID + linkedSpellIDs -- info.spellID alone is
-- the CAST spell, not the buff. We resolve the WHOLE candidate set from the CDM
-- cooldownID via C_CooldownViewer.GetCooldownViewerCooldownInfo (C API, taint-safe).
--
-- DUAL-UNIT (critical for debuffs): the CDM frame's auraDataUnit / the user's buff-vs-
-- debuff label CANNOT be trusted to route the aura to player vs target (CDM's selfAura
-- is not a routing flag; e.g. Flame Shock is selfAura=true yet lives on the target). So
-- for EVERY attach we create TWO slots -- player/HELPFUL + target/HARMFUL -- both driving
-- the same bar; whichever unit actually holds the aura populates and drives it, the other
-- stays empty (hidden by the engine). This is the proven AuraLab model. Ref:
-- E:\WoWDev\reference\CDM_cooldownID_to_spellID_resolution.md + ArcUI_AuraLab_Slots.lua.
--
-- Inert on live: the AuraContainer/AuraButton intrinsics don't exist on 12.0.x.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local BD = {}
ns.BarDuration = BD

local IS_121 = (ns.API and ns.API.IS_121) or false
function BD.IsAvailable() return IS_121 end

-- Per-bar trace of what Display saw (populated on live + 12.1 so /arcbardur is always useful).
BD.lastTrace = {}
function BD.Trace(barNumber, info) BD.lastTrace[barNumber] = info end

-- Resolve the FULL candidate spell-ID set a CDM entry's buff can land on. Taint-safe (C API +
-- plain field reads). base + overrideSpellID + overrideTooltipSpellID + linkedSpellIDs + any
-- explicit trackedSpellID. Usable on live too (C_CooldownViewer exists); only ever CALLED on 12.1.
function BD.ResolveCandidateSpellIDs(cooldownID, trackedSpellID)
  local set = {}
  if trackedSpellID and trackedSpellID > 0 then set[trackedSpellID] = true end
  if cooldownID and cooldownID > 0 and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
    if info then
      if info.spellID and info.spellID > 0 then set[info.spellID] = true end
      if info.overrideSpellID and info.overrideSpellID > 0 then set[info.overrideSpellID] = true end
      if info.overrideTooltipSpellID and info.overrideTooltipSpellID > 0 then set[info.overrideTooltipSpellID] = true end
      if info.linkedSpellIDs then
        for _, id in ipairs(info.linkedSpellIDs) do
          if id and id > 0 then set[id] = true end
        end
      end
    end
  end
  return set
end

local function SetKeys(set)
  local t = {}
  for id in pairs(set) do t[#t + 1] = id end
  return table.concat(t, ",")
end

if not IS_121 then
  function BD.Attach() end
  function BD.Detach() end
  function BD.DetachAll() end
  function BD.ApplyStyle() end
  SLASH_ARCBARDUR1 = "/arcbardur"
  SlashCmdList["ARCBARDUR"] = function()
    print("|cff33ff99[ArcBarDur]|r not a 12.1 client -- driver inert (stack bars unaffected).")
    for bn, t in pairs(BD.lastTrace) do
      print(("  bar %s: active=%s hasAuraInfo=%s cooldownID=%s trackedSpellID=%s secret=%s"):format(
        tostring(bn), tostring(t.active), tostring(t.hasAuraInfo), tostring(t.cooldownID), tostring(t.trackedSpellID), tostring(t.secret)))
    end
  end
  return
end

-- ── debug logging ─────────────────────────────────────────────────────────
BD.debug = false
local function Log(fmt, ...)
  if not BD.debug then return end
  local msg = (select("#", ...) > 0) and fmt:format(...) or fmt
  print("|cff33ff99[ArcBarDur]|r " .. msg)
end

local diag = { attachCall = 0, containerNew = 0, slotNew = 0, slotRetarget = 0, initFired = 0, combatDefer = 0, badArgs = 0 }
BD.diag = diag

-- Cached plain-decimal formatters so the engine countdown honours the bar's "Decimals" option
-- (e.g. "10.0" / "10") instead of the engine default ("10 s").
local durFormatters = {}
local function GetDurFormatter(decimals)
  decimals = decimals or 1
  local f = durFormatters[decimals]
  if not f and C_StringUtil and C_StringUtil.CreateNumericRuleFormatter then
    f = C_StringUtil.CreateNumericRuleFormatter()
    f:AddBreakpoint({ threshold = 0, format = "%." .. decimals .. "f" })
    durFormatters[decimals] = f
  end
  return f
end

-- ── state ─────────────────────────────────────────────────────────────────
local containers    = {}   -- [unit] -> AuraContainer
local attached      = {}   -- [barFrame] -> { idKey, cooldownID, spellIDs, subs = {...}, decimals, ... }
local pending       = {}   -- [barFrame] -> { fs, cooldownID, trackedSpellID, unit, opts }
local styleDeferred = {}   -- [barFrame] -> packed ApplyStyle args (buttons forbidden -> re-run on regen)
local seq           = 0

-- One AuraContainer per unit. Created out of combat only (in-combat creation is a Lua error);
-- guarded, so no pcall. Container creation is 12.1-only (IS_121 early-returned above).
local function EnsureContainer(unit)
  local c = containers[unit]
  if c then return c end
  if InCombatLockdown() then Log("EnsureContainer(%s): in combat, deferred", unit); return nil end
  c = CreateFrame("AuraContainer", "ArcBarDurContainer_" .. unit, UIParent, "CustomAuraContainerTemplate")
  if not c then Log("EnsureContainer(%s): CreateFrame returned nil", unit); return nil end
  if c.SetUnit then c:SetUnit(unit) end
  if c.SetEnabled then c:SetEnabled(true) end
  c:ClearAllPoints()
  c:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  c:SetSize(1, 1)
  c:Show()   -- must be shown+enabled to self-register UNIT_AURA
  containers[unit] = c
  diag.containerNew = diag.containerNew + 1
  Log("EnsureContainer(%s): CREATED shown=%s", unit, tostring(c:IsShown()))
  return c
end

-- Wire ONE AuraButton's own ArcBar/ArcTimer regions to overlay barFrame.bar / fs. Called from each
-- slot's initializeFrame; stores the regions on the sub. Multiple subs (player + target) overlay the
-- SAME bar -- only the populated one shows, so the aura is found on whichever unit actually holds it.
local function WireSub(button, barFrame, fs, opts, sub)
  sub.initFired = true
  diag.initFired = diag.initFired + 1
  local ab = button.ArcBar
  local holder = button.ArcTextHolder
  local at = holder and holder.ArcTimer   -- own frame so its LEVEL can go above the border
  sub.button, sub.arcBar, sub.arcTimer, sub.holder = button, ab, at, holder
  local direction     = opts.direction or Enum.StatusBarTimerDirection.RemainingTime
  local interpolation = opts.interpolation or Enum.StatusBarInterpolation.ExponentialEaseOut
  Log("initFrame FIRED key=%s (%s): ArcBar? %s ArcTimer? %s", sub.key, sub.filter, tostring(ab ~= nil), tostring(at ~= nil))

  -- Fill: drive the button's OWN bar (a forbidden region), styled to match our bar's fill.
  -- Skipped in text-only mode (no barFrame.bar): only ArcTimer drives.
  if ab and barFrame.bar and button.SetDurationBar then
    button:SetDurationBar(ab, { interpolation = interpolation, direction = direction })
    local srcTex = barFrame.bar.GetStatusBarTexture and barFrame.bar:GetStatusBarTexture()
    if srcTex and srcTex.GetTexture and ab.SetStatusBarTexture then ab:SetStatusBarTexture(srcTex:GetTexture()) end
    if barFrame.bar.GetOrientation and ab.SetOrientation then ab:SetOrientation(barFrame.bar:GetOrientation()) end
    if barFrame.bar.GetReverseFill and ab.SetReverseFill then ab:SetReverseFill(barFrame.bar:GetReverseFill()) end
    if opts.baseColor and ab.SetStatusBarColor then ab:SetStatusBarColor(opts.baseColor.r, opts.baseColor.g, opts.baseColor.b, opts.baseColor.a or 1) end
    ab:Show()
  end

  -- Countdown text on the button's OWN fontstring, overlaid where our duration text sits.
  if opts.showDuration and fs and at and button.SetDurationText then
    local topts = { zeroDurationText = "", expiredText = "" }
    local fmt = opts.durFormatter or GetDurFormatter(opts.durDecimals)   -- colored (seconds bands) OR plain decimals
    if fmt then topts.formatter = fmt end
    if opts.textColorCurve then topts.textColorCurve = opts.textColorCurve end
    button:SetDurationText(at, topts)
    if at.SetDrawLayer then at:SetDrawLayer("OVERLAY", 7) end
    if opts.durFontPath and at.SetFont then at:SetFont(opts.durFontPath, opts.durFontSize or 18, opts.durOutline) end
    if opts.durationColor and at.SetTextColor then at:SetTextColor(opts.durationColor.r, opts.durationColor.g, opts.durationColor.b, opts.durationColor.a or 1) end
    at:ClearAllPoints(); at:SetPoint("CENTER", fs, "CENTER", 0, 0)
    -- Raise the timer holder to the user's duration-frame level so it draws ABOVE the bar border.
    local dframe = fs.GetParent and fs:GetParent()
    if holder and dframe and holder.SetFrameLevel then
      holder:SetFrameStrata(dframe:GetFrameStrata())
      holder:SetFrameLevel(dframe:GetFrameLevel())
    end
    at:Show()
  end
  if button.EnableMouse then button:EnableMouse(false) end

  -- Anchor the BUTTON itself over the bar HERE, inside initializeFrame -- the
  -- one window PTR5 guarantees the button is not forbidden. Post-init, ANY
  -- API call on it Lua-errors whenever auras are secret (the in-combat
  -- "forbidden object" ClearAllPoints error), so the old post-AddAuraSlot
  -- anchor block cannot exist. Anchors persist through the engine's own
  -- hide/show, and re-attaches always create fresh subs, so once is enough.
  button:ClearAllPoints()
  button:SetAllPoints(barFrame.bar or barFrame)
  button:SetFrameStrata(barFrame:GetFrameStrata())
  button:SetFrameLevel((((barFrame.bar and barFrame.bar:GetFrameLevel()) or barFrame:GetFrameLevel()) or 1) + 1)
end

-- Create one spell-ID-filtered slot on `c` (unit `filter`) that drives barFrame.bar / fs, anchored
-- over the bar. Returns the sub record (or nil if the slot didn't come back).
local function CreateSub(c, filter, spellIDs, barFrame, fs, opts)
  seq = seq + 1
  local key = "arcbardur" .. seq
  local sub = { container = c, filter = filter, key = key, initFired = false }
  local slot = c:AddAuraSlot(key, filter, {
    candidateFilters = { includeSpellIDs = spellIDs },
    templateNames    = { "ArcBarDurButtonTemplate" },
    initializeFrame  = function(button) WireSub(button, barFrame, fs, opts, sub) end,
  })
  if c.UpdateAllAuras then c:UpdateAllAuras() end   -- parse ALREADY-active auras now, not next UNIT_AURA
  -- NO button touches past this point: anchoring/strata/mouse all happen in
  -- WireSub (the initializeFrame window). The returned slot IS forbidden right
  -- now if auras are secret -- storing the reference is fine, calling is not.
  sub.slot = slot
  diag.slotNew = diag.slotNew + 1
  return sub
end

-- BD.Attach(barFrame, fs, cooldownID, trackedSpellID, unit, opts)  -- `unit` is a hint only; both are tried.
function BD.Attach(barFrame, fs, cooldownID, trackedSpellID, unit, opts)
  diag.attachCall = diag.attachCall + 1
  -- barFrame.bar is OPTIONAL (text-only mode, e.g. Aura Textures). barFrame itself is required.
  if not barFrame then diag.badArgs = diag.badArgs + 1; Log("Attach: no barFrame"); return end
  opts = opts or {}
  local idKey = (cooldownID and cooldownID > 0) and cooldownID or trackedSpellID
  if not idKey then diag.badArgs = diag.badArgs + 1; Log("Attach: no cooldownID or trackedSpellID"); return end

  local spellIDs = BD.ResolveCandidateSpellIDs(cooldownID, trackedSpellID)
  if not next(spellIDs) then
    diag.badArgs = diag.badArgs + 1
    Log("Attach: EMPTY candidate set (cd=%s tracked=%s)", tostring(cooldownID), tostring(trackedSpellID))
    return
  end

  local prev = attached[barFrame]
  if prev and prev.idKey == idKey then
    -- same entry: re-target every sub's filter to the (possibly refreshed) candidate set.
    for _, sub in ipairs(prev.subs or {}) do
      if sub.container and sub.key and sub.container.SetAuraSlotCandidateFilters then
        sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = spellIDs })
        if sub.container.UpdateAllAuras then sub.container:UpdateAllAuras() end
      end
    end
    prev.spellIDs = spellIDs
    diag.slotRetarget = diag.slotRetarget + 1
    return
  end

  -- Route by the caller's buff/debuff PICKER (passed as `unit`): buff -> player/HELPFUL, debuff ->
  -- target/HARMFUL. That is the reliable signal; the CDM frame's auraDataUnit is NOT (selfAura
  -- entries like Flame Shock report "player" even though the aura lives on the target).
  unit = unit or "player"
  local c = EnsureContainer(unit)
  if not c or not c.AddAuraSlot then
    diag.combatDefer = diag.combatDefer + 1
    pending[barFrame] = { fs = fs, cooldownID = cooldownID, trackedSpellID = trackedSpellID, unit = unit, opts = opts }
    Log("Attach: container(%s) not ready -> pending (cd=%s)", unit, tostring(cooldownID))
    return
  end
  local assist = (unit == "player") or (UnitCanAssist and UnitCanAssist("player", unit))
  local filter = assist and "HELPFUL" or "HARMFUL"
  local subs = { CreateSub(c, filter, spellIDs, barFrame, fs, opts) }

  attached[barFrame] = {
    idKey = idKey, cooldownID = cooldownID, spellIDs = spellIDs, subs = subs, unit = unit,
    decimals = opts.durDecimals, textColorEnabled = opts.textColorEnabled,
    direction = opts.direction, interpolation = opts.interpolation,
  }
  Log("Attach: %s/%s {%s} (cd=%s)", unit, filter, SetKeys(spellIDs), tostring(cooldownID))
end

function BD.Detach(barFrame)
  pending[barFrame] = nil
  styleDeferred[barFrame] = nil
  local a = attached[barFrame]
  if not a then return end
  attached[barFrame] = nil
  for _, sub in ipairs(a.subs or {}) do
    -- NEVER touch the slot button here: post-init it is FORBIDDEN whenever
    -- auras are secret (PTR5). Parking the include set on a never-matching id
    -- makes the ENGINE release and hide the button itself (engine-side Hide is
    -- always legal, anchors are kept). Container methods stay callable.
    if sub.container and sub.key and sub.container.SetAuraSlotCandidateFilters then
      sub.container:SetAuraSlotCandidateFilters(sub.key, { includeSpellIDs = { [0] = true } })
      if sub.container.UpdateAllAuras then sub.container:UpdateAllAuras() end
    end
  end
end

function BD.DetachAll()
  local list = {}
  for bf in pairs(attached) do list[#list + 1] = bf end
  for _, bf in ipairs(list) do BD.Detach(bf) end
end

-- Re-push the CURRENT fill + text style onto BOTH engine subs so bar options take effect LIVE
-- (called from ApplyAppearance after it styles the real frames), not only after a reload.
function BD.ApplyStyle(barFrame, durationFrame, showDuration, decimals, durationColor, baseColor, fillDirection, durFormatter, textColorEnabled)
  local a = barFrame and attached[barFrame]
  if not a then return end
  -- PTR5: the engine button AND everything we templated into it (ArcBar/
  -- ArcTimer/holder are its CHILDREN) are FORBIDDEN while auras are secret.
  -- NO object probe works: IsForbidden() on the button returned FALSE in-game
  -- while holder:SetFrameStrata threw (the PTR5 state is not the classic
  -- forbidden flag), and data-secrecy probes over/under-gate (AurasSecret is
  -- IS_121-always; forced-CVar desks read secret data while buttons stay
  -- touchable out of combat). The gate is ENVIRONMENTAL: aura secrecy tracks
  -- combat/encounter (thread-confirmed), so defer there; the regen flush
  -- re-applies. Desk styling with forced CVars keeps working out of combat.
  if InCombatLockdown() or (IsEncounterInProgress and IsEncounterInProgress()) then
    styleDeferred[barFrame] = { durationFrame, showDuration, decimals, durationColor, baseColor, fillDirection, durFormatter, textColorEnabled }
    return
  end
  styleDeferred[barFrame] = nil
  local dtext = durationFrame and durationFrame.text
  local formatterChanged = (a.decimals ~= decimals) or (a.textColorEnabled ~= textColorEnabled) or textColorEnabled
  local directionChanged = fillDirection and a.direction ~= fillDirection
  for _, sub in ipairs(a.subs or {}) do
    local ab, at = sub.arcBar, sub.arcTimer
    -- Fill: mirror the freshly-styled real bar's texture/orientation/direction + CONFIGURED base
    -- colour (never barFrame.bar:GetStatusBarColor() -- that's a secret on 12.1 + the dimmed tint).
    if ab and barFrame.bar then
      local srcTex = barFrame.bar.GetStatusBarTexture and barFrame.bar:GetStatusBarTexture()
      if srcTex and srcTex.GetTexture and ab.SetStatusBarTexture then ab:SetStatusBarTexture(srcTex:GetTexture()) end
      if barFrame.bar.GetOrientation and ab.SetOrientation then ab:SetOrientation(barFrame.bar:GetOrientation()) end
      if barFrame.bar.GetReverseFill and ab.SetReverseFill then ab:SetReverseFill(barFrame.bar:GetReverseFill()) end
      if baseColor and ab.SetStatusBarColor then ab:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1) end
    end
    if ab and directionChanged and sub.button and sub.button.SetDurationBar then
      sub.button:SetDurationBar(ab, { interpolation = a.interpolation, direction = fillDirection })
    end
    -- Text: font + colour are cheap direct sets; only re-run SetDurationText (resets the binding)
    -- when the decimals / colour-by-time state changes.
    if at and showDuration then
      if sub.holder and durationFrame and sub.holder.SetFrameLevel then
        sub.holder:SetFrameStrata(durationFrame:GetFrameStrata())
        sub.holder:SetFrameLevel(durationFrame:GetFrameLevel())
      end
      if dtext and at.SetFont then local f, s, fl = dtext:GetFont(); if f then at:SetFont(f, s, fl) end end
      if durationColor and at.SetTextColor then at:SetTextColor(durationColor.r, durationColor.g, durationColor.b, durationColor.a or 1) end
      if formatterChanged and sub.button and sub.button.SetDurationText then
        local fmt = durFormatter or GetDurFormatter(decimals)
        local topts = { zeroDurationText = "", expiredText = "" }
        if fmt then topts.formatter = fmt end
        sub.button:SetDurationText(at, topts)
      end
    end
  end
  if fillDirection then a.direction = fillDirection end
  a.decimals = decimals
  a.textColorEnabled = textColorEnabled
end

-- ── combat deferral + eager container creation + target-swap refresh ─────────
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_TARGET_CHANGED" then
    -- Target containers do NOT self-refresh on target swap (they only react to their own unit's
    -- UNIT_AURA), so a target debuff bar/text goes stale until the new target fires an aura event.
    -- Force a full re-parse of every non-player container. (The exact debuff bug the AuraLab found.)
    for unit, c in pairs(containers) do
      if unit ~= "player" and c.UpdateAllAuras then c:UpdateAllAuras() end
    end
    return
  end
  if InCombatLockdown() then return end
  -- Pre-create BOTH containers out of combat so dual-unit attach never has to defer for creation
  -- (only container CREATION is combat-locked; AddAuraSlot on an existing one is fine mid-combat).
  EnsureContainer("player")
  EnsureContainer("target")
  if next(pending) then
    local q = pending
    pending = {}
    for bf, req in pairs(q) do
      BD.Attach(bf, req.fs, req.cooldownID, req.trackedSpellID, req.unit, req.opts)
    end
  end
  -- Style pushes that arrived while the buttons were forbidden (secret auras):
  -- re-run now; ApplyStyle re-defers itself if secrecy somehow still holds.
  if next(styleDeferred) then
    local q = styleDeferred
    styleDeferred = {}
    for bf, s in pairs(q) do
      BD.ApplyStyle(bf, s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8])
    end
  end
end)

-- ── diagnostics dump / debug toggle ─────────────────────────────────────────
SLASH_ARCBARDUR1 = "/arcbardur"
SlashCmdList["ARCBARDUR"] = function(msg)
  msg = (msg or ""):gsub("%s+", ""):lower()
  if msg == "debug" or msg == "on" then BD.debug = true;  print("|cff33ff99[ArcBarDur]|r debug ON");  return end
  if msg == "off"                 then BD.debug = false; print("|cff33ff99[ArcBarDur]|r debug OFF"); return end

  print("|cff33ff99[ArcBarDur]|r ===== 12.1 duration driver status =====")
  print(("  IS_121=%s  AurasSecret(player)=%s"):format(
    tostring(IS_121), tostring(ns.API and ns.API.AurasSecret and ns.API.AurasSecret("player"))))
  print(("  counters: attachCalls=%d newSlots=%d retargets=%d initFired=%d newContainers=%d combatDefer=%d badArgs=%d"):format(
    diag.attachCall, diag.slotNew, diag.slotRetarget, diag.initFired, diag.containerNew, diag.combatDefer, diag.badArgs))
  for u, c in pairs(containers) do
    print(("  container[%s]: shown=%s alpha=%.1f"):format(u, tostring(c:IsShown()), c:GetAlpha() or -1))
  end
  local nAtt = 0
  for bf, a in pairs(attached) do
    nAtt = nAtt + 1
    local parts = {}
    for _, sub in ipairs(a.subs or {}) do parts[#parts + 1] = sub.filter .. "/init=" .. tostring(sub.initFired) end
    print(("  driving: cooldownID=%s spellIDs={%s} subs=[%s]"):format(
      tostring(a.cooldownID), SetKeys(a.spellIDs), table.concat(parts, "  ")))
  end
  if nAtt == 0 then print("  driving: (none)") end
  print("  --- what Display saw per duration bar (BD.Trace) ---")
  local any = false
  for bn, t in pairs(BD.lastTrace) do
    any = true
    print(("  bar %s: active=%s hasAuraInfo=%s cooldownID=%s trackedSpellID=%s showDuration=%s secret=%s"):format(
      tostring(bn), tostring(t.active), tostring(t.hasAuraInfo),
      tostring(t.cooldownID), tostring(t.trackedSpellID), tostring(t.showDuration), tostring(t.secret)))
  end
  if not any then print("  (no duration-bar updates traced yet -- is the bar active/shown?)") end
end
