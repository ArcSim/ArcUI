-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_ArcAurasAuraGlows.lua
-- Pandemic-window glows for Arc AURA icons (12.1 AuraContainer buttons).
--
-- The engine API is AddPandemicRegion(region): hand the button any REGION
-- that is a descendant of it, and the ENGINE flips that region's shown flag
-- exactly at the pandemic (refresh) window edges. We never know when the
-- window is — zero reads, zero events, works under full secrecy.
--
-- The visual packs are the LAB-PROVEN builds (ArcUI_AuraLab_Slots), ported
-- 1:1: plain textures + animation groups living on btn.TextOverlay (the
-- swipe renders above button-parented textures, so packs must ride the
-- raised overlay — still a descendant, so registration stays legal).
--
-- Two consumers, composable in one registration pass:
--   * auraActiveState.glow + glowFollowPandemic  -> the user's glow style,
--     engine-shown only during the window ("glow when refreshable")
--   * pandemicBorder.enabled                     -> red edge frame at the
--     window (the classic 30% pandemic border)
--
-- Registration protocol (lab-proven): identity key per recipe; on change:
-- ClearPandemicRegions + stop/hide the old pack, then Show + AddPandemicRegion
-- each texture and Play the animation groups. Packs are cached per key on
-- the button — engine button recreation gets a fresh button = fresh cache.
--
-- SIZE RULE: engine button sizes are SECRET — all geometry comes from the
-- HOLDER's size (our frame, explicit SetSize, always readable).
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...
ns.AuraIconGlows = ns.AuraIconGlows or {}
local AIG = ns.AuraIconGlows

-- Dedicated GLOW LAYER: a frame one level ABOVE the TextOverlay. The active
-- border's edges are TextOverlay textures — packs built as sibling textures
-- tie with them (creation order decides) and rendered BEHIND the border.
-- A higher frame level wins decisively; glows draw over the border and text,
-- matching the CDM icon convention (Blizzard proc glows cover everything).
local function GlowHost(btn)
    local base = btn.TextOverlay or btn
    local g = btn._arcGlowLayer
    if not g then
        g = CreateFrame("Frame", nil, base)
        g:SetAllPoints(btn)
        btn._arcGlowLayer = g
    end
    g:SetFrameLevel(base:GetFrameLevel() + 1)
    return g
end

local DASH_H = "Interface\\AddOns\\ArcUI\\Textures\\glow_dash_h.tga"
local DASH_V = "Interface\\AddOns\\ArcUI\\Textures\\glow_dash_v.tga"

-- ───────────────────────────────────────────────────────────────────────────
-- PIXEL PACK (EQOL AuraCompat technique, ported): four REPEAT-wrapped dash
-- strips — one per edge — slid by looping Translation animations behind
-- static edge masks. The dashes are painted in the texture file, so the
-- lines are perfectly consistent (no corner artifacts, no per-line frames):
-- 4 textures + 4 animations total, vs the old N path-animated squares.
-- TexCoord base offsets per edge make the dashes flow seamlessly around the
-- corners; one texture repetition = one cycle (perimeter / lines).
-- A dark backdrop ring underneath gives the LCG border=true look (parity
-- with the ghost-side missing glow).
-- ───────────────────────────────────────────────────────────────────────────
local function BuildPixelPack(btn, host, cfg, W, H)
    local pack = { texs = {}, ags = {}, extra = {} }
    local N = math.max(1, cfg.lines or 8)
    local freq = cfg.speed or 0.25
    if not (freq > 0) then freq = 0.25 end
    local period = 1 / freq
    if period < 0.05 then period = 0.05 end
    -- tuned defaults (Arc, in-game vs the LCG ghost glow): thickness 3,
    -- line length 11 is the pack's LCG-parity look
    local th = cfg.thickness or 3
    local perimeter = 2 * (W + H)
    local cycle = perimeter / N
    local dur = math.max(0.01, period / N)
    -- LINE LENGTH: the dash textures carry 8 duty bands (11%..89% of a
    -- cycle, 8px bands on the cross axis) — the band is selected via
    -- texcoords: the one whose on-screen dash (duty * cycle) is closest
    -- to the requested length. 0/nil = the tuned default (11px).
    local L = cfg.length
    if not L or L <= 0 then L = 11 end
    local band = 3
    if cycle > 0 then
        local duty = L / cycle
        if duty < (1 / 9) then duty = 1 / 9 end
        if duty > (8 / 9) then duty = 8 / 9 end
        band = math.floor(duty * 9 + 0.5) - 1
        if band < 0 then band = 0 end
        if band > 7 then band = 7 end
    end
    local b0 = band / 8 + 0.004
    local b1 = (band + 1) / 8 - 0.004
    local edges = {
        { tex = DASH_H, len = W, dx = cycle, dy = 0, base = 0 },
        { tex = DASH_V, len = H, dx = 0, dy = -cycle, base = W / cycle },
        { tex = DASH_H, len = W, dx = -cycle, dy = 0, base = (W + H) / cycle },
        { tex = DASH_V, len = H, dx = 0, dy = cycle, base = ((W * 2) + H) / cycle },
    }

    -- ALL geometry anchors to HOST (the glow layer, SetAllPoints(btn) = same
    -- rect), NEVER to the button: masks may not inherit engine-driven
    -- anchors (the aspect wall) — button-anchored masks silently failed to
    -- crop and the strips' off-edge overhang leaked out past the corners
    -- (Arc's "rectangle overflowing the icon"). EQOL anchors to its own
    -- glow root for the same reason.

    -- dark backdrop ring (never recolored)
    for i = 1, 4 do
        local line = host:CreateTexture(nil, "OVERLAY", nil, 5)
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        line:SetVertexColor(0.1, 0.1, 0.1, 0.8)
        if i == 1 then
            line:SetPoint("TOPLEFT", host, "TOPLEFT")
            line:SetPoint("TOPRIGHT", host, "TOPRIGHT")
            line:SetHeight(th)
        elseif i == 2 then
            line:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT")
            line:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT")
            line:SetHeight(th)
        elseif i == 3 then
            line:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -th)
            line:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, th)
            line:SetWidth(th)
        else
            line:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -th)
            line:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, th)
            line:SetWidth(th)
        end
        table.insert(pack.extra, line)
    end

    for i = 1, 4 do
        local e = edges[i]
        local mask = host:CreateMaskTexture()
        mask:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:Show()
        local strip = host:CreateTexture(nil, "OVERLAY", nil, 7)
        strip:SetTexture(e.tex, "REPEAT", "REPEAT")
        strip:AddMaskTexture(mask)
        -- LCG parity: plain blend, no pixel-grid snapping (snapping turns
        -- the slow slide into visible stepping — lab lesson)
        strip:SetBlendMode("BLEND")
        strip:SetSnapToPixelGrid(false)
        strip:SetTexelSnappingBias(0)
        table.insert(pack.texs, strip)
        local cycles = (e.len + cycle) / cycle
        if i == 1 then
            mask:SetSize(e.len, th)
            mask:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
            strip:SetSize(e.len + cycle, th)
            strip:SetPoint("TOPLEFT", host, "TOPLEFT", e.dx > 0 and -cycle or 0, 0)
            strip:SetTexCoord(e.base, e.base + cycles, b0, b1)
        elseif i == 2 then
            mask:SetSize(th, e.len)
            mask:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
            strip:SetSize(th, e.len + cycle)
            if e.dy < 0 then
                strip:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, cycle)
            else
                strip:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, -cycle)
            end
            strip:SetTexCoord(b0, b1, e.base, e.base + cycles)
        elseif i == 3 then
            mask:SetSize(e.len, th)
            mask:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
            strip:SetSize(e.len + cycle, th)
            strip:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", e.dx > 0 and -cycle or 0, 0)
            strip:SetTexCoord(e.base, e.base + cycles, b0, b1)
        else
            mask:SetSize(th, e.len)
            mask:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
            strip:SetSize(th, e.len + cycle)
            if e.dy < 0 then
                strip:SetPoint("TOPLEFT", host, "TOPLEFT", 0, cycle)
            else
                strip:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, -cycle)
            end
            strip:SetTexCoord(b0, b1, e.base, e.base + cycles)
        end
        local ag = strip:CreateAnimationGroup()
        ag:SetLooping("REPEAT")
        table.insert(pack.ags, ag)
        local tr = ag:CreateAnimation("Translation")
        tr:SetSmoothing("NONE")
        tr:SetOffset(e.dx, e.dy)
        tr:SetDuration(dur)
    end
    return pack
end

-- ───────────────────────────────────────────────────────────────────────────
-- STYLE PACKS (lab BuildPandemicPack port). styleKey values:
--   "Pixel" | "AutoCast" | "Proc" | "Pulse" | "Spin" | "Edges"
-- ───────────────────────────────────────────────────────────────────────────
local function BuildPack(btn, styleKey, cfg, W, H)
    local host = GlowHost(btn)
    if styleKey == "Pixel" then
        return BuildPixelPack(btn, host, cfg, W, H)
    end
    local pack = { texs = {}, ags = {}, extra = {} }
    local function newTex(sub)
        local tex = host:CreateTexture(nil, "OVERLAY", nil, sub or 7)
        table.insert(pack.texs, tex)
        return tex
    end
    local function newAG()
        local ag = host:CreateAnimationGroup()
        ag:SetLooping("REPEAT")
        table.insert(pack.ags, ag)
        return ag
    end
    if styleKey == "Proc" then
        local tex = newTex()
        tex:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", -10, 10)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 10, -10)
        local ag = newAG()
        local fb = ag:CreateAnimation("FlipBook")
        fb:SetTarget(tex)
        fb:SetDuration(1)
        -- Blizzard's proc loop sheet is 6 ROWS x 5 COLUMNS (ActionButton XML)
        fb:SetFlipBookRows(6); fb:SetFlipBookColumns(5); fb:SetFlipBookFrames(30)
    elseif styleKey == "Pulse" then
        local tex = newTex()
        tex:SetAtlas("UI-HUD-ActionBar-Proc-Glow")
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", -12, 12)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 12, -12)
        local ag = newAG()
        ag:SetLooping("BOUNCE")
        local al = ag:CreateAnimation("Alpha")
        al:SetTarget(tex)
        al:SetFromAlpha(1); al:SetToAlpha(0.35); al:SetDuration(0.6)
    elseif styleKey == "Ants" then
        -- Blizzard's CDM marching-ants flipbook (EQOL-verified params:
        -- 6 rows x 5 columns x 30 frames, 1s loop, +17px padding).
        -- Desaturated so the user's color drives the tint.
        local tex = newTex()
        tex:SetAtlas("VisualAlert_Ants_Flipbook")
        tex:SetDesaturated(true)
        tex:SetSize(W + 17, H + 17)
        tex:SetPoint("CENTER", btn, "CENTER", 0, 0)
        local ag = newAG()
        local fb = ag:CreateAnimation("FlipBook")
        fb:SetTarget(tex)
        fb:SetDuration(1)
        fb:SetFlipBookRows(6); fb:SetFlipBookColumns(5); fb:SetFlipBookFrames(30)
    elseif styleKey == "Spin" then
        local tex = newTex()
        tex:SetTexture("Interface\\Cooldown\\star4")
        tex:SetBlendMode("ADD")
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", -14, 14)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 14, -14)
        local ag = newAG()
        local r = ag:CreateAnimation("Rotation")
        r:SetTarget(tex)
        r:SetDegrees(-360); r:SetDuration(4)
    elseif styleKey == "AutoCast" then
        -- LCG autocast rebuilt as animations: 4 additive sparkles orbiting a
        -- smoothed path through the button's corners
        local half = math.min(W, H) / 2 + 2
        local corners = { { -half, half }, { half, half }, { half, -half }, { -half, -half } }
        for di = 1, 4 do
            local sx, sy = corners[di][1], corners[di][2]
            local tex = newTex()
            tex:SetTexture("Interface\\Cooldown\\star4")
            tex:SetBlendMode("ADD")
            tex:SetSize(14, 14)
            tex:SetPoint("CENTER", btn, "CENTER", sx, sy)
            local ag = newAG()
            local path = ag:CreateAnimation("Path")
            path:SetTarget(tex)
            path:SetDuration(2.4)
            path:SetCurveType("SMOOTH")
            local cp0 = path:CreateControlPoint(nil, nil, 1)
            cp0:SetOffset(0, 0)
            for k = 1, 4 do
                local c = corners[((di - 1 + k) % 4) + 1]
                local cp = path:CreateControlPoint(nil, nil, k + 1)
                cp:SetOffset(c[1] - sx, c[2] - sy)
            end
        end
    else -- "Edges"
        local function edge(p1, p2, w, hh)
            local tex = newTex()
            tex:SetTexture("Interface\\Buttons\\WHITE8X8")
            if w then tex:SetWidth(w) end
            if hh then tex:SetHeight(hh) end
            tex:SetPoint(p1, btn, p1)
            tex:SetPoint(p2, btn, p2)
        end
        edge("TOPLEFT", "TOPRIGHT", nil, 2)
        edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
        edge("TOPLEFT", "BOTTOMLEFT", 2, nil)
        edge("TOPRIGHT", "BOTTOMRIGHT", 2, nil)
    end
    return pack
end

-- ArcUI glowType -> pack style (pandemic packs are our own texture builds,
-- not ns.Glows — map each dropdown style to its nearest pack)
local STYLE_MAP = {
    pixel = "Pixel", autocast = "AutoCast", proc = "Proc", ach_proc = "Proc",
    button = "Pulse", cdm_flash = "Pulse", ants = "Ants",
}

local function StopPack(pack)
    if not pack then return end
    for _, ag in ipairs(pack.ags or {}) do ag:Stop() end
    for _, tex in ipairs(pack.texs or {}) do tex:Hide() end
    for _, tex in ipairs(pack.extra or {}) do tex:Hide() end
end

-- ───────────────────────────────────────────────────────────────────────────
-- KILL-MASK (the lab-proven "glow that changes at the window"): a
-- TRANSPARENT mask (AM_29 = alpha 0 inside its rect) laid over the active
-- pack's textures and REGISTERED AS A PANDEMIC REGION. Masks obey their OWN
-- shown flag, so the engine showing the mask at window start zeroes the
-- active pack, and hiding it at window end brings it back. Generous rect
-- covers every pack style's overhang.
-- ───────────────────────────────────────────────────────────────────────────
local function BuildKillMask(btn, pack)
    local host = GlowHost(btn)
    local m = host:CreateMaskTexture()
    m:SetTexture("Interface\\AdventureMap\\BrokenIsles\\AM_29", "CLAMPTOWHITE", "CLAMPTOWHITE")
    -- anchored to HOST, not the button — masks may not inherit engine
    -- anchors (the aspect wall; same fix as the pixel strips' crop masks)
    m:SetPoint("TOPLEFT", host, "TOPLEFT", -24, 24)
    m:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 24, -24)
    for _, tex in ipairs(pack.texs) do tex:AddMaskTexture(m) end
    for _, tex in ipairs(pack.extra or {}) do tex:AddMaskTexture(m) end
    m:Hide()   -- the engine's pandemic SetShown drives it once registered
    return m
end

-- ───────────────────────────────────────────────────────────────────────────
-- APPLY (called from AuraIcons.ApplySettings' accessible branch — the
-- caller owns the forbidden gating; every call here may touch the button)
--
-- Composable consumers, one engine registration pass:
--   * rs.glow + timing "pandemic"            -> styled pack, window-only
--   * rs.glow + timing "always" + rs.pandemicSwap
--         -> ACTIVE pack always shown (NOT registered) + kill-mask
--            (registered: hides the active pack during the window) +
--            swap pack (registered: the window's replacement glow).
--            The glow visibly SWITCHES style/color at the window edges.
--   * pandemicBorder.enabled                 -> red edge frame, window-only
-- ───────────────────────────────────────────────────────────────────────────
function AIG.ApplyPandemic(btn, holder, settings)
    if not (btn and holder) then return end
    if not btn.AddPandemicRegion then return end   -- pre-12.1 client

    -- RE-PIN the glow layer EVERY call, before the identity early-return:
    -- ApplySettings re-levels the button's TextOverlay from the holder on
    -- every pass, and children do NOT follow a parent SetFrameLevel — with
    -- an unchanged pack identity the old code returned before re-asserting,
    -- leaving the glow buried under the border/text (glow existed but was
    -- invisible — audit finding)
    if btn._arcGlowLayer then GlowHost(btn) end

    -- the ACTIVE glow + timing modes live under cooldownStateVisuals.
    -- readyState.* in the aura option set (auraActiveState.* is the
    -- missing-glow side) — mirror the panel exactly
    local aa = (settings and settings.cooldownStateVisuals
        and settings.cooldownStateVisuals.readyState) or {}
    local pb = settings and settings.pandemicBorder or {}

    local function ColorOf(c, dr, dg, db)
        return { c and c.r or dr, c and c.g or dg, c and c.b or db }
    end
    local knobs = { lines = aa.glowLines, speed = aa.glowSpeed,
        thickness = aa.glowThickness, length = aa.glowLength }

    -- what should exist? records = { {style=, color=, register=, masked=} }
    -- register=true  -> engine-shown only during the pandemic window
    -- register=false -> always shown (visible whenever the button is — the
    --                   button hiding with the aura IS the on/off switch)
    local parts, recipes = {}, {}
    if aa.glow == true then
        if aa.glowFollowPandemic then
            local style = STYLE_MAP[aa.glowType or "pixel"] or "Pixel"
            local col = ColorOf(aa.glowColor, 1, 0.85, 0.1)
            recipes[#recipes + 1] = { style = style, color = col, register = true }
            parts[#parts + 1] = "glow:" .. style .. ":" .. table.concat(col, ",")
        elseif not aa.pandemicSwap then
            -- timing "always" (threshold modes are impossible here and run
            -- as always): plain active pack, never registered
            local style = STYLE_MAP[aa.glowType or "pixel"] or "Pixel"
            local col = ColorOf(aa.glowColor, 1, 0.85, 0.1)
            recipes[#recipes + 1] = { style = style, color = col, register = false }
            parts[#parts + 1] = "active:" .. style .. ":" .. table.concat(col, ",")
        elseif aa.pandemicSwap then
            local aStyle = STYLE_MAP[aa.glowType or "pixel"] or "Pixel"
            local aCol = ColorOf(aa.glowColor, 1, 0.85, 0.1)
            local wStyle = STYLE_MAP[aa.pandemicSwapType or aa.glowType or "pixel"] or aStyle
            local wCol = ColorOf(aa.pandemicSwapColor, 1, 0.2, 0.2)
            recipes[#recipes + 1] = { style = aStyle, color = aCol, register = false, masked = true }
            recipes[#recipes + 1] = { style = wStyle, color = wCol, register = true }
            parts[#parts + 1] = "swap:" .. aStyle .. ":" .. table.concat(aCol, ",")
                .. ">" .. wStyle .. ":" .. table.concat(wCol, ",")
        end
    end
    if pb.enabled then
        recipes[#recipes + 1] = { style = "Edges", color = { 1, 0.25, 0.25 }, register = true }
        parts[#parts + 1] = "border"
    end
    -- geometry is BAKED into a pack (line sizes, waypoint ring) while the
    -- masks stretch with the rect — a resize with a stale pack crushes the
    -- lines against the crops ("smooshed" pixel glow). Size is part of the
    -- identity so resizes rebuild.
    local W, H = holder:GetSize()
    W = (W and W > 0) and W or 36
    H = (H and H > 0) and H or W
    W = math.floor(W + 0.5)
    H = math.floor(H + 0.5)
    if #parts > 0 then
        parts[#parts + 1] = (aa.glowLines or 8) .. ":" .. (aa.glowSpeed or 0.25)
            .. ":" .. (aa.glowThickness or 3) .. ":" .. (aa.glowIntensity or 1)
            .. ":" .. (aa.glowLength or 0) .. ":" .. W .. "x" .. H
    end
    local want = (#parts > 0) and table.concat(parts, "|") or nil

    if btn._arcPandCur == want then return end

    -- change: clear the engine registry + stop whatever was showing
    if btn._arcPandCur then
        if btn.ClearPandemicRegions then btn:ClearPandemicRegions() end
        local old = btn._arcPandPacks and btn._arcPandPacks[btn._arcPandCur]
        if old then
            for _, rec in ipairs(old.records) do StopPack(rec.pack) end
            if old.mask then old.mask:Hide() end
        end
        btn._arcPandCur = nil
    end
    if not want then return end

    btn._arcPandPacks = btn._arcPandPacks or {}
    local built = btn._arcPandPacks[want]
    if not built then
        built = { records = {} }
        for _, r in ipairs(recipes) do
            local pack = BuildPack(btn, r.style, knobs, W, H)
            built.records[#built.records + 1] =
                { pack = pack, color = r.color, register = r.register }
            if r.masked then
                built.mask = BuildKillMask(btn, pack)
            end
        end
        btn._arcPandPacks[want] = built
    end

    -- re-assert the glow layer's level: holder levels move with group ops
    -- and cached packs skip the build path where GlowHost normally runs
    GlowHost(btn)

    local texAlpha = math.min(1, 0.95 * (aa.glowIntensity or 1))
    for _, rec in ipairs(built.records) do
        local c = rec.color
        for _, tex in ipairs(rec.pack.texs) do
            if c then tex:SetVertexColor(c[1], c[2], c[3], texAlpha) end
            tex:Show()
            if rec.register then btn:AddPandemicRegion(tex) end
        end
        for _, tex in ipairs(rec.pack.extra or {}) do
            tex:Show()
            if rec.register then btn:AddPandemicRegion(tex) end
        end
        for _, ag in ipairs(rec.pack.ags) do ag:Play() end
    end
    if built.mask then
        built.mask:Hide()
        btn:AddPandemicRegion(built.mask)
    end
    btn._arcPandCur = want
end

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF ArcUI_ArcAurasAuraGlows.lua
-- ═══════════════════════════════════════════════════════════════════════════
