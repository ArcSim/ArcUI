-- ===================================================================
-- ArcUI_Textures.lua
-- Aura Textures runtime engine.
--
-- A "texture" is a freely-placeable image on screen that flips between
-- an ACTIVE and an INACTIVE visual style based on whether a tracked
-- buff/debuff is present. It mirrors the buff/debuff bar trigger model
-- (so it can reuse the CDM aura resolution) but is otherwise a small,
-- self-contained, event-driven module -- it does NOT touch the bar
-- aura engine in ArcUI_Core.lua.
--
-- Rendering method (source / blend / desaturate / zoom / crop / mirror /
-- rotation) follows the standard texture-display approach.
-- ===================================================================
local ADDON, ns = ...

ns.Textures = ns.Textures or {}
local Textures = ns.Textures

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- [textureNum] = frame (frame holds frame.tex)
local textureFrames = {}

-- ===================================================================
-- ACTIVE-STATE RESOLUTION (reuses the CDM aura frame lookup)
-- ===================================================================

-- Secret-safe presence test for an auraInstanceID. A secret id means the
-- aura IS present (we just cannot compare it); a non-secret non-zero number
-- means present; nil/0 means absent. Never compares a secret to a number.
local function HasAuraInstanceID(aiid)
  if aiid == nil then return false end
  if issecretvalue and issecretvalue(aiid) then return true end
  if aiid ~= 0 then return true end
  return false
end

-- Returns the CDM frame whose tracked aura is currently present (or nil).
-- Checks the primary cooldownID and any alternate (cross-spec) cooldownIDs.
-- Returning the frame (not just a bool) lets the duration visuals read its
-- auraInstanceID for the secret-safe duration object.
local function FindActiveFrame(cfg)
  local t = cfg and cfg.tracking
  if not t then return nil end
  local find = ns.API and ns.API._FindCDMFrameForCooldownID
  if not find then return nil end
  local function get(cdID)
    if not cdID or cdID == 0 then return nil end
    local frame = find(cdID)
    if frame and HasAuraInstanceID(frame.auraInstanceID) then return frame end
    return nil
  end
  local f = get(t.cooldownID)
  if f then return f end
  if type(t.alternateCooldownIDs) == "table" then
    for _, cd in ipairs(t.alternateCooldownIDs) do
      f = get(cd)
      if f then return f end
    end
  end
  return nil
end

-- ===================================================================
-- DURATION FADE-OUT (secret-safe, via Blizzard ColorCurve alpha)
-- As the tracked aura runs down, the texture's alpha follows a curve.
-- Mirrors the bar duration-color-curve pattern in ArcUI_Display.lua.
-- ===================================================================

-- The duration object for the resolved aura (or nil if no live duration).
local function GetDurObjFor(cfg, activeFrame)
  if not activeFrame then return nil end
  if not (C_UnitAuras and C_UnitAuras.GetAuraDuration) then return nil end
  local aiid = activeFrame.auraInstanceID
  if not HasAuraInstanceID(aiid) then return nil end
  local unit = (cfg.tracking and cfg.tracking.trackType == "debuff") and "target" or "player"
  if C_UnitAuras.GetAuraDataByAuraInstanceID and not C_UnitAuras.GetAuraDataByAuraInstanceID(unit, aiid) then
    return nil
  end
  return C_UnitAuras.GetAuraDuration(unit, aiid)
end

-- Build an alpha curve: invisible at 0% remaining, full alpha at/above the
-- fade-start fraction. rgb stays the active tint; only alpha varies.
local function BuildFadeCurve(r, g, b, fullA, startFrac)
  if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return nil end
  local curve = C_CurveUtil.CreateColorCurve()
  curve:AddPoint(0.0, CreateColor(r, g, b, 0))
  if startFrac > 0.01 and startFrac < 0.999 then
    curve:AddPoint(startFrac, CreateColor(r, g, b, fullA))
  end
  curve:AddPoint(1.0, CreateColor(r, g, b, fullA))
  return curve
end

local function StopFade(frame)
  if frame._arcFadeRunning then
    frame:SetScript("OnUpdate", nil)
    frame._arcFadeRunning = false
    frame._arcFadeData = nil
  end
end

local function StartFade(num, frame, cfg, activeFrame)
  local d = cfg.display
  local ac = d.activeColor or {}
  local r, g, b = ac.r or 1, ac.g or 1, ac.b or 1
  local fullA = tonumber(d.activeAlpha) or 1
  local startFrac = (tonumber(d.fadeStartPct) or 50) / 100
  if startFrac < 0.01 then startFrac = 0.01 elseif startFrac > 1 then startFrac = 1 end

  local hash = string.format("%.3f|%.3f|%.3f|%.3f|%.3f", r, g, b, fullA, startFrac)
  -- Already fading the same instance with the same settings? Leave it running.
  if frame._arcFadeRunning and frame._arcFadeData
     and frame._arcFadeData.frame == activeFrame and frame._arcFadeHash == hash then
    return
  end

  if frame._arcFadeHash ~= hash or not frame._arcFadeCurve then
    frame._arcFadeCurve = BuildFadeCurve(r, g, b, fullA, startFrac)
    frame._arcFadeHash = hash
  end

  local tex = frame.tex
  tex:SetVertexColor(r, g, b, 1)

  local curve = frame._arcFadeCurve
  if not curve then
    -- No curve API available: fall back to a static active alpha (no fade).
    StopFade(frame)
    tex:SetAlpha(fullA)
    return
  end

  local unit = (cfg.tracking and cfg.tracking.trackType == "debuff") and "target" or "player"
  frame._arcFadeData = { unit = unit, frame = activeFrame, curve = curve, fullA = fullA, elapsed = 0, tex = tex }

  local durObj = C_UnitAuras.GetAuraDuration(unit, activeFrame.auraInstanceID)
  if durObj then
    local cr = durObj:EvaluateRemainingPercent(curve)
    if cr then local _, _, _, a = cr:GetRGBA(); tex:SetAlpha(a) else tex:SetAlpha(fullA) end
  else
    tex:SetAlpha(fullA)
  end

  frame._arcFadeRunning = true
  frame:SetScript("OnUpdate", function(self, elapsed)
    local data = self._arcFadeData
    if not data then self:SetScript("OnUpdate", nil); return end
    data.elapsed = data.elapsed + elapsed
    if data.elapsed < 0.05 then return end   -- 20fps throttle, matches the bars
    data.elapsed = 0
    local af = data.frame
    local aiid = af and af.auraInstanceID
    if not HasAuraInstanceID(aiid) then data.tex:SetAlpha(data.fullA); return end
    local durObj2 = C_UnitAuras.GetAuraDuration(data.unit, aiid)
    if not durObj2 then data.tex:SetAlpha(data.fullA); return end
    local cr2 = durObj2:EvaluateRemainingPercent(data.curve)
    if cr2 then local _, _, _, a2 = cr2:GetRGBA(); data.tex:SetAlpha(a2) else data.tex:SetAlpha(data.fullA) end
  end)
end

-- ===================================================================
-- LOOPING PULSE (size, via Blizzard AnimationGroup -- no OnUpdate)
-- ===================================================================
-- The pulse is driven by an active-only OnUpdate (set in StartPulse, removed in
-- StopPulse) rather than a Blizzard Scale AnimationGroup. Two C-side attempts both
-- jumped: a single BOUNCE Scale holds the peak value one extra frame (pop at the
-- top), and two ordered grow+shrink Scale animations COMPOUND -- the finished grow
-- leg holds its scale and the shrink leg multiplies ON TOP of it, so the size jumps
-- bigger at the peak and the legs never hand off cleanly. A cosine driver has no
-- legs, no held frames and no compounding: scale flows 1 -> max -> 1 as one smooth
-- curve, so it can't jump. This is how WeakAuras drives its pulse. It runs ONLY
-- while a tracked aura is active + Pulse is on (same active-only pattern as the
-- duration fade ticker), so it is not idle CPU.
local TWO_PI = 2 * math.pi
local function PulseOnUpdate(self, elapsed)
  local t = (self._arcPulseT or 0) + elapsed
  local period = self._arcPulsePeriod or 1
  if t >= period then t = t % period end
  self._arcPulseT = t
  -- 0 at t=0 (resting size), 1 at the half-period (max size), back to 0 at the
  -- period end. Cosine, so the velocity is continuous too -- no kink at either
  -- extreme, and the loop seam is the resting size (scale 1), never the peak.
  local phase = (1 - math.cos((t / period) * TWO_PI)) * 0.5
  self:SetScale(1 + (self._arcPulseAmp or 0) * phase)
end

local function StopPulse(frame)
  local vis = frame._arcVis or frame
  vis:SetScript("OnUpdate", nil)
  vis._arcPulsing = false
  vis:SetScale(1)
  frame:SetScale(1)   -- safety: clear any residual host-frame scale (older builds pulsed the frame)
end

local function StartPulse(frame, cfg)
  local d = cfg.display
  -- Pulse the visual wrapper, NOT the host frame, so only the image scales --
  -- the grips, Drain Start marker and duration text (on the host frame) stay put.
  local vis = frame._arcVis or frame
  local target = tonumber(d.pulseScale) or 1.15
  if target < 0.5 then target = 0.5 elseif target > 3 then target = 3 end
  local dur = tonumber(d.pulseSpeed) or 0.5
  if dur < 0.1 then dur = 0.1 elseif dur > 5 then dur = 5 end
  -- One full cycle = grow for `dur` then shrink for `dur`.
  local amp, period = target - 1, dur * 2
  -- UpdateTexture calls this on every aura event; if already pulsing with the same
  -- settings, leave the phase running so refreshes never snap it.
  if vis._arcPulsing and vis._arcPulseAmp == amp and vis._arcPulsePeriod == period then
    return
  end
  vis._arcPulseAmp = amp
  vis._arcPulsePeriod = period
  vis._arcPulseT = 0          -- start a clean cycle from the resting size
  vis._arcPulsing = true
  vis:SetScale(1)
  vis:SetScript("OnUpdate", PulseOnUpdate)
end

-- ===================================================================
-- LOAD GATES (spec / combat)
-- ===================================================================
local function GetCurrentSpec()
  if ns.Display and ns.Display.GetCachedSpec then
    local s = ns.Display.GetCachedSpec()
    if s then return s end
  end
  return (GetSpecialization and GetSpecialization()) or 0
end

local function SpecOK(cfg)
  local b = cfg and cfg.behavior
  if not b then return true end
  if type(b.showOnSpecs) == "table" and #b.showOnSpecs > 0 then
    local cur = GetCurrentSpec()
    for _, spec in ipairs(b.showOnSpecs) do
      if spec == cur then return true end
    end
    return false
  elseif b.showOnSpec and b.showOnSpec > 0 then
    return GetCurrentSpec() == b.showOnSpec
  end
  return true
end

-- Drain direction -> hidden-bar orientation/reverse + how the reveal mask anchors.
-- The mask spans from the bar fill's MOVING edge (fillCorner, anchored to the bar
-- fill texture) to the frame's FIXED edge (frameCorner). As the bar drains, the
-- fill's moving edge sweeps and the mask shrinks, revealing the in-place foreground
-- directionally -- the texture itself never moves. fillOff nudges the moving edge
-- ~1px so the mask never collapses to zero (a zero-size mask stops masking).
local PROGRESS_DIRS = {
  TOP_TO_BOTTOM = { orient = "VERTICAL",   reverse = false,
    fillCorner = "TOPLEFT",     frameCorner = "BOTTOMRIGHT", fillOffX = 0,  fillOffY = 1  },
  BOTTOM_TO_TOP = { orient = "VERTICAL",   reverse = true,
    fillCorner = "BOTTOMRIGHT", frameCorner = "TOPLEFT",     fillOffX = 0,  fillOffY = -1 },
  RIGHT_TO_LEFT = { orient = "HORIZONTAL", reverse = false,
    fillCorner = "BOTTOMRIGHT", frameCorner = "TOPLEFT",     fillOffX = 1,  fillOffY = 0  },
  LEFT_TO_RIGHT = { orient = "HORIZONTAL", reverse = true,
    fillCorner = "TOPLEFT",     frameCorner = "BOTTOMRIGHT", fillOffX = -1, fillOffY = 0  },
}

-- Rotation for a texture (the manual Rotate angle, in radians). Works in BOTH
-- static and drain now that the foreground is a normal, rotatable texture (the
-- mask-based drain no longer relies on a StatusBar fill visual).
local function EffectiveRotation(d)
  return (d.rotateEnabled == true) and (math.rad(tonumber(d.rotation) or 0)) or 0
end

-- Drain region: inset fractions -> a centered sub-rectangle (frame-local). Returns
-- center offset (x right, y up), size, and whether it's smaller than the texture.
local function DrainRegion(d, w, h)
  local l = math.max(0, math.min(0.49, tonumber(d.drainInsetL) or 0))
  local r = math.max(0, math.min(0.49, tonumber(d.drainInsetR) or 0))
  local t = math.max(0, math.min(0.49, tonumber(d.drainInsetT) or 0))
  local b = math.max(0, math.min(0.49, tonumber(d.drainInsetB) or 0))
  local regionW = w * (1 - l - r)
  local regionH = h * (1 - t - b)
  local cx = w * (l - r) * 0.5
  local cy = h * (b - t) * 0.5
  local isSub = (l > 0) or (r > 0) or (t > 0) or (b > 0)
  return cx, cy, regionW, regionH, isSub
end

-- How the CONSUMED-side mask (the depleted band) anchors per drain direction: its
-- fixed corner pins to the region bar's start edge, its moving corner rides the
-- bar fill's boundary edge.
local CONSUMED_ANCHOR = {
  TOP_TO_BOTTOM = { fixed = "TOPLEFT",     moving = "BOTTOMRIGHT", btPoint = "TOPRIGHT" },
  BOTTOM_TO_TOP = { fixed = "BOTTOMRIGHT", moving = "TOPLEFT",     btPoint = "BOTTOMLEFT" },
  RIGHT_TO_LEFT = { fixed = "BOTTOMRIGHT", moving = "TOPLEFT",     btPoint = "TOPRIGHT" },
  LEFT_TO_RIGHT = { fixed = "TOPLEFT",     moving = "BOTTOMRIGHT", btPoint = "BOTTOMLEFT" },
}

-- ===================================================================
-- FRAME POOL
-- ===================================================================
local function EnsureFrame(num)
  local frame = textureFrames[num]
  if frame then return frame end

  frame = CreateFrame("Frame", "ArcUITexture" .. tostring(num), UIParent)
  frame._arcTexNum = num
  frame:SetSize(64, 64)
  frame:Hide()

  -- Visual wrapper: holds ONLY the foreground image so the size pulse scales the
  -- IMAGE alone. The host frame is never scaled, so the editor grips, the Drain
  -- Start marker, the duration text, the ghost backdrop, and the drain bar/mask/
  -- region pieces (all parented to the host frame) hold still while the texture
  -- pulses. The foreground keeps anchoring to `frame` -- position is anchor-driven
  -- and `vis` overlays the frame exactly, while the pulse scale is inherited from
  -- `vis` (the parent), so only the image grows/shrinks about its own centre.
  -- (The ghost stays on the host frame so region-drain layering is preserved: it
  -- must render BELOW the solid "rest" pieces, which also live on the frame.)
  local vis = CreateFrame("Frame", nil, frame)
  vis:SetAllPoints(frame)
  frame._arcVis = vis

  local tex = vis:CreateTexture(nil, "ARTWORK")
  tex:SetPoint("CENTER", frame, "CENTER", 0, 0)
  tex:SetSize(64, 64)
  tex:SetDrawLayer("ARTWORK", 1)
  frame.tex = tex

  -- Dim full-texture "ghost" backdrop, shown behind the drained foreground.
  local ghost = frame:CreateTexture(nil, "ARTWORK")
  ghost:SetPoint("CENTER", frame, "CENTER", 0, 0)
  ghost:SetSize(64, 64)
  ghost:SetDrawLayer("ARTWORK", 0)   -- below the foreground
  ghost:Hide()
  frame.ghost = ghost

  -- Hidden status bar: a secret-safe TIMING driver only. Its fill texture's
  -- geometry positions the drain mask; the bar's own fill is invisible (alpha 0).
  -- The foreground texture never moves -- the mask reveals it in place.
  local bar = CreateFrame("StatusBar", nil, frame)
  bar:SetAllPoints(frame)
  bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
  bar:SetStatusBarColor(1, 1, 1, 0)
  bar:Hide()
  frame.bar = bar

  -- Mask that reveals the foreground only where the bar fill is (the remaining
  -- region). Re-anchored to the bar fill + frame edge per drain direction.
  local mask = frame:CreateMaskTexture()
  mask:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "NEAREST")
  if mask.SetTexelSnappingBias then mask:SetTexelSnappingBias(0) end
  if mask.SetSnapToPixelGrid then mask:SetSnapToPixelGrid(false) end
  frame.drainMask = mask

  -- REGION DRAIN "rest" pieces: when the drain is confined to a sub-band, the
  -- band itself drains via frame.tex (masked to the REMAINING part, so the used-up
  -- part truly VANISHES). WoW masks can't cut a hole, so the solid rest of the
  -- texture is drawn as up to four copies masked to the strips AROUND the region:
  -- 1=top, 2=bottom, 3=left, 4=right.
  frame.regionPieces = {}
  frame.regionMasks = {}
  for i = 1, 4 do
    local pm = frame:CreateMaskTexture()
    pm:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "NEAREST")
    if pm.SetTexelSnappingBias then pm:SetTexelSnappingBias(0) end
    if pm.SetSnapToPixelGrid then pm:SetSnapToPixelGrid(false) end
    local pt = frame:CreateTexture(nil, "ARTWORK")
    pt:SetDrawLayer("ARTWORK", 1)
    pt:AddMaskTexture(pm)
    pt:Hide()
    frame.regionPieces[i] = pt
    frame.regionMasks[i] = pm
  end

  -- Duration text overlay (secret-safe countdown via ns.DurationText). Its own
  -- child frame so it can sit at a configurable strata/level above the texture.
  local dtf = CreateFrame("Frame", nil, frame)
  dtf:SetSize(40, 20)
  -- Created with a font template so it has a font immediately (SetText errors
  -- otherwise); ApplyDurationTextStyle replaces the font from the config.
  local dtext = dtf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  dtext:SetPoint("CENTER", dtf, "CENTER", 0, 0)
  dtext:SetText("")
  dtf:Hide()
  frame._arcDurFrame = dtf
  frame._arcDurText = dtext

  textureFrames[num] = frame
  return frame
end

-- Hide the four "rest" pieces of the region drain.
local function HideRegionPieces(frame)
  if frame.regionPieces then
    for i = 1, 4 do
      if frame.regionPieces[i] then frame.regionPieces[i]:Hide() end
    end
  end
end

function Textures.HideTexture(num)
  local frame = textureFrames[num]
  if frame then
    StopFade(frame)
    StopPulse(frame)
    if frame.bar then frame.bar:Hide() end
    if frame.ghost then frame.ghost:Hide() end
    HideRegionPieces(frame)
    if frame._arcDurFrame then
      if ns.DurationText and ns.DurationText.Unbind then ns.DurationText.Unbind(frame._arcDurText) end
      frame._arcDurFrame:Hide()
    end
    frame._arcDrainSeeded = false   -- re-seed the drain timer on next activation
    frame._arcDrainFrame = nil
    frame._arcWasActive = false
    frame._arcRevealToken = (frame._arcRevealToken or 0) + 1   -- cancel any pending reveal
    frame:Hide()
    frame:EnableMouse(false)
  end
end

-- ===================================================================
-- ON-SCREEN RESIZE (corner grips resize both axes; edge grips stretch
-- one axis -- lengthen/widen; symmetric about center; optional aspect
-- lock). Grips show only while the options panel is open and this is
-- the selected texture.
-- ===================================================================
local GRIP_SIZE = 14
-- Unit offset of each grip from the frame center (x right, y up); rotated by the
-- texture's angle so the grips sit on the texture's actual corners/edges.
local GRIP_OFFSET = {
  TOPLEFT = { -1, 1 }, TOPRIGHT = { 1, 1 }, BOTTOMLEFT = { -1, -1 }, BOTTOMRIGHT = { 1, -1 },
  LEFT = { -1, 0 }, RIGHT = { 1, 0 }, TOP = { 0, 1 }, BOTTOM = { 0, -1 },
}
-- Editor-only "Drain Start" marker: the frame edge the drain STARTS at, the
-- rotation that points the (right-pointing) chevron toward the sweep direction,
-- and the outward direction to place the text label.
local DRAIN_ARROW = {
  TOP_TO_BOTTOM = { anchor = "TOP",    rot = -math.pi / 2, lx = 0,  ly = 1  },
  BOTTOM_TO_TOP = { anchor = "BOTTOM", rot =  math.pi / 2, lx = 0,  ly = -1 },
  LEFT_TO_RIGHT = { anchor = "LEFT",   rot =  0,           lx = -1, ly = 0  },
  RIGHT_TO_LEFT = { anchor = "RIGHT",  rot =  math.pi,     lx = 1,  ly = 0  },
}
local resizing = nil          -- { num, frame, axis, rot, lockAspect, ratio }
local sizerDriver
local EndResize               -- forward declaration (the ticker ends the drag)

local function EnsureSizerDriver()
  if sizerDriver then return end
  sizerDriver = CreateFrame("Frame")
  sizerDriver:Hide()
end

-- Screen coord of a rect's named anchor point.
local function AnchorCoord(point, l, b, w, h)
  point = tostring(point or "CENTER")
  local x
  if point:find("LEFT") then x = l
  elseif point:find("RIGHT") then x = l + w
  else x = l + w / 2 end
  local y
  if point:find("BOTTOM") then y = b
  elseif point:find("TOP") then y = b + h
  else y = b + h / 2 end
  return x, y
end

-- Position the resize grips at their (optionally rotated) offsets so they track
-- the texture's orientation; stretching then follows the texture's local axes.
local function PositionGrips(frame, w, h, rot)
  if not frame._arcGrips then return end
  local c, s = math.cos(rot or 0), math.sin(rot or 0)
  local hw, hh = (w or frame:GetWidth() or 64) * 0.5, (h or frame:GetHeight() or 64) * 0.5
  for _, g in ipairs(frame._arcGrips) do
    local px, py = (g._ox or 0) * hw, (g._oy or 0) * hh
    g:ClearAllPoints()
    g:SetPoint("CENTER", frame, "CENTER", px * c - py * s, px * s + py * c)
  end
end

local function ResizeTick()
  local r = resizing
  if not r then return end
  -- End the drag on mouse release (even if the cursor left the grip) or if the
  -- options panel closes mid-resize. OnMouseUp on the grip is unreliable here.
  if not (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) or ns._arcUIOptionsOpen ~= true then
    EndResize(r.num, r.frame)
    return
  end
  local frame = r.frame
  local cx, cy = frame:GetCenter()
  if not cx then return end
  local scale = UIParent:GetEffectiveScale()
  local mx, my = GetCursorPosition()
  mx, my = mx / scale, my / scale
  -- Project the cursor offset onto the texture's LOCAL axes so stretching follows
  -- the rotated texture (not the screen axes).
  local rot = r.rot or 0
  local c, s = math.cos(rot), math.sin(rot)
  local ox, oy = mx - cx, my - cy
  local localX = ox * c + oy * s
  local localY = -ox * s + oy * c
  -- axis: "both" (corner), "x" (left/right edge -> width only), "y" (top/bottom edge -> height only)
  local axis = r.axis or "both"
  local newW = frame:GetWidth()
  local newH = frame:GetHeight()
  if axis == "both" or axis == "x" then newW = math.abs(localX) * 2 end
  if axis == "both" or axis == "y" then newH = math.abs(localY) * 2 end
  if newW < 8 then newW = 8 elseif newW > 1024 then newW = 1024 end
  if newH < 8 then newH = 8 elseif newH > 1024 then newH = 1024 end
  if r.lockAspect and r.ratio and r.ratio > 0 then
    -- keep the aspect ratio, driven by whichever axis the user is dragging
    if axis == "y" then newW = newH * r.ratio else newH = newW / r.ratio end
    if newW < 8 then newW = 8 elseif newW > 1024 then newW = 1024 end
    if newH < 8 then newH = 8 elseif newH > 1024 then newH = 1024 end
  end
  frame:SetSize(newW, newH)
  if frame.tex then
    frame.tex:ClearAllPoints()
    frame.tex:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.tex:SetSize(newW, newH)
  end
  PositionGrips(frame, newW, newH, rot)   -- keep grips on the rotated corners live
  local cfg = ns.API.GetTextureConfig(r.num)
  if cfg then
    cfg.display.width = math.floor(newW + 0.5)
    cfg.display.height = math.floor(newH + 0.5)
  end
  if frame._arcSizeText then
    frame._arcSizeText:SetText(string.format("%d x %d", math.floor(newW + 0.5), math.floor(newH + 0.5)))
  end
end

local function BeginResize(num, frame, axis)
  local cfg = ns.API.GetTextureConfig(num)
  if not cfg then return end
  local w, h = frame:GetWidth(), frame:GetHeight()
  -- Re-anchor to CENTER at the current screen center so resize stays symmetric
  -- regardless of the configured anchor point; EndResize restores it.
  local cx, cy = frame:GetCenter()
  if cx then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
  end
  resizing = {
    num = num,
    frame = frame,
    axis = axis or "both",
    rot = EffectiveRotation(cfg.display),
    lockAspect = (cfg.display.lockAspect == true),
    ratio = (h and h > 0) and (w / h) or 1,
  }
  if frame._arcSizeText then frame._arcSizeText:Show() end
  EnsureSizerDriver()
  sizerDriver:SetScript("OnUpdate", ResizeTick)
  sizerDriver:Show()
end

EndResize = function(num, frame)
  resizing = nil
  if sizerDriver then sizerDriver:SetScript("OnUpdate", nil); sizerDriver:Hide() end
  if frame._arcSizeText then frame._arcSizeText:Hide() end

  local cfg = ns.API.GetTextureConfig(num)
  if cfg then
    cfg.display.width = math.floor(frame:GetWidth() + 0.5)
    cfg.display.height = math.floor(frame:GetHeight() + 0.5)
    -- Restore the configured anchor point, keeping the frame visually put.
    local pos = cfg.display.position or {}
    local point = pos.point or "CENTER"
    local l, b, w, h = frame:GetRect()
    if l then
      local fx, fy = AnchorCoord(point, l, b, w, h)
      local upx, upy = AnchorCoord(point, 0, 0, UIParent:GetWidth(), UIParent:GetHeight())
      cfg.display.position = {
        point = point,
        relPoint = point,
        x = math.floor((fx - upx) + 0.5),
        y = math.floor((fy - upy) + 0.5),
      }
    end
    Textures.ApplyAppearance(num)
  end

  if LibStub then
    local reg = LibStub("AceConfigRegistry-3.0", true)
    if reg then reg:NotifyChange("ArcUI") end
  end
end

local function EnsureGrips(num, frame, cfg)
  if not frame._arcGrips then
    frame._arcGrips = {}
    -- Corners (gold) resize both axes; edges (blue) stretch one axis.
    local specs = {
      { anchor = "TOPLEFT",     axis = "both" },
      { anchor = "TOPRIGHT",    axis = "both" },
      { anchor = "BOTTOMLEFT",  axis = "both" },
      { anchor = "BOTTOMRIGHT", axis = "both" },
      { anchor = "LEFT",        axis = "x" },
      { anchor = "RIGHT",       axis = "x" },
      { anchor = "TOP",         axis = "y" },
      { anchor = "BOTTOM",      axis = "y" },
    }
    for _, spec in ipairs(specs) do
      local grip = CreateFrame("Frame", nil, frame)
      -- All grips are squares so nothing looks tilted when the texture rotates;
      -- edges are a touch smaller + blue, corners full-size + gold.
      local gsz = (spec.axis == "both") and GRIP_SIZE or (GRIP_SIZE * 0.8)
      grip:SetSize(gsz, gsz)
      local off = GRIP_OFFSET[spec.anchor] or { 0, 0 }
      grip._ox, grip._oy = off[1], off[2]
      grip:SetFrameStrata("TOOLTIP")
      grip:EnableMouse(true)
      local base = (spec.axis == "both") and { 1, 0.82, 0, 0.9 } or { 0.35, 0.75, 1, 0.9 }
      grip._base = base
      grip._axis = spec.axis
      local t = grip:CreateTexture(nil, "OVERLAY")
      t:SetAllPoints()
      t:SetColorTexture(base[1], base[2], base[3], base[4])
      grip._tex = t
      grip:SetScript("OnEnter", function(self) self._tex:SetColorTexture(1, 1, 1, 1) end)
      grip:SetScript("OnLeave", function(self)
        local c = self._base
        self._tex:SetColorTexture(c[1], c[2], c[3], c[4])
      end)
      grip:SetScript("OnMouseDown", function(self) BeginResize(num, frame, self._axis) end)
      grip:Hide()
      frame._arcGrips[#frame._arcGrips + 1] = grip
    end
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("BOTTOM", frame, "TOP", 0, 12)  -- clears the top edge grip
    fs:Hide()
    frame._arcSizeText = fs

    -- Editor-only "Drain Start" marker: a chevron + label on a high-level TOOLTIP
    -- frame so it sits ABOVE the drag squares (TOOLTIP is the top strata, so we
    -- raise the frame LEVEL to win within it).
    local af = CreateFrame("Frame", nil, frame)
    af:SetFrameStrata("TOOLTIP")
    af:SetFrameLevel(500)
    af:SetSize(GRIP_SIZE * 2.2, GRIP_SIZE * 2.2)
    af:Hide()
    local atex = af:CreateTexture(nil, "OVERLAY")
    atex:SetAtlas("common-icon-forwardarrow", false)
    atex:SetSize(GRIP_SIZE * 1.9, GRIP_SIZE * 1.9)
    atex:SetPoint("CENTER", af, "CENTER", 0, 0)
    atex:SetVertexColor(1, 0.82, 0.1, 1)
    af._tex = atex
    local alabel = af:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    alabel:SetText("Drain Start")
    alabel:SetTextColor(1, 0.82, 0.1)
    af._label = alabel
    frame._arcDrainArrowFrame = af

    -- Editor-only drain-region outline (cyan rectangle) shown when the region is
    -- inset. On its own HIGH-strata overlay so it draws ABOVE the texture wrapper
    -- (frame._arcVis renders above the host frame's own regions).
    local rl = CreateFrame("Frame", nil, frame)
    rl:SetAllPoints(frame)
    rl:SetFrameStrata("HIGH")
    frame._arcRegionLineFrame = rl
    frame._arcRegionLines = {}
    for i = 1, 4 do
      local ln = rl:CreateTexture(nil, "OVERLAY")
      ln:SetColorTexture(0.2, 0.9, 1, 0.95)
      ln:Hide()
      frame._arcRegionLines[i] = ln
    end
  end

  -- Place grips on the texture's current rotated corners/edges.
  PositionGrips(frame, frame:GetWidth(), frame:GetHeight(), EffectiveRotation(cfg.display))

  local db = ns.API and ns.API.GetDB and ns.API.GetDB()
  local sel = db and db.selectedTexture
  local show = (ns._arcUIOptionsOpen == true) and (num == sel) and (cfg.display.movable ~= false)
  for _, g in ipairs(frame._arcGrips) do
    if show then g:Show() else g:Hide() end
  end

  local drainEditing = (ns._arcUIOptionsOpen == true) and (num == sel) and (cfg.display.progressEnabled == true)

  -- "Drain Start" marker: at the start edge, chevron pointing the sweep way.
  -- Screen-space (ignores texture rotation, matching the screen-space drain).
  local af = frame._arcDrainArrowFrame
  if af then
    if drainEditing then
      local a = DRAIN_ARROW[cfg.display.progressDir] or DRAIN_ARROW.TOP_TO_BOTTOM
      af:ClearAllPoints()
      af:SetPoint(a.anchor, frame, a.anchor, 0, 0)
      if af._tex then af._tex:SetRotation(a.rot) end
      if af._label then
        af._label:ClearAllPoints()
        af._label:SetPoint("CENTER", af, "CENTER", (a.lx or 0) * 36, (a.ly or 0) * 20)
      end
      af:Show()
    else
      af:Hide()
    end
  end

  -- Drain-region outline (cyan box): shown while editing when the region is inset,
  -- so the inset sliders show what's changing.
  local lines = frame._arcRegionLines
  if lines then
    local rcx, rcy, rW, rH, isSub = DrainRegion(cfg.display, frame:GetWidth(), frame:GetHeight())
    if drainEditing and isSub then
      local th = 2
      local lt, lb, ll, lr = lines[1], lines[2], lines[3], lines[4]
      lt:ClearAllPoints(); lt:SetSize(rW, th); lt:SetPoint("CENTER", frame, "CENTER", rcx, rcy + rH / 2); lt:Show()
      lb:ClearAllPoints(); lb:SetSize(rW, th); lb:SetPoint("CENTER", frame, "CENTER", rcx, rcy - rH / 2); lb:Show()
      ll:ClearAllPoints(); ll:SetSize(th, rH); ll:SetPoint("CENTER", frame, "CENTER", rcx - rW / 2, rcy); ll:Show()
      lr:ClearAllPoints(); lr:SetSize(th, rH); lr:SetPoint("CENTER", frame, "CENTER", rcx + rW / 2, rcy); lr:Show()
    else
      for _, ln in ipairs(lines) do ln:Hide() end
    end
  end
end

-- ===================================================================
-- MOVER (drag while the options panel is open)
-- ===================================================================
local function ApplyMover(num, frame, cfg)
  local movable = cfg.display.movable ~= false
  local editing = (ns._arcUIOptionsOpen == true) and movable

  frame:SetMovable(movable)
  frame:EnableMouse(editing and true or false)
  frame:RegisterForDrag("LeftButton")

  if not frame._arcMoverHooked then
    frame._arcMoverHooked = true

    frame:SetScript("OnDragStart", function(self)
      if self:IsMovable() and self:IsMouseEnabled() then
        self:StartMoving()
      end
    end)

    frame:SetScript("OnDragStop", function(self)
      self:StopMovingOrSizing()
      local c = ns.API.GetTextureConfig(self._arcTexNum)
      if not c then return end
      local point, _, relPoint, x, y = self:GetPoint(1)
      c.display.position = {
        point = point or "CENTER",
        relPoint = relPoint or "CENTER",
        x = math.floor((x or 0) + 0.5),
        y = math.floor((y or 0) + 0.5),
      }
      -- Re-anchor cleanly to UIParent so it never drifts via a relativeTo frame.
      self:ClearAllPoints()
      self:SetPoint(c.display.position.point, UIParent, c.display.position.relPoint,
        c.display.position.x, c.display.position.y)
      if Textures._onMoved then Textures._onMoved(self._arcTexNum) end
    end)

    frame:SetScript("OnEnter", function(self)
      if ns._arcUIOptionsOpen ~= true or not GameTooltip then return end
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      local c = ns.API.GetTextureConfig(self._arcTexNum)
      local label = (c and c.tracking and c.tracking.buffName) or ("Texture " .. tostring(self._arcTexNum))
      GameTooltip:AddLine(label)
      GameTooltip:AddLine("Drag to move", 0.8, 0.8, 0.8)
      GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
      if GameTooltip then GameTooltip:Hide() end
    end)
  end

  EnsureGrips(num, frame, cfg)
end

-- ===================================================================
-- RENDER: texcoord (zoom / crop / mirror). Skipped for atlas sources
-- because an atlas already defines its own sub-rect via texcoords.
-- ===================================================================
local function ApplyTexCoordAndCrop(frame, tex, d, isAtlas)
  local w = tonumber(d.width) or 64
  local h = tonumber(d.height) or 64

  if isAtlas then
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", frame, "CENTER", 0, 0)
    tex:SetSize(w, h)
    return
  end

  local mh = (d.mirrorH == true)
  local mv = (d.mirrorV == true)

  local zPct = (d.zoomEnabled == true) and (tonumber(d.zoomPct) or 0) or 0
  if zPct < 0 then zPct = 0 elseif zPct > 50 then zPct = 50 end
  local z = zPct / 100
  if z > 0.499 then z = 0.499 end

  local left, right = z, 1 - z
  local top, bottom = z, 1 - z

  local cropOn = (d.cropEnabled == true)
  local cropL, cropR, cropT, cropB = 0, 0, 0, 0
  if cropOn then
    local function clampPct(v)
      v = tonumber(v) or 0
      if v < 0 then v = 0 elseif v > 100 then v = 100 end
      return v / 100
    end
    cropL = clampPct(d.cropL)
    cropR = clampPct(d.cropR)
    cropT = clampPct(d.cropT)
    cropB = clampPct(d.cropB)

    local w2 = right - left
    local h2 = bottom - top
    left   = left   + (w2 * cropL)
    right  = right  - (w2 * cropR)
    top    = top    + (h2 * cropT)
    bottom = bottom - (h2 * cropB)
    if right < left then right = left end
    if bottom < top then bottom = top end
  end

  if mh then left, right = right, left end
  if mv then top, bottom = bottom, top end
  tex:SetTexCoord(left, right, top, bottom)

  -- "Cut off" crop without stretching: shrink + re-center the texture region.
  tex:ClearAllPoints()
  if cropOn then
    local newW = w * (1 - cropL - cropR)
    local newH = h * (1 - cropT - cropB)
    if newW < 1 then newW = 1 end
    if newH < 1 then newH = 1 end
    local dx = (cropL - cropR) * w * 0.5
    local dy = -(cropT - cropB) * h * 0.5
    tex:SetPoint("CENTER", frame, "CENTER", dx, dy)
    tex:SetSize(newW, newH)
  else
    tex:SetPoint("CENTER", frame, "CENTER", 0, 0)
    tex:SetSize(w, h)
  end
end

-- ===================================================================
-- PER-FRAME AURA HOOKS (refresh-correct, exactly like the Aura Bars)
-- Hook each tracked CDM frame's gain/refresh signals so a texture's drain
-- re-seeds when ITS OWN aura is gained, swapped, or refreshed (extended) --
-- and ONLY then, so unrelated UNIT_AURA events never re-seed (that double
-- seeding was the stutter). hooksecurefunc is additive + taint-safe; the
-- bars hook these same methods, so this composes cleanly with zero Core edits.
-- ===================================================================
local hookedTexFrames = setmetatable({}, { __mode = "k" })  -- [frame] = true (weak)

-- A tracked aura on this frame was gained/swapped/refreshed: force the drain of
-- every active texture tracking this frame's cooldownID to re-seed (new duration).
function Textures.OnFrameAuraChanged(frame)
  if not frame then return end
  local cid = frame.cooldownID
  if not cid then return end
  local active = (ns.API and ns.API.GetActiveTextures and ns.API.GetActiveTextures()) or {}
  for _, num in ipairs(active) do
    local cfg = ns.API.GetTextureConfig(num)
    local t = cfg and cfg.tracking
    if t then
      local match = (t.cooldownID == cid)
      if not match and type(t.alternateCooldownIDs) == "table" then
        for _, c in ipairs(t.alternateCooldownIDs) do
          if c == cid then match = true; break end
        end
      end
      if match then
        local f = textureFrames[num]
        if f then
          f._arcDrainSeeded = false   -- force re-seed against the new duration object
          f._arcDrainFrame = nil
        end
        Textures.UpdateTexture(num)
      end
    end
  end
end

local function HookTextureFrame(frame)
  if not frame or hookedTexFrames[frame] then return end
  hookedTexFrames[frame] = true

  -- Gained / instance swapped: re-seed now (auraInstanceID is set at hook time).
  if frame.OnAuraInstanceInfoSet then
    hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
      Textures.OnFrameAuraChanged(self)
    end)
  end

  -- Lost (incl. switching to a target without the debuff): re-resolve so the
  -- texture hides promptly instead of lingering. Defer a tick so a same-batch
  -- Set (new target HAS the aura) wins -- OnFrameAuraChanged re-reads the live
  -- auraInstanceID, so the post-tick state is authoritative (no token needed).
  if frame.OnAuraInstanceInfoCleared then
    hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
      C_Timer.After(0, function() Textures.OnFrameAuraChanged(self) end)
    end)
  end

  -- Same-instance refresh (duration extended): fires NO UNIT_AURA id, so this is
  -- the only signal -- exactly why the bars hook it. Coalesce (CDM calls it
  -- several times per batch) and only act when a live aura is present.
  if frame.RefreshData then
    hooksecurefunc(frame, "RefreshData", function(self)
      if not HasAuraInstanceID(self.auraInstanceID) then return end
      if self._arcTexRefreshPending then return end
      self._arcTexRefreshPending = true
      C_Timer.After(0, function()
        self._arcTexRefreshPending = false
        Textures.OnFrameAuraChanged(self)
      end)
    end)
  end
end

-- Hook the CDM frame(s) a texture currently tracks (idempotent; re-run picks up
-- frames rebuilt by a CDM rescan). Called from ApplyAppearance.
local function HookFramesForTexture(num)
  local find = ns.API and ns.API._FindCDMFrameForCooldownID
  if not find then return end
  local cfg = ns.API.GetTextureConfig(num)
  local t = cfg and cfg.tracking
  if not t then return end
  local cids = { t.cooldownID }
  if type(t.alternateCooldownIDs) == "table" then
    for _, c in ipairs(t.alternateCooldownIDs) do cids[#cids + 1] = c end
  end
  for _, cid in ipairs(cids) do
    if cid and cid ~= 0 then
      local frame = find(cid)
      if frame then HookTextureFrame(frame) end
    end
  end
end

-- ===================================================================
-- DURATION TEXT styling (font / size / outline / shadow / colour / anchor /
-- strata / level) -- mirrors the Aura Bars' duration-text exactly. The text
-- VALUE is driven secret-safely by ns.DurationText in UpdateTexture.
-- ===================================================================
local DUR_OUTLINE = { NONE = "", OUTLINE = "OUTLINE", THICKOUTLINE = "THICKOUTLINE" }

local function ApplyDurationTextStyle(frame, d)
  local dtf, fs = frame._arcDurFrame, frame._arcDurText
  if not (dtf and fs) then return end

  local size = tonumber(d.durationFontSize) or 18
  local outline = DUR_OUTLINE[d.durationOutline or "THICKOUTLINE"] or "THICKOUTLINE"
  local fontPath = "Fonts\\FRIZQT__.TTF"
  if LSM and d.durationFont then
    local f = LSM:Fetch("font", d.durationFont)
    if f and f ~= "" then fontPath = f end
  end
  fs:SetFont(fontPath, size, outline)

  local c = d.durationColor
  if type(c) == "table" then fs:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
  else fs:SetTextColor(1, 1, 1, 1) end

  if d.durationShadow == true then
    fs:SetShadowOffset(1, -1); fs:SetShadowColor(0, 0, 0, 1)
  else
    fs:SetShadowOffset(0, 0)
  end

  dtf:SetFrameStrata(d.durationTextStrata or "HIGH")
  dtf:SetFrameLevel(tonumber(d.durationTextLevel) or ((tonumber(d.frameLevel) or 10) + 3))
  dtf:SetSize(size * 4, size + 4)

  -- Anchor + offsets relative to the texture frame (mirrors the bar anchor map).
  local a = d.durationAnchor or "CENTER"
  local ox = tonumber(d.durationAnchorOffsetX) or 0
  local oy = tonumber(d.durationAnchorOffsetY) or 0
  local pad = 5
  dtf:ClearAllPoints()
  if a == "RIGHT" or a == "CENTERRIGHT" then dtf:SetPoint("CENTER", frame, "RIGHT", -pad + ox, oy)
  elseif a == "LEFT" or a == "CENTERLEFT" then dtf:SetPoint("CENTER", frame, "LEFT", pad + ox, oy)
  elseif a == "TOP" then dtf:SetPoint("CENTER", frame, "TOP", ox, -pad + oy)
  elseif a == "BOTTOM" then dtf:SetPoint("CENTER", frame, "BOTTOM", ox, pad + oy)
  elseif a == "TOPLEFT" then dtf:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", pad + ox, -pad + oy)
  elseif a == "TOPRIGHT" then dtf:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", -pad + ox, -pad + oy)
  elseif a == "BOTTOMLEFT" then dtf:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", pad + ox, pad + oy)
  elseif a == "BOTTOMRIGHT" then dtf:SetPoint("TOPLEFT", frame, "BOTTOMRIGHT", -pad + ox, pad + oy)
  elseif a == "OUTERRIGHT" or a == "OUTERCENTERRIGHT" then dtf:SetPoint("LEFT", frame, "RIGHT", -20 + ox, oy)
  elseif a == "OUTERLEFT" or a == "OUTERCENTERLEFT" then dtf:SetPoint("RIGHT", frame, "LEFT", 20 + ox, oy)
  elseif a == "OUTERTOP" then dtf:SetPoint("BOTTOM", frame, "TOP", ox, oy)
  elseif a == "OUTERBOTTOM" then dtf:SetPoint("TOP", frame, "BOTTOM", ox, oy)
  elseif a == "OUTERTOPLEFT" then dtf:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", ox, oy)
  elseif a == "OUTERTOPRIGHT" then dtf:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", ox, oy)
  elseif a == "OUTERBOTTOMLEFT" then dtf:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", ox, oy)
  elseif a == "OUTERBOTTOMRIGHT" then dtf:SetPoint("TOPLEFT", frame, "BOTTOMRIGHT", ox, oy)
  else dtf:SetPoint("CENTER", frame, "CENTER", ox, oy) end
end

-- ===================================================================
-- APPEARANCE: layout + source + transforms (config-change cost).
-- Ends by calling UpdateTexture to set the per-state visuals.
-- ===================================================================
function Textures.ApplyAppearance(num)
  local cfg = ns.API.GetTextureConfig(num)
  if not cfg then return end
  local d = cfg.display
  if not d then return end

  local frame = EnsureFrame(num)
  local tex = frame.tex

  local w = tonumber(d.width) or 64
  local h = tonumber(d.height) or 64
  frame:SetSize(w, h)
  frame:SetFrameStrata(d.frameStrata or "MEDIUM")
  frame:SetFrameLevel(tonumber(d.frameLevel) or 10)

  local p = d.position or {}
  frame:ClearAllPoints()
  frame:SetPoint(p.point or "CENTER", UIParent, p.relPoint or "CENTER", tonumber(p.x) or 0, tonumber(p.y) or 0)

  -- Resolve the source once (shared by the static texture and the drain bar).
  -- srcFile = FileDataID number OR file path string; srcAtlas = atlas name.
  local isAtlas = false
  local srcFile, srcAtlas
  if d.textureSource == "custom" and type(d.customTexturePath) == "string" and d.customTexturePath ~= "" then
    local path = d.customTexturePath:gsub("^%s+", ""):gsub("%s+$", "")
    while path:find("\\\\") do path = path:gsub("\\\\", "\\") end
    srcFile = path
  else
    local id = d.textureID
    if type(id) == "string" and id ~= "" then
      srcAtlas = id
      isAtlas = true
    elseif type(id) == "number" and id > 0 then
      srcFile = id
    else
      srcFile = "Interface\\ICONS\\INV_Misc_QuestionMark"
    end
  end

  local blend = (d.blendMode == "ADD") and "ADD" or "BLEND"

  -- Drain mode needs a file texture (atlases manage their own texcoords).
  -- While the options panel is open, render the FULL static texture (no drain) so
  -- the user can see and position/orient it; the drain returns when the panel closes.
  local progress = (d.progressEnabled == true) and (srcFile ~= nil) and (ns._arcUIOptionsOpen ~= true)
  frame._arcProgress = progress

  if progress then
    -- DRAIN (mask-based): a hidden status bar drives the timing; a mask reveals the
    -- depleting part in place -- the texture never moves.
    local dir = PROGRESS_DIRS[d.progressDir] or PROGRESS_DIRS.TOP_TO_BOTTOM
    local rcx, rcy, rW, rH, regionMode = DrainRegion(d, w, h)
    frame._arcRegionDrain = regionMode

    -- Foreground: the full, in-place texture.
    tex:SetTexture(nil)
    tex:SetTexture(srcFile)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", frame, "CENTER", 0, 0)
    tex:SetSize(w, h)
    tex:SetBlendMode(blend)
    if tex.SetTexCoord then tex:SetTexCoord(0, 1, 0, 1) end
    if tex.SetRotation then tex:SetRotation(EffectiveRotation(d)) end

    -- Ghost backdrop: the dim full texture (shown/hidden by progressHideGhost in
    -- UpdateTexture). In region mode it shows through the depleted band, in full
    -- mode behind the bright remaining -- the WeakAuras look either way.
    local ghost = frame.ghost
    ghost:SetTexture(nil)
    ghost:SetTexture(srcFile)
    ghost:ClearAllPoints()
    ghost:SetPoint("CENTER", frame, "CENTER", 0, 0)
    ghost:SetSize(w, h)
    ghost:SetBlendMode("BLEND")
    if ghost.SetTexCoord then ghost:SetTexCoord(0, 1, 0, 1) end
    if ghost.SetRotation then ghost:SetRotation(EffectiveRotation(d)) end

    local bar = frame.bar
    bar:ClearAllPoints()
    bar:SetStatusBarColor(1, 1, 1, 0)
    if bar.SetOrientation then bar:SetOrientation(dir.orient) end
    if bar.SetReverseFill then bar:SetReverseFill(dir.reverse) end
    if bar.SetRotatesTexture then bar:SetRotatesTexture(false) end
    bar:SetMinMaxValues(0, 1)

    if regionMode then
      -- REGION DRAIN: the band drains for real -- frame.tex is masked to the
      -- REMAINING part of the region (via a region-sized bar), so the used-up part
      -- VANISHES exactly like the full drain. The solid rest of the texture is drawn
      -- as up to four copies masked to the strips AROUND the region. (The ghost set
      -- up above shows through the depleted band when enabled.)
      bar:SetSize(rW, rH)
      bar:SetPoint("CENTER", frame, "CENTER", rcx, rcy)

      -- Band: reveal mask = the remaining part of the region (same anchoring as the
      -- full drain; just a region-sized bar).
      local bt = bar:GetStatusBarTexture()
      local mask = frame.drainMask
      if bt and mask then
        mask:ClearAllPoints()
        mask:SetPoint(dir.fillCorner, bt, dir.fillCorner, dir.fillOffX, dir.fillOffY)
        mask:SetPoint(dir.frameCorner, bar, dir.frameCorner, 0, 0)
        tex:AddMaskTexture(mask)
      end

      -- The solid "rest": four copies masked to the strips around the region. Zero-
      -- size strips (region touches that edge) stay hidden.
      local rT, rB, rL, rR = rcy + rH * 0.5, rcy - rH * 0.5, rcx - rW * 0.5, rcx + rW * 0.5
      local fT, fB, fL, fR = h * 0.5, -h * 0.5, -w * 0.5, w * 0.5
      local strips = {
        { 0, (rT + fT) * 0.5, w, fT - rT },        -- top
        { 0, (fB + rB) * 0.5, w, rB - fB },        -- bottom
        { (fL + rL) * 0.5, rcy, rL - fL, rH },     -- left
        { (rR + fR) * 0.5, rcy, fR - rR, rH },     -- right
      }
      for i = 1, 4 do
        local s = strips[i]
        local pt, pm = frame.regionPieces[i], frame.regionMasks[i]
        if pt and pm and s[3] > 0.5 and s[4] > 0.5 then
          pt:SetTexture(nil)
          pt:SetTexture(srcFile)
          pt:ClearAllPoints()
          pt:SetPoint("CENTER", frame, "CENTER", 0, 0)
          pt:SetSize(w, h)
          pt:SetBlendMode(blend)
          if pt.SetTexCoord then pt:SetTexCoord(0, 1, 0, 1) end
          if pt.SetRotation then pt:SetRotation(EffectiveRotation(d)) end
          pm:ClearAllPoints()
          pm:SetPoint("CENTER", frame, "CENTER", s[1], s[2])
          pm:SetSize(s[3], s[4])
          pt._arcActive = true
        elseif pt then
          pt._arcActive = false
          pt:Hide()
        end
      end
    else
      -- FULL DRAIN: bright remaining + dim full ghost. Bar sized to the rotated
      -- bounding box so the reveal mask covers the whole (possibly rotated) texture.
      HideRegionPieces(frame)

      local rot = EffectiveRotation(d)
      local acos, asin = math.abs(math.cos(rot)), math.abs(math.sin(rot))
      bar:SetSize(w * acos + h * asin, w * asin + h * acos)
      bar:SetPoint("CENTER", frame, "CENTER", 0, 0)

      local bt = bar:GetStatusBarTexture()
      local mask = frame.drainMask
      if bt and mask then
        mask:ClearAllPoints()
        mask:SetPoint(dir.fillCorner, bt, dir.fillCorner, dir.fillOffX, dir.fillOffY)
        mask:SetPoint(dir.frameCorner, bar, dir.frameCorner, 0, 0)
        tex:AddMaskTexture(mask)
      end
    end

    -- Config (direction/source) changed: re-seed the timer next update.
    frame._arcDrainSeeded = false
    frame._arcDrainFrame = nil
  else
    -- STATIC: the texture region (supports zoom/crop/mirror/rotation/fade).
    if frame.drainMask then tex:RemoveMaskTexture(frame.drainMask) end
    if frame.ghost then frame.ghost:Hide() end
    HideRegionPieces(frame)
    if srcAtlas then
      tex:SetTexture(nil)
      tex:SetAtlas(srcAtlas)
    else
      tex:SetTexture(nil)
      tex:SetTexture(srcFile)
    end
    tex:SetBlendMode(blend)
    ApplyTexCoordAndCrop(frame, tex, d, isAtlas)
    if tex.SetRotation then tex:SetRotation(EffectiveRotation(d)) end
    if frame.bar then frame.bar:Hide() end
  end

  ApplyDurationTextStyle(frame, d)
  ApplyMover(num, frame, cfg)
  HookFramesForTexture(num)   -- refresh-correct drain re-seeding (like the bars)

  frame._arcReady = true
  Textures.UpdateTexture(num)
end

-- ===================================================================
-- UPDATE: resolve active state and apply per-state visuals + visibility.
-- This is the hot path (called on UNIT_AURA / target change).
-- ===================================================================
function Textures.UpdateTexture(num)
  local frame = textureFrames[num]
  if not frame or not frame._arcReady then
    -- Build the frame/appearance first; ApplyAppearance calls back into here.
    Textures.ApplyAppearance(num)
    return
  end

  local cfg = ns.API.GetTextureConfig(num)
  if not cfg then return end
  local d = cfg.display
  local optionsOpen = (ns._arcUIOptionsOpen == true)

  if not (cfg.tracking and cfg.tracking.enabled) then
    Textures.HideTexture(num)
    return
  end

  -- Load gates are bypassed while editing so the user can position/style.
  local hideWhenAlpha = 1
  if not optionsOpen then
    if not SpecOK(cfg) then Textures.HideTexture(num); return end
    if ns.TrackingOptions and ns.TrackingOptions.AreTalentConditionsMet
       and not ns.TrackingOptions.AreTalentConditionsMet(cfg) then
      Textures.HideTexture(num)
      return
    end
    -- "Hide When..." conditions -- shared evaluator, identical to the Aura Bars.
    if ns.CooldownBars and ns.CooldownBars.GetHideWhen then
      local hideWhen = ns.CooldownBars.GetHideWhen(cfg)
      if hideWhen and ns.CooldownBars.EvaluateHideConditions
         and ns.CooldownBars.EvaluateHideConditions(hideWhen, cfg.behavior and cfg.behavior.hideLogic) then
        local hAlpha = tonumber(ns.CooldownBars.GetHideWhenAlpha and ns.CooldownBars.GetHideWhenAlpha(cfg)) or 0
        if hAlpha <= 0 then
          Textures.HideTexture(num)
          return
        end
        hideWhenAlpha = hAlpha
      end
    end
  end

  local activeFrame = FindActiveFrame(cfg)
  local active = activeFrame ~= nil
  local showInactive = (d.showWhenInactive == true)

  -- Hidden when inactive (and not editing): nothing to draw.
  if (not active) and (not showInactive) and (not optionsOpen) then
    Textures.HideTexture(num)
    return
  end

  -- Choose which state's style to use. While editing an otherwise-hidden
  -- inactive texture, fall back to the ACTIVE style so it is visible to drag.
  local useActiveStyle = active
  if (not active) and optionsOpen and (not showInactive) then
    useActiveStyle = true
  end

  local col, alpha, desatOn, desatPct
  if useActiveStyle then
    col       = d.activeColor
    alpha     = d.activeAlpha
    desatOn   = d.activeDesaturate
    desatPct  = d.activeDesaturatePct
  else
    col       = d.inactiveColor
    alpha     = d.inactiveAlpha
    desatOn   = d.inactiveDesaturate
    desatPct  = d.inactiveDesaturatePct
  end

  local r, g, b = (col and col.r) or 1, (col and col.g) or 1, (col and col.b) or 1
  local amt = (desatOn == true) and ((tonumber(desatPct) or 0) / 100) or 0
  if amt < 0 then amt = 0 elseif amt > 1 then amt = 1 end

  if frame._arcProgress then
    -- DRAIN MODE (mask-based): the hidden bar drives the reveal mask; the
    -- foreground texture is bright + in place; the ghost is the dim backdrop.
    local bar = frame.bar
    local fg = frame.tex
    local ghost = frame.ghost

    -- Foreground colour / desaturation / alpha (the bright remaining portion).
    fg:SetVertexColor(r, g, b)
    if fg.SetDesaturation then fg:SetDesaturation(amt) elseif fg.SetDesaturated then fg:SetDesaturated(amt > 0) end
    fg:SetAlpha(tonumber(alpha) or 1)
    fg:Show()

    -- Dim full-texture ghost backdrop: shown by default in BOTH the full and the
    -- region drain (hidden only via "Hide Background Ghost"). In region mode it shows
    -- through the depleted band; in full mode behind the bright remaining.
    if d.progressHideGhost ~= true then
      if ghost.SetDesaturation then ghost:SetDesaturation(0) elseif ghost.SetDesaturated then ghost:SetDesaturated(false) end
      ghost:SetVertexColor(0.5, 0.5, 0.5)
      ghost:SetAlpha((tonumber(alpha) or 1) * 0.5)
      ghost:Show()
    else
      ghost:Hide()
    end

    -- Region "rest" pieces (solid, coloured to match the active style) -- only in
    -- region mode; the full drain has no pieces.
    if frame._arcRegionDrain then
      for i = 1, 4 do
        local pt = frame.regionPieces[i]
        if pt and pt._arcActive then
          pt:SetVertexColor(r, g, b)
          if pt.SetDesaturation then pt:SetDesaturation(amt) elseif pt.SetDesaturated then pt:SetDesaturated(amt > 0) end
          pt:SetAlpha(tonumber(alpha) or 1)
          pt:Show()
        elseif pt then
          pt:Hide()
        end
      end
    else
      HideRegionPieces(frame)
    end

    -- Drive the hidden timing bar. Seed ONCE per activation -- re-seeding a
    -- running C-side timer halts it (the "stopped progressing" bug), so unrelated
    -- UNIT_AURA events must not reset it. The per-frame gain/refresh hooks clear
    -- _arcDrainSeeded so the aura's OWN refresh re-seeds. The bar stays invisible
    -- (alpha 0); only its fill geometry sweeps the mask over the foreground.
    bar:SetStatusBarColor(1, 1, 1, 0)
    local durObj = active and GetDurObjFor(cfg, activeFrame)
    if durObj and bar.SetTimerDuration and Enum and Enum.StatusBarInterpolation and Enum.StatusBarTimerDirection then
      if (not frame._arcDrainSeeded) or (frame._arcDrainFrame ~= activeFrame) then
        bar:SetMinMaxValues(0, 1)
        bar:SetTimerDuration(durObj, Enum.StatusBarInterpolation.ExponentialEaseOut, Enum.StatusBarTimerDirection.RemainingTime)
        frame._arcDrainSeeded = true
        frame._arcDrainFrame = activeFrame
        -- Fresh-in (target already has the debuff): hold the foreground hidden a
        -- few frames so the timer settles to the real remaining before revealing.
        if not frame._arcWasActive then
          -- Hide the draining band (fg) during the settle so it doesn't flash full
          -- before the timer settles; the solid "rest" pieces stay shown.
          fg:Hide()
          local token = (frame._arcRevealToken or 0) + 1
          frame._arcRevealToken = token
          C_Timer.After(0.05, function()
            if frame._arcProgress and frame._arcDrainSeeded and frame._arcRevealToken == token then
              if frame.tex then frame.tex:Show() end
            end
          end)
        end
      end
      -- already seeded: leave the running timer untouched.
    else
      bar:SetMinMaxValues(0, 1)
      bar:SetValue(active and 1 or 0)   -- no live duration: full / empty
      frame._arcDrainSeeded = false
      frame._arcDrainFrame = nil
    end
    bar:Show()   -- shown but invisible, so its fill geometry (and the mask) keep updating

    StopFade(frame)   -- the drain is the duration visual; the alpha fade is N/A here
  else
    -- STATIC MODE: the texture region (supports the alpha fade-out).
    if frame.bar then frame.bar:Hide() end
    if frame.ghost then frame.ghost:Hide() end
    local tex = frame.tex
    tex:Show()
    tex:SetVertexColor(r, g, b)
    if tex.SetDesaturation then
      tex:SetDesaturation(amt)
    elseif tex.SetDesaturated then
      tex:SetDesaturated(amt > 0)
    end

    -- Alpha: duration fade-out only applies in the real ACTIVE state with a
    -- live duration object; otherwise use the chosen state's static alpha.
    if active and (d.fadeOutEnabled == true) and GetDurObjFor(cfg, activeFrame) then
      StartFade(num, frame, cfg, activeFrame)   -- ticker owns alpha while fading
    else
      StopFade(frame)
      tex:SetAlpha(tonumber(alpha) or 1)
    end
  end

  -- Pulse shows whenever the ACTIVE appearance is shown -- including the editing
  -- preview (useActiveStyle) so toggling it updates live in the panel. It pauses
  -- during an active resize drag so it doesn't fight the corner grips.
  if useActiveStyle and (d.pulseEnabled == true) and (not resizing) then
    StartPulse(frame, cfg)
  else
    StopPulse(frame)
  end

  -- Duration text: secret-safe countdown via ns.DurationText (active state only).
  -- In the editor, show a sample so it can be positioned/styled without a live aura.
  local dtf, dtext = frame._arcDurFrame, frame._arcDurText
  if dtf and dtext then
    if d.showDuration == true then
      if optionsOpen then
        if ns.DurationText and ns.DurationText.Unbind then ns.DurationText.Unbind(dtext) end
        dtext:SetText("12.3")
        dtf:Show()
      else
        local durObj = active and GetDurObjFor(cfg, activeFrame)
        -- unit + auraInstanceID drive the optional threshold colour ticker (mirrors
        -- GetDurObjFor's resolution); `d` opts the duration text into colouring.
        local unit = (cfg.tracking and cfg.tracking.trackType == "debuff") and "target" or "player"
        local aiid = activeFrame and activeFrame.auraInstanceID
        if durObj and ns.DurationText and ns.DurationText.IsSupported and ns.DurationText.IsSupported()
           and ns.DurationText.Bind(dtext, durObj, tonumber(d.durationDecimals) or 1, unit, aiid, d) then
          dtf:Show()
        else
          if ns.DurationText and ns.DurationText.Unbind then ns.DurationText.Unbind(dtext) end
          dtf:Hide()
        end
      end
    else
      if ns.DurationText and ns.DurationText.Unbind then ns.DurationText.Unbind(dtext) end
      dtf:Hide()
    end
  end

  frame._arcWasActive = active   -- next activation knows if this is a fresh-in
  frame:SetAlpha(hideWhenAlpha)  -- "Hide When..." fade (1 = normal; <1 fades instead of hiding)
  frame:Show()
end

-- Called by ns.API.InitializeNewTexture for a freshly created slot.
function Textures.ShowTexture(num)
  Textures.ApplyAppearance(num)
end

-- ===================================================================
-- BULK REFRESH
-- ===================================================================
function Textures.RefreshAll()
  local active = (ns.API and ns.API.GetActiveTextures and ns.API.GetActiveTextures()) or {}
  local activeSet = {}
  for _, num in ipairs(active) do
    activeSet[num] = true
    Textures.ApplyAppearance(num)
  end
  -- Hide frames for slots that are no longer active.
  for num, frame in pairs(textureFrames) do
    if not activeSet[num] then
      frame:Hide()
      frame:EnableMouse(false)
    end
  end
end

-- Light refresh used on aura/target changes: only re-resolve state.
local function RefreshActiveStates()
  local active = (ns.API and ns.API.GetActiveTextures and ns.API.GetActiveTextures()) or {}
  for _, num in ipairs(active) do
    Textures.UpdateTexture(num)
  end
end

-- The options panel calls this when it closes so previews/movers update.
function Textures.OnOptionsClosed()
  Textures.RefreshAll()
end

-- ===================================================================
-- EVENT DRIVER (event-driven; no polling)
-- ===================================================================
local driver
local statePending = false

local function EnsureDriver()
  if driver then return end
  driver = CreateFrame("Frame")

  -- UNIT_AURA limited to the only units a buff/debuff texture can track.
  driver:RegisterUnitEvent("UNIT_AURA", "player", "target")
  driver:RegisterEvent("PLAYER_TARGET_CHANGED")
  driver:RegisterEvent("PLAYER_REGEN_ENABLED")
  driver:RegisterEvent("PLAYER_REGEN_DISABLED")
  driver:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
  driver:RegisterEvent("PLAYER_TALENT_UPDATE")
  driver:RegisterEvent("TRAIT_CONFIG_UPDATED")
  driver:RegisterEvent("PLAYER_ENTERING_WORLD")

  driver:SetScript("OnEvent", function(_, event)
    if event == "UNIT_AURA" or event == "PLAYER_TARGET_CHANGED" then
      -- Coalesce bursts into a single state refresh next tick.
      if statePending then return end
      statePending = true
      C_Timer.After(0, function()
        statePending = false
        RefreshActiveStates()
      end)
    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
      Textures.RefreshAll()
    else
      -- Spec / talent / world enter: active set + bindings may have changed.
      if ns.API and ns.API.InvalidateActiveTextureCache then
        ns.API.InvalidateActiveTextureCache()
      end
      C_Timer.After(0.1, function() Textures.RefreshAll() end)
    end
  end)
end

-- ===================================================================
-- INIT (called from ArcUI_Options.lua at PLAYER_LOGIN)
-- ===================================================================
function Textures.Init()
  EnsureDriver()

  -- Rebind whenever CDM frames are rescanned/rebuilt (login, spec change,
  -- CDM layout change). Chains the central scan-complete callback the same
  -- way the cooldown-bars module does, so Core stays untouched.
  if ns.Catalog and not Textures._scanChained then
    Textures._scanChained = true
    local orig = ns.Catalog.OnCDMScanComplete
    ns.Catalog.OnCDMScanComplete = function(...)
      if orig then orig(...) end
      if Textures.RefreshAll then Textures.RefreshAll() end
    end
  end

  Textures.RefreshAll()
end
