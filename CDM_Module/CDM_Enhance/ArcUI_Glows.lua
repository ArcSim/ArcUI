-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_Glows.lua — Unified glow module for ArcUI
--
-- Single API for all glow types across CDMEnhance and ArcAurasCooldown.
--
-- SUPPORTED GLOW TYPES:
--   LCG (LibCustomGlow):
--     "pixel"     — marching dots around frame edge
--     "autocast"  — spinning particle sparkles
--     "button"    — classic WoW action button glow
--     "proc"      — Blizzard-style proc flipbook (burst intro → loop)
--                    Also accepted as "blizzard" for backwards compat
--
--   Blizzard Templates (ArcUI-owned frames):
--     "ants"      — ActionBarButtonAssistedCombatHighlightTemplate
--     "ach_proc"  — ActionButtonSpellAlertTemplate (loop only, no burst)
--     "cdm_flash" — CDM VisualAlert-Glow (pulsing alpha bounce overlay)
--
--   CDM Native (passthrough):
--     "default"   — CDM's own SpellActivationAlert (managed by CDM, not us)
--
-- USAGE:
--   ns.Glows.Start(frame, "ready", "pixel", { color = {1,0.8,0,1}, lines = 8 })
--   ns.Glows.Stop(frame, "ready")
--   ns.Glows.StopAll(frame)
--
-- KEYS:
--   Each key ("ready", "usable", "proc", "aura", etc.) is independent.
--   Multiple keys can be active on the same frame simultaneously.
--   LCG supports per-key storage natively. Blizzard templates are cached
--   on the frame by composite key (e.g. frame._arcGlow_ants_ready).
--
-- OPTIONS SUPPORT MATRIX (queried via ns.Glows.GetSupportedOpts):
--   Option      | pixel | autocast | button | proc  | ants  | ach_proc
--   ------------|-------|----------|--------|-------|-------|----------
--   color       |  yes  |   yes    |  yes   |  yes  |  yes  |   yes
--   intensity   |  yes  |   yes    |   —    |  yes  |  yes  |   yes
--   scale       | thick |  native  | frame  | frame |  yes  |   yes
--   speed       |  yes  |   yes    |  yes   |   —   |   —   |    —
--   lines       |  yes  |    —     |   —    |   —   |   —   |    —
--   thickness   |  yes  |    —     |   —    |   —   |   —   |    —
--   length      |  yes  |    —     |   —    |   —   |   —   |    —
--   border      |  yes  |    —     |   —    |   —   |   —   |    —
--   particles   |   —   |   yes    |   —    |   —   |   —   |    —
--   xOffset     |  yes  |   yes    |   —    |  yes  |  yes  |   yes
--   yOffset     |  yes  |   yes    |   —    |  yes  |  yes  |   yes
--   frameLevel  |  yes  |   yes    |  yes   |  yes  |  yes  |   yes
--   strata      |  yes  |   yes    |  yes   |  yes  |  yes  |   yes
--
-- Scale behavior:
--   pixel    → baked into thickness (thickness * scale), not SetScale
--   autocast → LCG native particle scale param, not SetScale
--   button/proc → SetScale on glow frame
--   ants/ach_proc → direct sizing in template code
-- ═══════════════════════════════════════════════════════════════════════════

local _, ns = ...

ns.Glows = {}

-- ── Lazy references ──────────────────────────────────────────────────────

local LCG
local function GetLCG()
    if not LCG then
        LCG = LibStub and LibStub("ArcGlow-1.0", true)
    end
    return LCG
end

-- ── State tracking ───────────────────────────────────────────────────────
-- activeGlows[frame][key] = { type = glowType, opts = opts }
-- Caches opts so Resize can re-call Start (WeakAuras pattern).
-- Weak keys: if a frame is destroyed without StopAll, it gets GC'd.

local activeGlows = setmetatable({}, { __mode = "k" })

-- ── Cached frame sizes ────────────────────────────────────────────────────
-- frameSizeCache[frame] = { w, h }
-- When GetWidth/GetHeight returns a non-secret value, we store it here.
-- If the value is ever secret (CDM layout tainted), we fall back to the
-- last known good size so glow frames are still sized correctly.
-- Weak keys: auto-cleaned when frame is GC'd.
local frameSizeCache = setmetatable({}, { __mode = "k" })

local function GetFrameSize(frame)
    local w, h = frame:GetWidth(), frame:GetHeight()
    local wSecret = issecretvalue and issecretvalue(w)
    local hSecret = issecretvalue and issecretvalue(h)
    if not wSecret and not hSecret then
        -- Good values - cache and return
        if w and h and w > 1 and h > 1 then
            frameSizeCache[frame] = { w, h }
        end
        return w, h
    end
    -- Secret - use last cached size if available
    local cached = frameSizeCache[frame]
    if cached then
        return cached[1], cached[2]
    end
    -- No cache yet - return as-is (caller guards against bad values)
    return w, h
end

-- ── Constants ────────────────────────────────────────────────────────────

-- Sizing ratios from Blizzard's ActionButtonSpellAlertTemplate XML:
--   Default icon = 45x45, container ~66x66
local BLIZZ_CONTAINER_RATIO = 66 / 45   -- ~1.467

-- Default glow frame level offset above parent
local GLOW_LEVEL_OFFSET = 1

-- CDM Flash renders BEHIND the icon by default (looks better as a background pulse).
-- Users can override via the Glow Frame Level option.
local CDM_FLASH_LEVEL_OFFSET = -2

-- Shallow copy for opts caching (prevents stale data if caller reuses table)
local function ShallowCopy(t)
    if not t then return {} end
    local copy = {}
    for k, v in pairs(t) do copy[k] = v end
    return copy
end

-- Get storage key for a Blizzard template glow on a frame
local function BlizzKey(glowType, key)
    return "_arcGlow_" .. glowType .. "_" .. (key or "")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MASQUE SHAPE MATCHING
-- If Masque is skinning an icon with a non-square shape (circle, diamond,
-- hexagon), glow textures must match. This queries Masque's public API
-- and swaps flipbook textures on our Blizzard-template and LCG glows.
-- No-op when Masque is absent or using default square skin.
-- ═══════════════════════════════════════════════════════════════════════════

local MasqueLib  -- cached on first use

local function GetMasqueLib()
    if MasqueLib ~= nil then return MasqueLib end  -- false = checked, not found
    MasqueLib = LibStub and LibStub("Masque", true) or false
    return MasqueLib
end

local function GetMasqueShape(frame)
    if not frame then return nil end
    -- Respect user toggle: disable Masque shape-matching for glows
    if ns.db and ns.db.profile and ns.db.profile.cdmEnhance
        and ns.db.profile.cdmEnhance.glowUseMasqueShapes == false then
        return nil
    end
    local mcfg = frame._MSQ_CFG
    if not mcfg then return nil end
    if not mcfg.Enabled or mcfg.BaseSkin then return nil end
    return mcfg.Shape
end

-- Find the FlipBook animation child from an AnimationGroup
local function GetFlipBookAnim(animGroup)
    if not animGroup then return nil end
    for _, child in pairs({ animGroup:GetAnimations() }) do
        if child and child.SetFlipBookFrameWidth then return child end
    end
    return nil
end

-- Apply Masque shape textures to a Blizzard-template glow (ach_proc uses this)
local function ApplyMasqueShapeToTemplateProc(frame, glow)
    local shape = GetMasqueShape(frame)
    if not shape then return end
    local lib = GetMasqueLib()
    if not lib or not lib.GetSpellAlertFlipBook then return end

    local ok, flipData = pcall(lib.GetSpellAlertFlipBook, lib, "Modern", shape)
    if not ok or not flipData then
        ok, flipData = pcall(lib.GetSpellAlertFlipBook, lib, "Classic", shape)
    end
    if not ok or not flipData then return end

    -- Loop texture
    if flipData.LoopTexture and glow.ProcLoopFlipbook then
        glow.ProcLoopFlipbook:SetTexture(flipData.LoopTexture)
    end

    -- Start texture — ach_proc hides start, but guard for safety
    if glow.ProcStartFlipbook then
        if flipData.StartTexture then
            glow.ProcStartFlipbook:SetTexture(flipData.StartTexture)
            glow._Loop_Only = nil
        else
            glow._Loop_Only = true
            glow.ProcStartFlipbook:Hide()
            if glow.ProcStartAnim then
                local anim = GetFlipBookAnim(glow.ProcStartAnim)
                if anim then anim:SetDuration(0) end
            end
        end
    end

    -- Animation dimensions — ProcLoop
    local loopGroup = glow.ProcLoopAnim or glow.ProcLoop
    if loopGroup and flipData.FrameWidth then
        local anim = GetFlipBookAnim(loopGroup)
        if anim then
            anim:SetFlipBookFrameWidth(flipData.FrameWidth)
            anim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
        end
    end

    -- Animation dimensions — ProcStart
    if glow.ProcStartAnim and flipData.FrameWidth then
        local anim = GetFlipBookAnim(glow.ProcStartAnim)
        if anim then
            anim:SetFlipBookFrameWidth(flipData.FrameWidth)
            anim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
        end
    end

    -- AltGlow texture (some shapes provide it)
    if glow.ProcAltGlow and shape then
        local altPath = [[Interface\AddOns\Masque\Textures\]] .. shape .. [[\SpellAlert-AltGlow]]
        glow.ProcAltGlow:SetTexture(altPath)
    end
end

-- Apply Masque shape to LCG ProcGlow (uses .ProcStart/.ProcLoop, not Flipbook names)
local function ApplyMasqueShapeToLCGProc(frame, glowFrame)
    local shape = GetMasqueShape(frame)
    if not shape then return end
    local lib = GetMasqueLib()
    if not lib or not lib.GetSpellAlertFlipBook then return end

    local ok, flipData = pcall(lib.GetSpellAlertFlipBook, lib, "Modern", shape)
    if not ok or not flipData then
        ok, flipData = pcall(lib.GetSpellAlertFlipBook, lib, "Classic", shape)
    end
    if not ok or not flipData then return end

    -- LCG naming: .ProcLoop / .ProcStart (not .ProcLoopFlipbook)
    if flipData.LoopTexture and glowFrame.ProcLoop then
        glowFrame.ProcLoop:SetTexture(flipData.LoopTexture)
    end
    if glowFrame.ProcStart then
        glowFrame.ProcStart:SetTexture(flipData.StartTexture or flipData.LoopTexture or "")
    end

    -- Animation dimensions
    if glowFrame.ProcLoopAnim and flipData.FrameWidth then
        local anim = glowFrame.ProcLoopAnim.FlipAnim or GetFlipBookAnim(glowFrame.ProcLoopAnim)
        if anim then
            anim:SetFlipBookFrameWidth(flipData.FrameWidth)
            anim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
        end
    end
    if glowFrame.ProcStartAnim and flipData.FrameWidth then
        local anim = glowFrame.ProcStartAnim.FlipAnim or GetFlipBookAnim(glowFrame.ProcStartAnim)
        if anim then
            anim:SetFlipBookFrameWidth(flipData.FrameWidth)
            anim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
        end
    end
end

-- Apply Masque shape to ants (AssistedCombatHighlight) glow
local function ApplyMasqueShapeToAnts(frame, glow)
    if not glow or not glow.Flipbook then return end
    local shape = GetMasqueShape(frame)
    if not shape then return end
    local lib = GetMasqueLib()
    if not lib or not lib.GetAssistedCombatHighlightStyle then return end

    local ok, styleData = pcall(lib.GetAssistedCombatHighlightStyle, lib, shape)
    if not ok or not styleData then return end

    if styleData.Texture then
        glow.Flipbook:SetTexture(styleData.Texture)
    end
    if styleData.TexCoords then
        local tc = styleData.TexCoords
        glow.Flipbook:SetTexCoord(tc[1] or 0, tc[2] or 1, tc[3] or 0, tc[4] or 1)
    end
    if glow.Flipbook.Anim and styleData.FrameWidth then
        local anim = GetFlipBookAnim(glow.Flipbook.Anim)
        if anim then
            anim:SetFlipBookFrameWidth(styleData.FrameWidth)
            anim:SetFlipBookFrameHeight(styleData.FrameHeight or 0)
        end
        -- Reinitialize to pick up new texture/frame dimensions.
        -- If the glow is currently visible, restart the animation instead of stopping it.
        if glow:IsShown() then
            glow.Flipbook.Anim:Stop()
            glow.Flipbook.Anim:Play()
        else
            glow.Flipbook.Anim:Play()
            glow.Flipbook.Anim:Stop()
        end
    end
end

-- Apply Masque shape to LCG ButtonGlow via Masque's UpdateSpellAlert API
local function ApplyMasqueShapeToButton(frame, key)
    local shape = GetMasqueShape(frame)
    if not shape then return end
    local lib = GetMasqueLib()
    if not lib or not lib.UpdateSpellAlert then return end

    local glowFrame = frame["_ButtonGlow" .. key]
    if not glowFrame then return end
    pcall(lib.UpdateSpellAlert, lib, frame, glowFrame)
end

-- Apply Masque shape mask to CDM flash glow texture.
-- Without this, the soft radial glow renders as a square on circle icons.
local function ApplyMasqueShapeToCDMFlash(frame, glow)
    if not glow or not glow.Glow then return end
    local shape = GetMasqueShape(frame)

    if not shape or shape == "Square" then
        -- Remove mask if previously applied (user switched skin to square)
        if glow._arcFlashMask then
            glow.Glow:RemoveMaskTexture(glow._arcFlashMask)
            glow._arcFlashMask:Hide()
        end
        return
    end

    -- Create mask texture once, reuse across reshapes
    if not glow._arcFlashMask then
        glow._arcFlashMask = glow:CreateMaskTexture()
    end

    local mask = glow._arcFlashMask
    mask:SetAllPoints(glow)  -- match glow frame size (expanded beyond icon)

    if shape == "Circle" then
        mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    else
        -- Non-circle non-square: try to clone Masque's button mask texture
        local mcfg = frame._MSQ_CFG
        local bMask = mcfg and mcfg.ButtonMask
        if bMask then
            local atlas = bMask:GetAtlas()
            if atlas then
                mask:SetAtlas(atlas)
            else
                local tex = bMask:GetTexture()
                if tex then mask:SetTexture(tex) end
            end
        else
            -- Fallback: use circle mask for unknown shapes
            mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        end
    end

    mask:Show()
    glow.Glow:AddMaskTexture(mask)
end

-- ── Master dispatcher: call after Start() creates/shows a glow ───────────
local function ApplyMasqueShape(frame, glowType, key)
    if not GetMasqueShape(frame) then return end

    if glowType == "proc" then
        local glowFrame = frame["_ProcGlow" .. key]
        if glowFrame then ApplyMasqueShapeToLCGProc(frame, glowFrame) end

    elseif glowType == "ach_proc" then
        local storageKey = BlizzKey("ach_proc", key)
        local glow = frame[storageKey]
        if glow then ApplyMasqueShapeToTemplateProc(frame, glow) end

    elseif glowType == "ants" then
        local storageKey = BlizzKey("ants", key)
        local glow = frame[storageKey]
        if glow then ApplyMasqueShapeToAnts(frame, glow) end

    elseif glowType == "button" then
        ApplyMasqueShapeToButton(frame, key)

    elseif glowType == "cdm_flash" then
        local storageKey = BlizzKey("cdm_flash", key)
        local glow = frame[storageKey]
        if glow then ApplyMasqueShapeToCDMFlash(frame, glow) end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- LCG POST-START HELPERS
-- After LCG creates/shows a glow frame, apply options that LCG doesn't
-- handle natively: intensity (alpha), strata override, scale.
-- ═══════════════════════════════════════════════════════════════════════════

-- Map glowType+key → LCG frame reference on parent
local function GetLCGFrame(frame, glowType, key)
    if glowType == "pixel" then
        return frame["_PixelGlow" .. key]
    elseif glowType == "autocast" then
        return frame["_AutoCastGlow" .. key]
    elseif glowType == "button" then
        return frame["_ButtonGlow" .. (key or "")]
    elseif glowType == "proc" then
        return frame["_ProcGlow" .. key]
    end
    return nil
end

local function ApplyPostStartOpts(frame, glowType, key, opts)
    local glowFrame = GetLCGFrame(frame, glowType, key)
    if not glowFrame then return end

    -- Enforce glow frame dimensions to match parent frame.
    -- The old CDMEnhance overlay called SetSize(frameW, frameH) before every
    -- LCG call. Without this, Masque-skinned frames can report stale layout
    -- dimensions to LCG at creation time, causing undersized glows.
    local pw, ph = GetFrameSize(frame)
    if pw and ph and pw > 1 and ph > 1 and glowType ~= "button" then
        -- Button glow manages its own internal texture sizing
        -- Snap to integer screen pixels to prevent 1px glow misalignment at fractional UI scales
        local effScale = frame:GetEffectiveScale()
        if effScale and effScale > 0 then
            pw = math.floor(pw * effScale + 0.5) / effScale
            ph = math.floor(ph * effScale + 0.5) / effScale
        end
        glowFrame:SetSize(pw, ph)
    end

    -- Intensity (alpha override) — skip button, it has own fade animations
    if opts.intensity and glowType ~= "button" then
        glowFrame:SetAlpha(opts.intensity)
    end

    -- Scale via SetScale — skip pixel (baked into thickness) and autocast (native param)
    if glowType ~= "autocast" and glowType ~= "pixel" then
        if opts.scale and opts.scale ~= 1 then
            glowFrame:SetScale(opts.scale)
            glowFrame._arcGlowScaleOverride = opts.scale
        elseif glowFrame._arcGlowScaleOverride then
            glowFrame:SetScale(1)
            glowFrame._arcGlowScaleOverride = nil
        end
    end

    -- Strata override
    if opts.strata and opts.strata ~= "inherit" then
        pcall(glowFrame.SetFrameStrata, glowFrame, opts.strata)
        glowFrame._arcGlowStrataOverride = opts.strata
    elseif glowFrame._arcGlowStrataOverride then
        local parentStrata = frame:GetFrameStrata() or "MEDIUM"
        pcall(glowFrame.SetFrameStrata, glowFrame, parentStrata)
        glowFrame._arcGlowStrataOverride = nil
    end

    -- Translate: move entire glow frame by shifting both LCG anchors equally.
    -- GetSize() returns 0 before layout pass, so we can't use SetSize+CENTER.
    -- Re-apply LCG's TOPLEFT+BOTTOMRIGHT offsets shifted by tx/ty to preserve size.
    local tx = opts.translateX or 0
    local ty = opts.translateY or 0
    if tx ~= 0 or ty ~= 0 then
        local xOff = opts.xOffset or 0
        local yOff = opts.yOffset or 0
        glowFrame:ClearAllPoints()
        glowFrame:SetPoint("TOPLEFT",     frame, "TOPLEFT",     -xOff + 0.05 + tx,  yOff + 0.05 + ty)
        glowFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",  xOff         + tx, -yOff + 0.05 + ty)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BLIZZARD TEMPLATE GLOW HELPERS
-- Ants and ACH-Proc use Blizzard XML templates (not LCG).
-- Cached on the frame by composite key to avoid re-creation.
-- ═══════════════════════════════════════════════════════════════════════════

local function GetOrCreateACHGlow(frame, style, key)
    local storageKey = BlizzKey(style, key)
    if frame[storageKey] then return frame[storageKey] end

    local glow
    if style == "ants" then
        glow = CreateFrame("Frame", nil, frame, "ActionBarButtonAssistedCombatHighlightTemplate")
        if not glow then return nil end
        glow._achStyle = "ants"
        if glow.Flipbook and glow.Flipbook.Anim then
            glow.Flipbook.Anim:Play()
            glow.Flipbook.Anim:Stop()
        end
    elseif style == "ach_proc" then
        glow = CreateFrame("Frame", nil, frame, "ActionButtonSpellAlertTemplate")
        if not glow then return nil end
        glow._achStyle = "ach_proc"
        if glow.ProcLoopFlipbook then
            glow.ProcLoopFlipbook:SetAlpha(1)
            glow.ProcLoopFlipbook:Show()
        end
        if glow.ProcLoop then
            glow.ProcLoop:Play()
            glow.ProcLoop:Stop()
        end
        -- When the parent CDM frame is hidden/shown (e.g. totem update sweep),
        -- WoW stops all animations on hidden frames. Restart ProcLoop on re-show.
        glow:SetScript("OnShow", function(self)
            if self.ProcStartFlipbook then self.ProcStartFlipbook:Hide() end
            if self.ProcLoop and not self.ProcLoop:IsPlaying() then
                if self.ProcLoopFlipbook then
                    self.ProcLoopFlipbook:Show()
                    self.ProcLoopFlipbook:SetAlpha(1)
                end
                self.ProcLoop:Play()
            end
        end)
    else
        return nil
    end

    glow:SetPoint("CENTER")
    glow:Hide()
    frame[storageKey] = glow

    -- Apply Masque shape BEFORE first show (prevents square→circle flash)
    if style == "ants" then
        ApplyMasqueShapeToAnts(frame, glow)
    elseif style == "ach_proc" then
        ApplyMasqueShapeToTemplateProc(frame, glow)
    end

    return glow
end

local function ShowACHGlow(frame, style, key, opts)
    local glow = GetOrCreateACHGlow(frame, style, key)
    if not glow then return end

    local w, h = GetFrameSize(frame)
    if not w or not h or w <= 0 or h <= 0 then return end

    local scale = opts.scale or 1.0
    -- Square Masque skins make ach_proc oversized — default to 0.8 if user hasn't set scale
    if style == "ach_proc" and not opts.scale and GetMasqueShape(frame) == "Square" then
        scale = 0.8
    end
    local xOff = opts.xOffset or 0
    local yOff = opts.yOffset or 0
    local tx = opts.translateX or 0
    local ty = opts.translateY or 0
    local containerW = w * BLIZZ_CONTAINER_RATIO * scale
    local containerH = h * BLIZZ_CONTAINER_RATIO * scale

    if style == "ants" then
        -- ACH pattern: container = icon size, flipbook texture = expanded beyond
        local iconW = w * scale
        local iconH = h * scale
        glow:SetSize(iconW, iconH)
        if glow.Flipbook then
            glow.Flipbook:SetSize(iconW * BLIZZ_CONTAINER_RATIO, iconH * BLIZZ_CONTAINER_RATIO)
        end
    elseif style == "ach_proc" then
        glow:SetSize(containerW, containerH)
        if glow.ProcStartFlipbook then glow.ProcStartFlipbook:Hide() end
    end

    -- Position with offset + translate
    if xOff ~= 0 or yOff ~= 0 or tx ~= 0 or ty ~= 0 then
        glow:ClearAllPoints()
        glow:SetPoint("CENTER", frame, "CENTER", xOff + tx, yOff + ty)
    end

    glow:SetFrameLevel(frame:GetFrameLevel() + (opts.frameLevel or GLOW_LEVEL_OFFSET))

    -- Color
    local color = opts.color
    if color then
        local r = color[1] or color.r or 1
        local g = color[2] or color.g or 1
        local b = color[3] or color.b or 1
        local a = color[4] or color.a or 1

        if style == "ants" and glow.Flipbook then
            local hasCustomColor = not (r >= 0.99 and g >= 0.99 and b >= 0.99)
            glow.Flipbook:SetDesaturated(hasCustomColor)
            glow.Flipbook:SetVertexColor(r, g, b, a)
        elseif style == "ach_proc" then
            local hasCustomColor = not (r >= 0.99 and g >= 0.99 and b >= 0.99)
            if glow.ProcLoopFlipbook then
                glow.ProcLoopFlipbook:SetDesaturated(hasCustomColor)
                glow.ProcLoopFlipbook:SetVertexColor(r, g, b, a)
            end
            if glow.ProcAltGlow then
                glow.ProcAltGlow:SetDesaturated(hasCustomColor)
                glow.ProcAltGlow:SetVertexColor(r, g, b, a)
            end
        end
    end

    -- Intensity (alpha)
    glow:SetAlpha(opts.intensity or 1.0)

    -- Strata override
    if opts.strata and opts.strata ~= "inherit" then
        pcall(glow.SetFrameStrata, glow, opts.strata)
        glow._arcGlowStrataOverride = opts.strata
    elseif glow._arcGlowStrataOverride then
        local parentStrata = frame:GetFrameStrata() or "MEDIUM"
        pcall(glow.SetFrameStrata, glow, parentStrata)
        glow._arcGlowStrataOverride = nil
    end

    -- Show + play
    glow:Show()
    if style == "ants" and glow.Flipbook and glow.Flipbook.Anim then
        if not glow.Flipbook.Anim:IsPlaying() then
            glow.Flipbook.Anim:Play()
        end
    elseif style == "ach_proc" then
        if glow.ProcLoopFlipbook then
            glow.ProcLoopFlipbook:Show()
            glow.ProcLoopFlipbook:SetAlpha(1)
        end
        if glow.ProcLoop and not glow.ProcLoop:IsPlaying() then
            glow.ProcLoop:Play()
        end
    end
end

local function HideACHGlow(frame, style, key)
    local storageKey = BlizzKey(style, key)
    local glow = frame[storageKey]
    if not glow then return end

    if style == "ants" then
        if glow.Flipbook and glow.Flipbook.Anim and glow.Flipbook.Anim:IsPlaying() then
            glow.Flipbook.Anim:Stop()
        end
    elseif style == "ach_proc" then
        if glow.ProcLoop and glow.ProcLoop:IsPlaying() then
            glow.ProcLoop:Stop()
        end
        if glow.ProcLoopFlipbook then glow.ProcLoopFlipbook:Hide() end
    end

    glow:Hide()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CDM VISUAL ALERT GLOW HELPERS
-- CDM ships a pulsing glow overlay we can reuse:
--   cdm_flash — atlas UI-CooldownManager-VisualAlert-Glow
--               Alpha bounces 0.25→1.0, tintable via SetVertexColor.
--               For Masque circle skins, a circular mask is applied so the glow
--               matches the icon shape rather than rendering as a square.
-- Created programmatically (no XML template dependency).
-- ═══════════════════════════════════════════════════════════════════════════

local function GetOrCreateCDMFlash(frame, key)
    local storageKey = BlizzKey("cdm_flash", key)
    if frame[storageKey] then return frame[storageKey] end

    local glow = CreateFrame("Frame", nil, frame)
    if not glow then return nil end
    glow._cdmStyle = "cdm_flash"

    -- Pulsing glow overlay (CDM's UI-CooldownManager-VisualAlert-Glow)
    local tex = glow:CreateTexture(nil, "ARTWORK")
    tex:SetAtlas("UI-CooldownManager-VisualAlert-Glow")
    tex:SetAllPoints()
    glow.Glow = tex

    -- Alpha bounce animation: 0.25→1.0, 0.5s default, IN_OUT smoothing
    local ag = glow:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local alpha = ag:CreateAnimation("Alpha")
    alpha:SetChildKey("Glow")
    alpha:SetDuration(0.5)
    alpha:SetOrder(1)
    alpha:SetSmoothing("IN_OUT")
    alpha:SetFromAlpha(0.25)
    alpha:SetToAlpha(1)
    glow.Glow.AlphaAnim = alpha
    glow.FlashAG = ag

    glow:SetPoint("CENTER")
    glow:Hide()
    frame[storageKey] = glow

    -- Apply Masque shape mask BEFORE first show
    ApplyMasqueShapeToCDMFlash(frame, glow)

    return glow
end

local function ShowCDMFlash(frame, key, opts)
    local glow = GetOrCreateCDMFlash(frame, key)
    if not glow then return end

    local w, h = GetFrameSize(frame)
    if not w or not h or w <= 0 or h <= 0 then return end

    local scale = opts.scale or 1.0
    local xOff = opts.xOffset or 0
    local yOff = opts.yOffset or 0
    local tx = opts.translateX or 0
    local ty = opts.translateY or 0

    -- Expand slightly beyond icon edge like CDM's -8,+8 / +9,-9 anchoring
    local expandW = w * BLIZZ_CONTAINER_RATIO * scale
    local expandH = h * BLIZZ_CONTAINER_RATIO * scale
    glow:SetSize(expandW, expandH)

    -- Position
    glow:ClearAllPoints()
    glow:SetPoint("CENTER", frame, "CENTER", xOff + tx, yOff + ty)

    glow:SetFrameLevel(math.max(0, frame:GetFrameLevel() + (opts.frameLevel or CDM_FLASH_LEVEL_OFFSET)))

    -- Color — white-base atlas, easy to tint
    local color = opts.color
    if color and glow.Glow then
        local r = color[1] or color.r or 1
        local g = color[2] or color.g or 1
        local b = color[3] or color.b or 1
        local a = color[4] or color.a or 1
        local hasCustomColor = not (r >= 0.99 and g >= 0.99 and b >= 0.99)
        glow.Glow:SetDesaturated(hasCustomColor)
        glow.Glow:SetVertexColor(r, g, b, a)
    end

    -- Intensity
    glow:SetAlpha(opts.intensity or 1.0)

    -- Speed — controls pulse rate
    if glow.Glow and glow.Glow.AlphaAnim then
        local speed = opts.frequency or 0.5
        -- frequency is smaller = faster for consistency with other glow types
        -- map: 0.125 → 0.25s pulse, 0.25 → 0.5s, 0.5 → 1.0s
        glow.Glow.AlphaAnim:SetDuration(speed * 2)
    end

    -- Strata override
    if opts.strata and opts.strata ~= "inherit" then
        pcall(glow.SetFrameStrata, glow, opts.strata)
        glow._arcGlowStrataOverride = opts.strata
    elseif glow._arcGlowStrataOverride then
        local parentStrata = frame:GetFrameStrata() or "MEDIUM"
        pcall(glow.SetFrameStrata, glow, parentStrata)
        glow._arcGlowStrataOverride = nil
    end

    -- Show + play
    glow:Show()
    if glow.FlashAG and not glow.FlashAG:IsPlaying() then
        glow.FlashAG:Play()
    end
end

local function HideCDMFlash(frame, key)
    local storageKey = BlizzKey("cdm_flash", key)
    local glow = frame[storageKey]
    if not glow then return end

    if glow.FlashAG and glow.FlashAG:IsPlaying() then
        glow.FlashAG:Stop()
    end
    glow:Hide()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

--- Start a glow on a frame.
-- @param frame     The icon frame to glow
-- @param key       Glow slot: "ready", "usable", "proc", "aura", etc.
-- @param glowType  One of: "pixel", "autocast", "button", "proc",
--                  "blizzard" (alias for proc), "ants", "ach_proc",
--                  "cdm_flash", "default"
-- @param opts      Table of glow parameters (all optional):
--   color       {r, g, b, a} or {[1]=r, [2]=g, [3]=b, [4]=a}
--   intensity   alpha override 0-1, default 1 (not button — has own fade)
--   scale       size multiplier, default 1 (all types)
--   lines       (pixel) number of lines, default 8
--   frequency   (pixel/autocast/button) speed, default 0.25
--   length      (pixel) line length
--   thickness   (pixel) line thickness, default 2
--   particles   (autocast) particle groups, default 4
--   xOffset     offset from frame edge, default 0 (not button)
--   yOffset     offset from frame edge, default 0 (not button)
--   frameLevel  override frame level offset (default GLOW_LEVEL_OFFSET)
--   strata      frame strata override, "inherit" or "LOW"/"MEDIUM"/"HIGH"/"DIALOG"
--   startAnim   (proc only) play burst intro, default false
--   duration    (proc only) loop duration, default 1
function ns.Glows.Start(frame, key, glowType, opts)
    if not frame or not key or not glowType then return end
    opts = opts or {}

    -- Normalize "blizzard" → "proc" (merged — both use LCG ProcGlow)
    if glowType == "blizzard" then glowType = "proc" end

    -- If this key already has a DIFFERENT type active, stop it first
    local current = activeGlows[frame] and activeGlows[frame][key]
    if current and current.type ~= glowType then
        ns.Glows.Stop(frame, key)
    end

    -- Normalize color to array format for LCG
    local color = opts.color
    local colorArray
    if color then
        if color.r then
            colorArray = { color.r, color.g or 1, color.b or 1, color.a or 1 }
        else
            colorArray = color
        end
    end

    local lvl = opts.frameLevel or GLOW_LEVEL_OFFSET

    -- ── LCG types ────────────────────────────────────────────────────
    if glowType == "pixel" then
        local lib = GetLCG()
        if not lib then return end
        -- Bake scale into thickness (old CDMEnhance pattern) rather than SetScale
        -- SetScale would expand the entire glow frame including offsets
        local scale = opts.scale or 1
        local t = opts.thickness or 2
        if scale ~= 1 then t = math.max(1, math.floor(t * scale)) end
        lib.PixelGlow_Start(
            frame, colorArray,
            opts.lines or 8,
            opts.frequency or 0.25,
            opts.length,
            t,
            opts.xOffset or 0,
            opts.yOffset or 0,
            opts.border ~= false,  -- default true: lines orbit frame edges
            key,
            lvl
        )
        ApplyPostStartOpts(frame, glowType, key, opts)

    elseif glowType == "autocast" then
        local lib = GetLCG()
        if not lib then return end
        lib.AutoCastGlow_Start(
            frame, colorArray,
            opts.particles or 4,
            opts.frequency or 0.25,
            opts.scale or 1,  -- native particle scale (orbit radius stays at frame edge)
            opts.xOffset or 0,
            opts.yOffset or 0,
            key,
            lvl
        )
        ApplyPostStartOpts(frame, glowType, key, opts)

    elseif glowType == "button" then
        local lib = GetLCG()
        if not lib then return end
        lib.ButtonGlow_Start(
            frame, colorArray,
            opts.frequency or 0.125,
            lvl,
            key,
            opts.xOffset or 0,
            opts.yOffset or 0
        )
        ApplyPostStartOpts(frame, glowType, key, opts)

    elseif glowType == "proc" then
        local lib = GetLCG()
        if not lib then return end
        lib.ProcGlow_Start(frame, {
            key        = key,
            frameLevel = lvl,
            color      = colorArray,
            startAnim  = opts.startAnim or false,
            duration   = opts.duration or 1,
            xOffset    = opts.xOffset or 0,
            yOffset    = opts.yOffset or 0,
        })
        ApplyPostStartOpts(frame, glowType, key, opts)

    -- ── Blizzard template types ──────────────────────────────────────
    elseif glowType == "ants" then
        ShowACHGlow(frame, "ants", key, opts)

    elseif glowType == "ach_proc" then
        ShowACHGlow(frame, "ach_proc", key, opts)

    -- ── CDM visual alert types ───────────────────────────────────────
    elseif glowType == "cdm_flash" then
        ShowCDMFlash(frame, key, opts)

    elseif glowType == "default" then
        -- "default" = CDM's own SpellActivationAlert, not managed by us.
        -- Caller is responsible for CDM interaction. This is a no-op marker
        -- so StopAll knows a glow context is active.

    else
        return  -- Unknown type, don't track
    end

    -- Track (cache opts for Resize)
    if not activeGlows[frame] then
        activeGlows[frame] = {}
    end
    activeGlows[frame][key] = { type = glowType, opts = ShallowCopy(opts) }

    -- Apply Masque shape textures if Masque is skinning this frame.
    ApplyMasqueShape(frame, glowType, key)

    -- Auto-hook OnSizeChanged once per frame (WeakAuras pattern).
    if not frame._arcGlowSizeHooked then
        frame._arcGlowSizeHooked = true
        local throttle = 0
        frame:HookScript("OnSizeChanged", function(self)
            if not activeGlows[self] then return end
            local now = GetTime()
            if now == throttle then return end
            throttle = now
            local _sw, _sh = GetFrameSize(self)
            if not _sw or not _sh or _sw < 1 or _sh < 1 then return end
            ns.Glows.ResizeAll(self)
        end)
    end
end

--- Stop a glow on a frame by key.
function ns.Glows.Stop(frame, key)
    if not frame or not key then return end

    local frameGlows = activeGlows[frame]
    if not frameGlows then return end

    local entry = frameGlows[key]
    if not entry then return end

    local glowType = entry.type

    local lib = GetLCG()
    if glowType == "pixel" and lib then
        lib.PixelGlow_Stop(frame, key)
    elseif glowType == "autocast" and lib then
        lib.AutoCastGlow_Stop(frame, key)
    elseif glowType == "button" and lib then
        lib.ButtonGlow_Stop(frame, key)
    elseif glowType == "proc" and lib then
        if lib.ProcGlow_Stop then
            lib.ProcGlow_Stop(frame, key)
        end
    elseif glowType == "ants" then
        HideACHGlow(frame, "ants", key)
    elseif glowType == "ach_proc" then
        HideACHGlow(frame, "ach_proc", key)
    elseif glowType == "cdm_flash" then
        HideCDMFlash(frame, key)
    end

    frameGlows[key] = nil
    -- Clear forced alpha state if it was set for this key
    frame._arcForcedGlowAlpha = nil
    local gf = GetLCGFrame(frame, glowType, key)
    if gf then
        gf._arcAlphaForced = nil
        -- Restore original SetAlpha so the pooled frame isn't permanently hobbled
        -- when reused for a different glow key. LCG's FramePoolResetter doesn't
        -- clear these ArcUI flags, so without this a pixel glow frame that was
        -- used for ReadyGlow (with SetForcedAlpha) will silently block SetAlpha
        -- on its next use (e.g. AuraGlow), making pixel glows invisible.
        if gf._arcAlphaHooked and gf._arcOrigSetAlpha then
            gf.SetAlpha = gf._arcOrigSetAlpha
            gf._arcOrigSetAlpha = nil
            gf._arcAlphaHooked = nil
            gf:SetAlpha(1.0)
        end
    end
    if not next(frameGlows) then
        activeGlows[frame] = nil
    end
end

--- Stop ALL glows on a frame (all keys).
function ns.Glows.StopAll(frame)
    if not frame then return end
    local frameGlows = activeGlows[frame]
    if not frameGlows then return end

    local keys = {}
    for key in pairs(frameGlows) do
        keys[#keys + 1] = key
    end
    for _, key in ipairs(keys) do
        ns.Glows.Stop(frame, key)
    end
end

--- Check if a specific glow key is active on a frame.
function ns.Glows.IsActive(frame, key)
    if not frame or not key then return nil end
    local frameGlows = activeGlows[frame]
    local entry = frameGlows and frameGlows[key]
    return entry and entry.type
end

--- Get all active glow keys on a frame.
function ns.Glows.GetActive(frame)
    if not frame then return nil end
    local frameGlows = activeGlows[frame]
    if not frameGlows then return nil end
    local result = {}
    for key, entry in pairs(frameGlows) do
        result[key] = entry.type
    end
    return result
end

--- Get the actual LCG child frame for a glow key.
--- Use this to drive secret-safe SetAlpha() from curve evaluators.
--- Returns the LCG glow frame (or ACH template frame), or nil if not active.
function ns.Glows.GetGlowFrame(frame, key)
    if not frame or not key then return nil end
    local frameGlows = activeGlows[frame]
    local entry = frameGlows and frameGlows[key]
    if not entry then return nil end
    local t = entry.type
    if t == "pixel" then
        return frame["_PixelGlow" .. key]
    elseif t == "autocast" then
        return frame["_AutoCastGlow" .. key]
    elseif t == "button" then
        return frame["_ButtonGlow" .. (key or "")]
    elseif t == "proc" then
        return frame["_ProcGlow" .. key]
    elseif t == "ants" then
        return frame[BlizzKey("ants", key)]
    elseif t == "ach_proc" then
        return frame[BlizzKey("ach_proc", key)]
    elseif t == "cdm_flash" then
        return frame[BlizzKey("cdm_flash", key)]
    end
    return nil
end

--- Set forced alpha on a glow frame (secret-safe).
--- Hooks the glow frame's SetAlpha to block LCG's bgUpdate/animation overrides,
--- then calls the ORIGINAL SetAlpha directly with the secret value.
--- @param frame Frame The icon frame that owns the glow
--- @param key string The glow key (e.g. "ArcUI_ReadyGlow")
--- @param alpha number|secret The forced alpha value (0 = hidden, 1 = visible)
function ns.Glows.SetForcedAlpha(frame, key, alpha)
    if not frame or not key then return end
    local gf = ns.Glows.GetGlowFrame(frame, key)
    if not gf then return end
    -- Hook SetAlpha once — when forced, block ALL external SetAlpha calls
    -- (bgUpdate, animIn/Out callbacks, etc.)
    if not gf._arcAlphaHooked then
        gf._arcAlphaHooked = true
        gf._arcOrigSetAlpha = gf.SetAlpha
        gf.SetAlpha = function(self, a)
            if self._arcAlphaForced then return end
            self._arcOrigSetAlpha(self, a)
        end
    end
    gf._arcAlphaForced = true
    frame._arcForcedGlowAlpha = true
    -- Call ORIGINAL SetAlpha directly (bypasses our hook) with secret value
    gf._arcOrigSetAlpha(gf, alpha)
end

--- Clear forced alpha on a glow, restoring normal LCG alpha control.
function ns.Glows.ClearForcedAlpha(frame, key)
    if not frame then return end
    frame._arcForcedGlowAlpha = nil
    local gf = ns.Glows.GetGlowFrame(frame, key)
    if gf then
        gf._arcAlphaForced = nil
        -- Restore to full alpha so LCG can take over
        if gf._arcOrigSetAlpha then
            gf._arcOrigSetAlpha(gf, 1.0)
        elseif gf.SetAlpha then
            gf:SetAlpha(1.0)
        end
    end
end

--- Resize a specific glow after the parent frame changed size.
function ns.Glows.Resize(frame, key)
    if not frame or not key then return end
    local frameGlows = activeGlows[frame]
    if not frameGlows then return end
    local entry = frameGlows[key]
    if not entry then return end
    ns.Glows.Start(frame, key, entry.type, entry.opts)
end

--- Resize ALL active glows on a frame.
function ns.Glows.ResizeAll(frame)
    if not frame then return end
    local frameGlows = activeGlows[frame]
    if not frameGlows then return end
    for key, entry in pairs(frameGlows) do
        ns.Glows.Start(frame, key, entry.type, entry.opts)
    end
end

--- Force-hide a glow frame instantly (bypasses ButtonGlow fade animation).
function ns.Glows.ForceHide(frame, key)
    if not frame or not key then return end

    local frameGlows = activeGlows[frame]
    if not frameGlows then return end

    local entry = frameGlows[key]
    if not entry then return end

    -- For LCG types, find and instantly hide the glow frame
    local glowFrame = GetLCGFrame(frame, entry.type, key)
    if glowFrame then
        glowFrame:Hide()
    end

    ns.Glows.Stop(frame, key)
end

--- Force-hide ALL glows on a frame instantly.
function ns.Glows.ForceHideAll(frame)
    if not frame then return end
    local frameGlows = activeGlows[frame]
    if not frameGlows then return end

    local keys = {}
    for key in pairs(frameGlows) do
        keys[#keys + 1] = key
    end
    for _, key in ipairs(keys) do
        ns.Glows.ForceHide(frame, key)
    end
end

--- Refresh Masque shapes on all active glows (called when user toggles shape setting).
-- Destroys cached template glows (ants/ach_proc) so they get recreated with correct textures,
-- then restarts all active glows. No reload needed.
function ns.Glows.RefreshMasqueShapes()
    -- Collect active entries first (we'll modify activeGlows during iteration)
    local toRestart = {}
    for frame, frameGlows in pairs(activeGlows) do
        for key, entry in pairs(frameGlows) do
            toRestart[#toRestart + 1] = { frame = frame, key = key, type = entry.type, opts = entry.opts }
        end
    end

    -- Destroy cached template glows so they recreate with fresh textures
    for _, info in ipairs(toRestart) do
        local gt = info.type
        if gt == "ants" or gt == "ach_proc" or gt == "cdm_flash" then
            local storageKey = "_arcGlow_" .. gt .. "_" .. (info.key or "")
            local cached = info.frame[storageKey]
            if cached then
                cached:Hide()
                cached:ClearAllPoints()
                cached:SetParent(nil)
                info.frame[storageKey] = nil
            end
        end
        -- Stop all types so LCG recreates frames with fresh textures
        ns.Glows.Stop(info.frame, info.key)
    end

    -- Restart all glows (template types will be recreated, LCG types just refresh)
    for _, info in ipairs(toRestart) do
        ns.Glows.Start(info.frame, info.key, info.type, info.opts)
    end
end

--- Returns the options support matrix for a given glow type.
-- Used by options UI to show/hide the correct sliders per type.
-- @param glowType  string glow type
-- @return table of option name → boolean
function ns.Glows.GetSupportedOpts(glowType)
    if glowType == "blizzard" then glowType = "proc" end
    local SUPPORT = {
        pixel     = { color=true, intensity=true, scale=true, speed=true, lines=true, thickness=true, length=true, border=true, xOffset=true, yOffset=true, frameLevel=true, strata=true },
        autocast  = { color=true, intensity=true, scale=true, speed=true, particles=true, xOffset=true, yOffset=true, frameLevel=true, strata=true },
        button    = { color=true, scale=true, speed=true, frameLevel=true, strata=true, xOffset=true, yOffset=true },
        proc      = { color=true, intensity=true, scale=true, xOffset=true, yOffset=true, frameLevel=true, strata=true },
        ants      = { color=true, intensity=true, scale=true, xOffset=true, yOffset=true, frameLevel=true, strata=true },
        ach_proc  = { color=true, intensity=true, scale=true, xOffset=true, yOffset=true, frameLevel=true, strata=true },
        cdm_flash = { color=true, intensity=true, scale=true, speed=true, xOffset=true, yOffset=true, frameLevel=true, strata=true },
        default   = {},
    }
    return SUPPORT[glowType] or {}
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CDM NATIVE VISUAL ALERT SIZING
-- CDMVISFlashBaseMixin / CDMVISMarchingAntsBaseMixin use hardcoded ±8/9 px
-- offsets in GetAnchors designed for the default 30px CDM icon.
-- When ArcUI groups resize icons these stay fixed and look too small.
--
-- WHY we hook AcquireAlert on the global instance (not the mixin):
--   CreateFromMixins copies functions by value onto pool frame instances.
--   Hooking the mixin table with hooksecurefunc only intercepts calls that
--   go through that table — not calls on already-copied instances.
--   AcquireAlert fires after SetAlertTarget → AnchorAlert has already run,
--   so we re-anchor the latest alert from the target's container.
-- ═══════════════════════════════════════════════════════════════════════════

-- Default CDM icon size the ±8/9 offsets were designed for
local CDM_VIS_DEFAULT_SIZE = 30
local CDM_VIS_TL_OFF = -8  -- TOPLEFT  offset (negative = expand outward)
local CDM_VIS_BR_OFF =  9  -- BOTTOMRIGHT offset (positive = expand outward)

local function RescaleCDMVisAlert(target, alert)
    local targetFrame = target:GetAlertTargetFrame()
    if not targetFrame then return end

    local w, h = GetFrameSize(targetFrame)
    if not w or not h or w <= 1 or h <= 1 then return end

    -- Match our cdm_flash approach: expand by BLIZZ_CONTAINER_RATIO and center.
    -- Blizzard's fixed ±8/9px anchors only look right at the default 30px icon.
    alert:SetSize(w * BLIZZ_CONTAINER_RATIO, h * BLIZZ_CONTAINER_RATIO)
    alert:ClearAllPoints()
    alert:SetPoint("CENTER", targetFrame, "CENTER", 0, 0)
end

local cdmVisAlertsPatchApplied = false

function ns.Glows.PatchCDMVisualAlerts()
    if cdmVisAlertsPatchApplied then return end
    if not CooldownViewerVisualAlertsManager then return end
    cdmVisAlertsPatchApplied = true

    -- AcquireAlert fires after SetAlertTarget (and thus after AnchorAlert).
    -- We can't get the return value via hooksecurefunc, so we grab the most
    -- recently added alert from the target's container instead.
    hooksecurefunc(CooldownViewerVisualAlertsManager, "AcquireAlert", function(_, _, target)
        if not target then return end
        local container = target:GetAlertContainer()
        if not container then return end
        local alert = container[#container]
        if not alert then return end
        RescaleCDMVisAlert(target, alert)
    end)
end

-- Self-patch once CDM globals are available
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
        ns.Glows.PatchCDMVisualAlerts()
        f:UnregisterAllEvents()
    end)
end

-- Debug bridge: expose Glows API for standalone debugger addons
_G.ArcUI_Glows = ns.Glows